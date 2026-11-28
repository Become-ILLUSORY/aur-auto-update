#!/usr/bin/env bash
# 运行时依赖完整性检查（真实安装）。
#
# 与 check-deps.sh 的分工：
#   check-deps.sh     只用 `pacman -Sp` 解析依赖名 —— 能发现「依赖不存在」，
#                     但发现不了「依赖存在、只是包的 depends 没声明」。
#   check-install-deps.sh（本脚本）
#                     真实构建并安装每个包，扫描包内所有 ELF 的 NEEDED
#                     是否都能解析 —— 能发现 depends 漏声明。
#
# 为什么需要后者：pacman 只校验 depends 能否解析，不关心二进制实际 NEEDED
# 了什么。典型例子是 flclash-myflavor-bin —— tray 插件直接链接
# libayatana-indicator3.so.7，而 libayatana-appindicator 从 0.6.0 起不再
# 传递依赖 libayatana-indicator。开发机上因为别的包装了它而一切正常，
# 干净系统上托盘插件却加载失败。
#
# 隔离策略：每个包都在「只装它自己声明的 depends」的环境里安装，测完立即
# 卸载（连同依赖）回到基线，再测下一个。不隔离的话，上一个包的依赖会掩盖
# 下一个包缺失的依赖，检查就形同虚设。
#
# 只读：不碰 AUR、不 push、不发布任何东西。

set -uo pipefail

AUR_BASE="${AUR_BASE:-https://aur.archlinux.org}"
OUT="${OUT:-/tmp/install-check}"
SUMMARY="${REPORT:-}"
BUILD_USER="${BUILD_USER:-builder}"

if [[ $EUID -ne 0 ]]; then
  echo "!! 需要 root 运行（要安装/卸载软件包）"
  exit 1
fi

rm -rf "$OUT" 2>/dev/null || true
mkdir -p "$OUT" 2>/dev/null || true
TSV="$OUT/install.tsv"
: > "$TSV" 2>/dev/null || { echo "!! 无法写入 $TSV"; exit 1; }

# 基线：检查开始前的已装包集合。每次测完还原到它，保证下一个包从干净状态开始。
mapfile -t BASELINE < <(pacman -Qq | sort)

