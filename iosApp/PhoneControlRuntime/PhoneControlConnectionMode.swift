import Foundation

enum IOSPhoneControlConnectionMode: String, CaseIterable, Sendable {
    case embedded
    case existingVPN

    var nativeRouteMode: UInt32 { self == .embedded ? 0 : 1 }
}
