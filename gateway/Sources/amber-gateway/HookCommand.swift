import Foundation
import GatewayCore
import GatewayTransport
import HookIngest

/// Hard constraint (design doc 3.1): never write to stdout/stderr and always exit 0. Several of the
/// hooked events (`PermissionRequest`, `Stop`) treat hook output as a decision.
enum HookCommand {
    static func run(_ args: [String]) -> Never {
        guard let name = args.first, let source = AgentKind(rawValue: name), source != .run, source != .amber else { exit(0) }
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        guard var event = HookParser.parse(source: source, payload: payload) else { exit(0) }
        if let (identity, origin, host) = AgentProcess.locate(source: source) {
            event.process = identity
            event.origin = origin
            event.host = host
        }
        EventDelivery.deliver(event, paths: .resolve())
        exit(0)
    }
}

enum GatewayPathsDescription {
    static var current: String { GatewayPaths.resolve().stateDir.path }
}
