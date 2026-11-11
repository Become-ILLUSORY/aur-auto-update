# flclash-myflavor-bin 自动更新配置
#   上游: myflavor/FlClash  GitHub release 资产(deb)
#   当前 AUR 版: 1.19.32-1（上游已 v1.19.33）
source "${ROOT}/lib/common.sh"

run() {
  local repo="myflavor/FlClash"
  local last_tag last_ver
  last_tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  last_ver="${last_tag#v}"
  [[ -n "$last_ver" ]] || { echo "  !! 无法获取 $repo 最新版本"; return 1; }

  local cur
  cur="$(srcinfo_val pkgver)"
  echo "  flclash: 当前 $cur，上游 $last_ver"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  # 资产名: FlClash-<ver>-linux-amd64.deb
  local asset="FlClash-${last_ver}-linux-amd64.deb"
  gh api "repos/$repo/releases/tags/$last_tag" \
    --jq ".assets[] | select(.name == \"$asset\") | .name" | grep -q . \
    || { echo "  !! 上游 release 缺少资产 $asset"; return 1; }

  set_var PKGBUILD pkgver "$last_ver"
  # 用伴随 .sha256 资产取 deb 校验和，避免下载约 120MB 本体
  local sha2
  sha2="$(curl -fsSL --retry 3 "https://github.com/$repo/releases/download/$last_tag/$asset.sha256" | awk '{print $1}' || true)"
  if [[ -z "$sha2" ]]; then
    sha2="$(shasum_of_url "https://github.com/$repo/releases/download/$last_tag/$asset")"
  fi
  set_var PKGBUILD sha256sums_x86_64 "('$sha2')"
  gen_srcinfo
  echo "  -- 已更新 to $last_ver (x86_64 sha256=$sha2)"
}