# ArcBLEKit Design

## Summary

ArcBLEKit is a Swift Package for building iOS BLE central apps with a modern Swift Concurrency API. The first version targets Swift 5.5+ and iOS 14.0+, wraps CoreBluetooth behind a small public API, and provides both low-friction scanning and a per-device session layer.

The library focuses on generic BLE client behavior: scan, find, connect, reconnect by saved peripheral identifier, discover services and characteristics, read, write, subscribe to notifications, disconnect, track connection state, and perform limited foreground automatic reconnects.

## Goals

- Support iOS 14.0+ with Swift 5.5+ concurrency features.
- Provide an async-first API based on `async/await` and `AsyncStream`.
- Scan for devices advertising specific service UUIDs.
- Represent discovered devices with a stable `BLEDevice.id` that maps to `CBPeripheral.identifier`.
- Allow apps to persist a peripheral identifier and reconnect to that device later.
- Use `retrievePeripherals(withIdentifiers:)` before scanning during identifier-based reconnect.
- Provide a session object for connected peripherals.
- Keep CoreBluetooth delegate objects and raw CoreBluetooth references out of app code.
- Make the state machine and operations testable without physical BLE hardware.
- Reserve a restoration identifier configuration hook for future iOS state restoration support.

## Non-Goals

- Do not implement device-specific command protocols.
- Do not implement OTA, DFU, or firmware update flows.
- Do not fully implement iOS background state restoration in the first version.
- Do not expose CoreBluetooth delegate callbacks as the public extension mechanism.
- Do not support Swift 5.0 syntax without concurrency.
- Do not support Android, Linux, or non-Apple BLE stacks.

## Package Shape

The package name is `ArcBLEKit`.

```text
Package.swift
Sources/ArcBLEKit/
  BLEClient.swift
  BLEClient+Scan.swift
  BLEClient+Reconnect.swift
  BLEDevice.swift
  PeripheralSession.swift
  PeripheralSession+Operations.swift
  ScanFilter.swift
  ConnectionOptions.swift
  ConnectionState.swift
  BLEError.swift
  Internal/
    CentralManaging.swift
    PeripheralRepresenting.swift
    CentralManagerBox.swift
    PeripheralBox.swift
    AsyncOperationStore.swift
    CharacteristicCache.swift
    BLEAdvertisementParser.swift
Tests/ArcBLEKitTests/
  BLEClientScanTests.swift
  BLEClientReconnectTests.swift
  PeripheralSessionOperationTests.swift
  PeripheralSessionReconnectTests.swift
  Fakes/
    FakeCentralManager.swift
    FakePeripheral.swift
```

## Architecture

ArcBLEKit uses a three-layer architecture.

### Public API Layer

The public API contains app-facing value types and main entry points:

- `BLEClient`
- `BLEDevice`
- `PeripheralSession`
- `ScanFilter`
- `ConnectionOptions`
- `AutoReconnectPolicy`
- `ConnectionState`
- `BLEError`

App code uses these types and should not need to touch `CBCentralManagerDelegate`, `CBPeripheralDelegate`, `CBPeripheral`, `CBService`, or `CBCharacteristic`.

### CoreBluetooth Bridge Layer

The bridge layer owns the real `CBCentralManager` and `CBPeripheral` instances. It adapts delegate events into async operations and streams:

- scan result streams
- connect continuations
- service discovery continuations
- characteristic discovery continuations
- read and write continuations
- notification `AsyncStream<Data>`

The bridge layer is internal and replaceable in tests through protocols.

### Session Layer

Each connected peripheral is represented by a `PeripheralSession`. The session owns:

- connection state stream
- service and characteristic cache
- read operations
- write operations
- notification subscriptions
- disconnect operation
- limited auto-reconnect policy

Operations inside one session are serialized so CoreBluetooth callback ordering does not corrupt local state. Multiple sessions may operate concurrently.

## Public API Sketch

### Client

