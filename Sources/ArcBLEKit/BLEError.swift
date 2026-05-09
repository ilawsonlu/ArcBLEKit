#if compiler(>=5.6)
@preconcurrency import CoreBluetooth
#else
import CoreBluetooth
#endif
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
