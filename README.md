# aur-auto-update

定时检查你在 AUR 维护的包对应的上游仓库（GitHub release/tag），有新版本就更新 PKGBUILD 与 .SRCINFO 并推送到 `aur.archlinux.org`。

## 管理哪些包

| 包 | 上游 | 版本来源 | 特殊处理 |
|---|---|---|---|
| `wowtype-core` | Gloridust/WowType | release | checksum 取上游 SHA256SUMS |
| `flclash-myflavor-bin` | myflavor/FlClash | release | 架构特定 checksum |
| `honk-bin` | daeuniverse/honk | tag（无 release） | pkg 名与 tag 译码（`-`→去掉），多架构，jsDelivr 取 example.dae |
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

大陆直连 GitHub 下载慢，`source` 会挂一个加速镜像前缀（`https://<镜像>/https://github.com/...`）。镜像列在 `lib/common.sh` 的 `GH_MIRRORS`，`pick_mirror` 在维护端（`update-all.sh`/CI）逐个探测，取第一个可用的。

注意两件事：

- **jsDelivr 不能替代**：它只镜像 git 仓库内容（`@tag/path`），不代理 Release 资产，而这些包的 `source` 全是 release 资产。只有像 `honk-bin` 那样取仓库内文本文件时才可用。
- PKGBUILD 是静态文件，AUR 用户 `makepkg` 时不会探测，最终仍写死为选定的单一镜像。镜像失效时跑一次 `update-all.sh` 会自动迁移到可用镜像并 bump `pkgrel`，不需要手动改 76 处。

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