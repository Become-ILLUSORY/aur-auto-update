# designcraft-private-bin 自动更新配置
#   上游: storytold/designcraft  GitHub release 资产(官方 .pkg.tar.zst 重打包，只信任官方 SHA256SUMS.txt)
source "${ROOT}/lib/common.sh"

run() {
  local repo="storytold/designcraft"
  local last_tag last_ver cur
  last_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  last_ver="${last_tag#v}"
  [[ -n "$last_ver" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  cur="$(srcinfo_val pkgver)"
  echo "  designcraft-private-bin: 当前 $cur，上游 $last_ver"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  local asset="designcraft-${last_ver}-linux-x86_64.pkg.tar.zst"
  gh api "repos/$repo/releases/tags/$last_tag" \
    --jq ".assets[] | select(.name == \"$asset\") | .name" | grep -q . \
    || { echo "  !! 上游 release 缺少资产 $asset"; return 1; }

  set_var PKGBUILD pkgver "$last_ver"
  local sums tag
  sums="$(curl -fsSL --retry 3 "https://github.com/$repo/releases/download/$last_tag/SHA256SUMS.txt")"
  tag="$(printf '%s' "$sums" | awk -v a="$asset" '$2 == a {print $1}')"
  [[ -n "$tag" ]] || { echo "  !! SHA256SUMS.txt 里找不到 $asset"; return 1; }
  set_var PKGBUILD sha256sums "('$tag')"
  gen_srcinfo
  echo "  -- 已更新 to $last_ver (sha256=$tag)"
}
