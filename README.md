<div align="center">
  <img src="assets/companion-readme-hero.png" alt="Companion" width="680" />

  <h1>Companion</h1>

  <h3>一个以小花儿为核心的 macOS 本地桌面陪伴 App。</h3>

  中文文档
</div>

## 简介

Companion 是一个本地优先的 macOS 菜单栏应用，围绕“小花儿”桌面伴侣，把提醒、番茄专注、日记、AI 快捷动作和本地 MCP 工作流放在同一个轻量工具里。

当前版本：`0.2.1`

## 核心功能

- 小花儿桌面伴侣：桌面状态陪伴、语音提示、提醒反馈和专注反馈。
- 提醒事项：快速添加提醒、查看提醒记录、到点弹出提醒。
- 番茄闹钟：开始专注、开始休息、暂停、继续、停止和专注记录。
- 日记：创建新日记、查看日记、今日记录和专注复盘。
- AI 快捷动作：处理剪贴板内容、上传剪贴板图片，并把结果接入日记、提醒和专注工作流。
- Companion 数据：导入、导出、诊断包、iCloud 数据迁移和本地数据目录入口。
- Companion MCP：提供本地 stdio MCP 工具，便于外部 agent 调用提醒、日记、番茄钟、素材上传和 Focus Review。

## 菜单结构

```text
Companion
├─ 仪表盘
├─ 提醒事项
│  ├─ 添加提醒
│  └─ 查看记录
├─ 番茄闹钟
│  ├─ 开始专注 25 分钟
│  ├─ 开始休息 5 分钟
│  ├─ 专注复盘
│  └─ 提醒 → 专注 → 日记
├─ 日记
│  ├─ 创建新日记
│  └─ 查看日记
├─ 音乐
│  ├─ 开始播放
│  ├─ 停止播放
│  ├─ 下一首
│  ├─ 上一首
│  └─ 查看歌单
├─ 宠物皮肤...
├─ AI 快捷动作
├─ Companion 数据
├─ 检查更新
└─ 退出 Companion
```

设置类选项尽量收进仪表盘，菜单栏只保留高频动作和入口。

## 本地数据与隐私

Companion 默认把数据写到本机：

```text
~/.companion
```

开启 iCloud 存储后，数据会移动到：

```text
iCloud Drive/Companion
```

发布包不会包含本机运行数据、AI Key、上传凭据、提醒记录、番茄记录、日记文档或其他私有配置。打包脚本会拒绝把 `.companion`、`.env`、`auth.json`、`profiles.json`、`config.toml`、私钥、证书、provisioning profile 等敏感路径放进 DMG。

## AI 设置

Companion 使用自己的轻量 AI 设置，不沿用复杂的 provider bridge 配置。

当前支持一套 OpenAI-compatible provider：

- Provider Name
- API Base URL
- Model
- API Key

非敏感配置保存到当前 Companion 数据根下的 `ai-settings.json`。API Key 保存到 `ai-credentials.json`，主配置只保存引用。再次编辑时 API Key 可以留空，表示继续使用已保存密钥。

## MCP 工具

随 App 打包的 MCP helper：

```text
Companion.app/Contents/MacOS/CompanionMCP
```

当前工具命名空间：

```text
companion.reminder.parseDraft
companion.reminder.create
companion.reminder.createBatch
companion.journal.appendToday
companion.pomodoro.startFocus
companion.asset.upload
companion.focusReview.generate
```

## 构建与测试

构建 SwiftPM 可执行文件：

```bash
swift build --product Companion
```

运行测试：

```bash
scripts/run-tests.sh
```

构建本地 `.app`：

```bash
CODE_SIGN_IDENTITY=- bash scripts/build-menu-bar-app.sh
```

`build-menu-bar-app.sh` 默认会递增 `scripts/version.env` 里的 `APP_BUILD`，方便区分本地测试包。若外层发布流程已经传入 `APP_BUILD`，脚本不会重复递增。

## 打包 DMG

生成本地 DMG：

```bash
CODE_SIGN_IDENTITY=- bash scripts/package-dmg.sh
```

输出位置：

```text
dist/Companion-0.2.1-macos-arm64.dmg
dist/Companion-0.2.1-macos-arm64.dmg.sha256
```

执行完整发布烟测：

```bash
CODE_SIGN_IDENTITY=- bash scripts/smoke-release.sh
```

烟测会检查：

- 测试脚本
- App bundle 必要资源
- Info.plist 版本和 build
- 代码签名
- 敏感路径和敏感 macOS metadata
- DMG checksum
- CompanionMCP stdio 协议

## GitHub 首发流程

新建 GitHub 仓库并发布时，建议按这个顺序执行：

```bash
gh auth login -h github.com
gh repo create Companion --private --source=. --remote=origin
git add .
git commit -m "Initial Companion release"
git tag v0.2.1
git push -u origin main
git push origin v0.2.1
gh release create v0.2.1 \
  dist/Companion-0.2.1-macos-arm64.dmg \
  dist/Companion-0.2.1-macos-arm64.dmg.sha256 \
  --title "Companion 0.2.1" \
  --notes-file CHANGELOG.md
```

如果要发布公开仓库，把 `--private` 改成 `--public`。

## 发布前检查清单

- `git status -sb` 只包含本次要发布的文件。
- `scripts/run-tests.sh` 通过。
- `CODE_SIGN_IDENTITY=- bash scripts/smoke-release.sh` 通过。
- `dist/*.dmg.sha256` 校验通过。
- 仓库内没有 `.env`、私钥、证书、provisioning profile、个人数据和本地运行状态。
- GitHub CLI 已重新登录，并确认目标仓库名是 `Companion`。

## 签名与公证

本地开发包默认使用 ad-hoc 签名：

```bash
CODE_SIGN_IDENTITY=-
```

正式对外分发前，建议配置 Developer ID Application 签名和 Apple notarization。`scripts/package-dmg.sh` 已预留 `NOTARIZE=1` 与 `COMPANION_NOTARY_PROFILE`。
