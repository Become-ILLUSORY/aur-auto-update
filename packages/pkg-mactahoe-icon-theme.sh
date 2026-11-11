# mactahoe-icon-theme 自动更新配置
#   上游: vinceliuice/MacTahoe-icon-theme  Git tag（无 v 前缀，日期形式）
#   特点: tag 是 2026-09-10 → pkgver 2026.09.10（连字符不能出现在 pkgver），_tag 保留连字符
#   当前 AUR 版: 2026.09.10-1
source "${ROOT}/lib/common.sh"

run() {
  local repo="vinceliuice/MacTahoe-icon-theme"
  # 上游用 tag 发布（releases 里也有同名 tag），以 tag 列表第一个为准
  local tag
  tag="$(gh api "repos/$repo/tags" --jq '.[0].name' 2>/dev/null || true)"
  [[ -n "$tag" ]] || { echo "  !! 无法获取 $repo 最新 tag"; return 1; }

  local last_ver="${tag//-/.}"
  local cur
  cur="$(srcinfo_val pkgver)"
  echo "  mactahoe: 当前 $cur，上游 $last_ver (tag $tag)"
  [[ "$(ver_cmp "$last_ver" "$cur")" -le 0 ]] && { echo "  -> 无需更新"; return 0; }

  set_var PKGBUILD pkgver "$last_ver"
  set_var PKGBUILD _tag "$tag"

  local sha2
  sha2="$(shasum_of_url "https://github.com/$repo/archive/refs/tags/${tag}.tar.gz")"
  set_var PKGBUILD sha256sums "('$sha2')"
  gen_srcinfo
  echo "  -- 已更新 to $last_ver"
}