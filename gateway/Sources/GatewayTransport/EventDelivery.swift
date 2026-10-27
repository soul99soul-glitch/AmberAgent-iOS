import Foundation
import GatewayCore

public enum EventDelivery {
    public static let hookTimeout: TimeInterval = 0.2

    public enum Outcome: Equatable { case delivered, spooled, dropped }

    /// Hands the event to the daemon, or spools it if the daemon is absent, refusing, or too slow.
    @discardableResult
    public static func deliver(_ event: GatewayEvent, paths: GatewayPaths, timeout: TimeInterval = hookTimeout) -> Outcome {
        guard let payload = try? GatewayJSON.encoder().encode(event) else { return .dropped }
        if UnixSocketClient.send(payload, to: paths.socket.path, timeout: timeout) {
            return .delivered
        }
        do {
            try paths.ensureDirectories()
            try Spool(dir: paths.spoolDir).write(event)
            return .spooled
        } catch {
            return .dropped
        }
    }
}
