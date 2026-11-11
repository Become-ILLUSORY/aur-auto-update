# linux-wallpaperengine-v3-bin 自动更新配置
#   上游: Become-ILLUSORY/linux-wallpaperengine（自己的 fork 构建）GitHub release
#   资产: linux-wallpaperengine-<ver>-x86_64.tar.zst（CachyOS x86-64-v3 CI 构建）
#   当前 AUR 版: 1.0.1-1
source "${ROOT}/lib/common.sh"

run() {
  local repo="Become-ILLUSORY/linux-wallpaperengine"
  local last_tag last_ver
  last_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  last_ver="${last_tag#v}"
  [[ -n "$last_ver" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  local cur
  cur="$(srcinfo_val pkgver)"
  echo "  wallpaperengine: 当前 $cur，上游 $last_ver"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  local asset="linux-wallpaperengine-${last_ver}-x86_64.tar.zst"
  local base_url="https://github.com/$repo/releases/download/$last_tag"
  # 上游 release 没有伴随 .sha256 文件，直接下载目标资产算
  shasum_of_url "$base_url/$asset" \
    || { echo "  !! 无法算出 $asset 校验和"; return 1; }
  local sha2
  sha2="$(shasum_of_url "$base_url/$asset")"

  set_var PKGBUILD pkgver "$last_ver"
  set_var PKGBUILD sha256sums "('$sha2')"
  gen_srcinfo
  echo "  -- 已更新 to $last_ver"
}