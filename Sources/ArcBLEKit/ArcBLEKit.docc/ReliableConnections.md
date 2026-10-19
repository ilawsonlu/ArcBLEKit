# Reliable Connections

Choose a reconnect policy and understand how ArcBLEKit handles active operations during connection changes.

## Enable limited automatic reconnect

Automatic reconnect is disabled by default. Enable a finite retry policy when the app should recover from a temporary link loss:

```swift
let session = try await client.connect(
    to: device,
    options: ConnectionOptions(
        timeout: 10,
        autoReconnect: .limited(maxAttempts: 3, delay: 1)
    )
)
```

Observe `session.connectionStates` to keep the UI synchronized with reconnect attempts. Calling `disconnect()` is a deliberate user action and does not start automatic reconnect.

## Restore a saved peripheral

Persist `BLEDevice.id` after the user selects a device. On a later launch, ask CoreBluetooth for that peripheral and optionally fall back to scanning:

```swift
let session = try await client.reconnect(
    identifier: savedIdentifier,
    fallbackScan: ScanFilter(serviceUUIDs: [serviceUUID]),
    options: ConnectionOptions(
        timeout: 10,
        autoReconnect: .limited(maxAttempts: 3, delay: 1)
    )
)
```

The identifier is assigned by CoreBluetooth for the current app and Apple device context. It is not a Bluetooth MAC address and should not be treated as a cross-device identity.

## Reuse a system connection

After Bluetooth is ready, use `try client.retrieveConnectedDevices(withServices: [serviceUUID])` and select the saved peripheral identifier. Call `connect(to:)` even when the device is already connected to the system: the app still needs its own GATT session. These snapshots have unknown RSSI (zero) and no advertisement data.

On iOS, `client.connectionEvents(matching: ConnectionEventFilter(serviceUUIDs: [serviceUUID]))` observes future system peer connections and disconnections. Services and identifiers match with OR. Each client owns one event stream; a new stream finishes the old one, and cancelling consumption clears registration. An empty filter finishes immediately. Matching resumes when Bluetooth powers back on. This API is unavailable on macOS.

For compatible CTKD dual-mode hardware, opt into `ConnectionOptions(enableTransportBridging: true)` to request classic profiles after an LE connection. The setting is preserved across automatic reconnect attempts and ignored on macOS. A GATT connection or peer event does not confirm audio readiness.

`reconnect` shares `options.timeout` across retrieval, scanning, and connecting. Its optional `fallbackOnConnectionFailure: true` reserves half the budget for scan recovery when a retrieved peripheral fails to connect. Only connection failure or timeout triggers that recovery; cancellation and permission errors propagate immediately. Scan fallback always requires the saved identifier. The resulting session retains the original timeout for future automatic recovery.

Persisting devices, selecting a preferred peer, avoiding duplicate connection tasks, and suppressing automatic connection after manual disconnection remain app responsibilities. Full app-relaunch state restoration is not implemented.

## Operation behavior during disconnects

Pending reads, writes, discovery, and notification setup fail when the peripheral disconnects. Run a new operation after the session reports `.ready` again rather than retrying an old continuation.

Active notification streams are restored after a successful automatic reconnect. Consumers can continue iterating the same stream unless restoration fails, in which case the stream finishes with an error.

## Compatibility modes

The default behavior validates characteristic properties and performs targeted service and characteristic discovery. Keep these strict defaults unless a known non-compliant peripheral requires compatibility behavior.

For a peripheral that supports notifications but omits `.notify` and `.indicate`, set `allowUnsupportedProperties` for that subscription. For legacy firmware that only works after unfiltered GATT discovery, use ``GATTDiscoveryMode/all``.

```swift
let updates = try await session.notifications(
    for: notificationUUID,
    service: serviceUUID,
    allowUnsupportedProperties: true,
    discoveryMode: .all
)
```

Apply compatibility settings only to affected peripherals because they relax validation or perform more discovery work.
