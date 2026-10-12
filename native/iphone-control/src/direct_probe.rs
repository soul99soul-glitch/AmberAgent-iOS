use std::{net::SocketAddr, sync::Mutex};

use idevice::{Idevice, IdeviceError, services::lockdown::LockdownClient};

use crate::Failure;

pub(crate) fn validate_endpoint(endpoint: SocketAddr) -> Result<SocketAddr, Failure> {
    if !endpoint.is_ipv4() || endpoint.port() != LockdownClient::LOCKDOWND_PORT {
        return Err(Failure::new("invalid_endpoint", "传统开发服务诊断必须使用显式 IPv4:62078 地址。"));
    }
    Ok(endpoint)
}

pub(crate) async fn inspect_lockdown(endpoint: SocketAddr) -> Result<(), Failure> {
    // Deliberately bypass the LocalDevVPN route helper: this diagnostic measures
    // the direct socket path and must not create a tunnel or load credentials.
    let stream = tokio::net::TcpStream::connect(endpoint).await.map_err(|error| {
        Failure::transport("lockdown_connection_failed", "无法直接连接传统开发服务。",
            IdeviceError::Socket(error), &Mutex::new(Some("lockdown_connect")))
    })?;
    let mut device = Idevice::new(Box::new(stream), "AmberDirectProbe");
    let device_type = device.get_type().await.map_err(|error| {
        Failure::transport("lockdown_query_failed", "传统开发服务类型查询失败。",
            error, &Mutex::new(Some("lockdown_query_type")))
    })?;
    if device_type != "com.apple.mobile.lockdown" {
        return Err(Failure::transport("lockdown_type_mismatch", "端点回应的类型不是传统开发服务。",
            IdeviceError::UnexpectedResponse("unexpected lockdown type".into()),
            &Mutex::new(Some("lockdown_validate_type"))));
    }
    // Dropping Idevice closes this one QueryType connection. No provider or
    // LockdownClient session is constructed, so there is no implicit pairing.
    Ok(())
}

