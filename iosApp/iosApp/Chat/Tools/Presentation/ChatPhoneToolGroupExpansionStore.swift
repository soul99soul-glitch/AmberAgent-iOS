import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

/// Expanded phone-step groups for this app session, keyed by group id (first
/// phone toolCallId, globally unique). Presentation state only: the projection
/// reads it as an input; the timeline view is its single writer.
@MainActor
final class ChatPhoneToolGroupExpansionStore {
    static let shared = ChatPhoneToolGroupExpansionStore()
    private static let capacity = 256

    private(set) var expandedIDs: Set<String> = []
    private var order: [String] = []

    func setExpanded(_ expanded: Bool, groupID: String) {
        if expanded {
            guard expandedIDs.insert(groupID).inserted else { return }
            order.append(groupID)
            if order.count > Self.capacity {
                expandedIDs.remove(order.removeFirst())
            }
        } else {
            guard expandedIDs.remove(groupID) != nil else { return }
            order.removeAll { $0 == groupID }
        }
    }
}

