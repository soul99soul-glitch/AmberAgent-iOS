package app.amber.cloud.security

import java.net.InetAddress

/** Address policy shared by user-supplied HTTP targets in search and Watchtower. */
fun isPublicNetworkAddress(address: InetAddress): Boolean {
    if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
        address.isSiteLocalAddress || address.isMulticastAddress) return false

    val bytes = address.address
    val first = bytes[0].toInt() and 255
    if (bytes.size == 16) return first in 0x20..0x3f
    val second = bytes[1].toInt() and 255
    return first !in setOf(0, 10, 127, 169) && first < 224 &&
        !(first == 100 && second in 64..127) &&
        !(first == 192 && second in setOf(0, 168)) &&
        !(first == 198 && second in 18..19)
}
