# ArcBLE Sample App

This iOS sample app is a real-device debugging companion for ArcBLEKit. It covers:

- scan for peripherals advertising a service UUID
- connect to a discovered peripheral
- save the selected `CBPeripheral.identifier`
- reconnect later by the saved identifier with service UUID fallback scanning
- read and write configurable characteristics with hex payloads
- choose write with response or without response
- subscribe to notifications and inspect received bytes
- observe automatic reconnect and notification restoration in the log

## Requirements

- Xcode 26.4.1 or newer
- iPhone or iPad running iOS 14.0+
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
11. Stop and relaunch the app, then tap **Reconnect Saved Device**.

## Expected Behavior

- Scanning lists devices that match the service UUID filter.
- Connecting saves the peripheral identifier.
- Reconnect uses `BLEClient.reconnect(identifier:fallbackScan:options:)`.
- Read and notification values appear as hexadecimal bytes.
- Writes report validation, timeout, and CoreBluetooth errors in the log.
- The log shows scan, connect, reconnect, GATT data, and connection state transitions.

## Notes

`CBPeripheral.identifier` is stable for the current app and iOS device context, but it is not a BLE MAC address. Reinstalling the app or changing iOS devices can change the identifier relationship.