```swift
public final class BLEClient {
    public struct Configuration: Sendable {
        public var restoreIdentifier: String?

        public init(restoreIdentifier: String? = nil) {
            self.restoreIdentifier = restoreIdentifier
        }
    }

    public init(configuration: Configuration = .init())

    public func scan(filter: ScanFilter) -> AsyncStream<BLEDevice>

    public func findDevice(
        matching filter: ScanFilter,
        timeout: TimeInterval
    ) async throws -> BLEDevice

    public func connect(
        to device: BLEDevice,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession

    public func reconnect(
        identifier: UUID,
        fallbackScan: ScanFilter?,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession
}
```

`restoreIdentifier` is passed into the underlying central manager configuration when available, but first-version behavior does not promise full app relaunch restoration.

### Device

```swift
public struct BLEDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisedServiceUUIDs: [CBUUID]
    public let manufacturerData: Data?
}
```

`BLEDevice.id` maps to `CBPeripheral.identifier`. Apps may persist this value to reconnect to a previously selected peripheral. The value is assigned by iOS for the current app and device context; it is not a globally stable hardware address.

### Scan Filter

```swift
public struct ScanFilter: Sendable, Equatable {
    public var serviceUUIDs: [CBUUID]
    public var peripheralIdentifiers: Set<UUID>
    public var name: String?
    public var namePrefix: String?
    public var manufacturerDataPrefix: Data?

    public init(
        serviceUUIDs: [CBUUID] = [],
        peripheralIdentifiers: Set<UUID> = [],
        name: String? = nil,
        namePrefix: String? = nil,
        manufacturerDataPrefix: Data? = nil
    )
}
```

`serviceUUIDs` are passed into CoreBluetooth scanning so iOS can filter devices at the system layer. Other fields are applied to discovered advertisements by the library.

### Connection Options

```swift
public struct ConnectionOptions: Sendable, Equatable {
    public var timeout: TimeInterval
    public var autoReconnect: AutoReconnectPolicy

    public init(
        timeout: TimeInterval = 10,
        autoReconnect: AutoReconnectPolicy = .disabled
    )
}

public enum AutoReconnectPolicy: Sendable, Equatable {
    case disabled
    case limited(maxAttempts: Int, delay: TimeInterval)
}
```

First-version reconnect behavior is foreground-oriented and limited. It does not attempt indefinite background reconnects. Timeout and delay values use `TimeInterval` instead of `Duration` so the public API remains compatible with Swift 5.5.

### Session

```swift
public final class PeripheralSession {
    public var device: BLEDevice { get }
    public var connectionStates: AsyncStream<ConnectionState> { get }

    public func read(
        characteristic: CBUUID,
        service: CBUUID
    ) async throws -> Data

    public func write(
        _ data: Data,
        to characteristic: CBUUID,
        service: CBUUID,
        type: CBCharacteristicWriteType
    ) async throws

    public func notifications(
        for characteristic: CBUUID,
        service: CBUUID
    ) async throws -> AsyncStream<Data>

    public func disconnect() async
}
```

The session API uses explicit service UUID and characteristic UUID pairs. The caller should not need to fetch or retain CoreBluetooth characteristic objects.

## Typical Usage

### Scan for a Service UUID

```swift
let client = BLEClient()

let devices = client.scan(
    filter: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")])
)

for await device in devices {
    print(device.name ?? "Unknown", device.id, device.rssi)
}
```

### Find and Connect

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

### Reconnect by Saved Identifier

```swift
let session = try await client.reconnect(
    identifier: savedPeripheralIdentifier,
    fallbackScan: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")]),
    options: ConnectionOptions(timeout: 10)
)
```

Reconnect order:

1. Call `retrievePeripherals(withIdentifiers:)`.
2. If iOS returns the peripheral, connect directly.
3. If retrieval returns no peripheral and `fallbackScan` exists, scan using the fallback filter.
4. During fallback scan, connect only when the discovered peripheral identifier matches the saved identifier.
5. Throw `BLEError.deviceNotFound(identifier)` if neither path finds the device.

### Read, Write, and Notify

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

