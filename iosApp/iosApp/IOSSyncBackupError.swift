import Foundation

enum IOSSyncBackupError: LocalizedError {
    case emptyPayload
    case invalidArchive(String)
    case invalidPassphrase
    case providerNotConfigured(String)
    case remoteProviderUnavailable(String)
    case unsupportedCrypto(String)

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "备份内容为空"
        case .invalidArchive(let message):
            return message
        case .invalidPassphrase:
            return "同步口令不能为空"
        case .providerNotConfigured(let message):
            return message
        case .remoteProviderUnavailable(let message):
            return message
        case .unsupportedCrypto(let message):
            return message
        }
    }
}
