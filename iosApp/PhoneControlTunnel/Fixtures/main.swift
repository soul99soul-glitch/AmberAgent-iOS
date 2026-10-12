import Darwin
import Foundation

private func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for offset in stride(from: 0, to: bytes.count, by: 2) {
        sum += UInt32(bytes[offset]) << 8
        if offset + 1 < bytes.count { sum += UInt32(bytes[offset + 1]) }
    }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
}

private func writeWord(_ value: UInt16, to bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(value >> 8)
    bytes[offset + 1] = UInt8(value & 0xff)
}

private func pseudoHeader(_ packet: [UInt8], headerLength: Int) -> [UInt8] {
    let payloadLength = UInt16(packet.count - headerLength)
    return Array(packet[12..<20]) + [0, packet[9], UInt8(payloadLength >> 8), UInt8(payloadLength & 0xff)]
}

private func makePacket(ipProtocol: UInt8 = 6, options: Bool = false) -> Data {
    let headerLength = options ? 24 : 20
    let payload = Array("amber-loopback".utf8)
    let transportLength = ipProtocol == 6 ? 20 : 8
    var bytes = [UInt8](repeating: 0, count: headerLength + transportLength + payload.count)
    bytes[0] = 0x40 | UInt8(headerLength / 4)
    writeWord(UInt16(bytes.count), to: &bytes, at: 2)
    bytes[8] = 64
    bytes[9] = ipProtocol
    bytes.replaceSubrange(12..<20, with: [10, 7, 1, 1, 10, 7, 0, 1])
    if options { bytes.replaceSubrange(20..<24, with: [1, 1, 1, 0]) }
    writeWord(49152, to: &bytes, at: headerLength)
    writeWord(50123, to: &bytes, at: headerLength + 2)
    if ipProtocol == 6 {
        bytes[headerLength + 12] = 0x50
        bytes[headerLength + 13] = 0x18
    } else {
        writeWord(UInt16(transportLength + payload.count), to: &bytes, at: headerLength + 4)
    }
    bytes.replaceSubrange((headerLength + transportLength)..<bytes.count, with: payload)
    let transportChecksum = checksum(pseudoHeader(bytes, headerLength: headerLength) + bytes[headerLength...])
    writeWord(transportChecksum, to: &bytes, at: headerLength + (ipProtocol == 6 ? 16 : 6))
    let headerChecksum = checksum(Array(bytes[..<headerLength]))
    writeWord(headerChecksum, to: &bytes, at: 10)
    return Data(bytes)
}

private var checks = 0
@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    checks += 1
}

@MainActor
private func expectReflection(_ packet: Data, label: String, wholeDatagram: Bool = true) {
    guard let output = LocalPacketReflection.reflect(packet, protocolFamily: AF_INET) else {
        fatalError("FAIL: \(label) rejected")
    }
    let original = [UInt8](packet)
    let reflected = [UInt8](output)
    let headerLength = Int(reflected[0] & 0x0f) * 4
    expect(Array(reflected[12..<20]) == [10, 7, 0, 1, 10, 7, 1, 1], "\(label) swaps the two addresses")
    expect(original[..<12] == reflected[..<12] && original[20...] == reflected[20...], "\(label) preserves every other byte")
    expect(checksum(Array(reflected[..<headerLength])) == 0, "\(label) preserves IPv4 checksum")
    if wholeDatagram {
        expect(checksum(pseudoHeader(reflected, headerLength: headerLength) + reflected[headerLength...]) == 0, "\(label) preserves transport checksum")
    }
}

let tcpPacket = makePacket()
expectReflection(tcpPacket, label: "TCP")
expectReflection(makePacket(ipProtocol: 17), label: "UDP")
expectReflection(makePacket(options: true), label: "IPv4 options")
// Split a checksummed TCP datagram at an eight-byte fragment boundary. Neither
// fragment contains a separately valid transport checksum, but both retain the
// original payload and their own valid IPv4 header checksum after reflection.
for (label, fragmentOffset, payloadRange) in [
    ("First fragment", UInt16(0x2000), 20..<52),
    ("Later fragment", UInt16(4), 52..<tcpPacket.count)
] {
    var fragment = Array(tcpPacket.prefix(20)) + tcpPacket[payloadRange]
    writeWord(UInt16(fragment.count), to: &fragment, at: 2)
    writeWord(fragmentOffset, to: &fragment, at: 6)
    writeWord(0, to: &fragment, at: 10)
    let headerChecksum = checksum(Array(fragment[..<20]))
    writeWord(headerChecksum, to: &fragment, at: 10)
    expectReflection(Data(fragment), label: label, wholeDatagram: false)
}

var prefixed = Data([0xaa, 0xbb])
prefixed.append(tcpPacket)
expectReflection(prefixed.dropFirst(2), label: "Data slice")

expect(LocalPacketReflection.reflect(tcpPacket, protocolFamily: AF_INET6) == nil, "Reject other protocol families")
expect(LocalPacketReflection.reflect(Data(tcpPacket.prefix(19)), protocolFamily: AF_INET) == nil, "Reject truncated IPv4 header")

for (label, index, value) in [
    ("IPv6 version", 0, UInt8(0x65)),
    ("Short IHL", 0, UInt8(0x44)),
    ("Oversized IHL", 0, UInt8(0x4f)),
    ("Short total length", 3, UInt8(20)),
    ("Long total length", 2, UInt8(1)),
    ("Unrelated source", 15, UInt8(2)),
    ("Unrelated destination", 19, UInt8(2))
] {
    var malformed = tcpPacket
    malformed[index] = value
    expect(LocalPacketReflection.reflect(malformed, protocolFamily: AF_INET) == nil, label)
}

var reversed = tcpPacket
reversed.replaceSubrange(12..<20, with: [10, 7, 0, 1, 10, 7, 1, 1])
expect(LocalPacketReflection.reflect(reversed, protocolFamily: AF_INET) == nil, "Reject packets outside the outgoing route")
print("PASS: \(checks) packet reflection checks")
