# aur-auto-update

定时检查你在 AUR 维护的包对应的上游仓库（GitHub release/tag），有新版本就更新 PKGBUILD 与 .SRCINFO 并推送到 `aur.archlinux.org`。

## 管理哪些包

| 包 | 上游 | 版本来源 | 特殊处理 |
|---|---|---|---|
| `wowtype-core` | Gloridust/WowType | release | checksum 取上游 SHA256SUMS |
| `flclash-myflavor-bin` | myflavor/FlClash | release | 架构特定 checksum |
| `linux-wallpaperengine-v3-bin` | Become-ILLUSORY/linux-wallpaperengine | release | x86-64-v3 自构建 |
| `mactahoe-icon-theme` | vinceliuice/MacTahoe-icon-theme | tag | 日期式 tag（`-`→`.`） |
| `wordcraft-private-bin` 等 14 个 craft 套件 | storytold/<app> | release | 官方 `.pkg.tar.zst` 重打包，checksum 锁官方 SHA256SUMS.txt；首次由 bootstrap/ 自动建仓 |
| `uu-remote-linux-private-bin` | VallierDev/uu-remote-linux | release | 非官方 UU 远程被控端，source 走 GitHub 镜像加速（`lib/common.sh` 按可用性优选），镜像官方 .deb 布局，双架构 checksum 锁伴随 .sha256 |
| `oplus-connect-private-bin` | YuKongA/oplus-connect（本仓库 build-oplus 自编译） | 本仓库 GitHub Release | CI 用 cachyos-v3 编译出 `.pkg.tar.zst` 发到 `oplus-connect-latest`，AUR 包重打包它；版本=上游 git rev-count `1.0.0.r<N>.g<sha>`，checksum 取 Release asset digest |
| `misterdownloadmanager-private-bin` | anefzaoui/misterdownloadmanager | release | 预编译 Linux tar.gz 重打包，checksum 取上游 `SHA256SUMS.txt`；上游 tar.gz 不含 `.desktop`/图标，由 PKGBUILD 补 |

craft 系列（14 个）：`wordcraft` `deckcraft` `photocraft` `vectorcraft` `filmcraft` `lightcraft` `pdfcraft` `effectcraft` `designcraft` `figcraft` `soundcraft` `cadcraft` `gridcraft` `texturecraft`，均为 `*-private-bin` 自用包，脚本由 `/tmp` 生成的统一模板派生。

## 工作方式

- `lib/common.sh`：共享函数（GitHub API 查版本、比较版本、改 PKGBUILD、算 checksum、push AUR）
- `packages/<pkg>.sh`：每个包一个更新逻辑（`run()` 函数）
- `update-all.sh`：遍历每个包——先探测 AUR 仓库是否存在（RPC 探测，git ls-remote 不可靠），不存在则用 `bootstrap/<pkg>/` 的初版 PKGBUILD+.SRCINFO 首次建仓推送，存在则 clone AUR 仓库 → 执行包的 `run()` → 有改动就 commit+push

每个包的 `run()` 独立、幂等：当前已是最新时就跳过。

### 上游重发同版本资产

`run()` 只看版本号，上游用同一 tag 重发 release（删掉重建，资产内容变了但版本号不变）时会被判定为"无需更新"，AUR 里锁的 sha256 就会失效，用户 `makepkg` 必然校验失败。

`update-all.sh` 在 `run()` 之后额外跑一遍 `detect_upstream_republish`（`lib/common.sh`）：它不依赖包脚本，直接解析 `.SRCINFO` 里每个 `source` 的 URL 与 `sha256`，与 GitHub API 返回的 asset `digest`（GitHub 侧计算的真值）比对。不一致就写回新校验和并把 `pkgrel` +1（版本号没变但内容变了，不 bump 则已装该版本的用户不会升级）。仅当能定位到同一个 release 资产时才判定；release 被删或 API 查询失败一律放行，不做猜测。

### 下载镜像

大陆直连 GitHub 下载慢，`source` 会挂一个加速镜像前缀（`https://<镜像>/https://github.com/...`）。镜像列在 `lib/common.sh` 的 `GH_MIRRORS`，`pick_mirror` 在维护端（`update-all.sh`/CI）探测可用性。

注意三件事：

