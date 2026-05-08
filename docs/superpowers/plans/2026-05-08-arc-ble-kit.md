# ArcBLEKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build ArcBLEKit, a Swift 5.5+ iOS 14+ BLE central library with async scanning, connection, identifier-based reconnect, session operations, state streams, and testable CoreBluetooth isolation.

**Architecture:** ArcBLEKit exposes a small public API (`BLEClient`, `BLEDevice`, `PeripheralSession`, filters, options, states, errors) while hiding CoreBluetooth behind internal protocols and bridge boxes. Tests use fakes to drive scan, connect, discovery, read, write, notify, disconnect, and reconnect behavior without physical BLE hardware.

**Tech Stack:** Swift Package Manager, Swift 5.5 concurrency, XCTest, CoreBluetooth, Foundation.

---

## File Structure

- `Package.swift`: Swift Package definition for library and test target.
- `Sources/ArcBLEKit/BLEClient.swift`: public client initializer and shared client state.
- `Sources/ArcBLEKit/BLEClient+Scan.swift`: scan stream and `findDevice`.
- `Sources/ArcBLEKit/BLEClient+Reconnect.swift`: connect and reconnect flows.
- `Sources/ArcBLEKit/BLEDevice.swift`: discovered device value.
- `Sources/ArcBLEKit/PeripheralSession.swift`: connected device session, state stream, lifecycle.
- `Sources/ArcBLEKit/PeripheralSession+Operations.swift`: read, write, notifications.
- `Sources/ArcBLEKit/ScanFilter.swift`: public scan filter plus internal match function.
- `Sources/ArcBLEKit/ConnectionOptions.swift`: timeout and auto-reconnect policy.
- `Sources/ArcBLEKit/ConnectionState.swift`: public connection state enum.
- `Sources/ArcBLEKit/BLEError.swift`: public error enum.
- `Sources/ArcBLEKit/Internal/BluetoothState.swift`: internal central state abstraction.
- `Sources/ArcBLEKit/Internal/BLEAdvertisement.swift`: internal advertisement value.
- `Sources/ArcBLEKit/Internal/CentralManaging.swift`: central abstraction used by client.
- `Sources/ArcBLEKit/Internal/PeripheralRepresenting.swift`: peripheral abstraction used by session.
- `Sources/ArcBLEKit/Internal/CentralManagerBox.swift`: real `CBCentralManager` adapter.
- `Sources/ArcBLEKit/Internal/PeripheralBox.swift`: real `CBPeripheral` adapter.
- `Sources/ArcBLEKit/Internal/AsyncOperationStore.swift`: continuation storage by operation key.
- `Sources/ArcBLEKit/Internal/CharacteristicCache.swift`: service and characteristic lookup cache.
- `Sources/ArcBLEKit/Internal/SessionOperationQueue.swift`: serializes operations inside one peripheral session.
- `Sources/ArcBLEKit/Internal/BLEAdvertisementParser.swift`: advertisement dictionary parser.
- `Tests/ArcBLEKitTests/BLEClientScanTests.swift`: scan and `findDevice` tests.
- `Tests/ArcBLEKitTests/BLEClientReconnectTests.swift`: connect and reconnect tests.
- `Tests/ArcBLEKitTests/PeripheralSessionOperationTests.swift`: discovery, read, write, notify tests.
- `Tests/ArcBLEKitTests/PeripheralSessionReconnectTests.swift`: disconnect and limited reconnect tests.
- `Tests/ArcBLEKitTests/Fakes/FakeCentralManager.swift`: fake central.
- `Tests/ArcBLEKitTests/Fakes/FakePeripheral.swift`: fake peripheral.
- `README.md`: installation, permission keys, and usage examples.

## Implementation Notes

- Use `TimeInterval`, not `Duration`, because Swift 5.5 is required.
- Mark public value types `Sendable` where the compiler accepts it cleanly.
- `CBUUID` is imported from CoreBluetooth in public files because the API intentionally accepts service and characteristic UUIDs.
- `BLEDevice.id` always maps to `CBPeripheral.identifier`.
- `BLEClient` keeps an internal `[UUID: PeripheralRepresenting]` registry populated by scans so `connect(to:)` can resolve a public `BLEDevice`.
- `reconnect(identifier:fallbackScan:)` first calls `retrievePeripherals(withIdentifiers:)`, then scans with fallback only if retrieval fails.
- Operations inside a single `PeripheralSession` are serialized with `SessionOperationQueue`, which uses an actor-backed async semaphore.

---

### Task 1: Package Skeleton and Public Value Types

**Files:**
- Create: `Package.swift`
- Create: `Sources/ArcBLEKit/BLEDevice.swift`
- Create: `Sources/ArcBLEKit/ScanFilter.swift`
- Create: `Sources/ArcBLEKit/ConnectionOptions.swift`
- Create: `Sources/ArcBLEKit/ConnectionState.swift`
- Create: `Sources/ArcBLEKit/BLEError.swift`
- Test: `Tests/ArcBLEKitTests/PublicModelTests.swift`

- [ ] **Step 1: Create the Swift package manifest**

Write `Package.swift`:

```swift
// swift-tools-version: 5.5
import PackageDescription

let package = Package(
    name: "ArcBLEKit",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(name: "ArcBLEKit", targets: ["ArcBLEKit"])
    ],
    targets: [
        .target(name: "ArcBLEKit"),
        .testTarget(name: "ArcBLEKitTests", dependencies: ["ArcBLEKit"])
    ]
)
```

- [ ] **Step 2: Write failing public model tests**

Write `Tests/ArcBLEKitTests/PublicModelTests.swift`:

```swift
import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class PublicModelTests: XCTestCase {
    func testBLEDeviceStoresPeripheralIdentifierAndAdvertisementFields() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let service = CBUUID(string: "FFF0")
        let manufacturerData = Data([0x01, 0x02])

        let device = BLEDevice(
            id: id,
            name: "Arc Sensor",
            rssi: -42,
            advertisedServiceUUIDs: [service],
            manufacturerData: manufacturerData
        )

        XCTAssertEqual(device.id, id)
        XCTAssertEqual(device.name, "Arc Sensor")
        XCTAssertEqual(device.rssi, -42)
        XCTAssertEqual(device.advertisedServiceUUIDs, [service])
        XCTAssertEqual(device.manufacturerData, manufacturerData)
    }

    func testScanFilterDefaultsToNoRestrictions() {
        let filter = ScanFilter()

        XCTAssertEqual(filter.serviceUUIDs, [])
        XCTAssertEqual(filter.peripheralIdentifiers, [])
        XCTAssertNil(filter.name)
        XCTAssertNil(filter.namePrefix)
        XCTAssertNil(filter.manufacturerDataPrefix)
    }

    func testConnectionOptionsDefaults() {
        let options = ConnectionOptions()

        XCTAssertEqual(options.timeout, 10)
        XCTAssertEqual(options.autoReconnect, .disabled)
    }

    func testBLEErrorEquatableForIdentifierErrors() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        XCTAssertEqual(BLEError.deviceNotFound(id), BLEError.deviceNotFound(id))
        XCTAssertNotEqual(BLEError.scanTimedOut, BLEError.deviceNotFound(id))
    }
}
```

- [ ] **Step 3: Run tests and verify they fail because symbols do not exist**

Run:

```bash
swift test --filter PublicModelTests
```

Expected: build fails with missing symbols such as `BLEDevice`, `ScanFilter`, `ConnectionOptions`, and `BLEError`.

- [ ] **Step 4: Implement public value types**

Write `Sources/ArcBLEKit/BLEDevice.swift`:

```swift
import CoreBluetooth
import Foundation

public struct BLEDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisedServiceUUIDs: [CBUUID]
    public let manufacturerData: Data?

    public init(
        id: UUID,
        name: String?,
        rssi: Int,
        advertisedServiceUUIDs: [CBUUID],
        manufacturerData: Data?
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
        self.manufacturerData = manufacturerData
    }
}
```

