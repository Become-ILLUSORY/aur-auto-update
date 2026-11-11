# wowtype-core 自动更新配置
#   上游: Gloridust/WowType  GitHub release 资产(官方 .pkg.tar.zst，词库已内置)
#   当前 AUR 版: 0.3.10-1
source "${ROOT}/lib/common.sh"

run() {
  local repo="Gloridust/WowType"
  local last_ver last_tag
  last_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  last_ver="${last_tag#v}"
  [[ -n "$last_ver" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  local cur
  cur="$(srcinfo_val pkgver)"
  echo "  wowtype-core: 当前 $cur，上游 $last_ver"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  # 资产名固定含 pkgrel=1
  local asset="wowtype-${last_ver}-1-x86_64.pkg.tar.zst"
  gh api "repos/$repo/releases/tags/$last_tag" \
    --jq ".assets[] | select(.name == \"$asset\") | .name" | grep -q . \
    || { echo "  !! 上游 release 缺少资产 $asset"; return 1; }

  set_var PKGBUILD pkgver "$last_ver"
  # 新文件的实际 checksum 从上游 SHA256SUMS 资产取，不用下载 37MB 本体
  local sums tag
  sums="$(curl -fsSL --retry 3 "https://github.com/$repo/releases/download/$last_tag/SHA256SUMS")"
  tag="$(printf '%s' "$sums" | awk -v a="$asset" '$2 == a {print $1}')"
  [[ -n "$tag" ]] || { echo "  !! SHA256SUMS 里找不到 $asset"; return 1; }
  set_var PKGBUILD sha256sums "('$tag')"
  gen_srcinfo
  echo "  -- 已更新 to $last_ver (sha256=$tag)"
}