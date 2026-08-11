# 为 ArcBLEKit 贡献代码

[English](CONTRIBUTING.md) | 简体中文

感谢你帮助改进 ArcBLEKit。我们欢迎 Bug 报告、文档修正、测试以及范围明确的 API 提案。

## 提交 Issue 之前

- 搜索现有 Issue，并确认问题在最新版本中仍然存在。
- 将 Bug 精简为可以分享的最小复现示例。
- 提供 ArcBLEKit、Xcode、Swift、操作系统和设备版本。
- 对于 BLE 行为，请描述相关的服务、特征和特征属性。
- 删除设备标识符、负载和日志中包含的隐私信息。

如果准备提出较大的公共 API 修改，请先通过 Feature Request 描述需要解决的问题。这样更容易保持源码兼容性，并确保组件继续专注于核心目标。

## 本地开发

开发 ArcBLEKit 需要安装了 Xcode 的 macOS，以及 Swift 5.5 或更高版本的工具链。

```bash
git clone https://github.com/ilawsonlu/ArcBLEKit.git
cd ArcBLEKit
swift package dump-package
swift test
```

使用以下命令验证 iOS 构建：

```bash
xcodebuild build \
  -scheme ArcBLEKit \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

`Examples/ArcBLESampleApp` 中的示例 App 需要实体 iPhone 或 iPad 以及一个 BLE 外设。请按照示例目录中的 README 完成手动测试流程。

## Pull Request

- 保持修改小而专注。
- 每项行为修改都应新增或更新测试。
- 修改异步操作时，应保留任务取消、超时和断开连接的既有行为。
- 除非收益明显大于集成成本，否则不要增加依赖。
- 为公共 API 编写文档，并在用户可见行为发生变化时更新 `CHANGELOG.md`。
- 不要提交 `.build`、Derived Data、签名设置、设备标识符或捕获的 BLE 负载。

CI 会运行 SwiftPM 测试套件、iOS 构建和 DocC 文档构建。CI 无法覆盖依赖 BLE 硬件的真机行为，因此请在 Pull Request 中说明完成了哪些设备测试。

## 报告安全问题

对于可能暴露应用或设备数据的漏洞，请勿创建公开 Issue。如果仓库已启用 GitHub 私有漏洞报告，请通过该渠道提交。
