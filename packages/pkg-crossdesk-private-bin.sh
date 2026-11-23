# crossdesk-private-bin 自动更新配置
#   上游: kunkundi/crossdesk  GitHub release 资产（amd64 / arm64 .deb）
#   版本: tag v1.7.6-20261112 → pkgver 1.7.6.20261112
#         （去掉 v；连字符换点，把构建日期并入版本号——上游常用同版本号
#          重发只改日期，日期不进 pkgver 就会被 ver_cmp 判成"无需更新"）
#   注意: PKGBUILD 用 ${pkgver} 拼 source 文件名、用 ${_tag} 拼 URL 路径，
#         两者都要改；上游发布名是 crossdesk-linux-<amd64|arm64>-<tag>.deb。
source "${ROOT}/lib/common.sh"

run() {
  local repo="kunkundi/crossdesk"
  local last_tag last_ver cur
  # releases/latest 在本仓库已被固定成旧的 "latest" tag，不能用；
  # 直接取 release 列表第一项（按发布时间的语义顺序）才是真最新。
  last_tag="$(gh api "repos/$repo/releases" --jq '[.[] | select(.draft == false)] | .[0].tag_name' 2>/dev/null || true)"
  [[ -n "$last_tag" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  # v1.7.6-20261112 → 1.7.6.20261112
  last_ver="${last_tag#v}"
  last_ver="${last_ver//-/.}"

  cur="$(srcinfo_val pkgver)"
  echo "  crossdesk-private-bin: 当前 $cur，上游 $last_ver (tag $last_tag)"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  local asset_x="crossdesk-linux-amd64-${last_tag}.deb"
  local asset_a="crossdesk-linux-arm64-${last_tag}.deb"
  local have
  have="$(gh api "repos/$repo/releases/tags/$last_tag" \
           --jq '.assets[].name' 2>/dev/null || true)"
  # 上游可能只放一种架构；缺哪个就保留旧的，不猜。
  if ! grep -qx "$asset_x" <<< "$have"; then
    echo "  !! 上游 release 缺少资产 $asset_x（上游改了命名？）"; return 1
  fi

  set_var PKGBUILD pkgver "$last_ver"
  set_var PKGBUILD _tag "$last_tag"

  local base_url="https://github.com/$repo/releases/download/$last_tag"
  local sha_x sha_a
  sha_x="$(shasum_of_url "$base_url/$asset_x" || true)"
  [[ -n "$sha_x" ]] || { echo "  !! 无法获取 $asset_x 的 sha256"; return 1; }
  set_checksum_item PKGBUILD sha256sums_x86_64 1 "$sha_x"

  if grep -qx "$asset_a" <<< "$have"; then
    sha_a="$(shasum_of_url "$base_url/$asset_a" || true)"
    if [[ -n "$sha_a" ]]; then
      set_checksum_item PKGBUILD sha256sums_aarch64 1 "$sha_a"
    else
      echo "  ?? 取不到 $asset_a 的 sha256，保留原 aarch64 校验和"
    fi
  else
    echo "  ?? 上游未提供 $asset_a，保留原 aarch64 校验和"
  fi

  gen_srcinfo
  echo "  -- 已更新 to $last_ver (x86_64=$sha_x)"
}