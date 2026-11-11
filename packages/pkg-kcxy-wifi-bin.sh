# kcxy-wifi-bin 自动更新配置
#   上游: Become-ILLUSORY/kcxy-wifi（自己的项目）GitHub release，三架构资产
#   当前 AUR 版: 1.0.5-1
source "${ROOT}/lib/common.sh"

run() {
  local repo="Become-ILLUSORY/kcxy-wifi"
  local last_tag last_ver
  last_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  last_ver="${last_tag#v}"
  [[ -n "$last_ver" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  local cur
  cur="$(srcinfo_val pkgver)"
  echo "  kcxy-wifi: 当前 $cur，上游 $last_ver"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  # 资产名: kcxy-wifi-linux-{amd64,arm64,armv7}.tar.gz
  local -A arch2asset=( [x86_64]=amd64 [aarch64]=arm64 [armv7h]=armv7 )
  local base_url="https://github.com/$repo/releases/download/$last_tag"
  local srcsum ok=1
  local sarch url
  for sarch in x86_64 aarch64 armv7h; do
    srcsum="sha256sums_${sarch}"
    url="$base_url/kcxy-wifi-linux-${arch2asset[$sarch]}.tar.gz"
    local sha2
    sha2="$(curl -fsSL --retry 3 "$url.sha256" | awk '{print $1}' || true)"
    [[ -n "$sha2" ]] || sha2="$(shasum_of_url "$url")" || { echo "  !! $sarch 校验失败"; ok=0; break; }
    set_var PKGBUILD "$srcsum" "('$sha2')"
    echo "    $sarch -> $sha2"
  done
  [[ "$ok" -eq 1 ]] || { echo "  !! checksum 更新中断，回退版本号"; set_var PKGBUILD pkgver "$cur"; return 1; }

  set_var PKGBUILD pkgver "$last_ver"
  gen_srcinfo
  echo "  -- 已更新 to $last_ver"
}