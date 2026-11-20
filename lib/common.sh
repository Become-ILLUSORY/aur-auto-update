#!/usr/bin/env bash
# 共享函数库：AUR 包自动更新用。
# 被 packages/<pkg>/update.sh 以 . lib/common.sh 方式引入。

set -euo pipefail

# ---------- GitHub API ----------

# 读取 GitHub repo 指定路径下的 release asset：传入 asset name，打印 URL 或空。
# 用于确认新版本的文件名仍然存在（防止上游改名导致 update 落空）。
gh_asset_url() {
  local repo="$1" version="$2" asset="$3"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/tags/v${version}" \
    | jq -r --arg a "$asset" \
        '.assets[] | select(.name == $a) | .browser_download_url' 2>/dev/null || true
}

# 从当前目录的 .SRCINFO 读某个 key 的值（.SRCINFO 里是 "\tpkgver = 1.2.3" 制表缩进）。
srcinfo_val() {
  awk -v k="$1" '$1 == k { print $3; exit }' .SRCINFO
}

# ---------- 版本对比 ----------

# 语义化版本比较 A B：A>B 输出 1，A==B 输出 0，A<B 输出 -1。
# 按 . 分段逐段数位比较（数字段按数值，非数字段按字典序）。
ver_cmp() {
  local i
  local -a av bv
  IFS='.' read -r -a av <<< "$1"
  IFS='.' read -r -a bv <<< "$2"
  for (( i = 0; i < ${#av[@]} || i < ${#bv[@]}; i++ )); do
    local a="${av[$i]:-}" b="${bv[$i]:-}"
    if [[ -z "$a" ]] && [[ -z "$b" ]]; then break
    elif [[ -z "$a" ]]; then echo -1; return
    elif [[ -z "$b" ]]; then echo 1; return
    fi
    if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]]; then
      if (( 10#$a > 10#$b )); then echo 1; return
      elif (( 10#$a < 10#$b )); then echo -1; return; fi
    elif [[ "$a" > "$b" ]]; then echo 1; return
    elif [[ "$a" < "$b" ]]; then echo -1; return; fi
  done
  echo 0
}

# ---------- PKGBUILD 编辑 ----------

# 在 PKGBUILD 里把 key=value 替换为新值（key 须以变量名 + = 独立成行）。
set_var() {
  local file="$1" key="$2" value="$3"
  sed -i "s/^${key}=.*/${key}=${value}/" "$file"
}

# 生成 .SRCINFO（必须在含 PKGBUILD 的目录里运行）
gen_srcinfo() {
  makepkg --printsrcinfo > .SRCINFO
}

# ---------- checksum ----------

# 替换 PKGBUILD 里某个 sha256sums=('a' 'b' ...) 数组的第 idx 个值（idx 从 1 开始）。
# 用 python 处理带引号的多行数组，最稳。返回值非零则替换失败。
set_checksum_item() {
  local file="$1" var="$2" idx="$3" value="$4"
  python3 - "$file" "$var" "$idx" "$value" <<'PY'
import re, sys
file, var, idx, value = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
src = open(file, encoding='utf-8').read()
m = re.search(r'^' + re.escape(var) + r'=\s*\(', src, re.M)
if not m:
    sys.exit(2)
# 找配对的右括号：只考虑引号外，且 SHA256 数组内无嵌套括号
start = m.end() - 1  # 左括号位置
i = start + 1
depth = 1
inquote = False
q = ''
# 定位数组右括号
end = -1
while i < len(src):
    c = src[i]
    if inquote:
        if c == '\\':
            i += 2
            continue
        if c == q:
            inquote = False
    elif c in ("'", '"'):
        inquote = True
        q = c
    elif c == '(':
        depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            end = i
            break
    i += 1
if end < 0:
    sys.exit(3)
array = src[start:end+1]
items = re.findall(r"'([^']*)'|\"([^\"]*)\"", array)
quoted = [(a or b) for a, b in items]
if idx > len(quoted):
    sys.exit(4)
quoted[idx-1] = value
# 依序替换原引号内容
it = iter(quoted)
def repl(mm):
    out = next(it)
    return out.replace("\\", "\\\\").replace("'", "'\\''")
new_array = re.sub(r"'([^']*)'", lambda mm: "'" + repl(mm) + "'", array)
src = src[:start] + new_array + src[end+1:]
open(file, 'w', encoding='utf-8').write(src)
PY
}

# 下载 URL 并返回其 SHA256，任何失败返回非零，调用方可回退或 SKIP。
shasum_of_url() {
  local url="$1" tmp hash
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$tmp" || return 1
  hash="$(sha256sum "$tmp" | awk '{print $1}')" || return 1
  printf '%s\n' "$hash"
}

# ---------- AUR 提交 ----------

# 把工作目录里的改动提交并推送到 AUR（需已 remote add aur，走 SSH）。
# 跳过空提交。commit message 末尾不加任何外部署名。
aur_push_if_changed() {
  local msg="$1"
  if [[ -z "$(git status --porcelain)" ]]; then
    echo "  -> 无改动，跳过提交"
    return 0
  fi
  git add -A
  git commit -m "$msg"
  if [[ "${AUR_PUSH:-1}" == "1" ]]; then
    git push aur master
  else
    echo "  (dry-run) 跳过 push"
  fi
}

# 从 https 省流克隆一个 AUR 仓库并给 push 用的 aur remote
aur_clone() {
  local pkg="$1" dir="$2" i
  for i in 1 2 3; do
    git clone "https://aur.archlinux.org/${pkg}.git" "$dir" && {
      git -C "$dir" remote add aur "ssh://aur@aur.archlinux.org/${pkg}.git"
      return 0
    }
    rm -rf "$dir"
    sleep 5
  done
  return 1
}

# ---------- 上游资产重发检测 ----------
#
# 上游可能用同一个 tag/版本号"重发" release：删掉旧 release 重建，资产内容
# 变了但版本号不变。各包脚本按版本号比较会判定"无需更新"提前 return，AUR 里
# 锁的 sha256 就永久失效，用户 makepkg 必然校验失败。
#
# 这里不依赖包脚本，直接解析 .SRCINFO 里每个 source 的 URL 与 sha256，用
# GitHub API 的 asset digest（GitHub 侧计算的真值）比对。只在能定位到同一个
# release 资产时才判定；任何查询失败一律放行，避免网络抖动误判。

# 带重试的 GitHub API 调用：api.github.com 偶发 EOF，单次失败不代表上游异常。
gh_api_retry() {
  local i out
  for i in 1 2 3; do
    out="$(gh api "$@" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
    sleep $((i * 2))
  done
  return 1
}

# 剥掉 gh-proxy 之类加速前缀，还原真实上游 URL。
_strip_mirror() {
  local u="$1"
  [[ "$u" == *"gh-proxy.com/"* ]] && u="${u#*gh-proxy.com/}"
  printf '%s\n' "$u"
}

# URL 路径段百分号解码，用于匹配 GitHub 返回的资产原名。
_urldecode() { printf '%b' "${1//%/\\x}"; }

# 解析 GitHub release 资产 URL：成功输出 "owner\trepo\ttag\tasset"，否则输出空。
# 用 awk 而非 [[ =~ ]] + BASH_REMATCH：后者在 set -u 下遇到未匹配会
# 报 "BASH_REMATCH[1]: parameter not set"，在 CI 里是偶发失败源。
# 注意 awk 无匹配时仍退出 0，调用方必须判空而非判退出码。
_parse_gh_release_url() {
  _strip_mirror "$1" | awk -F/ '
    $1 == "https:" && $3 == "github.com" && $6 == "releases" \
      && $7 == "download" && NF >= 9 {
      asset = $9
      for (i = 10; i <= NF; i++) asset = asset "/" $i
      printf "%s\t%s\t%s\t%s\n", $4, $5, $8, asset
    }'
}

# 按 arch 分组输出 .SRCINFO 里成对的 source/sha256sums：
#   "组\t序号\tURL\tsha256"（组为空串代表无 arch 后缀的 sha256sums）
_srcinfo_sources() {
  awk '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line !~ /^(source|sha256sums)(_[A-Za-z0-9_]+)? = /) next
      eq = index(line, " = ")
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 3)
      if (key ~ /^source/) {
        g = key; sub(/^source_?/, "", g)
        n[g]++; u[g, n[g]] = val
      } else {
        g = key; sub(/^sha256sums_?/, "", g)
        m[g]++; h[g, m[g]] = val
      }
      if (!(g in seen)) { seen[g] = 1; order[++k] = g }
    }
    END {
      for (j = 1; j <= k; j++) {
        g = order[j]
        for (i = 1; i <= n[g]; i++)
          printf "%s\t%d\t%s\t%s\n", g, i, u[g, i], h[g, i]
      }
    }
  ' .SRCINFO
}

# 校验当前目录 .SRCINFO 锁定的校验和是否仍与上游资产一致。
# 返回 0 = 发现重发且已写回 PKGBUILD；1 = 无需改动；2 = 写回失败。
detect_upstream_republish() {
  local -a bad_group=() bad_idx=() bad_sha=()
  local -A seen_rel=()
  local group idx url sha parsed owner repo tag asset key listing upstream

  while IFS=$'\t' read -r group idx url sha; do
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || continue
    parsed="$(_parse_gh_release_url "$url")"
    [[ -n "$parsed" ]] || continue
    IFS=$'\t' read -r owner repo tag asset <<< "$parsed"
    asset="$(_urldecode "$asset")"

    key="$owner/$repo@$tag"
    if [[ -n "${seen_rel[$key]-}" ]]; then
      listing="${seen_rel[$key]}"
    else
      listing="$(gh_api_retry "repos/$owner/$repo/releases/tags/$tag" \
                   --jq '.assets[] | "\(.name)\t\(.digest // "")"' || true)"
      # 上游删了该 release 或网络抖动：不当作重发，放行
      [[ -n "$listing" ]] || { echo "  ?? 无法查询 $key，跳过该校验和" >&2; continue; }
      seen_rel[$key]="$listing"
    fi

    upstream="$(printf '%s\n' "$listing" | awk -F'\t' -v a="$asset" '$1 == a { print $2; exit }')"
    [[ -n "$upstream" ]] || { echo "  ?? $key 中未找到资产 $asset，跳过该校验和" >&2; continue; }
    [[ "$upstream" == sha256:* ]] || { echo "  ?? $asset 无 digest，跳过该校验和" >&2; continue; }
    upstream="${upstream#sha256:}"

    if [[ "$upstream" != "$sha" ]]; then
      echo "  !! 上游重发同版本资产：$asset" >&2
      echo "     AUR 锁定 $sha" >&2
      echo "     上游现在 $upstream" >&2
      bad_group+=("$group"); bad_idx+=("$idx"); bad_sha+=("$upstream")
    fi
  done < <(_srcinfo_sources)

  ((${#bad_sha[@]} > 0)) || return 1

  local i var
  for i in "${!bad_sha[@]}"; do
    var="sha256sums"
    [[ -n "${bad_group[$i]}" ]] && var="sha256sums_${bad_group[$i]}"
    set_checksum_item PKGBUILD "$var" "${bad_idx[$i]}" "${bad_sha[$i]}" \
      || { echo "  !! 写入 ${var}[${bad_idx[$i]}] 失败" >&2; return 2; }
  done
  return 0
}