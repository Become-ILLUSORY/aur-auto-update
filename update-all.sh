#!/usr/bin/env bash
# AUR 包自动更新主脚本：
#   git clone 每个 AUR 包到工作区 → source packages/<pkg>.sh 的 run()
#   修改 PKGBUILD/.SRCINFO → 有改动就 commit+push 到 aur.archlinux.org。
#
# 用法: bash update-all.sh [packages/*.sh ...]   （不传参=全部）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

source "$ROOT/lib/common.sh"

# AUR 仓库是否已存在：git ls-remote 对不存在的包也返回空仓库(exit 0)，
# 不可靠；用 AUR RPC v5 info 判断（resultcount>=1 = 已注册存在）。
aur_exist() {
  local r
  r="$(curl -fsSL --retry 2 "https://aur.archlinux.org/rpc/v5/info?arg[]=$1" 2>/dev/null \
       | jq -r '.resultcount // 0' 2>/dev/null || echo 0)"
  (( r >= 1 ))
}

# AUR 首次建仓：bootstrap/<pkg>/ 存有初版 PKGBUILD+.SRCINFO，
# 仓库不存在时用它们创建并 push，避免本机直连 AUR SSH。
init_pkg_repo() {
  local pkg="$1" dir="$2"
  [[ -f "$ROOT/bootstrap/$pkg/PKGBUILD" ]] || { echo "  !! bootstrap/$pkg 缺失，跳过建仓"; return 1; }
  mkdir -p "$dir"
  cp "$ROOT/bootstrap/$pkg/PKGBUILD" "$ROOT/bootstrap/$pkg/.SRCINFO" "$dir/"
  git -C "$dir" init -b master -q
  git -C "$dir" config user.name "Become-ILLUSORY"
  git -C "$dir" config user.email "becomeillusory@gmail.com"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "chore(${pkg}): initial import"
  git -C "$dir" remote add aur "ssh://aur@aur.archlinux.org/${pkg}.git"
  if [[ "${AUR_PUSH:-1}" == "1" ]]; then
    git -C "$dir" push aur master
  else
    echo "  (dry-run) 跳过首次 push"
  fi
}

# craft 包下载加速：给源 PKGBUILD 里的 storytold release URL 加 gh-proxy.com 前缀（幂等）。
# 无别名也行——srcdir 文件名=URL 末段，与 package() 引用一致。
ensure_ghproxy() {
  if grep -q 'gh-proxy.com' PKGBUILD; then
    echo "  -> source 已含 gh-proxy.com"
    return 0
  fi
  if grep -q 'https://github.com/storytold/' PKGBUILD; then
    sed -i 's|https://github.com/storytold/|https://gh-proxy.com/https://github.com/storytold/|' PKGBUILD
    gen_srcinfo
    echo "  -- source 已加 gh-proxy.com 前缀"
  fi
}

# ---- 单个包的一次性处理 ----
run_one() {
  local conf; conf="$(realpath "$1")"
  local pkg
  pkg="$(basename "$conf" .sh)"
  pkg="${pkg#pkg-}"

  echo "===== [$pkg] 开始 ====="
  local wd="$WORK/$pkg"
  if aur_exist "$pkg"; then
    aur_clone "$pkg" "$wd"
  else
    echo "  [$pkg] AUR 仓库不存在，首次建仓"
    init_pkg_repo "$pkg" "$wd"
  fi

  # 包脚本约定：source lib/common.sh 后在当前目录(PKGBUILD 所在)定义并执行 run()
  if ! (
    cd "$wd"
    export ROOT PKG_DIR="$ROOT/packages"
    source "$conf"
    run
  ); then
    echo "  !! [$pkg] run() 失败，跳过"
    return 0
  fi

  pushd "$wd" >/dev/null
    ensure_ghproxy
    aur_push_if_changed "chore(${pkg}): auto-update"
  popd >/dev/null
}

# 支持指定的包脚本，否则跑全部
if [[ $# -eq 0 ]]; then
  mapfile -t targets < <(compgen -G "$ROOT/packages/*.sh" | sort)
else
  targets=("$@")
fi

for conf in "${targets[@]}"; do
  [[ -f "$conf" ]] || { echo "配置不存在: $conf"; continue; }
  run_one "$conf"
done

echo "全部完成。"