let updates = try await session.notifications(
    for: CBUUID(string: "FFF3"),
    service: CBUUID(string: "FFF0")
)

for await data in updates {
    print(data)
}
```

## Connection State

```swift
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case discoveringServices
    case ready
    case reconnecting(attempt: Int)
    case failed(BLEError)
}
```

Normal state progression:

```text
disconnected -> connecting -> connected -> discoveringServices -> ready
```

Limited auto-reconnect progression:

```text
ready -> disconnected -> reconnecting(attempt: 1) -> connecting -> ready
```

## Error Handling

```swift
public enum BLEError: Error, Equatable, Sendable {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case scanTimedOut
    case deviceNotFound(UUID)
    case connectionTimedOut(UUID)
    case connectionFailed(UUID, underlying: String?)
    case disconnected(UUID, underlying: String?)
    case serviceNotFound(CBUUID)
    case characteristicNotFound(CBUUID, service: CBUUID)
    case readFailed(CBUUID, underlying: String?)
    case writeFailed(CBUUID, underlying: String?)
    case notificationSetupFailed(CBUUID, underlying: String?)
    case operationCancelled
}
```

The first version stores underlying errors as optional strings to keep `BLEError` equatable and sendable.

## Internal Testing Strategy

CoreBluetooth is isolated behind internal protocols.

```swift
protocol CentralManaging {
    var state: BluetoothState { get }
    func scanForPeripherals(withServices services: [CBUUID]?)
    func stopScan()
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting]
    func connect(_ peripheral: PeripheralRepresenting)
    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting)
}
```

```swift
protocol PeripheralRepresenting {
    var identifier: UUID { get }
    var name: String? { get }
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting)
    func readValue(for characteristic: CharacteristicRepresenting)
    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: WriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting)
}
```

The real implementations are `CentralManagerBox` and `PeripheralBox`. Unit tests use `FakeCentralManager` and `FakePeripheral` to trigger delegate-like events deterministically.

## Required Tests

- `scan(filter:)` passes service UUIDs to the central manager.
- Scan results become `BLEDevice` values with identifier, name, RSSI, advertised service UUIDs, and manufacturer data.
- `ScanFilter` filters by peripheral identifier.
- `ScanFilter` filters by exact name.
- `ScanFilter` filters by name prefix.
- `ScanFilter` filters by manufacturer data prefix.
- `findDevice(matching:timeout:)` returns the first matching device and stops scanning.
- `findDevice(matching:timeout:)` throws `scanTimedOut` when no match arrives.
- `reconnect(identifier:fallbackScan:)` calls `retrievePeripherals(withIdentifiers:)` first.
- `reconnect(identifier:fallbackScan:)` connects directly when retrieval succeeds.
- `reconnect(identifier:fallbackScan:)` scans with service UUID fallback when retrieval fails.
- Fallback reconnect only connects when the discovered peripheral identifier equals the saved identifier.
- `connect(to:)` creates a `PeripheralSession` after successful connection.
- `connect(to:)` throws `connectionTimedOut` when connection does not complete before the timeout.
- Session reads discover and cache the requested service and characteristic.
- Session writes use the requested service and characteristic.
- Session notification setup returns an `AsyncStream<Data>`.
- Missing service throws `serviceNotFound`.
- Missing characteristic throws `characteristicNotFound`.
- Unexpected disconnect emits `disconnected` and throws or terminates pending operations.
- Limited auto-reconnect stops after the configured maximum attempts.

## Documentation Requirements

The repository should include a README with:

- installation through Swift Package Manager
- required `Info.plist` Bluetooth permission keys
- scanning for a specific service UUID
- saving `BLEDevice.id`
- reconnecting by saved peripheral identifier
- reading and writing characteristics
- subscribing to notifications
- a note that `CBPeripheral.identifier` is iOS-assigned and not a global BLE MAC address
- a note that full background state restoration is not part of the first version

## Naming

The implementation plan will use `ArcBLEKit` as the package and module name.