- **镜像会下线，需定期复测**：`gh-proxy.com` 于 2026-11 一度对下载路径回 403 被封，改用 `gh-proxy.cn`；后 `gh-proxy.cn` 稳定 503，`gh-proxy.com` 恢复后曾换回；2026-11-28 换用 `cdn.gh-proxy.org`（CNAME → `www.gh-proxy.com`，同一后端；复测 4 类 URL × 4 轮全部返回真实文件字节）。`ghproxy.net` 真实 IP 不可达，未采用。**换镜像前必须绕开本地 DNS 劫持、按真实 IP 直连验证返回的是真实字节**，否则会把落地页误判为可用。
- **横跳已由 `pick_mirror` 兜住**：它先探当前已用的镜像，可用就不换；只有当前镜像不在 `GH_MIRRORS` 白名单或真不可用才迁移。所以 `GH_MIRRORS` 可以有备份项，顺序即优先级。
- **jsDelivr 不能替代**：它只镜像 git 仓库内容（`@tag/path`），不代理 Release 资产，而这些包的 `source` 全是 release 资产。
- PKGBUILD 是静态文件，AUR 用户 `makepkg` 时不会探测，最终仍写死为选定的单一镜像。用户可 `makepkg GH_MIRROR=https://另一镜像/` 覆盖。**镜像迁移只改下载路径，不 bump `pkgrel`**——产物字节和 sha256 没变，升 rel 只会让订阅者重装一个内容相同的包。

## 手动运行

```bash
bash update-all.sh                 # 全部包
bash update-all.sh packages/pkg-flclash-myflavor-bin.sh   # 只跑一个
```

dry-run（改动本地提交，不 push AUR）：

```bash
AUR_PUSH=0 bash update-all.sh
```

## GitHub Actions 配置

仓库 `Settings → Secrets and variables → Actions` 里加一个 secret：

- `AUR_SSH_KEY`：你访问 `aur.archlinux.org` 的 SSH 私钥全文（`ssh-keygen` 生成的那个 `id_ed25519` 内容）。对应公钥要已在 AUR 账户页面登记。

workflow（`.github/workflows/update-aur.yml`）每 6 小时自动跑一次，也可在 Actions 页面手动触发（`workflow_dispatch`）。需要在 Change 确认时保证 SSH `aur` 用户可 push 你的包。

## 新增一个包

1. 在 `packages/` 下写 `<pkg>.sh`，`source lib/common.sh`，实现 `run()`：
   - 用 `srcinfo_val pkgver` 读当前版本
   - 用你可靠的方式拿上游最新版本（`gh api .../releases/latest` 或 `/tags`）
   - 版本落后就改 PKGBUILD（`set_var` / `set_checksum_item` / `shasum_of_url`），再 `gen_srcinfo`
2. 用 `AUR_PUSH=0 bash update-all.sh packages/<pkg>.sh` dry-run 验证
3. commit 推到本仓库即可

## 依赖检查

两个检查互补，都在 `.github/workflows/check-deps.yml`：

| 脚本 | 做法 | 能发现 |
|---|---|---|
| `scripts/check-deps.sh` | 只 `pacman -Sp` 解析依赖名 | 依赖在仓库里不存在 |
| `scripts/check-install-deps.sh` | 真实构建+安装，扫包内 ELF 的 NEEDED | depends 漏声明（库存在但没写进 depends） |

后者是必需的：pacman 只校验 depends 能否解析，不关心二进制实际 NEEDED 了什么。`flclash-myflavor-bin` 就是典型——托盘插件直接链接 `libayatana-indicator3.so.7`，而 `libayatana-appindicator` 从 0.6.0 起不再传递依赖 `libayatana-indicator`。开发机上因为别的包装了它而一切正常，干净系统上托盘插件却加载失败。

隔离方式：每个包都在「只装它自己声明的 depends」的环境里安装，测完立即卸载（连同依赖）回到基线，再测下一个。不隔离的话，上一个包的依赖会掩盖下一个包缺失的依赖，检查就形同虚设。每个包一个 matrix job 并行跑（单包要下载上游产物，串行会超时）。

本地只查一个包：

```bash
sudo ONLY=flclash-myflavor-bin bash scripts/check-install-deps.sh
```

注意：这个检查会真实 `pacman -S`/`pacman -Rns`，只适合在容器或一次性环境里跑，别在主力机上执行。