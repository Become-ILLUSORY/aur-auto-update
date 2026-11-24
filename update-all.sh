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

# 逐包摘要收集：SUMMARY=("包名|动作|版本|备注")，最后渲染成 markdown 表。
# 动作 ∈ 更新推送 / 无更新 / 首次建仓 / 有改动未推送 / 失败 / 跳过
declare -a SUMMARY=()
summary_add() { SUMMARY+=("$1|$2|$3|$4"); }

# AUR 仓库是否已存在：git ls-remote 对不存在的包也返回空仓库(exit 0)，
# 不可靠；用 AUR RPC v5 info 判断（resultcount>=1 = 已注册存在）。
# 返回 0=存在，1=不存在，2=查询失败（网络抖动）。调用方必须区分 1 和 2，
# 否则偶发的 RPC 失败会被当成"包不存在"而误触建仓。
aur_exist() {
  local r i
  for i in 1 2 3; do
    r="$(curl -fsSL --retry 2 --connect-timeout 15 \
          "https://aur.archlinux.org/rpc/v5/info?arg[]=$1" 2>/dev/null \
         | jq -r '.resultcount // empty' 2>/dev/null || true)"
    if [[ "$r" =~ ^[0-9]+$ ]]; then
      (( r >= 1 )) && return 0
      return 1
    fi
    sleep 3
  done
  return 2
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

# 下载加速：把 PKGBUILD source 里的 GitHub release URL 挂到可用镜像前缀下（幂等）。
# 无别名也行——srcdir 文件名=URL 末段，与 package() 引用一致。
# 镜像失效时自动迁移到可用镜像；迁移只改下载路径，不 bump pkgrel。
ensure_mirror() {
  local prefix gh_url
  # 探测目标必须取 .SRCINFO 里 source 的真实下载 URL（剥掉旧前缀）。
  # 不能用仓库首页充当目标：镜像对首页回 200、对下载却 403，会误判。
  gh_url="$(grep -oE 'https://github\.com/[^"'"'"' )]+' .SRCINFO 2>/dev/null \
            | grep -E '/releases/download/|/archive/refs/' | head -1 || true)"
  if [[ -z "$gh_url" ]]; then
    echo "  -> source 里没有可探测的 GitHub 下载 URL，跳过镜像处理"
    return 0
  fi

  # pick_mirror 的缓存靠主 shell 里的变量，不能放进命令替换（子 shell）。
  pick_mirror "$gh_url"
  prefix="$_MIRROR_SELECTED"

  # 全部探测失败：可能是网络抖动而非镜像真挂，保持现状不改 PKGBUILD。
  # 否则每次抖动都会把 source 退回直连，下次又加回镜像，来回横跳。
  if [[ -z "$prefix" ]]; then
    local cur
    cur="$(current_mirror)"
    echo "  ?? 镜像探测全部失败，保持现状（当前：${cur:-直连}），不改 PKGBUILD"
    return 0
  fi

  ensure_mirror_var "$prefix" || { echo "  -> 镜像默认值已是最新"; return 0; }

  # 不 bump pkgrel：这只改了 source 的下载路径，产物字节与 sha256 都没变，
  # 升 rel 会让订阅者每天为一个"假更新"重装一次。pkgrel 只在内容真的变了
  # （新版本、上游重发）时才升——见 run() 与 detect_upstream_republish。
  gen_srcinfo
  echo "  -- 镜像默认值改为 $prefix（内容未变，不 bump pkgrel）"
}

