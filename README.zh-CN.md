# VibeToken

<p align="center">
  <img src="docs/assets/app-icon.png" width="128" alt="VibeToken 应用图标">
</p>

<p align="center">
  一个本地优先的 macOS 菜单栏应用，用于统计 AI 编程工具的 Token、预计费用和中转账号池额度。
</p>

<p align="center">
  <a href="README.md">English</a>
  ·
  <a href="#安装">安装</a>
  ·
  <a href="#隐私">隐私</a>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green">
</p>

VibeToken 面向高频使用 AI 编程工具的开发者，在一个菜单栏弹框中快速查看真实本地用量，不必反复打开多个后台页面。

> [!NOTE]
> 当前为早期预览版，已支持 Codex Desktop 和 Codex CLI。其他编程工具仍在计划中，暂未提供经过 Apple 公证的公开安装包。

## 界面预览

<p align="center">
  <img src="docs/screenshots/menu-popover.png" width="500" alt="VibeToken 菜单栏弹框，展示 Token、预计费用、趋势、分布和中转额度">
</p>

## 核心功能

- 实时读取 Codex Desktop 和 Codex CLI 的本地会话用量，不生成模拟增量。
- 支持今天、滚动 24 小时、7 天和 30 天统计与趋势。
- 展示输入、缓存、输出、推理、模型、工具和会话分布。
- 按模型 API 单价估算费用，并明确展示定价覆盖率。
- 过滤重复累计事件和 fork/subagent replay。
- 可选只读连接 Sub2API，汇总 Codex 5h/7d 账号池额度。
- 原生 macOS 菜单栏界面，支持英文和简体中文。

## 支持范围

| 数据源 | 状态 |
| --- | --- |
| Codex Desktop / CLI | 已支持 |
| Sub2API Codex 账号池 | 已支持，可选 |
| Claude Code | 计划中 |
| Gemini CLI / OpenCode | 计划中 |

VibeToken 不会从 ChatGPT 或 Claude 桌面客户端的对话界面推断精确 Token。订阅用量与 API 单价费用不是同一口径，因此费用始终标记为预计值。

## 安装

要求：macOS 14+、Xcode 16 或 Swift 6 命令行工具，并且本机已有 `~/.codex/sessions` 会话数据。

```bash
git clone https://github.com/giraffegzy-bot/VibeToken.git
cd VibeToken
swift test
./scripts/build-app.sh
open "dist/VibeToken.app"
```

构建脚本会在 `dist/VibeToken.app` 生成 ad-hoc 签名应用，适合本机使用，但不等同于经过 Developer ID 签名和 Apple 公证的正式安装包。

## 使用

1. 打开 VibeToken，点击菜单栏项目。
2. 选择今天、24H、7D 或 30D。
3. 选择实时、5 分钟、30 分钟或手动刷新。
4. 使用语言按钮切换英文或简体中文。

如需监控 Sub2API，在“中转额度”设置中使用管理员账号登录。VibeToken 只读取账号和 Codex 窗口数据，不会重置、编辑或删除中转账号。

## 统计口径

Token 来自本地结构化用量字段，费用按已知模型价格估算：

```text
预计费用 = 输入 * 输入单价
         + 缓存写入 * 输入单价
         + 缓存读取 * 缓存单价
         +（输出 + 推理）* 输出单价
```

未知模型不会套用猜测价格。历史用量目前按已安装版本内置的价格目录回算。

Sub2API 中每个符合条件的实体账号按 `100%` 总额度计算，实际可用额度取该账号 5h 和 7d 窗口剩余值中的较小值。明确的运行时限流状态和已耗尽窗口优先于快照过期判断，影子账号不重复计数。

## 隐私

- 不读取或保存对话正文。
- Codex JSONL 原始日志始终只读。
- 用量索引保存在本机应用支持目录。
- 日志不记录 Token、密码、Cookie、账号地址或响应正文。
- Sub2API 登录信息保存在受限权限的本地文件中，不使用 macOS Keychain。与 Keychain 相比，同一 macOS 用户权限下的其他进程更容易读取这些文件。

## 开发

```bash
swift build
swift test
```

修改数据源、统计公式、持久化结构或安全边界前，请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)
