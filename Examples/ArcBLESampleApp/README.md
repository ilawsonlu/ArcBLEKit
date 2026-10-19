# ArcBLE Sample App

This iOS sample app is a real-device debugging companion for ArcBLEKit. It covers:

- scan for peripherals advertising a service UUID
- connect to a discovered peripheral
- save the selected `CBPeripheral.identifier`
- reconnect later by the saved identifier with service UUID fallback scanning
- opt into foreground automatic recovery, reusing a system-connected peer before identifier retrieval and scanning
- observe system peer connection events for the saved device
- request classic audio bridging on compatible CTKD accessories
- read and write configurable characteristics with hex payloads
- choose write with response or without response
- subscribe to notifications and inspect received bytes
- observe automatic reconnect and notification restoration in the log

## Requirements

- Xcode 26.4.1 or newer
- iOS 15.0+ deployment target
- A physical iPhone or iPad supported by the selected Xcode version (Xcode 27 supports running and debugging on iOS 17+)
- A BLE peripheral advertising a known service UUID
- Bluetooth permission granted when the app prompts

## Open

Open:

```text
Examples/ArcBLESampleApp/ArcBLESampleApp.xcodeproj
```

The project references the root `ArcBLEKit` package locally, so keep the sample inside this repository.

## Run on Device

1. Select the `ArcBLESampleApp` scheme.
2. Select a physical iPhone or iPad.
3. Set a development team in Signing & Capabilities if Xcode asks.
4. Build and run.
5. Enter the target service UUID, such as `FFF0`.
6. Tap **Start Scan**.
7. Tap **Connect** on the target peripheral.
8. Enter the device's read, write, and notification characteristic UUIDs.
9. Exercise **Read Value**, **Send Value**, and **Start Notifications**.
10. Power-cycle the peripheral to observe automatic reconnect.
11. Enable **Auto-connect Saved Device**, then leave and reopen the app to exercise foreground recovery. The service UUID and preferences are saved along with the identifier.
12. On compatible dual-mode hardware, enable **Connect Audio Too** before the next connection and check the system audio route separately.

## Automatic Connection Behavior

Automatic connection and audio bridging both default to off. When enabled, foreground recovery first queries system-connected peripherals for the configured service and chooses only the saved identifier. Otherwise, it retrieves that identifier and falls back to scanning, including recovery after a failed retrieved connection.

Startup, system peer events, and manual requests share one connection task. **Disconnect** cancels a pending request and pauses automatic connection for the current app run, including subsequent Bluetooth power cycles or foreground transitions. **Reconnect Saved Device**, a manual device connection, or turning automatic connection off and on resumes it. Starting a manual scan also pauses automatic connection so it does not interrupt device selection.

Leaving the foreground cancels pending automatic recovery and event observation; it preserves an established GATT session and does not cancel a manual connection request. Session-level finite reconnect remains governed by `ConnectionOptions.autoReconnect`. Clearing the saved identifier cancels pending recovery and prevents a late result from saving it again.

This is a foreground integration example. It does not configure background Bluetooth modes or implement app-relaunch state restoration. A peer-connected event or a successful GATT connection does not prove that A2DP is ready.

## Regression Tests

Run `swift test --parallel` from the repository root. The test target uses a source link to the actual sample view model, with an in-memory preferences store and fake Bluetooth peripherals. It covers request coalescing, system-connection reuse, initial Bluetooth-off recovery, manual disconnect suppression, clearing a pending device, and foreground cancellation. These tests do not replace physical-device verification.

## Expected Behavior

- Scanning lists devices that match the service UUID filter.
- Connecting saves the peripheral identifier and service UUID.
- Reconnect prefers `retrieveConnectedDevices(withServices:)`, then uses `reconnect(identifier:fallbackScan:fallbackOnConnectionFailure:options:)`.
- Read and notification values appear as hexadecimal bytes.
- Writes report validation, timeout, and CoreBluetooth errors in the log.
- The log shows scan, connect, reconnect, GATT data, and connection state transitions.

## Notes

`CBPeripheral.identifier` is stable for the current app and iOS device context, but it is not a BLE MAC address. Reinstalling the app or changing iOS devices can change the identifier relationship.