# ---- 单个包的一次性处理 ----
run_one() {
  local conf; conf="$(realpath "$1")"
  local pkg
  pkg="$(basename "$conf" .sh)"
  pkg="${pkg#pkg-}"

  echo "===== [$pkg] 开始 ====="
  local wd="$WORK/$pkg"
  local exist_rc=0
  aur_exist "$pkg" || exist_rc=$?
  if (( exist_rc == 0 )); then
    if ! aur_clone "$pkg" "$wd"; then
      echo "  !! [$pkg] 克隆 AUR 仓库失败（网络？），跳过本包"
      summary_add "$pkg" "失败" "-" "git clone 失败（网络抖动？）"
      return 0
    fi
  elif (( exist_rc == 2 )); then
    echo "  !! [$pkg] AUR 存在性查询失败（网络？），跳过本包"
    summary_add "$pkg" "跳过" "-" "AUR RPC 查询失败，未作判断"
    return 0
  else
    echo "  [$pkg] AUR 仓库不存在，首次建仓"
    if ! init_pkg_repo "$pkg" "$wd"; then
      summary_add "$pkg" "失败" "-" "bootstrap 文件中缺 PKGBUILD/"
      return 0
    fi
  fi

  # 跑各包脚本 run()：捕获退出码，输出原样透传
  local run_rc=0 run_out
  run_out="$(cd "$wd" && export ROOT PKG_DIR="$ROOT/packages" && source "$conf" && run)" || run_rc=$?
  [[ -n "$run_out" ]] && echo "$run_out"

  # 版本信息从 .SRCINFO 读（更新前后同一读法）
  local ver
  ver="$(cd "$wd" && srcinfo_val pkgver 2>/dev/null || echo '-')"

  # run() 失败不立刻返回：镜像迁移与重发检测不依赖"查到上游新版本"，
  # 上游 API 抖动时仍应把 source 前缀修正推上去。失败信息记在备注里。
  local run_failed=0 run_note=""
  if (( run_rc != 0 )); then
    run_failed=1
    run_note="run() 退出码 $run_rc（见上方日志）"
    echo "  !! [$pkg] run() 失败(rc=$run_rc)，仍尝试镜像修正"
  fi

  # 下载镜像前缀：无条件执行（幂等），镜像失效时自动迁移到可用镜像。
  # 首次跟进时即使 run() 无新版本也要把前缀修正提交推上去。
  pushd "$wd" >/dev/null
    ensure_mirror

    # run() 按版本号相同提前 return 时，上游仍可能重发了同一版本的资产，
    # 使 AUR 锁定的 sha256 失效。此处按上游 digest 复核并写回。
    local republish_rc=0
    detect_upstream_republish || republish_rc=$?
    if (( republish_rc == 1 )); then
      :
    elif (( republish_rc == 0 )); then
      # pkgver 没变、内容变了：必须 bump pkgrel，否则已装该版本的用户不会升级
      local rel
      rel="$(bump_pkgrel)"
      gen_srcinfo
      echo "  -- 上游重发同版本，已更新校验和并 pkgrel -> $rel"
    else
      echo "  !! 重发检测失败，跳过该校验和"
    fi
  popd >/dev/null

  local state="$(git -C "$wd" status --porcelain)"
  local action note=""
  if [[ -z "$state" ]]; then
    action="无更新"
    note="上游无新版本，AUR 已是最新"
  elif [[ "${AUR_PUSH:-1}" == "1" ]]; then
    local before after push_rc=0
    before="$(git -C "$wd" rev-parse HEAD)"
    pushd "$wd" >/dev/null
      aur_push_if_changed "chore(${pkg}): auto-update" || push_rc=$?
    popd >/dev/null
    after="$(git -C "$wd" rev-parse HEAD)"
    if (( push_rc != 0 )); then
      # 单个包 push 被拒（如 AUR 上该包 orphaned）不能中断整轮：后面的包
      # 无辜受累，本轮的更新也全部丢失。记为失败，继续下一个。
      action="失败"
      note="push 到 AUR 失败（rc=$push_rc，见上方日志）"
    elif [[ "$before" != "$after" ]]; then
      action="更新推送"
      note="$(git -C "$wd" show --stat --format='%s' "${after:0:7}" | tail -n +2 | tr '\n' ' ' | awk '{$1=$1};1')"
    else
      action="未推送"
      note="有改动但 HEAD 未前进（dry-run？或 push 失败，见日志）"
    fi
  else
    action="DRY-RUN"
    note="有改动，未 push（AUR_PUSH=0）"
  fi
  # run() 失败时即便镜像已修正，这个包仍算失败（上游状态没跟上）
  (( run_failed )) && { action="失败"; note="$run_note"; }
  summary_add "$pkg" "$action" "$ver" "$note"
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

echo ""
echo "===== 汇总 ====="
for line in "${SUMMARY[@]}"; do
  IFS='|' read -r pkg action ver note <<< "$line"
  printf '  %-28s %s   %-10s %s\n' "$pkg" "$action" "$ver" "$note"
done
echo "全部完成。"