Write `Sources/ArcBLEKit/ScanFilter.swift`:

```swift
import CoreBluetooth
import Foundation

public struct ScanFilter: Equatable, Sendable {
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
    ) {
        self.serviceUUIDs = serviceUUIDs
        self.peripheralIdentifiers = peripheralIdentifiers
        self.name = name
        self.namePrefix = namePrefix
        self.manufacturerDataPrefix = manufacturerDataPrefix
    }

    func matches(_ device: BLEDevice) -> Bool {
        if !peripheralIdentifiers.isEmpty && !peripheralIdentifiers.contains(device.id) {
            return false
        }

        if let name, device.name != name {
            return false
        }

        if let namePrefix {
            guard let deviceName = device.name, deviceName.hasPrefix(namePrefix) else {
                return false
            }
        }

        if let manufacturerDataPrefix {
            guard let manufacturerData = device.manufacturerData,
                  manufacturerData.starts(with: manufacturerDataPrefix) else {
                return false
            }
        }

        return true
    }
}
```

Write `Sources/ArcBLEKit/ConnectionOptions.swift`:

```swift
import Foundation

public struct ConnectionOptions: Equatable, Sendable {
    public var timeout: TimeInterval
    public var autoReconnect: AutoReconnectPolicy

    public init(
        timeout: TimeInterval = 10,
        autoReconnect: AutoReconnectPolicy = .disabled
    ) {
        self.timeout = timeout
        self.autoReconnect = autoReconnect
    }
}

public enum AutoReconnectPolicy: Equatable, Sendable {
    case disabled
    case limited(maxAttempts: Int, delay: TimeInterval)
}
```

Write `Sources/ArcBLEKit/ConnectionState.swift`:

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

Write `Sources/ArcBLEKit/BLEError.swift`:

```swift
import CoreBluetooth
import Foundation

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

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
swift test --filter PublicModelTests
```

Expected: `PublicModelTests` passes.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ArcBLEKit Tests/ArcBLEKitTests/PublicModelTests.swift
git commit -m "feat: add ArcBLEKit public models"
```

---

### Task 2: Internal Protocols, Advertisement Parser, and Fakes

**Files:**
- Create: `Sources/ArcBLEKit/Internal/BluetoothState.swift`
- Create: `Sources/ArcBLEKit/Internal/BLEAdvertisement.swift`
- Create: `Sources/ArcBLEKit/Internal/CentralManaging.swift`
- Create: `Sources/ArcBLEKit/Internal/PeripheralRepresenting.swift`
- Create: `Sources/ArcBLEKit/Internal/BLEAdvertisementParser.swift`
- Create: `Tests/ArcBLEKitTests/Fakes/FakeCentralManager.swift`
- Create: `Tests/ArcBLEKitTests/Fakes/FakePeripheral.swift`
- Test: `Tests/ArcBLEKitTests/BLEAdvertisementParserTests.swift`

- [ ] **Step 1: Write failing advertisement parser tests**

Write `Tests/ArcBLEKitTests/BLEAdvertisementParserTests.swift`:

```swift
import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class BLEAdvertisementParserTests: XCTestCase {
    func testParsesLocalNameServiceUUIDsAndManufacturerData() {
        let service = CBUUID(string: "FFF0")
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "Arc Sensor",
            CBAdvertisementDataServiceUUIDsKey: [service],
            CBAdvertisementDataManufacturerDataKey: Data([0xAA, 0xBB])
        ]

        let advertisement = BLEAdvertisementParser.parse(advertisementData)

        XCTAssertEqual(advertisement.localName, "Arc Sensor")
        XCTAssertEqual(advertisement.serviceUUIDs, [service])
        XCTAssertEqual(advertisement.manufacturerData, Data([0xAA, 0xBB]))
    }

    func testBuildsBLEDeviceFromPeripheralAndAdvertisement() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Fallback Name")
        let advertisement = BLEAdvertisement(
            localName: "Advertisement Name",
            serviceUUIDs: [CBUUID(string: "FFF0")],
            manufacturerData: Data([0x10])
        )

        let device = BLEAdvertisementParser.makeDevice(
            peripheral: peripheral,
            advertisement: advertisement,
            rssi: -55
        )

        XCTAssertEqual(device.id, id)
        XCTAssertEqual(device.name, "Advertisement Name")
        XCTAssertEqual(device.rssi, -55)
        XCTAssertEqual(device.advertisedServiceUUIDs, [CBUUID(string: "FFF0")])
        XCTAssertEqual(device.manufacturerData, Data([0x10]))
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter BLEAdvertisementParserTests
```

Expected: build fails because internal parser, protocols, and fakes do not exist.

- [ ] **Step 3: Implement internal protocol surface**

Write `Sources/ArcBLEKit/Internal/BluetoothState.swift`:

```swift
import CoreBluetooth

enum BluetoothState: Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}
```

Write `Sources/ArcBLEKit/Internal/BLEAdvertisement.swift`:

```swift
import CoreBluetooth
import Foundation

struct BLEAdvertisement: Equatable {
    let localName: String?
    let serviceUUIDs: [CBUUID]
    let manufacturerData: Data?
}
```

Write `Sources/ArcBLEKit/Internal/CentralManaging.swift`:

```swift
import CoreBluetooth
import Foundation

protocol CentralManaging: AnyObject {
    var state: BluetoothState { get }
    var onStateChange: ((BluetoothState) -> Void)? { get set }
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)? { get set }
    var onConnect: ((PeripheralRepresenting) -> Void)? { get set }
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)? { get set }
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)? { get set }

    func scanForPeripherals(withServices services: [CBUUID]?)
    func stopScan()
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting]
    func connect(_ peripheral: PeripheralRepresenting)
    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting)
}
```

Write `Sources/ArcBLEKit/Internal/PeripheralRepresenting.swift`:

```swift
import CoreBluetooth
import Foundation

protocol ServiceRepresenting: AnyObject {
    var uuid: CBUUID { get }
}

protocol CharacteristicRepresenting: AnyObject {
    var uuid: CBUUID { get }
    var serviceUUID: CBUUID { get }
}

protocol PeripheralRepresenting: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)? { get set }
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)? { get set }
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)? { get set }
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)? { get set }
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)? { get set }
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)? { get set }

    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting)
    func readValue(for characteristic: CharacteristicRepresenting)
    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting)
}
```

- [ ] **Step 4: Implement parser and fakes**

Write `Sources/ArcBLEKit/Internal/BLEAdvertisementParser.swift`:

```swift
import CoreBluetooth
import Foundation

enum BLEAdvertisementParser {
    static func parse(_ advertisementData: [String: Any]) -> BLEAdvertisement {
        BLEAdvertisement(
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            serviceUUIDs: advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [],
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        )
    }

    static func makeDevice(
        peripheral: PeripheralRepresenting,
        advertisement: BLEAdvertisement,
        rssi: Int
    ) -> BLEDevice {
        BLEDevice(
            id: peripheral.identifier,
            name: advertisement.localName ?? peripheral.name,
            rssi: rssi,
            advertisedServiceUUIDs: advertisement.serviceUUIDs,
            manufacturerData: advertisement.manufacturerData
        )
    }
}
```

Write `Tests/ArcBLEKitTests/Fakes/FakePeripheral.swift`:

```swift
import CoreBluetooth
import Foundation
@testable import ArcBLEKit

final class FakeService: ServiceRepresenting {
    let uuid: CBUUID

    init(uuid: CBUUID) {
        self.uuid = uuid
    }
}

final class FakeCharacteristic: CharacteristicRepresenting {
    let uuid: CBUUID
    let serviceUUID: CBUUID

