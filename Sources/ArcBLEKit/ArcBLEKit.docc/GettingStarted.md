# Getting Started

Add ArcBLEKit to an iOS app, discover a peripheral, and exchange GATT data.

## Add the package

In Xcode, choose **File > Add Package Dependencies** and enter:

```text
https://github.com/ilawsonlu/ArcBLEKit.git
```

Select version `0.2.2` or newer. Then add the Bluetooth usage description to the app target's `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to connect to nearby devices.</string>
```

## Scan and connect

Create one ``BLEClient`` for the lifetime of the central workflow. Wait for Bluetooth to become ready before starting a scan.

```swift
import ArcBLEKit
import CoreBluetooth

let client = BLEClient()
let serviceUUID = CBUUID(string: "FFF0")

try await client.waitUntilReady(timeout: 10)

let device = try await client.findDevice(
    matching: ScanFilter(serviceUUIDs: [serviceUUID]),
    timeout: 10
)

let session = try await client.connect(
    to: device,
    options: ConnectionOptions(timeout: 10)
)
```

To present every matching device instead, iterate the throwing stream returned by `scan(filter:)`. End the task or stop iterating when the UI no longer needs scan results.

## Read and write

Identify characteristics by both their service and characteristic UUID. This avoids ambiguity when a peripheral reuses a characteristic UUID in more than one service.

```swift
let readUUID = CBUUID(string: "FFF1")
let writeUUID = CBUUID(string: "FFF2")

let value = try await session.read(
    characteristic: readUUID,
    service: serviceUUID
)

try await session.write(
    Data([0x01, 0x02]),
    to: writeUUID,
    service: serviceUUID,
    type: .withResponse
)
```

ArcBLEKit validates characteristic properties and payload length before writing. For `.withoutResponse`, it also waits for CoreBluetooth backpressure to clear.

## Subscribe to notifications

```swift
let notificationUUID = CBUUID(string: "FFF3")
let updates = try await session.notifications(
    for: notificationUUID,
    service: serviceUUID
)

for try await data in updates {
    print(data)
}
```

Cancel the consuming task to remove that subscription. Multiple consumers of the same service and characteristic share the underlying CoreBluetooth notification subscription.

## Handle failures

ArcBLEKit reports operational failures as ``BLEError`` values. Treat cancellation, timeouts, authorization, powered-off Bluetooth, and disconnection as distinct user experiences.

```swift
do {
    let value = try await session.read(
        characteristic: readUUID,
        service: serviceUUID
    )
    print(value)
} catch BLEError.operationCancelled {
    // The owning task ended; usually no user-facing error is needed.
} catch let error as BLEError {
    // Update the UI or offer a retry appropriate to the failure.
    print(error)
}
```
