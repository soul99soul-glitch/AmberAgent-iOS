import SwiftUI

enum ChatDataImageLoadState: Sendable {
    case loading
    case success(UIImage)
    case failure

    static func resolve(urlString: String) async -> ChatDataImageLoadState {
        await Task.detached(priority: .userInitiated) {
            guard let comma = urlString.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])),
                  let image = UIImage(data: data) else {
                return ChatDataImageLoadState.failure
            }
            return ChatDataImageLoadState.success(image)
        }.value
    }
}