    init(uuid: CBUUID, serviceUUID: CBUUID) {
        self.uuid = uuid
        self.serviceUUID = serviceUUID
    }
}

final class FakePeripheral: PeripheralRepresenting {
    let identifier: UUID
    let name: String?

    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)?
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)?
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)?
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)?

    private(set) var discoveredServiceUUIDs: [CBUUID]?
    private(set) var discoveredCharacteristicUUIDs: [CBUUID]?
    private(set) var readCharacteristics: [CBUUID] = []
    private(set) var writtenValues: [(data: Data, characteristic: CBUUID, type: CBCharacteristicWriteType)] = []
    private(set) var notifyChanges: [(enabled: Bool, characteristic: CBUUID)] = []

    init(identifier: UUID = UUID(), name: String? = nil) {
        self.identifier = identifier
        self.name = name
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        discoveredServiceUUIDs = serviceUUIDs
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting) {
        discoveredCharacteristicUUIDs = characteristicUUIDs
    }

    func readValue(for characteristic: CharacteristicRepresenting) {
        readCharacteristics.append(characteristic.uuid)
    }

    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType) {
        writtenValues.append((data, characteristic.uuid, type))
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting) {
        notifyChanges.append((enabled, characteristic.uuid))
    }

    func completeServiceDiscovery(_ services: [ServiceRepresenting], error: Error? = nil) {
        onServicesDiscovered?(services, error)
    }

    func completeCharacteristicDiscovery(
        service: ServiceRepresenting,
        characteristics: [CharacteristicRepresenting],
        error: Error? = nil
    ) {
        onCharacteristicsDiscovered?(service, characteristics, error)
    }

    func completeRead(characteristic: CharacteristicRepresenting, data: Data?, error: Error? = nil) {
        onValueRead?(characteristic, data, error)
    }

    func completeWrite(characteristic: CharacteristicRepresenting, error: Error? = nil) {
        onValueWritten?(characteristic, error)
    }

    func completeNotifySetup(characteristic: CharacteristicRepresenting, error: Error? = nil) {
        onNotificationStateUpdated?(characteristic, error)
    }

    func emitNotification(characteristic: CharacteristicRepresenting, data: Data) {
        onNotificationValue?(characteristic, data)
    }
}
```

Write `Tests/ArcBLEKitTests/Fakes/FakeCentralManager.swift`:

```swift
import CoreBluetooth
import Foundation
@testable import ArcBLEKit

final class FakeCentralManager: CentralManaging {
    var state: BluetoothState
    var onStateChange: ((BluetoothState) -> Void)?
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)?
    var onConnect: ((PeripheralRepresenting) -> Void)?
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)?
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)?

    private(set) var scannedServiceUUIDs: [CBUUID]?
    private(set) var didStopScan = false
    private(set) var retrievedIdentifiers: [UUID] = []
    private(set) var connectedIdentifiers: [UUID] = []
    private(set) var cancelledIdentifiers: [UUID] = []
    var retrievedPeripherals: [PeripheralRepresenting] = []

    init(state: BluetoothState = .poweredOn) {
        self.state = state
    }

    func scanForPeripherals(withServices services: [CBUUID]?) {
        scannedServiceUUIDs = services
        didStopScan = false
    }

    func stopScan() {
        didStopScan = true
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting] {
        retrievedIdentifiers = identifiers
        return retrievedPeripherals
    }

    func connect(_ peripheral: PeripheralRepresenting) {
        connectedIdentifiers.append(peripheral.identifier)
    }

    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting) {
        cancelledIdentifiers.append(peripheral.identifier)
    }

    func updateState(_ state: BluetoothState) {
        self.state = state
        onStateChange?(state)
    }

    func discover(
        _ peripheral: PeripheralRepresenting,
        advertisement: BLEAdvertisement,
        rssi: Int
    ) {
        onDiscover?(peripheral, advertisement, rssi)
    }

    func completeConnection(_ peripheral: PeripheralRepresenting) {
        onConnect?(peripheral)
    }

    func failConnection(_ peripheral: PeripheralRepresenting, error: Error? = nil) {
        onFailToConnect?(peripheral, error)
    }

    func disconnect(_ peripheral: PeripheralRepresenting, error: Error? = nil) {
        onDisconnect?(peripheral, error)
    }
}
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
swift test --filter BLEAdvertisementParserTests
```

Expected: `BLEAdvertisementParserTests` passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/ArcBLEKit/Internal Tests/ArcBLEKitTests/BLEAdvertisementParserTests.swift Tests/ArcBLEKitTests/Fakes
git commit -m "feat: add BLE internals and test fakes"
```

---

### Task 3: Scan Streams and Scan Filtering

**Files:**
- Create: `Sources/ArcBLEKit/BLEClient.swift`
- Create: `Sources/ArcBLEKit/BLEClient+Scan.swift`
- Test: `Tests/ArcBLEKitTests/BLEClientScanTests.swift`

- [ ] **Step 1: Write failing scan tests**

Write `Tests/ArcBLEKitTests/BLEClientScanTests.swift`:

```swift
import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class BLEClientScanTests: XCTestCase {
    func testScanPassesServiceUUIDsToCentral() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let service = CBUUID(string: "FFF0")

        let stream = client.scan(filter: ScanFilter(serviceUUIDs: [service]))
        _ = stream.makeAsyncIterator()

        XCTAssertEqual(central.scannedServiceUUIDs, [service])
    }

    func testScanEmitsMatchingDeviceAndStoresPeripheralForLaterConnection() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc Peripheral")
        let service = CBUUID(string: "FFF0")
        var iterator = client.scan(filter: ScanFilter(serviceUUIDs: [service])).makeAsyncIterator()

        central.discover(
            peripheral,
            advertisement: BLEAdvertisement(localName: "Arc Sensor", serviceUUIDs: [service], manufacturerData: Data([0x01])),
            rssi: -45
        )

        let device = await iterator.next()
        XCTAssertEqual(device?.id, id)
        XCTAssertEqual(device?.name, "Arc Sensor")
        XCTAssertEqual(device?.rssi, -45)
        XCTAssertEqual(device?.advertisedServiceUUIDs, [service])
    }

    func testScanFiltersByPeripheralIdentifierNamePrefixAndManufacturerData() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let matchingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let matchingPeripheral = FakePeripheral(identifier: matchingID, name: "Arc One")
        let rejectedPeripheral = FakePeripheral(identifier: UUID(), name: "Other")
        var iterator = client.scan(
            filter: ScanFilter(
                peripheralIdentifiers: [matchingID],
                namePrefix: "Arc",
                manufacturerDataPrefix: Data([0xAA])
            )
        ).makeAsyncIterator()

        central.discover(
            rejectedPeripheral,
            advertisement: BLEAdvertisement(localName: "Other", serviceUUIDs: [], manufacturerData: Data([0xAA])),
            rssi: -70
        )
        central.discover(
            matchingPeripheral,
            advertisement: BLEAdvertisement(localName: "Arc One", serviceUUIDs: [], manufacturerData: Data([0xAA, 0x01])),
            rssi: -40
        )

        let device = await iterator.next()
        XCTAssertEqual(device?.id, matchingID)
    }

    func testCancellingScanIteratorStopsCentralScan() async {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        var stream: AsyncStream<BLEDevice>? = client.scan(filter: ScanFilter())
        _ = stream?.makeAsyncIterator()

        stream = nil
        await Task.yield()

        XCTAssertTrue(central.didStopScan)
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter BLEClientScanTests
```

Expected: build fails because `BLEClient` and scan implementation do not exist.

- [ ] **Step 3: Implement `BLEClient` storage and injected initializer**

Write `Sources/ArcBLEKit/BLEClient.swift`:

