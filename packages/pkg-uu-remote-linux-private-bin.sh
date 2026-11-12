# uu-remote-linux-private-bin 自动更新配置
#   上游: VallierDev/uu-remote-linux  GitHub release 资产(x86_64+aarch64 tarball + 伴随 .sha256)
#   版本: tag v0.2.57 → pkgver 0.2.57，无译码。
#   注意: PKGBUILD source 里用 ${pkgver} 拼 URL，set_var pkgver 后自动指向新版本。
source "${ROOT}/lib/common.sh"

run() {
  local repo="VallierDev/uu-remote-linux"
  local last_tag last_ver cur
  last_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  last_ver="${last_tag#v}"
  [[ -n "$last_ver" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  cur="$(srcinfo_val pkgver)"
  echo "  uu-remote-linux-private-bin: 当前 $cur，上游 $last_ver"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  # 资产名: uu-remote-linux-v<ver>-<arch>-linux.tar.gz（版本前带 v），两架构都有
  local asset_x="uu-remote-linux-v${last_ver}-x86_64-linux.tar.gz"
  local asset_a="uu-remote-linux-v${last_ver}-aarch64-linux.tar.gz"
  gh api "repos/$repo/releases/tags/$last_tag" \
    --jq ".assets[] | select(.name == \"$asset_x\" or .name == \"$asset_a\") | .name" | grep -q . \
    || { echo "  !! 上游 release 缺少资产（x=$asset_x / a=$asset_a）"; return 1; }

  set_var PKGBUILD pkgver "$last_ver"

  # 优先级: 上游 .sha256 伴随文件 > 下载本体算
  local base_url="https://github.com/$repo/releases/download/$last_tag"
  local sha_x sha_a
  sha_x="$(curl -fsSL --retry 3 "$base_url/$asset_x.sha256" | awk '{print $1}' || true)"
  [[ -n "$sha_x" ]] || sha_x="$(shasum_of_url "$base_url/$asset_x")"
  sha_a="$(curl -fsSL --retry 3 "$base_url/$asset_a.sha256" | awk '{print $1}' || true)"
  [[ -n "$sha_a" ]] || sha_a="$(shasum_of_url "$base_url/$asset_a")"

  set_var PKGBUILD sha256sums_x86_64  "('$sha_x')"
  set_var PKGBUILD sha256sums_aarch64 "('$sha_a')"

  gen_srcinfo
  echo "  -- 已更新 to $last_ver (x86_64=$sha_x / aarch64=$sha_a)"
}