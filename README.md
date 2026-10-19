# ArcBLEKit

English | [简体中文](README.zh-CN.md)

[![CI](https://github.com/ilawsonlu/ArcBLEKit/actions/workflows/ci.yml/badge.svg)](https://github.com/ilawsonlu/ArcBLEKit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ilawsonlu/ArcBLEKit)](https://github.com/ilawsonlu/ArcBLEKit/releases/latest)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Filawsonlu%2FArcBLEKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ilawsonlu/ArcBLEKit)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Filawsonlu%2FArcBLEKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ilawsonlu/ArcBLEKit)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

ArcBLEKit is a zero-dependency Swift Package for building Bluetooth Low Energy central apps with Swift Concurrency. It provides cancellable scanning, connection, GATT, and notification APIs with explicit timeouts, automatic reconnect, notification restoration, and CoreBluetooth write-backpressure handling.

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

## Why ArcBLEKit?

- **Native Swift Concurrency** — scanning and notifications use asynchronous streams; connection and GATT operations use `async throws`.
- **Predictable failure behavior** — operations support task cancellation, enforce timeouts, and fail pending work on disconnect.
- **Reliable reconnects** — finite automatic retry policies and notification restoration are built in.
- **Safe GATT writes** — characteristic capabilities, maximum payload length, and `.withoutResponse` backpressure are handled for you.
- **Precise subscriptions** — notifications are keyed by service and characteristic UUID, and multiple consumers share the underlying subscription.
- **Focused integration** — no third-party dependencies and support for iOS 14+, macOS 11+, and Swift 5.5+.

| Capability | Direct CoreBluetooth | ArcBLEKit |
| --- | --- | --- |
| Scanning | Delegate callbacks | `AsyncThrowingStream<BLEDevice, Error>` |
| Read and write | Coordinate delegate state manually | Cancellable `async throws` operations |
| Timeouts | Application-managed | Built into connection and GATT options |
| Reconnect | Application-managed | Limited retry policy with state updates |
| Notifications after reconnect | Resubscribe manually | Active subscriptions are restored |
| Write without response | Track readiness callbacks | Backpressure handled automatically |

## Requirements

- Swift 5.5+
- iOS 14.0+ or macOS 11.0+
- Swift Package Manager

Xcode 27 supports deployment targets starting with iOS 15 and macOS 12. ArcBLEKit keeps its lower package declarations for consumers that build with compatible earlier Xcode versions.

## Installation

In Xcode, choose **File > Add Package Dependencies** and enter:

```text
https://github.com/ilawsonlu/ArcBLEKit.git
```

Or add ArcBLEKit to a package manifest:

```swift
dependencies: [
    .package(
        url: "https://github.com/ilawsonlu/ArcBLEKit.git",
        from: "0.2.3"
    )
]
```

Add the Bluetooth usage description required by the app target:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to connect to nearby BLE devices.</string>
```

## Scan for a Service UUID

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

`scan(filter:)` reports Bluetooth power, authorization, and availability failures instead of ending silently. Cancel the consuming task when the UI no longer needs scan results.

## Find and Connect

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

## Save and Reconnect by Peripheral Identifier

`BLEDevice.id` maps to `CBPeripheral.identifier`. Save it after the user chooses a device:

```swift
let savedID = device.id
```

Reconnect later, with an optional fallback scan:

```swift
let session = try await client.reconnect(
    identifier: savedID,
    fallbackScan: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")]),
    options: ConnectionOptions(timeout: 10)
)
```

The identifier is assigned by CoreBluetooth for the current app and Apple device context. It is not a global BLE MAC address.

## System Connections and Dual-Mode Accessories

After Bluetooth is ready, call `try client.retrieveConnectedDevices(withServices: [serviceUUID])`, select the saved identifier, then use `connect(to:)` to establish this client's GATT session. An empty service list returns no devices. Retrieved snapshots have unknown RSSI (zero) and empty advertisement fields; they do not indicate audio readiness.

For compatible CTKD dual-mode hardware, `ConnectionOptions(enableTransportBridging: true)` requests classic Bluetooth profiles after LE connects. The default is false; macOS ignores this option. The system handles pairing, and the app tracks audio readiness separately.

On iOS, observe future system peer events using:

```swift
#if os(iOS)
for try await event in client.connectionEvents(
    matching: ConnectionEventFilter(serviceUUIDs: [serviceUUID])
) {
    if event.kind == .connected, event.device.id == savedID {
        // Route through one app-owned connection task to avoid duplicate requests.
    }
}
#endif
```

Services and identifiers match with OR. An empty filter finishes immediately. Each client owns one event stream: a new subscription finishes the old one; cancelling consumption clears registration. Matching is registered again when Bluetooth powers back on. Events do not establish GATT sessions or confirm audio readiness. This event API is unavailable on macOS.

`reconnect` shares `options.timeout` across the entire recovery. With `fallbackOnConnectionFailure: true` and a fallback scan, half the budget is reserved for scan recovery after connection failure or timeout. Cancellation and permission errors do not trigger fallback. Scanning accepts only the requested identifier. The resulting session retains the full timeout and reconnect policy.

The app owns saved devices, auto-connect preferences, and suppression after manual disconnection. Full background state restoration is not included.

## Read and Write

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

Writes validate characteristic properties and the peripheral's maximum write length. A `.withoutResponse` write waits for CoreBluetooth backpressure when necessary and returns after the value is accepted for transmission.

Inspect the current payload limit before sending:

```swift
let maximum = session.maximumWriteValueLength(for: .withoutResponse)
```

## Notifications

```swift
let updates = try await session.notifications(
    for: CBUUID(string: "FFF3"),
    service: CBUUID(string: "FFF0")
)

for try await data in updates {
    print(data)
}
```

Multiple subscribers to the same service and characteristic share the underlying CoreBluetooth subscription. Active streams are restored after a successful automatic reconnect.

Some non-compliant peripherals support notifications without declaring `.notify` or `.indicate`, or require unfiltered GATT discovery. Compatibility behavior is opt-in:

```swift
let updates = try await session.notifications(
    for: CBUUID(string: "FFF3"),
    service: CBUUID(string: "FFF0"),
    allowUnsupportedProperties: true,
    discoveryMode: .all
)
```

Keep the strict defaults for compliant peripherals.

## Bluetooth and Connection States

```swift
for await state in client.bluetoothStates {
    print("Bluetooth:", state)
}

for await state in session.connectionStates {
    print("Connection:", state)
}
```

All GATT operations have a timeout, support task cancellation, and fail pending work when the peripheral disconnects.

## Documentation and Sample App

- [API documentation](https://swiftpackageindex.com/ilawsonlu/ArcBLEKit/documentation)
- [Real-device sample app](Examples/ArcBLESampleApp)
- [Changelog](CHANGELOG.md)

The sample app demonstrates scanning, persisted peripheral identifiers and services, opt-in foreground automatic recovery, system-connection reuse, optional audio bridging, configurable GATT operations, notifications, and connection-state logging on a physical iPhone or iPad. Manual disconnect pauses foreground automatic recovery until the user explicitly resumes it.

## State Restoration

`BLEClient.Configuration.restoreIdentifier` reserves a CoreBluetooth restoration identifier. Full app relaunch state restoration is not implemented yet.

## Contributing

Bug reports, documentation improvements, and focused pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change.

## License

ArcBLEKit is available under the MIT License. See [LICENSE](LICENSE) for details.