```swift
import CoreBluetooth
import Foundation

public final class BLEClient {
    public struct Configuration: Sendable {
        public var restoreIdentifier: String?

        public init(restoreIdentifier: String? = nil) {
            self.restoreIdentifier = restoreIdentifier
        }
    }

    let central: CentralManaging
    private let lock = NSLock()
    private var peripheralsByIdentifier: [UUID: PeripheralRepresenting] = [:]

    public convenience init(configuration: Configuration = .init()) {
        self.init(central: CentralManagerBox(configuration: configuration))
    }

    init(central: CentralManaging) {
        self.central = central
    }

    func remember(_ peripheral: PeripheralRepresenting) {
        lock.lock()
        peripheralsByIdentifier[peripheral.identifier] = peripheral
        lock.unlock()
    }

    func rememberedPeripheral(identifier: UUID) -> PeripheralRepresenting? {
        lock.lock()
        defer { lock.unlock() }
        return peripheralsByIdentifier[identifier]
    }

    func validateBluetoothReady() throws {
        switch central.state {
        case .poweredOn:
            return
        case .unauthorized:
            throw BLEError.bluetoothUnauthorized
        case .unsupported:
            throw BLEError.bluetoothUnavailable
        case .poweredOff:
            throw BLEError.bluetoothPoweredOff
        case .unknown, .resetting:
            throw BLEError.bluetoothUnavailable
        }
    }
}
```

- [ ] **Step 4: Implement scan stream**

Write `Sources/ArcBLEKit/BLEClient+Scan.swift`:

```swift
import CoreBluetooth
import Foundation

public extension BLEClient {
    func scan(filter: ScanFilter) -> AsyncStream<BLEDevice> {
        AsyncStream { continuation in
            do {
                try validateBluetoothReady()
            } catch {
                continuation.finish()
                return
            }

            central.onDiscover = { [weak self] peripheral, advertisement, rssi in
                guard let self else { return }
                let device = BLEAdvertisementParser.makeDevice(
                    peripheral: peripheral,
                    advertisement: advertisement,
                    rssi: rssi
                )
                guard filter.matches(device) else { return }
                self.remember(peripheral)
                continuation.yield(device)
            }

            central.scanForPeripherals(
                withServices: filter.serviceUUIDs.isEmpty ? nil : filter.serviceUUIDs
            )

            continuation.onTermination = { [weak self] _ in
                self?.central.stopScan()
            }
        }
    }
}
```

- [ ] **Step 5: Add temporary real bridge stubs so the package compiles**

Write `Sources/ArcBLEKit/Internal/CentralManagerBox.swift`:

```swift
import CoreBluetooth
import Foundation

final class CentralManagerBox: NSObject, CentralManaging {
    var state: BluetoothState { .poweredOff }
    var onStateChange: ((BluetoothState) -> Void)?
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)?
    var onConnect: ((PeripheralRepresenting) -> Void)?
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)?
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)?

    init(configuration: BLEClient.Configuration) {
        super.init()
    }

    func scanForPeripherals(withServices services: [CBUUID]?) {}
    func stopScan() {}
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting] { [] }
    func connect(_ peripheral: PeripheralRepresenting) {}
    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting) {}
}
```

Write `Sources/ArcBLEKit/Internal/PeripheralBox.swift`:

```swift
import CoreBluetooth
import Foundation

final class PeripheralBox: NSObject, PeripheralRepresenting {
    var identifier: UUID { UUID() }
    var name: String? { nil }
    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)?
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)?
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)?
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)?

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting) {}
    func readValue(for characteristic: CharacteristicRepresenting) {}
    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType) {}
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting) {}
}
```

- [ ] **Step 6: Run tests and verify they pass**

Run:

```bash
swift test --filter BLEClientScanTests
```

