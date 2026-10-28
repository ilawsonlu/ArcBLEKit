# ArcBLEKit

[English](README.md) | 简体中文

[![CI](https://github.com/ilawsonlu/ArcBLEKit/actions/workflows/ci.yml/badge.svg)](https://github.com/ilawsonlu/ArcBLEKit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ilawsonlu/ArcBLEKit)](https://github.com/ilawsonlu/ArcBLEKit/releases/latest)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Filawsonlu%2FArcBLEKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ilawsonlu/ArcBLEKit)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Filawsonlu%2FArcBLEKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ilawsonlu/ArcBLEKit)
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

Xcode 27 支持的最低部署目标为 iOS 15 和 macOS 12。ArcBLEKit 保留较低的 Package 平台声明，供使用兼容旧版 Xcode 的项目继续使用。

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
        from: "0.2.3"
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

## 复用系统连接与双模音箱

蓝牙就绪后，可先查询系统已连接且提供指定 GATT 服务的外设，按保存的 identifier 选择设备，再调用 `connect` 建立本 App 的会话：

```swift
let connected = try client.retrieveConnectedDevices(withServices: [serviceUUID])
if let device = connected.first(where: { $0.id == savedID }) {
    let session = try await client.connect(to: device)
    // 使用 session 读写 GATT。
}
```

返回结果不代表音频已就绪；RSSI 未知时为 0，广播字段为空。空服务列表返回空结果。

在支持 CTKD 的双模设备上，连接时可设置 `ConnectionOptions(enableTransportBridging: true)`，请求系统拉起传统蓝牙配置。默认关闭；macOS 忽略该选项。配对授权和音频状态仍由系统及 App 管理。

在 iOS 上可监听后续系统连接事件，无需持续扫描：

```swift
#if os(iOS)
for try await event in client.connectionEvents(
    matching: ConnectionEventFilter(serviceUUIDs: [serviceUUID])
) {
    if event.kind == .connected, event.device.id == savedID {
        // 交给 App 的统一连接任务处理，避免与启动恢复或用户点击重复连接。
    }
}
#endif
```

服务与设备 identifier 按 OR 匹配；空过滤器直接结束。每个 client 只有一个事件流，新订阅结束旧订阅，取消消费任务清除注册；蓝牙再次开启后重新注册。事件仅反映系统 peer 状态，不能直接当成 GATT 会话或音频已就绪。macOS 不提供该事件 API。

`reconnect` 的 `options.timeout` 为整次恢复的共享预算。设置 `fallbackOnConnectionFailure: true` 且提供 `fallbackScan` 时，会为扫描恢复预留一半预算；仅连接失败或超时触发回退，取消和权限错误不会触发。回退扫描只接受目标 identifier。成功后的会话仍保留完整超时和重连策略。

设备记录、自动连接偏好、主动断开后的暂停策略由 App 保存和调度。此能力不包含完整后台状态恢复。

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

自动重连会保留每个消费者的兼容和发现配置，原通知流可以继续接收数据。
共享通道仅在所有活跃消费者都设置 `allowUnsupportedProperties: true` 时容忍通知设置失败；
只要有一个活跃消费者要求 `.all`，恢复就使用全量发现。
严格消费者加入尚未成功确认设置的兼容通道时，必须先通过属性检查并成功开启通知。
取消消费者会移除其配置，最后一个消费者退出时才关闭底层通知。
兼容模式仍会传播取消、断线、发现错误和超时。首次订阅使用该次调用的操作超时，恢复使用会话的连接超时。

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
- [掘金博客专栏](https://juejin.cn/column/7674961083950858259)
- [真机示例 App](Examples/ArcBLESampleApp)
- [更新日志](CHANGELOG.md)

示例 App 展示了扫描、保存外设标识符及服务、可选的前台自动恢复、复用系统连接、音频桥接开关、可配置 GATT 操作、通知，以及在实体 iPhone 或 iPad 上记录连接状态。用户主动断开后会暂停前台自动连接，直到用户明确恢复。

## 状态恢复

`BLEClient.Configuration.restoreIdentifier` 预留了 CoreBluetooth 恢复标识符。目前尚未实现 App 重新启动后的完整状态恢复。

## 参与贡献

欢迎提交 Bug 报告、文档改进和范围明确的 Pull Request。提交修改前请阅读[中文贡献指南](CONTRIBUTING.zh-CN.md)。

## 许可证

ArcBLEKit 使用 MIT 许可证，详情请参阅 [LICENSE](LICENSE)。