pub(crate) fn timeout_failure(message: &'static str) -> Failure {
    Failure::transport("startup_timeout", message, IdeviceError::Timeout,
        &Mutex::new(Some("lockdown_inspection")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{ffi::{CStr, CString}, time::Duration};
    use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{TcpListener, TcpStream}};
    use crate::{AmberIPhoneControlHandle, Operation, Status};

    async fn fixture() -> (*mut AmberIPhoneControlHandle, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        // The public ABI restricts callers to 62078. Use the same operation on
        // an ephemeral fixture port so tests cannot collide with local tools.
        let handle = crate::start_operation(Ok(Operation::LockdownInspection(listener.local_addr().unwrap())));
        let (stream, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await.unwrap().unwrap();
        (handle, stream)
    }

    async fn read_query(stream: &mut TcpStream) {
        let length = stream.read_u32().await.unwrap() as usize;
        assert!(length < 4096);
        let mut bytes = vec![0; length];
        stream.read_exact(&mut bytes).await.unwrap();
        let request = plist::Value::from_reader_xml(bytes.as_slice()).unwrap();
        let dictionary = request.as_dictionary().unwrap();
        assert_eq!(dictionary.len(), 2, "the greeting must not include credentials or session options");
        assert_eq!(dictionary.get("Request").and_then(plist::Value::as_string), Some("QueryType"));
        assert_eq!(dictionary.get("Label").and_then(plist::Value::as_string), Some("AmberDirectProbe"));
    }

    async fn reply(stream: &mut TcpStream, fields: &[(&str, &str)]) {
        let dictionary: plist::Dictionary = fields.iter().map(|(key, value)| {
            (key.to_string(), plist::Value::String(value.to_string()))
        }).collect();
        let mut bytes = Vec::new();
        plist::Value::Dictionary(dictionary).to_writer_xml(&mut bytes).unwrap();
        stream.write_u32(bytes.len() as u32).await.unwrap();
        stream.write_all(&bytes).await.unwrap();
    }

    async fn terminal_status(handle: *mut AmberIPhoneControlHandle, timeout: Duration) -> Status {
        tokio::time::timeout(timeout, async {
            loop {
                let status = unsafe { &*handle }.session.status.lock().unwrap().clone();
                if matches!(status.phase, "stopped" | "failed") {
                    return status;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }).await.expect("probe must terminate")
    }

    async fn assert_closed_without_more_requests(stream: &mut TcpStream) {
        let mut extra = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), stream.read_to_end(&mut extra)).await.unwrap().unwrap();
        assert!(extra.is_empty(), "probe must not proceed to StartSession, pair or StartService");
    }

    #[test]
    fn public_endpoint_validation_rejects_missing_non_numeric_ipv6_and_other_ports() {
        let invalid = [None, Some(""), Some("localhost:62078"), Some("127.0.0.1:0"),
            Some("127.0.0.1:49152"), Some("[::1]:62078"), Some("[fe80::1%4]:62078")];
        for input in invalid {
            let text = input.map(|text| CString::new(text).unwrap());
            let pointer = text.as_ref().map_or(std::ptr::null(), |text| text.as_ptr());
            unsafe {
                let handle = crate::amber_iphone_control_inspect_lockdown(pointer);
                assert!((*handle).thread.is_none(), "invalid input must not start network work");
                assert_eq!((&*handle).session.status.lock().unwrap().code, "invalid_endpoint");
                crate::amber_iphone_control_free(handle);
            }
        }
        assert!(validate_endpoint("192.0.2.1:62078".parse().unwrap()).is_ok());
    }

    #[test]
    fn numeric_ipv6_scope_survives_existing_endpoint_parser() {
        let text = CString::new("[fe80::1234%7]:49152").unwrap();
        let endpoint = unsafe { crate::read_endpoint(text.as_ptr(), "") }.unwrap_or_else(|_| panic!("numeric scope supported"));
        let SocketAddr::V6(endpoint) = endpoint else { panic!("expected IPv6") };
        assert_eq!(endpoint.scope_id(), 7);
        assert_eq!(endpoint.port(), 49152);
        assert_eq!(endpoint.ip().to_string(), "fe80::1234");
    }

    #[tokio::test]
    async fn successful_query_sends_only_query_type_and_closes_without_private_result() {
        let (handle, mut stream) = fixture().await;
        read_query(&mut stream).await;
        reply(&mut stream, &[("Type", "com.apple.mobile.lockdown")]).await;
        assert_closed_without_more_requests(&mut stream).await;
        let status = terminal_status(handle, Duration::from_secs(2)).await;
        assert_eq!(status.phase, "stopped");
        assert_eq!(status.code, "lockdown_query_ok");
        unsafe {
            assert!(crate::amber_iphone_control_pairing_copy_plist(handle).is_null());
            crate::amber_iphone_control_free(handle);
        }
    }

    #[tokio::test]
    async fn wrong_type_and_remote_error_are_terminal_and_redacted() {
        for (fields, code, stage) in [
            (vec![("Type", "private-remote-marker")], "lockdown_type_mismatch", "lockdown_validate_type"),
            (vec![("Error", "private-remote-marker")], "lockdown_query_failed", "lockdown_query_type"),
        ] {
            let (handle, mut stream) = fixture().await;
            read_query(&mut stream).await;
            reply(&mut stream, &fields).await;
            assert_closed_without_more_requests(&mut stream).await;
            let status = terminal_status(handle, Duration::from_secs(2)).await;
            assert_eq!(status.phase, "failed");
            assert_eq!(status.code, code);
            assert_eq!(status.native.unwrap().native_transport_stage, Some(stage));
            unsafe {
                let json = crate::amber_iphone_control_status_json(handle);
                assert!(!CStr::from_ptr(json).to_str().unwrap().contains("private-remote-marker"));
                crate::amber_iphone_control_string_free(json);
                crate::amber_iphone_control_free(handle);
            }
        }
    }

    #[tokio::test]
    async fn connection_failure_retains_typed_io_diagnostics() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap();
        drop(listener);
        let failure = match inspect_lockdown(endpoint).await {
            Ok(()) => panic!("closed port cannot answer"),
            Err(failure) => failure,
        };
        assert_eq!(failure.code, "lockdown_connection_failed");
        let diagnostic = failure.native.unwrap();
        assert_eq!(diagnostic.native_transport_stage, Some("lockdown_connect"));
        assert_eq!(diagnostic.native_io_kind.as_deref(), Some("ConnectionRefused"));
        assert!(diagnostic.native_os_error_code.is_some());
    }

    #[tokio::test]
    async fn response_eof_retains_io_error_and_query_stage() {
        let (handle, mut stream) = fixture().await;
        read_query(&mut stream).await;
        drop(stream);
        let status = terminal_status(handle, Duration::from_secs(2)).await;
        assert_eq!(status.code, "lockdown_query_failed");
        let diagnostic = status.native.unwrap();
        assert_eq!(diagnostic.native_io_kind.as_deref(), Some("UnexpectedEof"));
        assert_eq!(diagnostic.native_transport_stage, Some("lockdown_query_type"));
        unsafe { crate::amber_iphone_control_free(handle); }
    }

    #[tokio::test]
    async fn deadline_stops_pending_query_and_closes_socket() {
        let (handle, mut stream) = fixture().await;
        read_query(&mut stream).await;
        let status = terminal_status(handle, Duration::from_secs(10)).await;
        assert_eq!(status.phase, "failed");
        assert_eq!(status.code, "startup_timeout");
        assert_eq!(status.native.unwrap().native_transport_stage, Some("lockdown_inspection"));
        assert_closed_without_more_requests(&mut stream).await;
        unsafe { crate::amber_iphone_control_free(handle); }
    }

    #[tokio::test]
    async fn stop_and_free_close_pending_query_without_more_requests() {
        let (handle, mut stream) = fixture().await;
        read_query(&mut stream).await;
        unsafe {
            crate::amber_iphone_control_stop(handle);
            crate::amber_iphone_control_stop(handle);
            crate::amber_iphone_control_free(handle);
        }
        assert_closed_without_more_requests(&mut stream).await;
    }
}
