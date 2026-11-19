import SwiftUI

/// Owns the lifetime of the two dialogue surfaces when the execution host changes.
struct ChatDialogueHostContent<Local: View, Cloud: View>: View {
    let isCloudSelected: Bool
    @ViewBuilder let local: () -> Local
    @ViewBuilder let cloud: () -> Cloud
    @State private var hasPresentedLocal = false
    @State private var hasPresentedCloud = false

    var body: some View {
        ZStack {
            // A host change must retain the timeline's render caches and scroll state.
            // Mount each surface only after its first selection, then keep its identity.
            if !isCloudSelected || hasPresentedLocal {
                local()
                    .opacity(isCloudSelected ? 0 : 1)
                    .allowsHitTesting(!isCloudSelected)
                    .accessibilityHidden(isCloudSelected)
                    .onAppear { hasPresentedLocal = true }
            }
            if isCloudSelected || hasPresentedCloud {
                cloud()
                    .opacity(isCloudSelected ? 1 : 0)
                    .allowsHitTesting(isCloudSelected)
                    .accessibilityHidden(!isCloudSelected)
                    .onAppear { hasPresentedCloud = true }
            }
        }
    }
}
