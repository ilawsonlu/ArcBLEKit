import XCTest
@testable import ArcBLEKit

final class CoreBluetoothBridgeCompileTests: XCTestCase {
    func testBLEClientCanBeCreatedWithPublicInitializer() {
        let client = BLEClient(configuration: .init(restoreIdentifier: "com.example.arc.ble"))

        XCTAssertNotNil(client)
    }
}
