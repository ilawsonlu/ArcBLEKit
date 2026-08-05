# Changelog

## 0.2.1

- Add an opt-in notification compatibility mode for peripherals that omit the `.notify` or `.indicate` characteristic property.

## 0.2.0

- Breaking: `scan(filter:)` and notification streams now throw operation errors.
- Add cancellable, timeout-bound GATT operation coordination.
- Make scanning an `AsyncThrowingStream` and expose Bluetooth state updates.
- Add `waitUntilReady(timeout:)`.
- Correct write-without-response behavior and CoreBluetooth backpressure handling.
- Validate characteristic capabilities and maximum write payload length.
- Support notification streams keyed by service and characteristic UUID.
- Share notifications across multiple subscribers and restore them after reconnect.
- Rework automatic reconnect states, retry limits, and manual disconnect behavior.
- Expand the sample app with real read, write, notification, and logging controls.
