# misterdownloadmanager-private-bin 自动更新配置
#   上游: anefzaoui/misterdownloadmanager  GitHub release 资产(x86_64 tar.gz + SHA256SUMS.txt)
#   版本: tag v0.5.2 → pkgver 0.5.2，无译码。
#   注意: PKGBUILD source 用 ${pkgver} 拼 URL，set_var pkgver 后自动指向新版本；
#         图标 source 固定上游 commit，不随版本变化，checksum 只改 tar.gz 那一项。
source "${ROOT}/lib/common.sh"

run() {
  local repo="anefzaoui/misterdownloadmanager"
  local last_tag last_ver cur
  last_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  last_ver="${last_tag#v}"
  [[ -n "$last_ver" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  cur="$(srcinfo_val pkgver)"
  echo "  misterdownloadmanager-private-bin: 当前 $cur，上游 $last_ver"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  local asset="MisterDownloadManager-${last_ver}-linux-x86_64.tar.gz"
  gh api "repos/$repo/releases/tags/$last_tag" \
    --jq ".assets[] | select(.name == \"$asset\") | .name" | grep -q . \
    || { echo "  !! 上游 release 缺少资产 $asset（上游改了命名？）"; return 1; }

  set_var PKGBUILD pkgver "$last_ver"

  # checksum 优先取上游 SHA256SUMS.txt（免下载 21MB 本体），回退下载算
  local base_url="https://github.com/$repo/releases/download/$last_tag"
  local sha
  sha="$(curl -fsSL --retry 3 "$base_url/SHA256SUMS.txt" \
         | awk -v a="$asset" '$2 == a { print $1; exit }' || true)"
  [[ -n "$sha" ]] || sha="$(shasum_of_url "$base_url/$asset" || true)"
  [[ -n "$sha" ]] || { echo "  !! 无法获取 $asset 的 sha256"; return 1; }

  set_checksum_item PKGBUILD sha256sums 1 "$sha"

  gen_srcinfo
  echo "  -- 已更新 to $last_ver (sha256=$sha)"
}
