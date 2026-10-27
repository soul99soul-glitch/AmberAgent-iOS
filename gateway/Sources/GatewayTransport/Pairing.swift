import CoreImage
import Foundation
import GatewayCore
import SystemConfiguration

/// Everything a phone needs to reach and trust this gateway, carried in the QR code / deep link.
public struct PairingPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var name: String
    public var addrs: [String]
    public var port: UInt16
    /// base64 SHA-256 of the TLS certificate's SPKI.
    public var fp: String
    /// One-time pairing secret.
    public var s: String

    public init(id: String, name: String, addrs: [String], port: UInt16, fp: String, s: String) {
        self.v = 1
        self.id = id
        self.name = name
        self.addrs = addrs
        self.port = port
        self.fp = fp
        self.s = s
    }

    public var url: String {
        let data = (try? GatewayJSON.encoder().encode(self)) ?? Data()
        return "amber://gateway/pair?p=" + data.base64URLEncoded()
    }

    public static func parse(url: String) -> PairingPayload? {
        guard let items = URLComponents(string: url)?.queryItems,
              let p = items.first(where: { $0.name == "p" })?.value,
              let data = Data(base64URLEncoded: p)
        else { return nil }
        return try? GatewayJSON.decoder().decode(PairingPayload.self, from: data)
    }
}

public enum CandidateAddresses {
    /// `<LocalHostName>.local` first (follows DHCP changes via mDNS), then the Tailscale name if present,
    /// then configured public addresses, then current IPv4 addresses. Off-LAN, `.local` fails at once and the
    /// public address answers before the phone spends a connect timeout on each LAN IP.
    public static func current(publicAddresses: [String] = []) -> [String] {
        var result: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            result.append(name + ".local")
        }
        if let tailscale = tailscaleDNSName() {
            result.append(tailscale)
        }
        result += publicAddresses
        result += ipv4Addresses()
        return result
    }

    static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254."), !result.contains(ip) { result.append(ip) }
        }
        return result
    }

    static func tailscaleDNSName() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String, !name.isEmpty
        else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}

public enum TerminalQR {
    /// Two modules per character cell with explicit black-on-white ANSI colours, so it scans on both
    /// light and dark terminal themes.
    public static func render(_ text: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // L keeps a ~300-char payload within an 80-column terminal; a screen has no smudges to correct.
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent)
        else { return nil }
        let size = cg.width
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        let quiet = 2
        let total = size + quiet * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let (mx, my) = (x - quiet, y - quiet)
            guard mx >= 0, my >= 0, mx < size, my < size else { return false }
            return pixels[my * size + mx] < 128
        }
        var out = ""
        for y in stride(from: 0, to: total, by: 2) {
            out += "\u{1B}[30;47m"
            for x in 0..<total {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): out += "█"
                case (true, false): out += "▀"
                case (false, true): out += "▄"
                case (false, false): out += " "
                }
            }
            out += "\u{1B}[0m\n"
        }
        return out
    }
}
