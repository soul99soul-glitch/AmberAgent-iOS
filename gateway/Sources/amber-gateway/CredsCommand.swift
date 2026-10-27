import Foundation
import GatewayCore
import GatewayPush

enum CredsCommand {
    static func importUsage(_ kind: CredentialKind) -> String {
        switch kind {
        case .apns: "amber-gateway creds import apns --key AuthKey_XXXX.p8 --key-id XXXX --team-id YYYY --topic <bundle id> [--delete-source]"
        case .fcm: "amber-gateway creds import fcm --service-account firebase-sa.json [--delete-source]"
        case .huawei: "amber-gateway creds import huawei --service-account agc-sa.json [--project-id ID] [--category MARKETING] [--delete-source]"
        }
    }

    static let usageText = """
    用法:
      amber-gateway creds                                  查看已导入的推送凭据
      \(CredentialKind.allCases.map(importUsage).joined(separator: "\n  "))
      amber-gateway creds delete apns|fcm|huawei
    """

    static func run(_ args: [String]) -> Int32 {
        let paths = GatewayPaths.resolve()
        let store = CredentialStore(dir: paths.secretsDir)
        switch args.first {
        case nil, "list":
            for kind in CredentialKind.allCases {
                print("\(StatusCommand.pad(kind.displayName, 22)) \(store.exists(kind) ? "已导入" : "未导入")")
            }
            let missing = CredentialKind.allCases.filter { !store.exists($0) }
            if !missing.isEmpty {
                print("\n只需导入你手机对应的那一种：")
                for kind in missing { print("  \(importUsage(kind))") }
            }
            print("\n凭据位于 \(paths.secretsDir.path)（目录 700、文件 600）")
            return 0
        case "delete":
            guard args.count == 2, let kind = CredentialKind(rawValue: args[1]) else { return usage() }
            do {
                try store.delete(kind)
            } catch {
                return fail("删除失败: \(error.localizedDescription)")
            }
            AuditLog(url: paths.audit).record("creds-delete", ["kind": kind.rawValue])
            print("已删除 \(kind.displayName) 凭据")
            return 0
        case "import":
            guard args.count >= 2, let kind = CredentialKind(rawValue: args[1]) else { return usage() }
            return importCreds(kind, options: Array(args.dropFirst(2)), store: store, audit: AuditLog(url: paths.audit))
        default:
            return usage()
        }
    }

    private static func importCreds(_ kind: CredentialKind, options: [String], store: CredentialStore, audit: AuditLog) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = options.firstIndex(of: flag), i + 1 < options.count else { return nil }
            return options[i + 1]
        }
        let sourceFlag = kind == .apns ? "--key" : "--service-account"
        guard let source = value(sourceFlag) else { return usage() }
        let sourceURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: sourceURL) else { return fail("无法读取 \(sourceURL.path)") }

        do {
            switch kind {
            case .apns:
                guard let keyId = value("--key-id"), let teamId = value("--team-id"), let topic = value("--topic") else { return usage() }
                try CredentialImport.apns(keyPEM: data, keyId: keyId, teamId: teamId, topic: topic, into: store)
            case .fcm:
                try CredentialImport.fcm(serviceAccount: data, into: store)
            case .huawei:
                try CredentialImport.huawei(serviceAccount: data, projectId: value("--project-id"),
                                            category: value("--category") ?? "MARKETING", into: store)
            }
        } catch {
            return fail("导入失败: \(error)")
        }
        audit.record("creds-import", ["kind": kind.rawValue])
        print("已导入 \(kind.displayName) 凭据")

        if options.contains("--delete-source") {
            do {
                try FileManager.default.removeItem(at: sourceURL)
                print("已删除原文件 \(sourceURL.path)")
            } catch {
                return fail("凭据已导入，但删除原文件失败: \(error.localizedDescription)")
            }
        } else if kind == .apns {
            print("提示：.p8 只能从 Apple 下载一次，请把 \(sourceURL.lastPathComponent) 离线备份后再删除（或下次加 --delete-source）")
        }
        print("验证：amber-gateway test-push")
        return 0
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data((usageText + "\n").utf8))
        return 64
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return 1
    }
}
