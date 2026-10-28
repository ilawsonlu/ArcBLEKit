#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
import XCTest
@testable import ArcBLEKit

final class NotificationRegistryTests: XCTestCase {
    private let id = GATTCharacteristicID(serviceUUID: CBUUID(string: "FFF0"), characteristicUUID: CBUUID(string: "FFF3"))
    private let compatible = NotificationSubscriptionConfiguration(allowUnsupportedProperties: true, discoveryMode: .targeted)
    private let strictAll = NotificationSubscriptionConfiguration(allowUnsupportedProperties: false, discoveryMode: .all)

    func testRemovingConsumerRecomputesSharedConfigurationAndInvalidatesSnapshot() throws {
        let registry = NotificationRegistry()
        let characteristic = makeCharacteristic()
        let first = add(to: registry, characteristic: characteristic, configuration: compatible)
        let second = add(to: registry, characteristic: characteristic, configuration: strictAll)
        let snapshot = try XCTUnwrap(registry.snapshot(for: id))
        XCTAssertEqual(snapshot.configuration, strictAll)

        XCTAssertNil(registry.remove(subscriberID: second.id, from: id))
        XCTAssertFalse(registry.isCurrent(snapshot))
        XCTAssertFalse(registry.update(characteristic: characteristic, setupState: .confirmed, for: snapshot))
        XCTAssertEqual(registry.snapshot(for: id)?.configuration, compatible)
        XCTAssertTrue(registry.remove(subscriberID: first.id, from: id) === characteristic)
        XCTAssertNil(registry.snapshot(for: id))
        withExtendedLifetime((first.stream, second.stream)) {}
    }

    func testReplacedChannelRejectsOldRestorationSnapshot() throws {
        let registry = NotificationRegistry()
        let old = add(to: registry, characteristic: makeCharacteristic(), configuration: compatible)
        let snapshot = try XCTUnwrap(registry.snapshot(for: id))
        _ = registry.remove(subscriberID: old.id, from: id)
        let replacement = makeCharacteristic()
        let new = add(to: registry, characteristic: replacement, configuration: strictAll)

        XCTAssertNotEqual(snapshot.generation, registry.snapshot(for: id)?.generation)
        XCTAssertFalse(registry.beginSetup(characteristic: snapshot.characteristic, for: snapshot))
        XCTAssertFalse(registry.update(characteristic: snapshot.characteristic, setupState: .unconfirmed, for: snapshot))
        XCTAssertTrue(registry.snapshot(for: id)?.characteristic === replacement)
        XCTAssertEqual(registry.snapshot(for: id)?.configuration, strictAll)
        withExtendedLifetime((old.stream, new.stream)) {}
    }

    func testDisconnectInvalidatesConfirmationAndCancelledChannelNeedsNoDisable() throws {
        let registry = NotificationRegistry()
        let subscriber = add(to: registry, characteristic: makeCharacteristic(), configuration: compatible)
        let snapshot = try XCTUnwrap(registry.snapshot(for: id))
        registry.invalidateSetups()
        XCTAssertFalse(registry.isCurrent(snapshot))
        XCTAssertEqual(registry.snapshot(for: id)?.setupState, .inactive)
        XCTAssertNil(registry.remove(subscriberID: subscriber.id, from: id))
        XCTAssertTrue(registry.snapshots().isEmpty)
        withExtendedLifetime(subscriber.stream) {}
    }

    func testCancellationDuringSetupUsesTheNewCharacteristicForCleanup() throws {
        let registry = NotificationRegistry()
        let subscriber = add(to: registry, characteristic: makeCharacteristic(), configuration: compatible)
        registry.invalidateSetups()
        let snapshot = try XCTUnwrap(registry.snapshot(for: id))
        let rediscovered = makeCharacteristic()
        XCTAssertTrue(registry.beginSetup(characteristic: rediscovered, for: snapshot))
        XCTAssertTrue(registry.remove(subscriberID: subscriber.id, from: id) === rediscovered)
        XCTAssertFalse(registry.update(characteristic: rediscovered, setupState: .confirmed, for: snapshot))
        XCTAssertTrue(registry.activeIDs().isEmpty)
        withExtendedLifetime(subscriber.stream) {}
    }

    func testSameCharacteristicUUIDInDifferentServicesKeepsConfigurationAndValuesSeparate() async throws {
        let registry = NotificationRegistry()
        let otherID = GATTCharacteristicID(serviceUUID: CBUUID(string: "AAA0"), characteristicUUID: id.characteristicUUID)
        let first = add(to: registry, characteristic: makeCharacteristic(), configuration: compatible)
        let second = add(
            to: registry,
            characteristic: FakeCharacteristic(uuid: otherID.characteristicUUID, serviceUUID: otherID.serviceUUID),
            configuration: strictAll, id: otherID
        )
        XCTAssertEqual(registry.snapshot(for: id)?.configuration, compatible)
        XCTAssertEqual(registry.snapshot(for: otherID)?.configuration, strictAll)
        registry.yield(Data([1]), for: id)
        registry.yield(Data([2]), for: otherID)
        var firstIterator = first.stream.makeAsyncIterator()
        var secondIterator = second.stream.makeAsyncIterator()
        let firstValue = try await firstIterator.next()
        let secondValue = try await secondIterator.next()
        XCTAssertEqual(firstValue, Data([1]))
        XCTAssertEqual(secondValue, Data([2]))
    }

    func testFinishedSessionRejectsLateRegistrationAndCannotRestoreOldSnapshot() async throws {
        let registry = NotificationRegistry()
        let first = add(to: registry, characteristic: makeCharacteristic(), configuration: compatible)
        let snapshot = try XCTUnwrap(registry.snapshot(for: id))
        registry.finishAll(throwing: BLEError.operationCancelled)
        let late = add(to: registry, characteristic: makeCharacteristic(), configuration: compatible)
        XCTAssertFalse(registry.update(characteristic: snapshot.characteristic, setupState: .confirmed, for: snapshot))
        XCTAssertTrue(registry.activeIDs().isEmpty)
        for stream in [first.stream, late.stream] {
            var iterator = stream.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                XCTFail("Expected termination")
            } catch { XCTAssertEqual(error as? BLEError, .operationCancelled) }
        }
    }

    private func makeCharacteristic() -> FakeCharacteristic {
        FakeCharacteristic(uuid: id.characteristicUUID, serviceUUID: id.serviceUUID)
    }

    private func add(
        to registry: NotificationRegistry, characteristic: FakeCharacteristic,
        configuration: NotificationSubscriptionConfiguration, id: GATTCharacteristicID? = nil
    ) -> (id: UUID, stream: AsyncThrowingStream<Data, Error>) {
        let subscriberID = UUID()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            registry.add(
                continuation, subscriberID: subscriberID, characteristic: characteristic,
                configuration: configuration, setupState: .confirmed, for: id ?? self.id
            )
        }
        return (subscriberID, stream)
    }
}
