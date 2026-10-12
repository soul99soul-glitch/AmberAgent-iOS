import Darwin
import Foundation

enum LocalPacketReflection {
    static func reflect(_ packet: Data, protocolFamily: Int32) -> Data? {
        guard protocolFamily == AF_INET, packet.count >= 20 else { return nil }
        let isExpectedPacket = packet.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            let headerLength = Int(bytes[0] & 0x0f) * 4
            let totalLength = Int(bytes[2]) << 8 | Int(bytes[3])
            guard bytes[0] >> 4 == 4, headerLength >= 20,
                  headerLength <= packet.count, totalLength == packet.count else { return false }
            return bytes[12] == 10 && bytes[13] == 7 && bytes[14] == 1 && bytes[15] == 1
                && bytes[16] == 10 && bytes[17] == 7 && bytes[18] == 0 && bytes[19] == 1
        }
        guard isExpectedPacket else { return nil }

        var reflected = packet
        reflected.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            // Swapping these equal-width addresses preserves both the IPv4
            // header sum and the TCP/UDP pseudo-header sum, including fragments.
            for offset in 0..<4 {
                let source = bytes[12 + offset]
                bytes[12 + offset] = bytes[16 + offset]
                bytes[16 + offset] = source
            }
        }
        return reflected
    }
}
