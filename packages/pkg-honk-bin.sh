# honk-bin 自动更新配置
#   上游: daeuniverse/honk  GitHub release 资产(musl 静态二进制，x86_64+aarch64)
#   特点: pkgver 与上游 tag 不同形 —— tag v0.1.0-beta.6 → pkgver 0.1.0beta.6
#   （pkgver 不能含连字符，脚本里保持 _upver 供 URL 用，pkgver 供版本比较/库目录用）
#   当前 AUR 版: 0.1.0beta.3-1
source "${ROOT}/lib/common.sh"

run() {
  local repo="daeuniverse/honk"
  # honk 没有 GitHub Release，只有 tag（v0.1.0-beta.X 形）
  local last_tag
  last_tag="$(gh api "repos/$repo/tags" --jq '.[0].name' 2>/dev/null || true)"
  [[ -n "$last_tag" ]] || { echo "  !! 无法获取 $repo 最新 tag"; return 1; }

  # 上游 tag: v0.1.0-beta.6 → 实际版本号(去 v)、pkgver(去连字符)
  local raw_ver="${last_tag#v}"
  local last_ver="${raw_ver//-/}"
  # 注意 -beta 后缀：pkgver 0.1.0beta.6 若有人在同一版本发 pre/post tag，按字符串比较即可
  local cur
  cur="$(srcinfo_val pkgver)"
  echo "  honk: 当前 $cur，上游 $last_ver (tag $last_tag)"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  # 资产目录名: honk-core-v<raw_ver>-<arch>-unknown-linux-musl-full
  local base="honk-core-v${raw_ver}"
  local asset_x="honk-core-v${raw_ver}-x86_64-unknown-linux-musl-full.tar.gz"
  local asset_a="honk-core-v${raw_ver}-aarch64-unknown-linux-musl-full.tar.gz"
  gh api "repos/$repo/releases/tags/$last_tag" \
    --jq ".assets[] | select(.name == \"$asset_x\" or .name == \"$asset_a\") | .name" | grep -q . \
    || { echo "  !! 上游 release 缺少资产（x=$asset_x / a=$asset_a）"; return 1; }

  set_var PKGBUILD pkgver "$last_ver"
  # _upver 保持连字符形式，供 _dl_base 和目录名使用
  set_var PKGBUILD _upver "'${raw_ver}'"

  # 三个依赖 raw_ver 的目录名行
  set_var PKGBUILD _dir_x86_64  "\"honk-core-v${raw_ver}-x86_64-unknown-linux-musl-full\""
  set_var PKGBUILD _dir_aarch64 "\"honk-core-v${raw_ver}-aarch64-unknown-linux-musl-full\""

  local base_url="https://github.com/$repo/releases/download/$last_tag"
  local sha_x sha_a
  # 优先级: 上游 .sha256 伴随文件 > 下载算
  sha_x="$(curl -fsSL --retry 3 "$base_url/$asset_x.sha256" | awk '{print $1}' || true)"
  [[ -n "$sha_x" ]] || sha_x="$(shasum_of_url "$base_url/$asset_x")"
  sha_a="$(curl -fsSL --retry 3 "$base_url/$asset_a.sha256" | awk '{print $1}' || true)"
  [[ -n "$sha_a" ]] || sha_a="$(shasum_of_url "$base_url/$asset_a")"

  set_var PKGBUILD sha256sums_x86_64  "('$sha_x')"
  set_var PKGBUILD sha256sums_aarch64 "('$sha_a')"

  # base 第 5 项 config.example.dae 来自上游 tag（jsDelivr），随版本变，重算
  local example_sha
  example_sha="$(shasum_of_url "https://fastly.jsdelivr.net/gh/${repo}@v${raw_ver}/example.dae")" \
    || example_sha="SKIP"
  set_checksum_item PKGBUILD sha256sums 5 "$example_sha"

  gen_srcinfo
  echo "  -- 已更新 to $last_ver (x=$sha_x / a=$sha_a)"
}