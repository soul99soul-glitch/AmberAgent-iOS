use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tokio::net::TcpStream;

use super::Failure;

const VPN_PEER: Ipv4Addr = Ipv4Addr::new(10, 7, 0, 1);
#[cfg(any(target_vendor = "apple", test))]
const VPN_INTERFACE_ADDRESS: Ipv4Addr = Ipv4Addr::new(10, 7, 1, 1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RouteMode {
    Embedded,
    ExistingVpn,
}

impl TryFrom<u32> for RouteMode {
    type Error = Failure;

    fn try_from(value: u32) -> Result<Self, Failure> {
        match value {
            0 => Ok(Self::Embedded),
            1 => Ok(Self::ExistingVpn),
            _ => Err(Failure::new("invalid_route_mode", "本机连接方式无效，连接未发送。")),
        }
    }
}

impl RouteMode {
    pub(super) fn validate_endpoint(self, endpoint: SocketAddr) -> Result<SocketAddr, Failure> {
        if self == Self::ExistingVpn && (endpoint.ip() != IpAddr::V4(VPN_PEER) || endpoint.port() != 49152) {
            return Err(Failure::new("invalid_endpoint", "现有 VPN 仅支持本机开发地址 10.7.0.1:49152。"));
        }
        Ok(endpoint)
    }

    pub(super) async fn connect(
        self, endpoint: SocketAddr, failure_code: &'static str, failure_message: &'static str,
    ) -> Result<TcpStream, Failure> {
        match self {
            Self::Embedded => connect(endpoint, failure_code, failure_message).await,
            Self::ExistingVpn => connect_using_current_route(endpoint, failure_code, failure_message).await,
        }
    }
}

/// Scope the real connection, including dynamically assigned tunnel ports.
/// A separate route probe cannot constrain a later TCP socket if the VPN stops.
pub(super) async fn connect(
    endpoint: SocketAddr,
    failure_code: &'static str,
    failure_message: &'static str,
) -> Result<TcpStream, Failure> {
    if endpoint.ip() != IpAddr::V4(VPN_PEER) {
        return TcpStream::connect(endpoint).await.map_err(|error| {
            Failure::device(failure_code, failure_message, error.into())
        });
    }

    #[cfg(target_vendor = "apple")]
    {
        let interface = unique_interface_index(&local_interfaces()?)?;
        let socket = tokio::net::TcpSocket::new_v4().map_err(|error| {
            Failure::device(failure_code, failure_message, error.into())
        })?;
        bind_interface(&socket, interface)?;
        socket.connect(endpoint).await.map_err(|error| {
            Failure::device(failure_code, failure_message, error.into())
        })
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        Err(Failure::new(
            "loopback_route_unavailable",
            "当前平台无法约束本机连接路由，连接未发送。",
        ))
    }
}

/// Discover the kernel's current VPN route without sending a UDP payload, then
/// constrain the actual socket to that interface. Every new connection repeats
/// this lookup, including a dynamically assigned development tunnel port.
pub(super) async fn connect_using_current_route(
    endpoint: SocketAddr, failure_code: &'static str, failure_message: &'static str,
) -> Result<TcpStream, Failure> {
    let endpoint = validate_routed_endpoint(endpoint)?;
    #[cfg(target_vendor = "apple")]
    {
        let source = route_source_address(endpoint)?;
        let interface = unique_interface_index_for_address(&local_interfaces()?, source)?;
        let socket = tokio::net::TcpSocket::new_v4().map_err(|error| {
            Failure::device(failure_code, failure_message, error.into())
        })?;
        bind_interface(&socket, interface)?;
        socket.connect(endpoint).await.map_err(|error| {
            Failure::device(failure_code, failure_message, error.into())
        })
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (endpoint, failure_code, failure_message);
        Err(Failure::new("loopback_route_unavailable", "当前平台无法约束本机连接路由，连接未发送。"))
    }
}

pub(super) fn validate_routed_endpoint(endpoint: SocketAddr) -> Result<SocketAddr, Failure> {
    if !endpoint.is_ipv4() || endpoint.port() == 0 {
        return Err(Failure::new("invalid_endpoint", "当前 VPN 路由必须使用显式 IPv4 地址和有效端口。"));
    }
    Ok(endpoint)
}

#[cfg(target_vendor = "apple")]
fn route_source_address(endpoint: SocketAddr) -> Result<Ipv4Addr, Failure> {
    let route_error = |error: std::io::Error| {
        Failure::device("loopback_route_unavailable", "无法查询开发地址的当前路由，连接未发送。", error.into())
    };
    let probe = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).map_err(route_error)?;
    // UDP connect only selects a route and peer; no send/write is performed.
    probe.connect(endpoint).map_err(route_error)?;
    match probe.local_addr().map_err(route_error)?.ip() {
        IpAddr::V4(source) => Ok(source),
        IpAddr::V6(_) => Err(Failure::new("loopback_route_unavailable", "开发地址未选中 IPv4 路由，连接未发送。")),
    }
}

#[cfg(any(target_vendor = "apple", test))]
struct Interface {
    name: String,
    address: Ipv4Addr,
    up: bool,
    index: u32,
}

