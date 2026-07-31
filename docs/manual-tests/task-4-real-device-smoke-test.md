# Task 4 Real Device Smoke Test

This checklist verifies the Task 4 behavior against a real BLE peripheral:

- scan for a device advertising a target service UUID
- connect to the selected device
- persist `BLEDevice.id`, which maps to `CBPeripheral.identifier`
- reconnect by identifier
- fall back to service UUID scanning when direct retrieval does not find the peripheral
- read, write, and receive notifications without hanging
- recover active notifications after an unexpected disconnect

## Requirements

- iPhone or iPad running iOS 14.0+
- A BLE peripheral advertising a known service UUID
- An app target that imports `ArcBLEKit`
- `NSBluetoothAlwaysUsageDescription` in the app target's `Info.plist`

## Test Values

Replace these with values for your device:

```swift
let serviceUUID = CBUUID(string: "FFF0")
let readUUID = CBUUID(string: "FFF1")
let writeUUID = CBUUID(string: "FFF2")
let notifyUUID = CBUUID(string: "FFF3")
let timeout: TimeInterval = 10
```

## 1. Scan by Service UUID

Run:

```swift
let client = BLEClient()
let filter = ScanFilter(serviceUUIDs: [serviceUUID])
let device = try await client.findDevice(matching: filter, timeout: timeout)

print("Found:", device.id, device.name ?? "Unknown", device.rssi)
```

Expected:

- Bluetooth permission prompt appears if permission has not been granted.
- The target device is discovered before timeout.
- `device.advertisedServiceUUIDs` includes the expected service UUID when the peripheral advertises it.
- `device.id` is a stable `UUID` for this app/device installation.

## 2. Connect to the Discovered Device

Run:

```swift
let session = try await client.connect(
    to: device,
    options: ConnectionOptions(timeout: timeout)
)

print("Connected:", session.device.id)
```

Expected:

- Connection succeeds.
- `session.device.id == device.id`.

## 3. Persist the Peripheral Identifier

Save the identifier after the user selects the device:

```swift
let savedIdentifier = device.id
```

Expected:

- The app stores `savedIdentifier` in app storage, such as `UserDefaults` or Keychain.
- Do not treat this value as a BLE MAC address. iOS assigns it for the current app and iOS device context.

## 4. Reconnect by Identifier

Close the session or restart the app, then run:

```swift
let session = try await client.reconnect(
    identifier: savedIdentifier,
    fallbackScan: ScanFilter(serviceUUIDs: [serviceUUID]),
    options: ConnectionOptions(timeout: timeout)
)

print("Reconnected:", session.device.id)
```

Expected:

- If iOS can retrieve the peripheral, reconnect starts without visible scan latency.
- If retrieval does not return the peripheral, ArcBLEKit scans by the fallback service UUID and only connects when the discovered `BLEDevice.id` equals `savedIdentifier`.
- `session.device.id == savedIdentifier`.

## 5. Negative Check: Wrong Identifier

Run with a random identifier:

```swift
let randomIdentifier = UUID()

do {
    _ = try await client.reconnect(
        identifier: randomIdentifier,
        fallbackScan: ScanFilter(serviceUUIDs: [serviceUUID]),
        options: ConnectionOptions(timeout: 5)
    )
    assertionFailure("Expected reconnect to fail")
} catch {
    print("Expected failure:", error)
}
```

Expected:

- The library does not connect to other peripherals advertising the same service UUID.
- The call fails with `scanTimedOut` or `deviceNotFound`, depending on whether fallback scan is used.

## 6. Timeout and Cancellation Checks

Timeout:

```swift
do {
    _ = try await client.findDevice(
        matching: ScanFilter(serviceUUIDs: [serviceUUID], name: "Definitely Missing"),
        timeout: 3
    )
    assertionFailure("Expected scan timeout")
} catch {
    print("Expected timeout:", error)
}
```

Cancellation:

```swift
let task = Task {
    try await client.findDevice(matching: ScanFilter(serviceUUIDs: [serviceUUID]), timeout: 30)
}

task.cancel()
```

Expected:

- Timeout returns a BLE error instead of hanging.
- Cancellation stops the scan and returns `operationCancelled`.

## 7. Read, Write, and Notify

Using the connected session:

```swift
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

let updates = try await session.notifications(
    for: notifyUUID,
    service: serviceUUID
)

for try await data in updates {
    print("Notification:", data)
}
```

Expected:

- Reads and writes finish before their configured timeout.
- A write with response reports the peripheral's error.
- A write without response returns without waiting for `didWriteValueFor`.
- Notification values continue to arrive without being mistaken for read responses.

## 8. Backpressure and Payload Limits

Run repeated `.withoutResponse` writes using payloads no larger than:

```swift
session.maximumWriteValueLength(for: .withoutResponse)
```

Expected:

- Writes pause while CoreBluetooth reports that it cannot send.
- Writes resume after the peripheral becomes ready.
- An oversized payload fails with `valueTooLong` instead of being sent.

## 9. Unexpected Disconnect and Notification Recovery

Connect with:

```swift
ConnectionOptions(
    timeout: 10,
    autoReconnect: .limited(maxAttempts: 3, delay: 1)
)
```

Keep a notification stream active, then power-cycle or move the peripheral out of range.

Expected:

- States progress through `disconnected`, `reconnecting`, and `connecting`.
- A successful reconnect emits `connected`, rediscovers GATT attributes, restores notification state, and emits `ready`.
- The existing notification stream receives new data after recovery.
- Calling `session.disconnect()` never starts automatic reconnect.

## 10. Stress Checks

Repeat the following on a physical device:

- 100 sequential reads
- 100 writes with response
- sustained writes without response at the device's supported rate
- simultaneous notification streams on multiple characteristics
- weak-signal disconnect and reconnect cycles
- payloads at exactly the reported maximum write length

Expected:

- No operation waits forever.
- Cancellation or disconnect completes all pending callers with an error.
- Notification data stays routed to the matching service and characteristic.

## Pass Criteria

Task 4 passes real-device smoke testing when:

- scanning by service UUID finds only expected candidates
- connecting to a discovered device succeeds
- saved `BLEDevice.id` can be used for reconnect
- fallback scan does not connect to the wrong device
- timeout and cancellation do not leave a stuck scan or connection attempt
- read, write, and notification operations complete or fail predictably
- automatic reconnect restores active notification streams
- backpressure and maximum payload checks behave correctly
