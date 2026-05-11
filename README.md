# ArcBLEKit

ArcBLEKit is a Swift Package for iOS BLE central apps. It wraps CoreBluetooth with Swift Concurrency APIs for scanning, connecting, reconnecting, reading, writing, and subscribing to notifications.

## Requirements

- Swift 5.5+
- iOS 14.0+
- Swift Package Manager

## Installation

Add this package in Xcode through **File > Add Package Dependencies** and select the repository URL for ArcBLEKit.

## iOS Permissions

Add the Bluetooth usage description required by your app target:

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

for await device in client.scan(filter: ScanFilter(serviceUUIDs: [service])) {
    print(device.name ?? "Unknown", device.id, device.rssi)
}
```

## Find and Connect

```swift
let device = try await client.findDevice(
    matching: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")]),
    timeout: 10
)

let session = try await client.connect(
    to: device,
    options: ConnectionOptions(timeout: 10)
)
```

## Save and Reconnect by Peripheral Identifier

`BLEDevice.id` maps to `CBPeripheral.identifier`. Save it after the user chooses a device:

```swift
let savedID = device.id
```

Reconnect later:

```swift
let session = try await client.reconnect(
    identifier: savedID,
    fallbackScan: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")]),
    options: ConnectionOptions(timeout: 10)
)
```

`CBPeripheral.identifier` is assigned by iOS. It is useful for reconnecting to a previously selected device from the same app and iOS device, but it is not a global BLE MAC address.

## Read and Write

```swift
let value = try await session.read(
    characteristic: CBUUID(string: "FFF1"),
    service: CBUUID(string: "FFF0")
)

try await session.write(
    Data([0x01, 0x02]),
    to: CBUUID(string: "FFF2"),
    service: CBUUID(string: "FFF0"),
    type: .withResponse
)
```

## Notifications

```swift
let updates = try await session.notifications(
    for: CBUUID(string: "FFF3"),
    service: CBUUID(string: "FFF0")
)

for await data in updates {
    print(data)
}
```

## State Restoration

`BLEClient.Configuration.restoreIdentifier` reserves a hook for CoreBluetooth restoration identifiers. Full app relaunch state restoration is not implemented in the first version.
