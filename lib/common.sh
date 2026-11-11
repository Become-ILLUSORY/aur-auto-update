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
  local pkg="$1" dir="$2"
  git clone "https://aur.archlinux.org/${pkg}.git" "$dir"
  git -C "$dir" remote add aur "ssh://aur@aur.archlinux.org/${pkg}.git"
}