#[cfg(any(target_vendor = "apple", test))]
fn unique_interface_index(interfaces: &[Interface]) -> Result<u32, Failure> {
    unique_interface_index_for_address(interfaces, VPN_INTERFACE_ADDRESS)
}

#[cfg(any(target_vendor = "apple", test))]
fn unique_interface_index_for_address(interfaces: &[Interface], source: Ipv4Addr) -> Result<u32, Failure> {
    let mut candidates = std::collections::BTreeSet::new();
    for interface in interfaces {
        let is_utun = interface.name.strip_prefix("utun")
            .is_some_and(|suffix| !suffix.is_empty() && suffix.bytes().all(|b| b.is_ascii_digit()));
        if is_utun && interface.up && interface.address == source && interface.index != 0 {
            candidates.insert(interface.index);
        }
    }
    match candidates.len() {
        0 => Err(Failure::new(
            "loopback_route_unavailable",
            "未找到本机连接路由，请在 Amber 的手机控制设置中检查本地连接。",
        )),
        1 => Ok(*candidates.first().expect("one interface")),
        _ => Err(Failure::new(
            "loopback_route_ambiguous",
            "发现多个匹配本机连接的接口，本次连接已停止。",
        )),
    }
}

#[cfg(target_vendor = "apple")]
fn local_interfaces() -> Result<Vec<Interface>, Failure> {
    use std::ffi::CStr;
    let mut first: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut first) } != 0 {
        return Err(Failure::device(
            "loopback_route_unavailable", "无法读取本机连接路由。",
            std::io::Error::last_os_error().into(),
        ));
    }
    struct Addresses(*mut libc::ifaddrs);
    impl Drop for Addresses {
        fn drop(&mut self) {
            if !self.0.is_null() { unsafe { libc::freeifaddrs(self.0) }; }
        }
    }
    let _addresses = Addresses(first);
    let mut interfaces = Vec::new();
    let mut current = first;
    while let Some(item) = unsafe { current.as_ref() } {
        current = item.ifa_next;
        if item.ifa_name.is_null() || item.ifa_addr.is_null() { continue; }
        let address = unsafe { &*item.ifa_addr };
        if i32::from(address.sa_family) != libc::AF_INET { continue; }
        let address = unsafe { &*(item.ifa_addr.cast::<libc::sockaddr_in>()) };
        interfaces.push(Interface {
            name: unsafe { CStr::from_ptr(item.ifa_name) }.to_string_lossy().into_owned(),
            address: Ipv4Addr::from(address.sin_addr.s_addr.to_ne_bytes()),
            up: item.ifa_flags & libc::IFF_UP as u32 != 0,
            index: unsafe { libc::if_nametoindex(item.ifa_name) },
        });
    }
    Ok(interfaces)
}

