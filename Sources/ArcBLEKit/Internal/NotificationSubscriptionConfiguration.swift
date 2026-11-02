/// Behavior owned by one notification consumer, independent of operation timeouts.
struct NotificationSubscriptionConfiguration: Equatable, Sendable {
    var allowUnsupportedProperties: Bool
    var discoveryMode: GATTDiscoveryMode

    func merging(_ other: Self) -> Self {
        Self(
            allowUnsupportedProperties: allowUnsupportedProperties && other.allowUnsupportedProperties,
            discoveryMode: discoveryMode == .all || other.discoveryMode == .all ? .all : .targeted
        )
    }
}

enum NotificationSetupState: Equatable {
    case inactive
    case unconfirmed
    case confirmed
}
