# 贡献指南

感谢你关注 VibeToken。

## 开始之前

- Bug、文档修正和小范围测试补充可以直接提交 Pull Request。
- 新数据源、统计口径、持久化结构或安全策略变更，请先创建 Issue 讨论。
- 不要提交真实会话日志、服务地址、账号、密码、Token、Cookie 或其他个人数据。

## 本地开发

环境要求：macOS 14+、Xcode 16 或兼容 Swift 6 的命令行工具。

```bash
git clone https://github.com/giraffegzy-bot/VibeToken.git
cd VibeToken
swift test
swift run VibeToken
```

构建本地应用：

```bash
./scripts/build-app.sh
open "dist/VibeToken.app"
```

## Pull Request 要求

1. 修改范围保持单一，避免混入无关重构。
2. 新行为必须覆盖成功、失败、空数据和边界状态。
3. 涉及统计口径时，说明输入字段、公式、去重逻辑和未知数据处理方式。
4. 涉及外部服务时，设置超时、页数或并发上限，并确保日志脱敏。
5. 修改界面时，同步检查中文、英文和 `500×720` 菜单窗口。
6. 修改行为后，同步 README、专项文档和验收标准。
7. 提交前运行 `swift test`。

## 代码原则

- 真实数据优先，不生成模拟 Token 冒充实时用量。
- 本地优先，不读取或上传对话正文。
- 未知模型保持未定价，不使用静默兜底价格。
- 原始 AI 工具日志只读，派生数据写入独立本地数据库。
- 破坏性操作和外部写操作必须有明确确认与可审计反馈。
