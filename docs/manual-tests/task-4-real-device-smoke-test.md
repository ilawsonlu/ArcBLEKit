# Task 4 Real Device Smoke Test

This checklist verifies the Task 4 behavior against a real BLE peripheral:

- scan for a device advertising a target service UUID
- connect to the selected device
- persist `BLEDevice.id`, which maps to `CBPeripheral.identifier`
- reconnect by identifier
- fall back to service UUID scanning when direct retrieval does not find the peripheral

## Requirements

- iPhone or iPad running iOS 14.0+
- A BLE peripheral advertising a known service UUID
- An app target that imports `ArcBLEKit`
- `NSBluetoothAlwaysUsageDescription` in the app target's `Info.plist`

## Test Values

Replace these with values for your device:

```swift
let serviceUUID = CBUUID(string: "FFF0")
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

## Pass Criteria

Task 4 passes real-device smoke testing when:

- scanning by service UUID finds only expected candidates
- connecting to a discovered device succeeds
- saved `BLEDevice.id` can be used for reconnect
- fallback scan does not connect to the wrong device
- timeout and cancellation do not leave a stuck scan or connection attempt
