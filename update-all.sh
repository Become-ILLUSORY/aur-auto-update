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

# ---- 单个包的一次性处理 ----
run_one() {
  local conf="$1"
  local pkg
  pkg="$(basename "$conf" .sh)"
  pkg="${pkg#pkg-}"

  echo "===== [$pkg] 开始 ====="
  local wd="$WORK/$pkg"
  aur_clone "$pkg" "$wd"

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