# Changelog

## Unreleased

- Preserve each notification consumer's compatibility and discovery configuration during automatic reconnect, restoring the original streams without a new session.
- Enforce strict shared-consumer validation and merge restoration settings across active consumers; recompute them when consumers cancel.
- Reject stale notification restoration snapshots and prevent cancelled subscriptions from being recreated or updated by an earlier restoration.
- Add opt-in classic transport bridging to connection options, preserving it across automatic reconnect attempts.
- Add system-connected peripheral retrieval and iOS system peer connection events, with registration cleanup and Bluetooth power-cycle recovery.
- Restrict fallback scans to the requested identifier and share the reconnect timeout across scanning and connecting. Optionally recover from a failed retrieved connection by scanning.
- Preserve the original reconnect method signature for stored function references.
- Add opt-in foreground saved-device recovery and an audio bridging toggle to the sample app, with request coalescing and manual disconnect suppression.
- Synchronize test-double state shared by async tests and simulated delegate callbacks.
- Fix a write-without-response readiness race that could time out after CoreBluetooth reported that the peripheral was ready.

## 0.2.3

- Add explicit Xcode 27 compatibility CI and raise the sample app deployment target to iOS 15.
- Add continuous integration for SwiftPM tests, iOS builds, and DocC documentation.
- Add hosted DocC configuration, getting-started guides, and contributor templates.
- Improve README positioning, adoption guidance, and project metadata.

## 0.2.2

- Add an opt-in discovery mode for legacy peripherals that require unfiltered service and characteristic discovery before notification setup.

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
