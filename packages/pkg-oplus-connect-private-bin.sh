# oplus-connect-private-bin 自动更新配置
#   "上游"是构成本仓库 CI 自编译的 Release（tag: oplus-connect-latest）。
#   版本从 asset 名解析：oplus-connect-1.0.0.r<N>.g<sha>-1-x86_64.pkg.tar.zst → 1.0.0.r<N>.g<sha>
#   sha256 优先取 Release API 的 digest（构建时锁死），回退下载计算。
#   注意：版本段 r<N> 非纯数字，字典序会 r99>r100 误判，用字符串相等判断更新。
source "${ROOT}/lib/common.sh"

run() {
  local capi="https://api.github.com/repos/Become-ILLUSORY/aur-auto-update/releases/tags/oplus-connect-latest"
  local asset last_ver sha cur

  asset="$(gh api "$capi" --jq '.assets[] | select(.name|startswith("oplus-connect-") and endswith(".pkg.tar.zst")) | .name' 2>/dev/null | head -1 || true)"
  [[ -n "$asset" ]] || { echo "  !! 本仓库 Release 里没找到 oplus-connect 资产（<$capi>）"; return 1; }

  last_ver="$(printf '%s' "$asset" | sed -E 's/^oplus-connect-(.*)-[0-9]+-x86_64\.pkg\.tar\.zst$/\1/')"
  [[ -n "$last_ver" ]] || { echo "  !! 资产名解析失败: $asset"; return 1; }

  cur="$(srcinfo_val pkgver)"
  echo "  oplus-connect-private-bin: 当前 $cur，上游(CI Release) $last_ver"
  [[ "$last_ver" == "$cur" ]] && { echo "  -> 无需更新"; return 0; }

  # digest 形如 "sha256:<hex>"，取冒号后段；没有就下载算
  local stored
  stored="$(gh api "$capi" --jq --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' 2>/dev/null || true)"
  sha="${stored#sha256:}"
  if [[ -z "$sha" ]]; then
    sha="$(shasum_of_url "https://github.com/Become-ILLUSORY/aur-auto-update/releases/download/oplus-connect-latest/$asset")" || { echo "  !! 计算 sha256 失败"; return 1; }
  fi

  set_var PKGBUILD pkgver "$last_ver"
  set_var PKGBUILD sha256sums "('$sha')"
  gen_srcinfo
  echo "  -- 已更新 to $last_ver (sha256=$sha)"
}