Expected: `BLEClientScanTests` passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/ArcBLEKit/BLEClient.swift Sources/ArcBLEKit/BLEClient+Scan.swift Sources/ArcBLEKit/Internal/CentralManagerBox.swift Sources/ArcBLEKit/Internal/PeripheralBox.swift Tests/ArcBLEKitTests/BLEClientScanTests.swift
git commit -m "feat: add BLE scan stream"
```

---

### Task 4: Find Device, Connect, and Reconnect

**Files:**
- Modify: `Sources/ArcBLEKit/BLEClient+Scan.swift`
- Create: `Sources/ArcBLEKit/BLEClient+Reconnect.swift`
- Test: `Tests/ArcBLEKitTests/BLEClientReconnectTests.swift`

- [ ] **Step 1: Write failing find/connect/reconnect tests**

Write `Tests/ArcBLEKitTests/BLEClientReconnectTests.swift`:

```swift
import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class BLEClientReconnectTests: XCTestCase {
    func testFindDeviceReturnsFirstMatchAndStopsScanning() async throws {
        let central = FakeCentralManager()
        let client = BLEClient(central: central)
        let peripheral = FakePeripheral(identifier: UUID(), name: "Arc")

        let task = Task {
            try await client.findDevice(matching: ScanFilter(name: "Arc"), timeout: 1)
        }

        await Task.yield()
        central.discover(
            peripheral,
            advertisement: BLEAdvertisement(localName: "Arc", serviceUUIDs: [], manufacturerData: nil),
            rssi: -50
        )

        let device = try await task.value
        XCTAssertEqual(device.id, peripheral.identifier)
        XCTAssertTrue(central.didStopScan)
    }

    func testFindDeviceTimesOut() async {
        let client = BLEClient(central: FakeCentralManager())

        do {
            _ = try await client.findDevice(matching: ScanFilter(name: "Missing"), timeout: 0.01)
            XCTFail("Expected scan timeout")
        } catch {
            XCTAssertEqual(error as? BLEError, .scanTimedOut)
        }
    }

    func testReconnectRetrievesPeripheralBeforeScanning() async throws {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc")
        central.retrievedPeripherals = [peripheral]
        let client = BLEClient(central: central)

        let task = Task {
            try await client.reconnect(identifier: id, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
        }

        await Task.yield()
        central.completeConnection(peripheral)

        let session = try await task.value
        XCTAssertEqual(session.device.id, id)
        XCTAssertEqual(central.retrievedIdentifiers, [id])
        XCTAssertEqual(central.connectedIdentifiers, [id])
    }

    func testReconnectFallsBackToServiceScanAndMatchesIdentifier() async throws {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let peripheral = FakePeripheral(identifier: id, name: "Arc")
        let service = CBUUID(string: "FFF0")
        let client = BLEClient(central: central)

        let task = Task {
            try await client.reconnect(
                identifier: id,
                fallbackScan: ScanFilter(serviceUUIDs: [service]),
                options: ConnectionOptions(timeout: 1)
            )
        }

        await Task.yield()
        central.discover(
            peripheral,
            advertisement: BLEAdvertisement(localName: "Arc", serviceUUIDs: [service], manufacturerData: nil),
            rssi: -44
        )
        await Task.yield()
        central.completeConnection(peripheral)

        let session = try await task.value
        XCTAssertEqual(session.device.id, id)
        XCTAssertEqual(central.scannedServiceUUIDs, [service])
    }

    func testReconnectThrowsDeviceNotFoundWithoutFallback() async {
        let central = FakeCentralManager()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let client = BLEClient(central: central)

        do {
            _ = try await client.reconnect(identifier: id, fallbackScan: nil, options: ConnectionOptions(timeout: 1))
            XCTFail("Expected deviceNotFound")
        } catch {
            XCTAssertEqual(error as? BLEError, .deviceNotFound(id))
        }
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter BLEClientReconnectTests
```

Expected: build fails because `findDevice`, `connect`, `reconnect`, and `PeripheralSession` do not exist.

- [ ] **Step 3: Implement `findDevice`**

Append to `Sources/ArcBLEKit/BLEClient+Scan.swift`:

```swift
public extension BLEClient {
    func findDevice(
        matching filter: ScanFilter,
        timeout: TimeInterval
    ) async throws -> BLEDevice {
        try await withThrowingTaskGroup(of: BLEDevice.self) { group in
            group.addTask {
                var iterator = self.scan(filter: filter).makeAsyncIterator()
                guard let device = await iterator.next() else {
                    throw BLEError.scanTimedOut
                }
                return device
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BLEError.scanTimedOut
            }

            let device = try await group.next()!
            group.cancelAll()
            central.stopScan()
            return device
        }
    }
}
```

- [ ] **Step 4: Implement minimal `PeripheralSession` for connection flows**

Write `Sources/ArcBLEKit/PeripheralSession.swift`:

```swift
import Foundation

public final class PeripheralSession {
    public let device: BLEDevice
    let peripheral: PeripheralRepresenting
    let central: CentralManaging
    let options: ConnectionOptions

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    public let connectionStates: AsyncStream<ConnectionState>

    init(
        device: BLEDevice,
        peripheral: PeripheralRepresenting,
        central: CentralManaging,
        options: ConnectionOptions
    ) {
        self.device = device
        self.peripheral = peripheral
        self.central = central
        self.options = options

        var continuation: AsyncStream<ConnectionState>.Continuation!
        self.connectionStates = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
        emit(.connected)
    }

    func emit(_ state: ConnectionState) {
        stateContinuation.yield(state)
    }

    public func disconnect() async {
        central.cancelPeripheralConnection(peripheral)
        emit(.disconnected)
        stateContinuation.finish()
    }
}
```

- [ ] **Step 5: Implement connect and reconnect**

Write `Sources/ArcBLEKit/BLEClient+Reconnect.swift`:

```swift
import Foundation

public extension BLEClient {
    func connect(
        to device: BLEDevice,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession {
        guard let peripheral = rememberedPeripheral(identifier: device.id) else {
            throw BLEError.deviceNotFound(device.id)
        }
        return try await connect(peripheral: peripheral, device: device, options: options)
    }

    func reconnect(
        identifier: UUID,
        fallbackScan: ScanFilter?,
        options: ConnectionOptions = .init()
    ) async throws -> PeripheralSession {
        let retrieved = central.retrievePeripherals(withIdentifiers: [identifier])

        if let peripheral = retrieved.first {
            remember(peripheral)
            let device = BLEDevice(
                id: peripheral.identifier,
                name: peripheral.name,
                rssi: 0,
                advertisedServiceUUIDs: [],
                manufacturerData: nil
            )
            return try await connect(peripheral: peripheral, device: device, options: options)
        }

        guard let fallbackScan else {
            throw BLEError.deviceNotFound(identifier)
        }

        var filter = fallbackScan
        filter.peripheralIdentifiers.insert(identifier)
        let device = try await findDevice(matching: filter, timeout: options.timeout)
        return try await connect(to: device, options: options)
    }

    private func connect(
        peripheral: PeripheralRepresenting,
        device: BLEDevice,
        options: ConnectionOptions
    ) async throws -> PeripheralSession {
        try validateBluetoothReady()

        return try await withThrowingTaskGroup(of: PeripheralSession.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.central.onConnect = { connectedPeripheral in
                        guard connectedPeripheral.identifier == peripheral.identifier else { return }
                        let session = PeripheralSession(
                            device: device,
                            peripheral: connectedPeripheral,
                            central: self.central,
                            options: options
                        )
                        continuation.resume(returning: session)
                    }

                    self.central.onFailToConnect = { failedPeripheral, error in
                        guard failedPeripheral.identifier == peripheral.identifier else { return }
                        continuation.resume(
                            throwing: BLEError.connectionFailed(
                                peripheral.identifier,
                                underlying: error.map(String.init(describing:))
                            )
                        )
                    }

                    self.central.connect(peripheral)
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000))
                throw BLEError.connectionTimedOut(peripheral.identifier)
            }

            let session = try await group.next()!
            group.cancelAll()
            return session
        }
    }
}
```

- [ ] **Step 6: Run tests and verify they pass**

Run:

```bash
swift test --filter BLEClientReconnectTests
```

Expected: `BLEClientReconnectTests` passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/ArcBLEKit/BLEClient+Scan.swift Sources/ArcBLEKit/BLEClient+Reconnect.swift Sources/ArcBLEKit/PeripheralSession.swift Tests/ArcBLEKitTests/BLEClientReconnectTests.swift
git commit -m "feat: add connect and reconnect flows"
```

---

### Task 5: Characteristic Cache and Session Operations

**Files:**
- Create: `Sources/ArcBLEKit/Internal/AsyncOperationStore.swift`
- Create: `Sources/ArcBLEKit/Internal/CharacteristicCache.swift`
- Create: `Sources/ArcBLEKit/Internal/SessionOperationQueue.swift`
- Create: `Sources/ArcBLEKit/PeripheralSession+Operations.swift`
- Modify: `Sources/ArcBLEKit/PeripheralSession.swift`
- Test: `Tests/ArcBLEKitTests/PeripheralSessionOperationTests.swift`

- [ ] **Step 1: Write failing session operation tests**

Write `Tests/ArcBLEKitTests/PeripheralSessionOperationTests.swift`:

```swift
import CoreBluetooth
import XCTest
@testable import ArcBLEKit

final class PeripheralSessionOperationTests: XCTestCase {
    func testReadDiscoversServiceAndCharacteristicThenReturnsData() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF1")
        let peripheral = FakePeripheral()
        let central = FakeCentralManager()
        let session = PeripheralSession(
            device: BLEDevice(id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil),
            peripheral: peripheral,
            central: central,
            options: ConnectionOptions()
        )
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let task = Task {
            try await session.read(characteristic: characteristicUUID, service: serviceUUID)
        }

        await Task.yield()
        XCTAssertEqual(peripheral.discoveredServiceUUIDs, [serviceUUID])
        peripheral.completeServiceDiscovery([service])
        await Task.yield()
        XCTAssertEqual(peripheral.discoveredCharacteristicUUIDs, [characteristicUUID])
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await Task.yield()
        XCTAssertEqual(peripheral.readCharacteristics, [characteristicUUID])
        peripheral.completeRead(characteristic: characteristic, data: Data([0x01, 0x02]))

        let data = try await task.value
        XCTAssertEqual(data, Data([0x01, 0x02]))
    }

    func testWriteUsesDiscoveredCharacteristic() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF2")
        let peripheral = FakePeripheral()
        let session = PeripheralSession(
            device: BLEDevice(id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil),
            peripheral: peripheral,
            central: FakeCentralManager(),
            options: ConnectionOptions()
        )
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let task = Task {
            try await session.write(Data([0x09]), to: characteristicUUID, service: serviceUUID, type: .withResponse)
        }

        await Task.yield()
        peripheral.completeServiceDiscovery([service])
        await Task.yield()
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await Task.yield()
        XCTAssertEqual(peripheral.writtenValues.first?.data, Data([0x09]))
        XCTAssertEqual(peripheral.writtenValues.first?.characteristic, characteristicUUID)
        peripheral.completeWrite(characteristic: characteristic)

        try await task.value
    }

    func testNotificationsReturnStreamAndEmitValues() async throws {
        let serviceUUID = CBUUID(string: "FFF0")
        let characteristicUUID = CBUUID(string: "FFF3")
        let peripheral = FakePeripheral()
        let session = PeripheralSession(
            device: BLEDevice(id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil),
            peripheral: peripheral,
            central: FakeCentralManager(),
            options: ConnectionOptions()
        )
        let service = FakeService(uuid: serviceUUID)
        let characteristic = FakeCharacteristic(uuid: characteristicUUID, serviceUUID: serviceUUID)

        let streamTask = Task {
            try await session.notifications(for: characteristicUUID, service: serviceUUID)
        }

        await Task.yield()
        peripheral.completeServiceDiscovery([service])
        await Task.yield()
        peripheral.completeCharacteristicDiscovery(service: service, characteristics: [characteristic])
        await Task.yield()
        XCTAssertEqual(peripheral.notifyChanges.first?.enabled, true)
        peripheral.completeNotifySetup(characteristic: characteristic)

        let stream = try await streamTask.value
        var iterator = stream.makeAsyncIterator()
        peripheral.emitNotification(characteristic: characteristic, data: Data([0xAA]))

        let value = await iterator.next()
        XCTAssertEqual(value, Data([0xAA]))
    }

    func testMissingServiceThrowsServiceNotFound() async {
        let serviceUUID = CBUUID(string: "FFF0")
        let peripheral = FakePeripheral()
        let session = PeripheralSession(
            device: BLEDevice(id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil),
            peripheral: peripheral,
            central: FakeCentralManager(),
            options: ConnectionOptions()
        )

        let task = Task {
            try await session.read(characteristic: CBUUID(string: "FFF1"), service: serviceUUID)
        }

        await Task.yield()
        peripheral.completeServiceDiscovery([])

        do {
            _ = try await task.value
            XCTFail("Expected serviceNotFound")
        } catch {
            XCTAssertEqual(error as? BLEError, .serviceNotFound(serviceUUID))
        }
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter PeripheralSessionOperationTests
```

Expected: build fails because session operation methods do not exist.

- [ ] **Step 3: Implement operation store and cache**

Write `Sources/ArcBLEKit/Internal/AsyncOperationStore.swift`:

```swift
import Foundation

actor AsyncOperationStore<Key: Hashable, Value> {
    private var continuations: [Key: CheckedContinuation<Value, Error>] = [:]

    func store(_ continuation: CheckedContinuation<Value, Error>, for key: Key) {
        continuations[key] = continuation
    }

    func resume(key: Key, returning value: Value) {
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(returning: value)
    }

    func resume(key: Key, throwing error: Error) {
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(throwing: error)
    }
}
```

Write `Sources/ArcBLEKit/Internal/CharacteristicCache.swift`:

```swift
import CoreBluetooth

final class CharacteristicCache {
    private var servicesByUUID: [CBUUID: ServiceRepresenting] = [:]
    private var characteristicsByServiceAndUUID: [String: CharacteristicRepresenting] = [:]

    func service(for uuid: CBUUID) -> ServiceRepresenting? {
        servicesByUUID[uuid]
    }

    func store(services: [ServiceRepresenting]) {
        for service in services {
            servicesByUUID[service.uuid] = service
        }
    }

    func characteristic(_ characteristicUUID: CBUUID, service serviceUUID: CBUUID) -> CharacteristicRepresenting? {
        characteristicsByServiceAndUUID[key(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)]
    }

    func store(characteristics: [CharacteristicRepresenting], serviceUUID: CBUUID) {
        for characteristic in characteristics {
            characteristicsByServiceAndUUID[key(serviceUUID: serviceUUID, characteristicUUID: characteristic.uuid)] = characteristic
        }
    }

    private func key(serviceUUID: CBUUID, characteristicUUID: CBUUID) -> String {
        "\(serviceUUID.uuidString)::\(characteristicUUID.uuidString)"
    }
}
```

Write `Sources/ArcBLEKit/Internal/SessionOperationQueue.swift`:

```swift
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class SessionOperationQueue {
    private let semaphore = AsyncSemaphore(value: 1)

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        await semaphore.wait()
        defer {
            Task {
                await semaphore.signal()
            }
        }
        return try await operation()
    }
}
```

- [ ] **Step 4: Implement session operations**

Write `Sources/ArcBLEKit/PeripheralSession+Operations.swift`:

```swift
import CoreBluetooth
import Foundation

public extension PeripheralSession {
    func read(
        characteristic characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) async throws -> Data {
        try await operationQueue.run {
            let characteristic = try await resolveCharacteristic(characteristicUUID, service: serviceUUID)
            return try await withCheckedThrowingContinuation { continuation in
                peripheral.onValueRead = { readCharacteristic, data, error in
                    guard readCharacteristic.uuid == characteristicUUID else { return }
                    if let error {
                        continuation.resume(throwing: BLEError.readFailed(characteristicUUID, underlying: String(describing: error)))
                    } else {
                        continuation.resume(returning: data ?? Data())
                    }
                }
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func write(
        _ data: Data,
        to characteristicUUID: CBUUID,
        service serviceUUID: CBUUID,
        type: CBCharacteristicWriteType
    ) async throws {
        try await operationQueue.run {
            let characteristic = try await resolveCharacteristic(characteristicUUID, service: serviceUUID)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peripheral.onValueWritten = { writtenCharacteristic, error in
                    guard writtenCharacteristic.uuid == characteristicUUID else { return }
                    if let error {
                        continuation.resume(throwing: BLEError.writeFailed(characteristicUUID, underlying: String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                }
                peripheral.writeValue(data, for: characteristic, type: type)
            }
        }
    }

    func notifications(
        for characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) async throws -> AsyncStream<Data> {
        try await operationQueue.run {
            let characteristic = try await resolveCharacteristic(characteristicUUID, service: serviceUUID)

            return try await withCheckedThrowingContinuation { continuation in
                peripheral.onNotificationStateUpdated = { updatedCharacteristic, error in
                    guard updatedCharacteristic.uuid == characteristicUUID else { return }
                    if let error {
                        continuation.resume(throwing: BLEError.notificationSetupFailed(characteristicUUID, underlying: String(describing: error)))
                    } else {
                        let stream = AsyncStream<Data> { streamContinuation in
                            self.peripheral.onNotificationValue = { notifiedCharacteristic, data in
                                guard notifiedCharacteristic.uuid == characteristicUUID else { return }
                                streamContinuation.yield(data)
                            }
                        }
                        continuation.resume(returning: stream)
                    }
                }
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    private func resolveCharacteristic(
        _ characteristicUUID: CBUUID,
        service serviceUUID: CBUUID
    ) async throws -> CharacteristicRepresenting {
        let service = try await resolveService(serviceUUID)

        if let cached = characteristicCache.characteristic(characteristicUUID, service: serviceUUID) {
            return cached
        }

        return try await withCheckedThrowingContinuation { continuation in
            peripheral.onCharacteristicsDiscovered = { discoveredService, characteristics, error in
                guard discoveredService.uuid == serviceUUID else { return }
                if let error {
                    continuation.resume(throwing: BLEError.characteristicNotFound(characteristicUUID, service: serviceUUID))
                    _ = error
                    return
                }
                self.characteristicCache.store(characteristics: characteristics, serviceUUID: serviceUUID)
                guard let characteristic = self.characteristicCache.characteristic(characteristicUUID, service: serviceUUID) else {
                    continuation.resume(throwing: BLEError.characteristicNotFound(characteristicUUID, service: serviceUUID))
                    return
                }
                continuation.resume(returning: characteristic)
            }
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    private func resolveService(_ serviceUUID: CBUUID) async throws -> ServiceRepresenting {
        if let cached = characteristicCache.service(for: serviceUUID) {
            return cached
        }

        return try await withCheckedThrowingContinuation { continuation in
            peripheral.onServicesDiscovered = { services, error in
                if let error {
                    continuation.resume(throwing: BLEError.serviceNotFound(serviceUUID))
                    _ = error
                    return
                }
                self.characteristicCache.store(services: services)
                guard let service = self.characteristicCache.service(for: serviceUUID) else {
                    continuation.resume(throwing: BLEError.serviceNotFound(serviceUUID))
                    return
                }
                continuation.resume(returning: service)
            }
            peripheral.discoverServices([serviceUUID])
        }
    }
}
```

Modify `Sources/ArcBLEKit/PeripheralSession.swift` by adding a stored cache property:

```swift
let characteristicCache = CharacteristicCache()
let operationQueue = SessionOperationQueue()
```

Place it after the existing `options` property:

```swift
let options: ConnectionOptions
let characteristicCache = CharacteristicCache()
let operationQueue = SessionOperationQueue()
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
swift test --filter PeripheralSessionOperationTests
```

Expected: `PeripheralSessionOperationTests` passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/ArcBLEKit/Internal/AsyncOperationStore.swift Sources/ArcBLEKit/Internal/CharacteristicCache.swift Sources/ArcBLEKit/Internal/SessionOperationQueue.swift Sources/ArcBLEKit/PeripheralSession.swift Sources/ArcBLEKit/PeripheralSession+Operations.swift Tests/ArcBLEKitTests/PeripheralSessionOperationTests.swift
git commit -m "feat: add peripheral session operations"
```

---

### Task 6: Disconnect Handling and Limited Auto-Reconnect

**Files:**
- Modify: `Sources/ArcBLEKit/PeripheralSession.swift`
- Modify: `Sources/ArcBLEKit/BLEClient+Reconnect.swift`
- Test: `Tests/ArcBLEKitTests/PeripheralSessionReconnectTests.swift`

- [ ] **Step 1: Write failing reconnect state tests**

Write `Tests/ArcBLEKitTests/PeripheralSessionReconnectTests.swift`:

```swift
import XCTest
@testable import ArcBLEKit

final class PeripheralSessionReconnectTests: XCTestCase {
    func testUnexpectedDisconnectEmitsDisconnectedState() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = BLEDevice(id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil)
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(to: device, options: ConnectionOptions(timeout: 1))
        }
        await Task.yield()
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        var iterator = session.connectionStates.makeAsyncIterator()

        _ = await iterator.next()
        central.disconnect(peripheral)

        let state = await iterator.next()
        XCTAssertEqual(state, .disconnected)
    }

    func testLimitedAutoReconnectEmitsReconnectStateAndReconnectsOnce() async throws {
        let central = FakeCentralManager()
        let peripheral = FakePeripheral()
        let client = BLEClient(central: central)
        let device = BLEDevice(id: peripheral.identifier, name: nil, rssi: 0, advertisedServiceUUIDs: [], manufacturerData: nil)
        client.remember(peripheral)

        let connectTask = Task {
            try await client.connect(
                to: device,
                options: ConnectionOptions(
                    timeout: 1,
                    autoReconnect: .limited(maxAttempts: 1, delay: 0.01)
                )
            )
        }
        await Task.yield()
        central.completeConnection(peripheral)
        let session = try await connectTask.value
        var iterator = session.connectionStates.makeAsyncIterator()

        _ = await iterator.next()
        central.disconnect(peripheral)
        let disconnected = await iterator.next()
        let reconnecting = await iterator.next()

        XCTAssertEqual(disconnected, .disconnected)
        XCTAssertEqual(reconnecting, .reconnecting(attempt: 1))
        XCTAssertEqual(central.connectedIdentifiers.filter { $0 == peripheral.identifier }.count, 2)
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter PeripheralSessionReconnectTests
```

Expected: reconnect state tests fail because disconnect callbacks are not wired to sessions.

- [ ] **Step 3: Wire disconnect callbacks to sessions**

Modify `Sources/ArcBLEKit/BLEClient.swift` to add session storage:

```swift
private var sessionsByIdentifier: [UUID: PeripheralSession] = [:]

func remember(_ session: PeripheralSession) {
    lock.lock()
    sessionsByIdentifier[session.device.id] = session
    lock.unlock()
}

func session(identifier: UUID) -> PeripheralSession? {
    lock.lock()
    defer { lock.unlock() }
    return sessionsByIdentifier[identifier]
}
```

In `init(central:)`, install the disconnect callback:

```swift
self.central.onDisconnect = { [weak self] peripheral, error in
    self?.session(identifier: peripheral.identifier)?.handleDisconnect(error: error)
}
```

Because assigning the callback uses `self`, set it after `self.central = central`.

- [ ] **Step 4: Add reconnect handling to session**

Modify `Sources/ArcBLEKit/PeripheralSession.swift`:

```swift
func handleDisconnect(error: Error?) {
    emit(.disconnected)

    guard case let .limited(maxAttempts, delay) = options.autoReconnect else {
        return
    }

    Task {
        for attempt in 1...maxAttempts {
            emit(.reconnecting(attempt: attempt))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            emit(.connecting)
            central.connect(peripheral)
            return
        }
    }
}
```

Modify `Sources/ArcBLEKit/BLEClient+Reconnect.swift` so successful connection stores the session:

```swift
let session = PeripheralSession(
    device: device,
    peripheral: connectedPeripheral,
    central: self.central,
    options: options
)
self.remember(session)
continuation.resume(returning: session)
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
swift test --filter PeripheralSessionReconnectTests
```

Expected: `PeripheralSessionReconnectTests` passes.

- [ ] **Step 6: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ArcBLEKit/BLEClient.swift Sources/ArcBLEKit/BLEClient+Reconnect.swift Sources/ArcBLEKit/PeripheralSession.swift Tests/ArcBLEKitTests/PeripheralSessionReconnectTests.swift
git commit -m "feat: add disconnect and limited reconnect handling"
```

---

### Task 7: Real CoreBluetooth Bridge

**Files:**
- Replace: `Sources/ArcBLEKit/Internal/CentralManagerBox.swift`
- Replace: `Sources/ArcBLEKit/Internal/PeripheralBox.swift`
- Test: `Tests/ArcBLEKitTests/CoreBluetoothBridgeCompileTests.swift`

- [ ] **Step 1: Write compile-focused bridge tests**

Write `Tests/ArcBLEKitTests/CoreBluetoothBridgeCompileTests.swift`:

```swift
import XCTest
@testable import ArcBLEKit

final class CoreBluetoothBridgeCompileTests: XCTestCase {
    func testBLEClientCanBeCreatedWithPublicInitializer() {
        let client = BLEClient(configuration: .init(restoreIdentifier: "com.example.arc.ble"))

        XCTAssertNotNil(client)
    }
}
```

- [ ] **Step 2: Run tests and verify bridge still uses stubs**

Run:

```bash
swift test --filter CoreBluetoothBridgeCompileTests
```

Expected: test passes with stubs. This test protects the public initializer while replacing internals.

- [ ] **Step 3: Replace `CentralManagerBox` with real adapter**

Write `Sources/ArcBLEKit/Internal/CentralManagerBox.swift`:

```swift
import CoreBluetooth
import Foundation

final class CentralManagerBox: NSObject, CentralManaging {
    private let manager: CBCentralManager
    private var boxesByIdentifier: [UUID: PeripheralBox] = [:]

    var state: BluetoothState {
        BluetoothState(manager.state)
    }

    var onStateChange: ((BluetoothState) -> Void)?
    var onDiscover: ((PeripheralRepresenting, BLEAdvertisement, Int) -> Void)?
    var onConnect: ((PeripheralRepresenting) -> Void)?
    var onFailToConnect: ((PeripheralRepresenting, Error?) -> Void)?
    var onDisconnect: ((PeripheralRepresenting, Error?) -> Void)?

    init(configuration: BLEClient.Configuration) {
        var options: [String: Any]?
        if let restoreIdentifier = configuration.restoreIdentifier {
            options = [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        }
        self.manager = CBCentralManager(delegate: nil, queue: nil, options: options)
        super.init()
        self.manager.delegate = self
    }

    func scanForPeripherals(withServices services: [CBUUID]?) {
        manager.scanForPeripherals(withServices: services, options: nil)
    }

    func stopScan() {
        manager.stopScan()
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [PeripheralRepresenting] {
        manager.retrievePeripherals(withIdentifiers: identifiers).map { box(for: $0) }
    }

    func connect(_ peripheral: PeripheralRepresenting) {
        guard let box = peripheral as? PeripheralBox else { return }
        manager.connect(box.peripheral, options: nil)
    }

    func cancelPeripheralConnection(_ peripheral: PeripheralRepresenting) {
        guard let box = peripheral as? PeripheralBox else { return }
        manager.cancelPeripheralConnection(box.peripheral)
    }

    private func box(for peripheral: CBPeripheral) -> PeripheralBox {
        if let existing = boxesByIdentifier[peripheral.identifier] {
            return existing
        }
        let box = PeripheralBox(peripheral: peripheral)
        boxesByIdentifier[peripheral.identifier] = box
        return box
    }
}

extension CentralManagerBox: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateChange?(BluetoothState(central.state))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        onDiscover?(
            box(for: peripheral),
            BLEAdvertisementParser.parse(advertisementData),
            RSSI.intValue
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onConnect?(box(for: peripheral))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onFailToConnect?(box(for: peripheral), error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        onDisconnect?(box(for: peripheral), error)
    }
}
```

- [ ] **Step 4: Replace `PeripheralBox` with real adapter**

Write `Sources/ArcBLEKit/Internal/PeripheralBox.swift`:

```swift
import CoreBluetooth
import Foundation

final class ServiceBox: ServiceRepresenting {
    let service: CBService
    var uuid: CBUUID { service.uuid }

    init(service: CBService) {
        self.service = service
    }
}

final class CharacteristicBox: CharacteristicRepresenting {
    let characteristic: CBCharacteristic
    var uuid: CBUUID { characteristic.uuid }
    var serviceUUID: CBUUID { characteristic.service.uuid }

    init(characteristic: CBCharacteristic) {
        self.characteristic = characteristic
    }
}

final class PeripheralBox: NSObject, PeripheralRepresenting {
    let peripheral: CBPeripheral

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var onServicesDiscovered: (([ServiceRepresenting], Error?) -> Void)?
    var onCharacteristicsDiscovered: ((ServiceRepresenting, [CharacteristicRepresenting], Error?) -> Void)?
    var onValueRead: ((CharacteristicRepresenting, Data?, Error?) -> Void)?
    var onValueWritten: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationStateUpdated: ((CharacteristicRepresenting, Error?) -> Void)?
    var onNotificationValue: ((CharacteristicRepresenting, Data) -> Void)?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        self.peripheral.delegate = self
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        peripheral.discoverServices(serviceUUIDs)
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: ServiceRepresenting) {
        guard let serviceBox = service as? ServiceBox else { return }
        peripheral.discoverCharacteristics(characteristicUUIDs, for: serviceBox.service)
    }

    func readValue(for characteristic: CharacteristicRepresenting) {
        guard let characteristicBox = characteristic as? CharacteristicBox else { return }
        peripheral.readValue(for: characteristicBox.characteristic)
    }

    func writeValue(_ data: Data, for characteristic: CharacteristicRepresenting, type: CBCharacteristicWriteType) {
        guard let characteristicBox = characteristic as? CharacteristicBox else { return }
        peripheral.writeValue(data, for: characteristicBox.characteristic, type: type)
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRepresenting) {
        guard let characteristicBox = characteristic as? CharacteristicBox else { return }
        peripheral.setNotifyValue(enabled, for: characteristicBox.characteristic)
    }
}

extension PeripheralBox: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services?.map(ServiceBox.init(service:)) ?? []
        onServicesDiscovered?(services, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let serviceBox = ServiceBox(service: service)
        let characteristics = service.characteristics?.map(CharacteristicBox.init(characteristic:)) ?? []
        onCharacteristicsDiscovered?(serviceBox, characteristics, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let box = CharacteristicBox(characteristic: characteristic)
        if let error {
            onValueRead?(box, nil, error)
            return
        }
        if characteristic.isNotifying, let value = characteristic.value {
            onNotificationValue?(box, value)
        } else {
            onValueRead?(box, characteristic.value, nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        onValueWritten?(CharacteristicBox(characteristic: characteristic), error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        onNotificationStateUpdated?(CharacteristicBox(characteristic: characteristic), error)
    }
}
```

- [ ] **Step 5: Run full tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ArcBLEKit/Internal/CentralManagerBox.swift Sources/ArcBLEKit/Internal/PeripheralBox.swift Tests/ArcBLEKitTests/CoreBluetoothBridgeCompileTests.swift
git commit -m "feat: add CoreBluetooth bridge"
```

---

### Task 8: README and Final Verification

**Files:**
- Create: `README.md`
- Modify: files only if final verification reveals compile or test failures.

- [ ] **Step 1: Write README**

Write `README.md`:

```markdown
# ArcBLEKit

ArcBLEKit is a Swift Package for iOS BLE central apps. It wraps CoreBluetooth with Swift Concurrency APIs for scanning, connecting, reconnecting, reading, writing, and subscribing to notifications.

## Requirements

- Swift 5.5+
- iOS 14.0+
- Swift Package Manager

## Installation

Add this package in Xcode through **File > Add Package Dependencies** and select the repository URL for ArcBLEKit.

## iOS Permissions

Add the Bluetooth usage description required by your app target:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to connect to nearby BLE devices.</string>
```

## Scan for a Service UUID

```swift
import ArcBLEKit
import CoreBluetooth

let client = BLEClient()
let service = CBUUID(string: "FFF0")

for await device in client.scan(filter: ScanFilter(serviceUUIDs: [service])) {
    print(device.name ?? "Unknown", device.id, device.rssi)
}
```

## Find and Connect

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

## Save and Reconnect by Peripheral Identifier

`BLEDevice.id` maps to `CBPeripheral.identifier`. Save it after the user chooses a device:

```swift
let savedID = device.id
```

Reconnect later:

```swift
let session = try await client.reconnect(
    identifier: savedID,
    fallbackScan: ScanFilter(serviceUUIDs: [CBUUID(string: "FFF0")]),
    options: ConnectionOptions(timeout: 10)
)
```

`CBPeripheral.identifier` is assigned by iOS. It is useful for reconnecting to a previously selected device from the same app and iOS device, but it is not a global BLE MAC address.

## Read and Write

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
```

## Notifications

```swift
let updates = try await session.notifications(
    for: CBUUID(string: "FFF3"),
    service: CBUUID(string: "FFF0")
)

for await data in updates {
    print(data)
}
```

## State Restoration

`BLEClient.Configuration.restoreIdentifier` reserves a hook for CoreBluetooth restoration identifiers. Full app relaunch state restoration is not implemented in the first version.
```

- [ ] **Step 2: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 3: Build the package**

Run:

```bash
swift build
```

Expected: package builds successfully.

- [ ] **Step 4: Inspect git status**

Run:

```bash
git status --short
```

Expected: only intended README or verification fixes appear before commit.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: add ArcBLEKit README"
```

---

## Self-Review Checklist

- Spec coverage: Tasks cover package setup, public API, service UUID scanning, `BLEDevice.id`, identifier reconnect through retrieval first, fallback scan, session operations, state stream, limited reconnect, CoreBluetooth isolation, fakes, and README.
- Scope check: This plan produces the first generic BLE client library only. It excludes device protocols, OTA, DFU, and full restoration as required.
- Type consistency: The plan uses `TimeInterval` for timeouts and delays, `CBUUID` for service and characteristic UUIDs, `UUID` for peripheral identifiers, and `CBCharacteristicWriteType` for write mode.
- Testing path: Each behavior has focused XCTest coverage before implementation.
- Final verification: `swift test` and `swift build` are required before the work is considered complete.
