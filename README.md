# aur-auto-update

定时检查你在 AUR 维护的包对应的上游仓库（GitHub release/tag），有新版本就更新 PKGBUILD 与 .SRCINFO 并推送到 `aur.archlinux.org`。

## 管理哪些包

| 包 | 上游 | 版本来源 | 特殊处理 |
|---|---|---|---|
| `wowtype-core` | Gloridust/WowType | release | checksum 取上游 SHA256SUMS |
| `flclash-myflavor-bin` | myflavor/FlClash | release | 架构特定 checksum |
| `honk-bin` | daeuniverse/honk | tag（无 release） | pkg 名与 tag 译码（`-`→去掉），多架构，jsDelivr 取 example.dae |
| `kcxy-wifi-bin` | Become-ILLUSORY/kcxy-wifi | release | 三架构 checksum |
| `linux-wallpaperengine-v3-bin` | Become-ILLUSORY/linux-wallpaperengine | release | x86-64-v3 自构建 |
| `mactahoe-icon-theme` | vinceliuice/MacTahoe-icon-theme | tag | 日期式 tag（`-`→`.`） |

## 工作方式

- `lib/common.sh`：共享函数（GitHub API 查版本、比较版本、改 PKGBUILD、算 checksum、push AUR）
- `packages/<pkg>.sh`：每个包一个更新逻辑（`run()` 函数）
- `update-all.sh`：遍历每个包——clone AUR 仓库 → 执行包的 `run()` → 有改动就 commit+push

每个包的 `run()` 独立、幂等：当前已是最新时就跳过。

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