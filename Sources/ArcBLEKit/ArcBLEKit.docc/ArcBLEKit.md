# ``ArcBLEKit``

Build reliable Bluetooth Low Energy central applications with Swift Concurrency.

## Overview

ArcBLEKit wraps CoreBluetooth's delegate-based central APIs in structured asynchronous operations. Scan with `AsyncThrowingStream`, connect and perform GATT operations with `async throws`, and observe Bluetooth and connection state changes as asynchronous streams.

Operations have explicit timeouts, respond to task cancellation, and fail when a peripheral disconnects. Optional automatic reconnect restores active notification subscriptions after a successful reconnection.

Start with <doc:GettingStarted>, then read <doc:ReliableConnections> before choosing a reconnect policy for a production app.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ReliableConnections>

### Scanning and connecting

- ``BLEClient``
- ``BLEDevice``
- ``ScanFilter``
- ``ConnectionOptions``
- ``AutoReconnectPolicy``

### Peripheral communication

- ``PeripheralSession``
- ``GATTOperationOptions``
- ``GATTDiscoveryMode``
- ``GATTOperation``

### State and errors

- ``BluetoothState``
- ``ConnectionState``
- ``BLEError``