#[cfg(target_vendor = "apple")]
fn bind_interface(socket: &tokio::net::TcpSocket, index: u32) -> Result<(), Failure> {
    use std::os::fd::AsRawFd;
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(), libc::IPPROTO_IP, libc::IP_BOUND_IF,
            (&index as *const u32).cast(), std::mem::size_of_val(&index) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(Failure::device(
            "loopback_route_bind_failed", "无法将开发连接限定到本机隧道，本次连接已停止。",
            std::io::Error::last_os_error().into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn route_mode_is_explicit_and_existing_vpn_keeps_the_fixed_development_peer() {
        assert_eq!(RouteMode::try_from(0).ok(), Some(RouteMode::Embedded));
        assert_eq!(RouteMode::try_from(1).ok(), Some(RouteMode::ExistingVpn));
        assert_eq!(RouteMode::try_from(2).err().unwrap().code, "invalid_route_mode");
        assert_eq!(RouteMode::try_from(u32::MAX).err().unwrap().code, "invalid_route_mode");
        assert!(RouteMode::ExistingVpn.validate_endpoint("10.7.0.1:49152".parse().unwrap()).is_ok());
        for endpoint in ["127.0.0.1:49152", "192.0.2.1:49152", "10.7.0.1:49153", "[::1]:49152"] {
            let endpoint = endpoint.parse().unwrap();
            assert_eq!(RouteMode::ExistingVpn.validate_endpoint(endpoint).err().unwrap().code, "invalid_endpoint");
            assert!(RouteMode::Embedded.validate_endpoint(endpoint).is_ok(), "existing diagnostic endpoints remain available");
        }
    }

    #[cfg(target_vendor = "apple")]
    #[tokio::test]
    async fn selected_mode_applies_to_both_pairing_and_dynamic_tls_sockets() {
        // Two actual listeners represent RemotePairing and the later port from
        // create_tcp_listener. Embedded permits explicit localhost fixtures;
        // ExistingVpn must not fall back to either reachable localhost socket.
        for failure_code in ["connection_failed", "tunnel_connection_failed"] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = listener.local_addr().unwrap();
            let connected = RouteMode::Embedded.connect(endpoint, failure_code, "fixture").await;
            assert!(connected.is_ok());
            let _accepted = listener.accept().await.unwrap();
            drop(connected);

            let failure = RouteMode::ExistingVpn.connect(endpoint, failure_code, "fixture").await.err().unwrap();
            assert_eq!(failure.code, "loopback_route_unavailable", "route errors retain their actionable code");
            assert!(tokio::time::timeout(std::time::Duration::from_millis(30), listener.accept()).await.is_err());
        }
    }

    fn interface(name: &str, up: bool, address: [u8; 4], index: u32) -> Interface {
        Interface { name: name.into(), up, address: Ipv4Addr::from(address), index }
    }

    #[test]
    fn route_requires_an_up_utun_with_the_exact_default_address() {
        for candidates in [
            vec![],
            vec![interface("en0", true, [10, 7, 1, 1], 4)],
            vec![interface("utun4", false, [10, 7, 1, 1], 5)],
            vec![interface("utun4", true, [10, 7, 0, 1], 5)],
            vec![interface("utun4", true, [10, 7, 1, 1], 0)],
        ] {
            let error = unique_interface_index(&candidates).expect_err("route must be rejected");
            assert_eq!(error.code, "loopback_route_unavailable");
        }
        assert_eq!(unique_interface_index(&[
            interface("en0", true, [192, 0, 2, 3], 4),
            interface("utun4", true, [10, 7, 1, 1], 5),
            interface("utun4", true, [10, 7, 1, 1], 5),
        ]).ok(), Some(5));
    }

    #[test]
    fn multiple_matching_interfaces_stop_instead_of_selecting_the_first() {
        let error = unique_interface_index(&[
            interface("utun4", true, [10, 7, 1, 1], 5),
            interface("utun8", true, [10, 7, 1, 1], 9),
        ]).expect_err("ambiguous route must be rejected");
        assert_eq!(error.code, "loopback_route_ambiguous");
    }

    #[test]
    fn routed_probe_accepts_vpn_addresses_other_than_the_amber_default() {
        for address in [[198, 18, 0, 1], [100, 64, 0, 2], [10, 0, 0, 1], [10, 7, 1, 1]] {
            let candidates = [
                interface("en0", true, address, 4),
                interface("utun12", true, address, 14),
                interface("utun12", true, address, 14),
            ];
            assert_eq!(unique_interface_index_for_address(&candidates, address.into()).ok(), Some(14));
        }
    }

    #[test]
    fn routed_probe_rejects_non_vpn_down_unmatched_invalid_and_ambiguous_routes() {
        let source = Ipv4Addr::new(198, 18, 0, 1);
        for candidates in [
            vec![],
            vec![interface("en0", true, [198, 18, 0, 1], 4)],
            vec![interface("pdp_ip0", true, [198, 18, 0, 1], 4)],
            vec![interface("lo0", true, [198, 18, 0, 1], 1)],
            vec![interface("utun", true, [198, 18, 0, 1], 4)],
            vec![interface("utun1x", true, [198, 18, 0, 1], 4)],
            vec![interface("utun4", false, [198, 18, 0, 1], 4)],
            vec![interface("utun4", true, [198, 18, 0, 1], 0)],
            vec![interface("utun4", true, [10, 7, 1, 1], 4)],
        ] {
            let failure = unique_interface_index_for_address(&candidates, source).expect_err("route must be rejected");
            assert_eq!(failure.code, "loopback_route_unavailable");
        }
        let failure = unique_interface_index_for_address(&[
            interface("utun4", true, [198, 18, 0, 1], 4),
            interface("utun5", true, [198, 18, 0, 1], 5),
        ], source).expect_err("ambiguous route must be rejected");
        assert_eq!(failure.code, "loopback_route_ambiguous");
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn darwin_route_lookup_selects_the_source_without_sending_a_udp_payload() {
        let peer = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        peer.set_nonblocking(true).unwrap();
        assert_eq!(route_source_address(peer.local_addr().unwrap()).ok(), Some(Ipv4Addr::LOCALHOST));
        let error = peer.recv_from(&mut [0u8; 1]).expect_err("route lookup must not send a datagram");
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    }

    #[cfg(target_vendor = "apple")]
    #[tokio::test]
    async fn binding_is_applied_to_the_actual_socket_and_invalid_index_is_rejected() {
        use std::os::fd::AsRawFd;
        let socket = tokio::net::TcpSocket::new_v4().unwrap();
        let index = unsafe { libc::if_nametoindex(c"lo0".as_ptr()) };
        assert_ne!(index, 0);
        assert!(bind_interface(&socket, index).is_ok());
        let mut actual: u32 = 0;
        let mut length = std::mem::size_of_val(&actual) as libc::socklen_t;
        assert_eq!(unsafe { libc::getsockopt(
            socket.as_raw_fd(), libc::IPPROTO_IP, libc::IP_BOUND_IF,
            (&mut actual as *mut u32).cast(), &mut length,
        ) }, 0);
        assert_eq!(actual, index);
        let error = bind_interface(&socket, u32::MAX).expect_err("invalid interface must fail");
        assert_eq!(error.code, "loopback_route_bind_failed");
    }
}
