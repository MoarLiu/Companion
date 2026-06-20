<div align="center">
  <img src="assets/companion-readme-hero.png" alt="Companion" width="620" />

  <h1>Companion</h1>

  <h3>以小花儿为核心的本地桌面陪伴、记录、提醒、专注与 MCP 工作流应用。</h3>

  [English](README.md) | 中文
</div>

## 当前状态

Companion 是面向“小花儿桌面伴侣”产品线的新 macOS App 项目库。

当前种子版本：`0.1.0`

## 产品方向

Companion 聚焦 Companion 代码里更偏日常陪伴和个人工作流的部分：

- 小花儿桌面宠物与状态陪伴
- Journal 与 Focus Journal
- 提醒
- 番茄专注
- 语音、音乐和本地陪伴反馈
- 服务于陪伴工作流的 AI Quick Actions
- `companion.*` namespace 下的本地 stdio MCP 工具

与 Companion 产品本身无关的开发者工具链能力已经从 app 边界移除。AI 功能现在使用 Companion 自己的轻量设置，MCP 只暴露本地陪伴工作流工具。

## 本地数据

Companion 默认写入自己的数据根：

```text
~/.companion
```

开启 iCloud 存储后使用：

```text
iCloud Drive/Companion
```

这样 Companion 数据默认保持在本 app 内；只有你显式开启 iCloud 时才会移动到 iCloud Drive/Companion。

## 轻量 AI 设置

Companion 使用自己的轻量 AI 设置来支持 AI 会话、AI 翻译、Quick Actions 和 Focus Review。入口在菜单：

```text
AI Quick Actions -> AI Settings...
```

这一版只配置一套 OpenAI-compatible provider：

- Provider Name
- API Base URL
- Model
- API Key

非敏感设置写入当前数据根的 `ai-settings.json`；API Key 写入同一数据根下的 `ai-credentials.json`，主配置里只保存密钥引用。再次编辑时 API Key 可以留空，表示沿用已保存密钥。

## MCP

随 app 打包的 helper 名称是：

```text
Companion.app/Contents/MacOS/CompanionMCP
```

当前工具 namespace：

```text
companion.reminder.parseDraft
companion.reminder.create
companion.reminder.createBatch
companion.journal.appendToday
companion.pomodoro.startFocus
companion.asset.upload
companion.focusReview.generate
```

helper 会保持轻量：提醒、Journal、番茄钟、素材上传和 Focus Review。

## 构建

构建 SwiftPM 可执行文件：

```bash
swift build --product Companion
```

构建本地 app bundle：

```bash
CODE_SIGN_IDENTITY=- bash scripts/build-menu-bar-app.sh
```

app bundle 输出到：

```text
Companion.app
```

运行聚焦后的测试脚本：

```bash
bash scripts/run-tests.sh
```
