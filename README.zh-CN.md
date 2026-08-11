# ArcBLEKit

[English](README.md) | 简体中文

[![CI](https://github.com/ilawsonlu/ArcBLEKit/actions/workflows/ci.yml/badge.svg)](https://github.com/ilawsonlu/ArcBLEKit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ilawsonlu/ArcBLEKit)](https://github.com/ilawsonlu/ArcBLEKit/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-5.5%2B-orange.svg)](https://www.swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2014%2B%20%7C%20macOS%2011%2B-lightgrey.svg)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

ArcBLEKit 是一个零第三方依赖的 Swift Package，用于通过 Swift Concurrency 构建低功耗蓝牙（BLE）中心设备应用。它提供支持取消的扫描、连接、GATT 操作和通知 API，并内置明确的超时机制、自动重连、通知恢复以及 CoreBluetooth 写入背压处理。

```swift
let device = try await client.findDevice(
    matching: ScanFilter(serviceUUIDs: [serviceUUID]),
    timeout: 10
)
let session = try await client.connect(to: device)
let value = try await session.read(
    characteristic: characteristicUUID,
    service: serviceUUID
)
```

## 为什么选择 ArcBLEKit？

- **原生 Swift Concurrency** — 扫描和通知使用异步流，连接和 GATT 操作使用 `async throws`。
- **可预测的失败行为** — 操作支持任务取消、强制执行超时，并在外设断开时结束尚未完成的任务。
- **可靠的重连机制** — 内置有限次数的自动重试策略和通知恢复。
- **安全的 GATT 写入** — 自动处理特征能力、最大负载长度和 `.withoutResponse` 写入背压。
- **精确的通知订阅** — 使用服务 UUID 与特征 UUID 共同标识通知，多个消费者共享底层订阅。
- **轻量集成** — 无第三方依赖，支持 iOS 14+、macOS 11+ 和 Swift 5.5+。

| 能力 | 直接使用 CoreBluetooth | ArcBLEKit |
| --- | --- | --- |
| 扫描 | Delegate 回调 | `AsyncThrowingStream<BLEDevice, Error>` |
| 读写 | 手动协调 Delegate 状态 | 支持取消的 `async throws` 操作 |
| 超时 | 由应用自行管理 | 内置于连接和 GATT 选项 |
| 重连 | 由应用自行管理 | 提供带状态更新的有限重试策略 |
| 重连后的通知 | 手动重新订阅 | 自动恢复活跃订阅 |
| 无响应写入 | 手动跟踪就绪回调 | 自动处理背压 |

## 环境要求

- Swift 5.5+
- iOS 14.0+ 或 macOS 11.0+
- Swift Package Manager

## 安装

在 Xcode 中选择 **File > Add Package Dependencies**，然后输入：

```text
https://github.com/ilawsonlu/ArcBLEKit.git
```

也可以将 ArcBLEKit 添加到 Package 清单中：

```swift
dependencies: [
    .package(
        url: "https://github.com/ilawsonlu/ArcBLEKit.git",
        from: "0.2.2"
    )
]
```

在 App Target 中添加蓝牙使用说明：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>此 App 使用蓝牙连接附近的低功耗蓝牙设备。</string>
```

## 按服务 UUID 扫描

```swift
import ArcBLEKit
import CoreBluetooth

let client = BLEClient()
let service = CBUUID(string: "FFF0")

try await client.waitUntilReady(timeout: 10)

for try await device in client.scan(
    filter: ScanFilter(serviceUUIDs: [service])
) {
    print(device.name ?? "Unknown", device.id, device.rssi)
}
```

`scan(filter:)` 会明确报告蓝牙电源、授权和可用性错误，而不是静默结束。当界面不再需要扫描结果时，请取消消费该异步流的任务。

## 查找并连接

```swift
let device = try await client.findDevice(
    matching: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")]),
    timeout: 10
)

let session = try await client.connect(
    to: device,
    options: ConnectionOptions(
        timeout: 10,
        autoReconnect: .limited(maxAttempts: 3, delay: 1)
    )
)
```

## 保存外设标识符并重新连接

`BLEDevice.id` 对应 `CBPeripheral.identifier`。请在用户选择设备后保存它：

```swift
let savedID = device.id
```

之后可以使用可选的回退扫描重新连接：

```swift
let session = try await client.reconnect(
    identifier: savedID,
    fallbackScan: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")]),
    options: ConnectionOptions(timeout: 10)
)
```

该标识符由 CoreBluetooth 针对当前 App 和 Apple 设备环境分配，并不是全局 BLE MAC 地址。

## 读取和写入

```swift
let value = try await session.read(
    characteristic: CBUUID(string: "FFF1"),
    service: CBUUID(string: "FFF0"),
    options: GATTOperationOptions(timeout: 10)
)

try await session.write(
    Data([0x01, 0x02]),
    to: CBUUID(string: "FFF2"),
    service: CBUUID(string: "FFF0"),
    type: .withResponse
)
```

写入操作会验证特征属性和外设支持的最大写入长度。`.withoutResponse` 写入会在必要时等待 CoreBluetooth 背压解除，并在数据被接受发送后返回。

发送前可以查看当前负载上限：

```swift
let maximum = session.maximumWriteValueLength(for: .withoutResponse)
```

## 通知

```swift
let updates = try await session.notifications(
    for: CBUUID(string: "FFF3"),
    service: CBUUID(string: "FFF0")
)

for try await data in updates {
    print(data)
}
```

针对相同服务和特征的多个订阅者会共享底层 CoreBluetooth 通知订阅。自动重连成功后，活跃的通知流会被恢复。

某些不符合规范的外设可以发送通知，却没有声明 `.notify` 或 `.indicate` 属性；还有一些外设要求执行未过滤的 GATT 发现。兼容行为需要显式启用：

```swift
let updates = try await session.notifications(
    for: CBUUID(string: "FFF3"),
    service: CBUUID(string: "FFF0"),
    allowUnsupportedProperties: true,
    discoveryMode: .all
)
```

对于符合规范的外设，请保留严格的默认设置。

## 蓝牙和连接状态

```swift
for await state in client.bluetoothStates {
    print("Bluetooth:", state)
}

for await state in session.connectionStates {
    print("Connection:", state)
}
```

所有 GATT 操作均带有超时、支持任务取消，并会在外设断开时结束尚未完成的任务。

## 文档和示例 App

- [API 文档](https://swiftpackageindex.com/ilawsonlu/ArcBLEKit/documentation)
- [真机示例 App](Examples/ArcBLESampleApp)
- [更新日志](CHANGELOG.md)

示例 App 展示了扫描、持久化外设标识符、连接和重连流程、可配置 GATT 操作、通知，以及在实体 iPhone 或 iPad 上记录连接状态。

## 状态恢复

`BLEClient.Configuration.restoreIdentifier` 预留了 CoreBluetooth 恢复标识符。目前尚未实现 App 重新启动后的完整状态恢复。

## 参与贡献

欢迎提交 Bug 报告、文档改进和范围明确的 Pull Request。提交修改前请阅读[中文贡献指南](CONTRIBUTING.zh-CN.md)。

## 许可证

ArcBLEKit 使用 MIT 许可证，详情请参阅 [LICENSE](LICENSE)。