reset_to_baseline() {
  local -a extra
  mapfile -t extra < <(comm -13 <(printf '%s\n' "${BASELINE[@]}") <(pacman -Qq | sort))
  ((${#extra[@]} == 0)) && return 0
  # -Rns 优先；万一有包被别的东西挡住（不该发生），退回 -Rdd 强删。
  # 容器是一次性的，这里只求回到基线，不求保留任何东西。
  pacman -Rns --noconfirm "${extra[@]}" >/dev/null 2>&1 \
    || pacman -Rdd --noconfirm "${extra[@]}" >/dev/null 2>&1 || true
}

mapfile -t PKGS < <(ls packages/pkg-*.sh 2>/dev/null | sed 's|.*/pkg-||; s|\.sh$||' | sort)
# 可只查指定包：ONLY="flclash-myflavor-bin uu-remote-linux-private-bin"（也接受逗号/空格混合）
if [[ -n "${ONLY:-}" ]]; then
  declare -a wanted=()
  read -ra wanted <<< "${ONLY//,/ }"
  declare -a filtered=()
  for w in "${wanted[@]}"; do
    [[ -z "$w" ]] && continue
    for p in "${PKGS[@]}"; do [[ "$p" == "$w" ]] && filtered+=("$p"); done
  done
  PKGS=("${filtered[@]}")
fi

if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "::error::没有找到 packages/pkg-*.sh（工作目录不对？或 ONLY 过滤后为空）"
  PKGS=()
  NOINPUT=1
else
  NOINPUT=0
  echo "共 ${#PKGS[@]} 个包待检查"
fi

# 从 .SRCINFO 取依赖名（去掉版本约束，排除含变量的动态项）
srcinfo_deps() {
  local file="$1" key="$2"
  sed -n "s/^[[:space:]]*${key}\(_[a-z0-9_]*\)\{0,1\} = //p" "$file" 2>/dev/null \
    | sed 's/[<>=].*//' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -vE '^\$|^$' || true
}

# PKGBUILD 里的 _gh_mirror 是 URL 前缀："${_gh_mirror}${url}"，默认值是面向
# 国内的 cdn.gh-proxy.org。CI runner 在美国，未必通得了国内镜像。
#
# 与其和前缀变量较劲（${VAR:-默认} 会把空串回落成默认，没法表示"不要前缀"），
# 不如先把 source 直连 GitHub 下载到 SRCDEST：makepkg 发现缓存命中就不再下载，
# 前缀写什么都不影响。直连失败再回落到镜像。
#
# 文件名规则与 makepkg 一致：source 写成 "文件名::URL" 时用文件名，否则取
# URL 的 basename。

strip_mirror_prefix() {
  local url="$1" m
  for m in "https://gh-proxy.cn" "https://gh-proxy.com" "https://cdn.gh-proxy.org"; do
    [[ "$url" == "$m/"* ]] && { printf '%s\n' "${url#"$m/"}"; return 0; }
  done
  printf '%s\n' "$url"
}

# 把 .SRCINFO 里的 http(s) source 下载到 srcdest。已存在则跳过。
prefetch_sources() {
  local srcinfo="$1" dest="$2"
  mkdir -p "$dest"
  local entry fname url real
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == *"::"* ]]; then
      fname="${entry%%::*}"
      url="${entry#*::}"
    else
      url="$entry"
      fname="${url##*/}"
    fi
    [[ "$url" == http* ]] || continue
    [[ -n "$fname" && -f "$dest/$fname" ]] && continue

    real="$(strip_mirror_prefix "$url")"
    if curl -fL --retry 2 --max-time 300 -o "$dest/$fname" "$real" 2>/dev/null; then
      echo "  ↓ 预下载 $fname（直连）"
    elif [[ "$real" != "$url" ]] && curl -fL --retry 2 --max-time 300 -o "$dest/$fname" "$url" 2>/dev/null; then
      echo "  ↓ 预下载 $fname（镜像）"
    else
      echo "  ?? 预下载失败 $fname，留给 makepkg 自己处理"
      rm -f "$dest/$fname"
    fi
  done < <(sed -n 's/^[[:space:]]*source\(_[a-z0-9_]*\)\{0,1\} = //p' "$srcinfo" 2>/dev/null)
}

# 判断某 soname 是否由当前包的 optdepends 提供。optdepends 是可选的，
# 缺它们属设计意图（如不装 alsa-lib 就没有声音），不算漏依赖。
# 结果按包缓存在 OPTDEPS_SONAMES，避免重复解析。
OPTDEPS_SONAMES=""

# 仓库文件数据库是否可用（pacman -Fl 能查未安装包的文件列表）。
# optdepends 大多没装，靠它反查 soname 归属。
FILE_DB_OK=0
if pacman -Fl alsa-lib >/dev/null 2>&1; then
  FILE_DB_OK=1
else
  echo "同步仓库文件数据库（pacman -Fy）..."
  if pacman -Fy --noconfirm >/dev/null 2>&1 && pacman -Fl alsa-lib >/dev/null 2>&1; then
    FILE_DB_OK=1
  else
    echo "!! 文件数据库不可用，未安装的 optdepends 将无法反查（可能误报）"
  fi
fi

soname_in_optdeps() {
  local soname="$1"
  [[ -z "$OPTDEPS_SONAMES" ]] && return 1
  grep -qxF "$soname" <<< "$OPTDEPS_SONAMES"
}

# 收集包 optdepends 对应的 soname 集合（写入 OPTDEPS_SONAMES）。
# 优先从 .SRCINFO 取 optdepends（格式规范，每行一项），回落到 pacman -Qi。
#
# optdepends 通常没装，pacman -Ql 查不到文件列表，所以用仓库文件数据库
# （pacman -Fl）反查它提供哪些 .so。数据库由脚本启动时统一同步一次。
collect_optdeps_sonames() {
  local pkg="$1" srcinfo="${2:-}"
  OPTDEPS_SONAMES=""
  local -a optpkgs=()

  if [[ -n "$srcinfo" && -f "$srcinfo" ]]; then
    mapfile -t optpkgs < <(sed -n 's/^[[:space:]]*optdepends\(_[a-z0-9_]*\)\{0,1\} = //p' "$srcinfo" \
      | sed 's/:.*//' | sed 's/[[:space:]]*$//' | grep -vE '^$|^\$')
  else
    mapfile -t optpkgs < <(pacman -Qi "$pkg" 2>/dev/null \
      | sed -n 's/^可选依赖[[:space:]]*: //p' \
      | sed 's/  /\n/g' | sed 's/:.*//' | grep -vE '^$|^无$')
  fi

  local p sons
  for p in "${optpkgs[@]}"; do
    # 已装的包用 -Ql 最准；没装的走 -Fl（仓库文件数据库）
    local src=""
    if pacman -Qq "$p" >/dev/null 2>&1; then
      src="$(pacman -Ql "$p" 2>/dev/null | awk '{print $2}')"
    elif (( FILE_DB_OK )); then
      src="$(pacman -Fl "$p" 2>/dev/null | awk '{print $2}')"
    fi
    [[ -n "$src" ]] || continue
    while IFS= read -r sons; do
      [[ -n "$sons" ]] && OPTDEPS_SONAMES+="$sons"$'\n'
    done < <(printf '%s\n' "$src" | sed -n 's|.*/\([^/]*\.so[.0-9]*\)$|\1|p')
  done
  OPTDEPS_SONAMES="$(printf '%s' "$OPTDEPS_SONAMES" | grep . | sort -u)"
}

# 扫描已装包的所有 ELF，把解析不到的 NEEDED 写进 TSV。
#
# 不用 ldd：ldd 对某些格式会实际执行二进制（上游产物不可信），这里改用
# readelf 静态取 NEEDED，再按动态链接器的搜索顺序找文件，结果确定且不执行代码。
# 包内私有 .so 目录加进搜索路径，模拟启动脚本的 LD_LIBRARY_PATH。
#
# 跳过 /usr/lib/debug/：makepkg 默认开 debug 包，那些 .debug 文件是 stripped
# 二进制的调试信息副本，不是运行时加载的库，它们的 NEEDED 与真实运行无关。
scan_package() {
  local pkg="$1" srcinfo="${2:-}"
  local -a files=() libdirs=() elfs=()
  collect_optdeps_sonames "$pkg" "$srcinfo"
  mapfile -t files < <(pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' \
    | grep -v '/$' | grep -v '^/usr/lib/debug/')

  local f
  for f in "${files[@]}"; do
    [[ "$f" == *.so || "$f" == *.so.* ]] && libdirs+=("$(dirname "$f")")
  done
  mapfile -t libdirs < <(printf '%s\n' "${libdirs[@]}" 2>/dev/null | grep . | sort -u)

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    readelf -h "$f" >/dev/null 2>&1 && elfs+=("$f")
  done

  if ((${#elfs[@]} == 0)); then
    echo "  (包内无 ELF，跳过二进制扫描)"
    printf '%s\t%s\t%s\tOK\n' "$pkg" "-" "-" >> "$TSV"
    return 0
  fi

  local missing=0 soname hit
  for f in "${elfs[@]}"; do
    while IFS= read -r soname; do
      [[ -z "$soname" ]] && continue
      hit=""
      for d in "${libdirs[@]}" /usr/lib /lib /usr/lib64; do
        [[ -e "$d/$soname" ]] && { hit="$d/$soname"; break; }
      done
      [[ -n "$hit" ]] && continue
      # 由已声明的 optdepends 提供的库算通过：可选功能缺失是设计意图，
      # 不是漏依赖（如 alsa-lib 之于音频支持）。
      if soname_in_optdeps "$soname"; then
        echo "  · $soname 由 optdepends 提供（可选功能，跳过）"
        continue
      fi
      printf '%s\t%s\t%s\tMISSING\n' "$pkg" "$soname" "${f#/}" >> "$TSV"
      echo "  !! $soname 未解析（需要它的文件：${f#/}）"
      missing=$((missing + 1))
    done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
  done

  if ((missing == 0)); then
    printf '%s\t%s\t%s\tOK\n' "$pkg" "-" "-" >> "$TSV"
    echo "  -> ${#elfs[@]} 个 ELF 的依赖全部可解析"
  fi
  return 0
}

for pkg in "${PKGS[@]}"; do
  echo "===== $pkg"
  work="$OUT/$pkg"
  rm -rf "$work"
  mkdir -p "$work"

  reset_to_baseline
  if ! git clone --depth 1 -q "$AUR_BASE/$pkg.git" "$work/repo" 2>"$work/clone.err"; then
    printf '%s\t%s\t%s\tERROR\n' "$pkg" "clone 失败" "-" >> "$TSV"
    echo "  !! 克隆 AUR 仓库失败"
    continue
  fi
  [[ -f "$work/repo/.SRCINFO" ]] || ( cd "$work/repo" && makepkg --printsrcinfo > .SRCINFO 2>/dev/null )

  mapfile -t deps < <(srcinfo_deps "$work/repo/.SRCINFO" depends)
  mapfile -t mdeps < <(srcinfo_deps "$work/repo/.SRCINFO" makedepends)

  # 构建阶段：depends + makedepends 都要装（--asdeps 便于稍后整体清除）
  build_deps=("${deps[@]}" "${mdeps[@]}")
  if ((${#build_deps[@]})); then
    if ! pacman -S --noconfirm --needed --asdeps "${build_deps[@]}" >"$work/deps.log" 2>&1; then
      printf '%s\t%s\t%s\tERROR\n' "$pkg" "依赖装不上" "-" >> "$TSV"
      echo "  !! depends/makedepends 装不上，日志尾部："
      tail -n 15 "$work/deps.log" | sed 's/^/     | /'
      reset_to_baseline
      continue
    fi
  fi

  chown -R "$BUILD_USER:$BUILD_USER" "$work"

  # 预下载 source 到 SRCDEST：直连 GitHub 优先，失败再试镜像。命中缓存后
  # makepkg 不再走 PKGBUILD 里那个国内镜像前缀，避免 CI（美国 runner）因
  # 镜像不通而误判成构建失败。
  srcdest="$work/srcdest"
  prefetch_sources "$work/repo/.SRCINFO" "$srcdest"
  chown -R "$BUILD_USER:$BUILD_USER" "$srcdest" 2>/dev/null || true

  if ! runuser -u "$BUILD_USER" -- env HOME="/home/$BUILD_USER" SRCDEST="$srcdest" \
      bash -c "cd '$work/repo' && makepkg -f --nodeps --noconfirm --nocheck" \
      >"$work/build.log" 2>&1; then
    # 下载失败不等于包有问题：CI 在境外，PKGBUILD 里的国内镜像可能不通。
    # 明确区分，避免把网络问题误读成依赖缺失。
    if grep -qiE "failure while downloading|failed to retrieve|Could not resolve host|Connection timed out" "$work/build.log"; then
      printf '%s\t%s\t%s\tERROR\n' "$pkg" "下载失败（网络/镜像）" "-" >> "$TSV"
      echo "  !! 源码下载失败（网络问题，非依赖问题），日志尾部："
    else
      printf '%s\t%s\t%s\tERROR\n' "$pkg" "构建失败" "-" >> "$TSV"
      echo "  !! 构建失败，日志尾部："
    fi
    tail -n 25 "$work/build.log" | sed 's/^/     | /'
    reset_to_baseline
    rm -rf "$work"
    continue
  fi

  mapfile -t built < <(ls "$work/repo"/*.pkg.tar.* 2>/dev/null | grep -v '\.sig$')
  if ((${#built[@]} == 0)); then
    printf '%s\t%s\t%s\tERROR\n' "$pkg" "无构建产物" "-" >> "$TSV"
    echo "  !! 构建后没找到 .pkg.tar.*"
    reset_to_baseline
    rm -rf "$work"
    continue
  fi

  # 检查阶段：先清掉构建用的 makedepends，只装声明的 depends
  reset_to_baseline
  if ((${#deps[@]})); then
    pacman -S --noconfirm --needed --asdeps "${deps[@]}" >"$work/deps2.log" 2>&1 || true
  fi

  # split package 会产出多个 .pkg.tar.*，全部装上再扫描（否则漏测其余子包）
  if ! pacman -U --noconfirm --asdeps "${built[@]}" >"$work/install.log" 2>&1; then
    printf '%s\t%s\t%s\tERROR\n' "$pkg" "安装失败" "-" >> "$TSV"
    echo "  !! pacman -U 安装失败，日志尾部："
    tail -n 15 "$work/install.log" | sed 's/^/     | /'
    reset_to_baseline
    rm -rf "$work"
    continue
  fi

  built_names=()
  for b in "${built[@]}"; do
    n="$(pacman -Qp "$b" 2>/dev/null | head -n1 | awk '{print $1}')"
    [[ -n "$n" ]] && built_names+=("$n")
  done
  ((${#built_names[@]})) || built_names=("$pkg")

  for n in "${built_names[@]}"; do
    scan_package "$n" "$work/repo/.SRCINFO"
  done

  reset_to_baseline
  rm -rf "$work"
done

sort -u "$TSV" -o "$TSV" 2>/dev/null || true
total=$(grep -c . "$TSV" 2>/dev/null || true)
missing=$(grep -c $'\tMISSING$' "$TSV" 2>/dev/null || true)
errors=$(grep -c $'\tERROR$' "$TSV" 2>/dev/null || true)
ok_pkgs=$(awk -F'\t' '$4=="OK"{print $1}' "$TSV" | sort -u | wc -l)
bad_pkgs=$(awk -F'\t' '$4=="MISSING"{print $1}' "$TSV" | sort -u | wc -l)
: "${total:=0}" "${missing:=0}" "${errors:=0}" "${ok_pkgs:=0}" "${bad_pkgs:=0}"

{
  echo "## 运行时依赖检查（真实安装）"
  echo
  echo "- 检查时间：$(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "- 包数量：${#PKGS[@]}"
  echo "- 依赖完整：${ok_pkgs}"
  echo "- 缺依赖：${bad_pkgs}"
  echo "- 未解析的 soname：${missing}"
  echo "- 检查出错：${errors}"
  echo
  if (( NOINPUT == 1 )); then
    echo "> **没有找到 packages/pkg-*.sh**，检查未执行。"
  elif (( bad_pkgs > 0 )); then
    echo "> **有 ${bad_pkgs} 个包在只装声明依赖的干净环境里出现未解析的 soname**，"
    echo "> 这些包在别人机器上会加载失败，需要补 depends。"
  elif (( errors > 0 )); then
    echo "> 已检查的包依赖完整，但有 ${errors} 个包未能完成检查（构建/安装失败），结果不完整。"
  else
    echo "> 所有包在只装声明依赖的干净环境里都能完整加载。"
  fi
  echo
  if (( missing > 0 )); then
    echo "| 包 | 未解析的 soname | 需要它的文件 | 结果 |"
    echo "|---|---|---|---|"
    awk -F'\t' '$4=="MISSING"{printf "| %s | `%s` | `%s` | ❌ |\n", $1, $2, $3}' "$TSV"
    echo
  fi
  errs=$(awk -F'\t' '$4=="ERROR"' "$TSV")
  if [[ -n "$errs" ]]; then
    echo "| 包 | 阶段 | 结果 |"
    echo "|---|---|---|"
    awk -F'\t' '$4=="ERROR"{printf "| %s | %s | ⚠️ |\n", $1, $2}' "$TSV"
  fi
} > "$OUT/report.md"

cat "$OUT/report.md"
if [[ -n "$SUMMARY" ]]; then
  cat "$OUT/report.md" >> "$SUMMARY"
fi

# 有意不因检查结果而失败：报告即结论，是否处理由人决定。
exit 0
