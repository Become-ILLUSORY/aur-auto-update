#!/usr/bin/env bash
# 依赖可解析性检查（只读）。
#
# 在 archlinux 容器里用 pacman 实际解析每个包的 depends / optdepends / makedepends，
# 判断能否在官方仓库解析到（包含 provides 提供的虚拟包，例如 sdl2 由 sdl2-compat 提供）。
#
# 设计原则：任何单点失败都不中止，全部跑完后统一输出一份 markdown 报告。
# 不修改 AUR、不构建、不 push。

set -uo pipefail

AUR_BASE="${AUR_BASE:-https://aur.archlinux.org}"
OUT="${OUT:-/tmp/deps-report}"
SUMMARY="${REPORT:-}"

rm -rf "$OUT"
mkdir -p "$OUT"
TSV="$OUT/deps.tsv"
: > "$TSV"

mapfile -t PKGS < <(ls packages/pkg-*.sh 2>/dev/null | sed 's|.*/pkg-||; s|\.sh$||' | sort)
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "!! 没有找到 packages/pkg-*.sh（工作目录不对？）"
  exit 1
fi
echo "共 ${#PKGS[@]} 个包待检查"

for pkg in "${PKGS[@]}"; do
  echo "===== $pkg"
  work="$OUT/$pkg"
  rm -rf "$work"
  mkdir -p "$work"

  if ! curl -fsSL --retry 3 --max-time 60 \
      "$AUR_BASE/cgit/aur.git/plain/PKGBUILD?h=$pkg" -o "$work/PKGBUILD"; then
    printf '%s\t%s\t%s\tERROR\t%s\n' "$pkg" "-" "-" "取不到 AUR PKGBUILD" >> "$TSV"
    echo "  !! 取不到 PKGBUILD"
    continue
  fi

  if ! ( cd "$work" && makepkg --printsrcinfo > .SRCINFO 2>"$work/makepkg.err" ); then
    # install=/changelog= 指向的文件不在 AUR 网页接口里，先按名字补齐再试一次
    if grep -qiE "install script|changelog|No such file" "$work/makepkg.err" 2>/dev/null; then
      inst="$(sed -n "s/^[[:space:]]*install=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*$/\1/p" "$work/PKGBUILD" | head -n1)"
      [[ -n "$inst" ]] && curl -fsSL --retry 2 --max-time 30 \
        "$AUR_BASE/cgit/aur.git/plain/$inst?h=$pkg" -o "$work/$inst" 2>/dev/null || true
    fi
    if ! ( cd "$work" && makepkg --printsrcinfo > .SRCINFO 2>"$work/makepkg.err" ); then
      printf '%s\t%s\t%s\tERROR\t%s\n' "$pkg" "-" "-" \
        "makepkg 失败: $(tr '\n' ' ' < "$work/makepkg.err" | cut -c1-160)" >> "$TSV"
      echo "  !! makepkg --printsrcinfo 失败"
      continue
    fi
  fi

  # .SRCINFO 每行形如 "\tdepends = glibc"（行首是 TAB），先去掉前导空白再匹配。
  mapfile -t ENTRIES < <(sed 's/^[[:space:]]*//' "$work/.SRCINFO" | awk -F' = ' '
    $1 ~ /^(depends|makedepends|optdepends)(_[a-z0-9_]+)?$/ {
      key = $1
      sub(/_[a-z0-9_]+$/, "", key)
      print key "\t" $2
    }')

  if [[ ${#ENTRIES[@]} -eq 0 ]]; then
    echo "  (无依赖条目)"
    continue
  fi

  while IFS=$'\t' read -r cat raw; do
    [[ -z "${raw:-}" ]] && continue

    # optdepends 形如 "alsa-lib: sound support"，取冒号前
    name="${raw%%:*}"
    # 去掉版本约束 "foo>=1.2"
    name="${name%%[<>=]*}"
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    [[ -z "$name" ]] && continue

    # -Sp 只解析不安装；rc=0 即代表 pacman 能在仓库里满足该目标（含 provides）
    printed="$(pacman -Sp --print-format '%n' --noconfirm "$name" 2>/dev/null)"
    rc=$?

    if (( rc == 0 )); then
      resolved="$(printf '%s\n' "$printed" | head -n1)"
      [[ -z "$resolved" ]] && resolved="$name"
      printf '%s\t%s\t%s\tOK\t%s\n' "$pkg" "$name" "$cat" "$resolved" >> "$TSV"
    else
      printf '%s\t%s\t%s\tMISSING\t-\n' "$pkg" "$name" "$cat" >> "$TSV"
      echo "::warning::$pkg 的依赖 $name 在官方仓库解析不到"
    fi
  done < <(printf '%s\n' "${ENTRIES[@]}")
done

sort -u "$TSV" -o "$TSV"
total=$(grep -c . "$TSV" || true)
missing=$(grep -c $'\tMISSING\t' "$TSV" || true)
errors=$(grep -c $'\tERROR\t' "$TSV" || true)
# 硬依赖解析不到才是真问题；可选/构建依赖缺失只作提示
hard_missing=$(awk -F'\t' '$4=="MISSING" && $3=="depends"' "$TSV" | wc -l)
soft_missing=$(( missing - hard_missing ))

{
  echo "## 依赖解析检查报告"
  echo
  echo "- 检查时间：$(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "- 包数量：${#PKGS[@]}"
  echo "- 依赖条目：${total}"
  echo "- 硬依赖（depends）解析失败：${hard_missing}"
  echo "- 可选/构建依赖解析失败：${soft_missing}"
  echo "- 检查出错：${errors}"
  echo
  if (( hard_missing > 0 )); then
    echo "> **有 ${hard_missing} 条 depends 无法在官方仓库解析**，这些包会装不上，见下方 ❌ 行。"
  elif (( missing > 0 )); then
    echo "> 全部 depends 均可解析；有 ${missing} 条可选/构建依赖解析不到（多为 AUR 包或未收录，通常不影响安装）。"
  elif (( errors > 0 )); then
    echo "> 没有发现解析失败的依赖，但有 ${errors} 个包未能完成检查，见下方 ⚠️ 行。"
  else
    echo "> 全部依赖均可在官方仓库解析（已包含 provides 提供的虚拟包）。"
  fi
  echo
  echo "| 包 | 依赖 | 类别 | 结果 | 解析到 |"
  echo "|---|---|---|---|---|"
  while IFS=$'\t' read -r p n c r res; do
    case "$r" in
      OK)      icon="✅" ;;
      MISSING) [[ "$c" == "depends" ]] && icon="❌" || icon="🔸" ;;
      *)       icon="⚠️" ;;
    esac
    printf '| %s | `%s` | %s | %s %s | %s |\n' "$p" "$n" "$c" "$icon" "$r" "$res"
  done < "$TSV"
} > "$OUT/report.md"

cat "$OUT/report.md"
if [[ -n "$SUMMARY" ]]; then
  cat "$OUT/report.md" >> "$SUMMARY"
fi

# 有意不因检查结果而失败：报告即结论，是否处理由人决定。
exit 0
