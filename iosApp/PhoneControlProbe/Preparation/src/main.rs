use idevice::{
    IdeviceError, IdeviceService,
    remote_pairing::{
        RemotePairingClient, RemotePairingLockdownService, RpPairingFile, RpPairingSocketProvider,
        errors::RemotePairingError,
    },
    services::os_trace_relay::{LogLevel, OsTraceRelayClient},
    usbmuxd::{Connection, UsbmuxdAddr},
};
use std::{
    error::Error,
    fs::OpenOptions,
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
    process::ExitCode,
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

// One-time provisioning and read-only checks. Never launch or maintain XCTest from this computer.
#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!(
            "usage: amber-phone-prepare <device UDID> <new output plist> | --check-device <device UDID> | --check-runner-auth <device UDID> | --read-pairing-service-errors <device UDID>"
        );
        return ExitCode::from(2);
    }
    match run(&args).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{}", diagnostic(error.as_ref()));
            ExitCode::FAILURE
        }
    }
}

fn diagnostic(error: &(dyn Error + 'static)) -> String {
    // Protocol errors can embed private plist contents; never format their payload.
    if let Some(error) = error.downcast_ref::<IdeviceError>() {
        let mut detail = format!("native={}, subcode={}", error.code(), error.sub_code());
        if let IdeviceError::Socket(io) = error {
            detail.push_str(&format!(", io={:?}, os={:?}", io.kind(), io.raw_os_error()));
        }
        format!("preparation_failed: {detail}")
    } else if let Some(error) = error.downcast_ref::<std::io::Error>() {
        format!(
            "preparation_failed: io={:?}, os={:?}",
            error.kind(),
            error.raw_os_error()
        )
    } else if error.is::<tokio::time::error::Elapsed>() {
        "preparation_timeout".into()
    } else {
        "preparation_failed: local configuration or service unavailable".into()
    }
}

async fn run(args: &[String]) -> Result<(), Box<dyn Error>> {
    if args[1] == "--read-pairing-service-errors" {
        let pid = pairing_service_pid()?;
        return tokio::time::timeout(
            Duration::from_secs(20),
            read_pairing_service_errors(&args[2], pid),
        )
        .await?;
    }
    if args[1] == "--check-runner-auth" {
        return tokio::time::timeout(Duration::from_secs(5), async {
            let mut mux = UsbmuxdAddr::from_env_var()?.connect(0).await?;
            let device = mux.get_device(&args[2]).await?;
            if device.connection_type != Connection::Usb {
                return Err(std::io::Error::from(std::io::ErrorKind::NotConnected).into());
            }
            let connection = mux
                .connect_to_device(device.device_id, 8100, "AmberUnsignedStatusCheck")
                .await?;
            let mut socket = connection
                .get_socket()
                .ok_or(IdeviceError::NoEstablishedConnection)?;
            require_unsigned_status_rejection(&mut socket).await?;
            Ok::<_, Box<dyn Error>>(())
        })
        .await?;
    }
    if args[1] == "--check-device" {
        let device = tokio::time::timeout(Duration::from_secs(5), async {
            let mut mux = UsbmuxdAddr::from_env_var()?.connect(0).await?;
            let devices = mux.get_devices().await?;
            println!("usbmuxd parsed_device_count={}", devices.len());
            devices
                .into_iter()
                .find(|device| device.udid == args[2])
                .ok_or(IdeviceError::DeviceNotFound)
        })
        .await??;
        let transport = match device.connection_type {
            Connection::Usb => "usb",
            Connection::Network(_) => "network",
            Connection::Unknown(_) => "unknown",
        };
        println!(
            "Device found via usbmuxd; transport={transport}. Read-only: no pairing record read or created."
        );
        return Ok(());
    }
    if args[1].starts_with("--") {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidInput).into());
    }
    // Reserve a private new file before changing device pairing state. Never overwrite a record.
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&args[2])?;
    let attempt = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    // A new attempt must not replace a different installation's controller identity.
    let hostname = format!("AmberSelfControl-{}-{attempt}", std::process::id());
    let mut file = RpPairingFile::generate(&hostname);
    let result = tokio::time::timeout(Duration::from_secs(60), async {
        eprintln!("stage=usbmux_connect");
        let mut mux = UsbmuxdAddr::from_env_var()?.connect(0).await?;
        eprintln!("stage=device_lookup");
        let device = mux.get_device(&args[1]).await?;
        if device.connection_type != Connection::Usb {
            return Err("USB connection required for this initialization".into());
        }
        let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, &hostname);
        // Upstream USB initialization has an initial flow and a device-save flow.
        for (service_stage, pairing_stage) in [
            ("lockdown_service_1", "pairing_pass_1"),
            ("lockdown_service_2", "pairing_pass_2"),
        ] {
            eprintln!("stage={service_stage}");
            let mut client = RemotePairingLockdownService::connect(&provider)
                .await?
                .into_client(&hostname)?;
            eprintln!("stage={pairing_stage}");
            connect_pairing(&mut client, &mut file).await?;
        }
        Ok::<_, Box<dyn Error>>(())
    })
    .await
    .map_err(Box::<dyn Error>::from)
    .and_then(|result| result);
    if let Err(error) = result {
        // Retain an unverified private identity after an ambiguous peer result; never import it automatically.
        if let Err(save_error) = output
            .write_all(&file.to_bytes())
            .and_then(|_| output.sync_all())
        {
            eprintln!(
                "Private failed identity preservation error: {}",
                diagnostic(&save_error)
            );
        }
        eprintln!(
            "Initialization incomplete; retained output is unverified. Do not import or automatically retry."
        );
        return Err(error);
    }
    eprintln!("stage=export_write");
    output.write_all(&file.to_bytes())?;
    eprintln!("stage=export_sync");
    output.sync_all()?;
    eprintln!("stage=complete");
    println!(
        "Created a private RemotePairing record. No key material was logged. No XCTest session was started."
    );
    Ok(())
}

async fn require_unsigned_status_rejection<
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
>(
    socket: &mut S,
) -> Result<(), std::io::Error> {
    socket
        .write_all(b"GET /status HTTP/1.1\r\nHost: 127.0.0.1:8100\r\nConnection: close\r\n\r\n")
        .await?;
    socket.flush().await?;
    let mut line = Vec::new();
    while line.len() < 1024 {
        let byte = socket.read_u8().await?;
        line.push(byte);
        if byte == b'\n' {
            break;
        }
    }
    if !line.ends_with(b"\r\n") {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    let text = std::str::from_utf8(&line)
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData))?;
    let mut fields = text.split_whitespace();
    if !matches!(fields.next(), Some("HTTP/1.1" | "HTTP/1.0")) {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    let code = fields
        .next()
        .filter(|code| code.len() == 3)
        .and_then(|code| code.parse::<u16>().ok())
        .filter(|code| (100..=599).contains(code))
        .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidData))?;
    println!("{code}");
    if code != 401 {
        return Err(std::io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}

fn pairing_service_pid() -> Result<u32, io::Error> {
    let raw = std::env::var("AMBER_PAIRING_SERVICE_PID")
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    parse_positive_pid(&raw)
}

fn parse_positive_pid(raw: &str) -> Result<u32, io::Error> {
    let pid = raw
        .parse::<u32>()
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    if pid == 0 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    Ok(pid)
}

async fn read_pairing_service_errors(udid: &str, pid: u32) -> Result<(), Box<dyn Error>> {
    let mut mux = UsbmuxdAddr::from_env_var()?.connect(0).await?;
    let device = mux.get_device(udid).await?;
    if device.connection_type != Connection::Usb {
        return Err(io::Error::from(io::ErrorKind::NotConnected).into());
    }
    let provider = device.to_provider(
        UsbmuxdAddr::from_env_var()?,
        "AmberPairingServiceDiagnostics",
    );
    let client = OsTraceRelayClient::connect(&provider).await?;
    let mut receiver = client.start_trace(Some(pid)).await?;
    let mut accepted = 0usize;
    while accepted < 32 {
        let log = receiver.next().await?;
        if log.pid != pid {
            continue;
        }
        let Some(line) = format_trace_metadata(log.pid, log.level, &log.filename, &log.message)
        else {
            continue;
        };
        println!("{line}");
        accepted += 1;
    }
    drop(receiver);
    Ok(())
}

fn format_trace_metadata(
    pid: u32,
    level: LogLevel,
    filename: &str,
    message: &str,
) -> Option<String> {
    let basename = Path::new(filename).file_name()?.to_str()?;
    if basename != "remotepairingdeviced" {
        return None;
    }

    let text = message.to_ascii_lowercase();
    let error = matches!(level, LogLevel::Error);
    let fault = matches!(level, LogLevel::Fault);
    let rejects_self = has_any(
        &text,
        &[
            "rejectsself",
            "rejects self",
            "self rejected",
            "reject self connection",
            "rejects self connection",
            "self connection rejected",
            "self-pairing rejected",
            "same device rejected",
            "same-device rejected",
            "same device denied",
            "same-device denied",
        ],
    );
    let loopback = has_any(&text, &["loopback", "127.0.0.1", "localhost"]);
    let invalid_origin = has_any(
        &text,
        &[
            "invalid origin",
            "origin invalid",
            "invalid originatedby",
            "invalid_origin",
        ],
    );
    let direction = has_any(
        &text,
        &[
            "invalid direction",
            "direction invalid",
            "direction mismatch",
            "wrong direction",
            "wrong side",
            "unexpected direction",
        ],
    );
    let version_mismatch = has_any(
        &text,
        &[
            "version mismatch",
            "version_mismatch",
            "unsupported version",
            "unsupported protocol version",
            "protocol version mismatch",
            "wire protocol mismatch",
        ],
    );
    let device_initiated_required = has_any(
        &text,
        &[
            "device initiated required",
            "device-initiated required",
            "deviceinitiated required",
            "device initiated pairing required",
            "device-initiated pairing required",
            "must be initiated by device",
            "pairable host required",
            "pairablehost required",
        ],
    );
    let auth_rejected = has_any(
        &text,
        &[
            "auth rejected",
            "authentication failed",
            "authentication rejected",
            "pairing rejected",
            "unauthorized",
            "not authorized",
            "permission denied",
            "authreject",
        ],
    );
    let error_code = parse_error_code(&text)
        .map(|code| code.to_string())
        .unwrap_or_else(|| "none".into());
    Some(format!(
        "pid={pid} level={} error={error} fault={fault} rejectsSelf={rejects_self} loopback={loopback} invalidOrigin={invalid_origin} direction={direction} versionMismatch={version_mismatch} deviceInitiatedRequired={device_initiated_required} authRejected={auth_rejected} errorCode={error_code}",
        level_name(level),
    ))
}

fn has_any(text: &str, patterns: &[&str]) -> bool {
    patterns.iter().any(|pattern| text.contains(pattern))
}

fn level_name(level: LogLevel) -> &'static str {
    match level {
        LogLevel::Notice => "notice",
        LogLevel::Info => "info",
        LogLevel::Debug => "debug",
        LogLevel::Error => "error",
        LogLevel::Fault => "fault",
    }
}

fn parse_error_code(text: &str) -> Option<i64> {
    ["errorcode", "error_code", "error code", "code"]
        .iter()
        .find_map(|key| number_after_key(text, key))
}

fn number_after_key(text: &str, key: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    let mut offset = 0usize;
    while let Some(relative) = text[offset..].find(key) {
        let start = offset + relative;
        let end = start + key.len();
        let before_ok =
            start == 0 || !bytes[start - 1].is_ascii_alphanumeric() && bytes[start - 1] != b'_';
        let after_ok =
            end == bytes.len() || !bytes[end].is_ascii_alphanumeric() && bytes[end] != b'_';
        if before_ok && after_ok {
            let mut index = end;
            while index < bytes.len() && matches!(bytes[index], b' ' | b'\t' | b':' | b'=') {
                index += 1;
            }
            let value_start = index;
            if index < bytes.len() && bytes[index] == b'-' {
                index += 1;
            }
            let number_start = index;
            while index < bytes.len() && bytes[index].is_ascii_digit() {
                index += 1;
            }
            if index > number_start {
                if let Ok(value) = text[value_start..index].parse() {
                    return Some(value);
                }
            }
        }
        offset = end;
    }
    None
}

async fn connect_pairing<R: RpPairingSocketProvider>(
    client: &mut RemotePairingClient<R>,
    file: &mut RpPairingFile,
) -> Result<(), IdeviceError> {
    client.attempt_pair_verify().await?;
    if let Err(error) = client.validate_pairing(file).await {
        if !matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyFailed)
        ) {
            return Err(error);
        }
        client.pair(file, async || "000000".to_owned()).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn unknown_option_cannot_create_or_pair_an_identity() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let output = std::env::temp_dir().join(format!(
            "amber-invalid-option-{}-{stamp}",
            std::process::id()
        ));
        let args = vec![
            "prepare".into(),
            "--check-runner-auth-typo".into(),
            output.to_str().unwrap().into(),
        ];
        let error = run(&args).await.unwrap_err();
        assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().kind(),
            std::io::ErrorKind::InvalidInput
        );
        assert!(!output.exists());
    }

    #[tokio::test]
    async fn unsigned_status_sends_one_read_only_request_and_requires_401() {
        for (reply, expected) in [
            (
                b"HTTP/1.1 401 Unauthorized\r\n\r\nsecret body".as_slice(),
                None,
            ),
            (
                b"HTTP/1.1 200 OK\r\n\r\nsecret body".as_slice(),
                Some(std::io::ErrorKind::PermissionDenied),
            ),
            (
                b"private invalid response\r\n".as_slice(),
                Some(std::io::ErrorKind::InvalidData),
            ),
        ] {
            let (mut client, mut server) = tokio::io::duplex(2048);
            let server = tokio::spawn(async move {
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    request.push(server.read_u8().await.unwrap());
                }
                assert_eq!(
                    request,
                    b"GET /status HTTP/1.1\r\nHost: 127.0.0.1:8100\r\nConnection: close\r\n\r\n"
                );
                server.write_all(reply).await.unwrap();
            });
            let result = require_unsigned_status_rejection(&mut client).await;
            assert_eq!(result.err().map(|error| error.kind()), expected);
            server.await.unwrap();
            let mut remaining = Vec::new();
            client.read_to_end(&mut remaining).await.unwrap();
            let expected_remaining = if reply.starts_with(b"HTTP/") {
                b"\r\nsecret body".as_slice()
            } else {
                b"".as_slice()
            };
            assert_eq!(remaining, expected_remaining);
        }
    }

    #[test]
    fn trace_formatter_keeps_only_fixed_metadata() {
        let text = format_trace_metadata(
            39281,
            LogLevel::Error,
            "/usr/libexec/remotepairingdeviced",
            "errorCode=-6720 loopback invalid origin authentication rejected secret body key=private_key token=abc123",
        ).unwrap();
        assert!(text.contains("pid=39281"));
        assert!(text.contains("error=true"));
        assert!(text.contains("loopback=true"));
        assert!(text.contains("invalidOrigin=true"));
        assert!(text.contains("authRejected=true"));
        assert!(text.contains("errorCode=-6720"));
        assert!(!text.contains("secret body"));
        assert!(!text.contains("private_key"));
        assert!(!text.contains("abc123"));
        assert!(!text.contains("/usr/libexec"));
        let normal_same_device = format_trace_metadata(
            39281,
            LogLevel::Info,
            "remotepairingdeviced",
            "same-device advertisement discovered",
        )
        .unwrap();
        assert!(normal_same_device.contains("rejectsSelf=false"));
        assert!(
            format_trace_metadata(
                39281,
                LogLevel::Error,
                "/usr/libexec/otherd",
                "errorCode=54"
            )
            .is_none()
        );
    }

    #[test]
    fn pairing_service_pid_requires_positive_decimal_u32() {
        for raw in ["", "0", "-1", "not-a-pid", "4294967296"] {
            assert!(
                parse_positive_pid(raw).is_err(),
                "fixture should be invalid: {raw}"
            );
        }
        assert_eq!(parse_positive_pid("39281").unwrap(), 39281);
    }

    #[tokio::test]
    async fn transport_failure_stops_but_explicit_verify_rejection_requests_setup() {
        use idevice::remote_pairing::RpPairingSocket;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        for explicit_rejection in [false, true] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let replies: &[&[u8]] = &[
                    br#"{"message":{"plain":{"_0":{"response":{"_1":{"handshake":{"_0":{}}}}}}}}"#,
                    br#"{"message":{"plain":{"_0":{"event":{"_0":{"pairingData":{"_0":{"data":"BwEC"}}}}}}}}"#,
                    b"",
                    br#"{"message":{"plain":{"_0":{"event":{"_0":{"pairingRejectedWithError":{}}}}}}}"#,
                ];
                for round in 0..if explicit_rejection { 4 } else { 1 } {
                    let mut header = [0u8; 11];
                    stream.read_exact(&mut header).await.unwrap();
                    let mut body = vec![0; u16::from_be_bytes([header[9], header[10]]) as usize];
                    stream.read_exact(&mut body).await.unwrap();
                    if !explicit_rejection {
                        break;
                    }
                    if round == 3 {
                        assert!(
                            String::from_utf8(body)
                                .unwrap()
                                .contains("setupManualPairing")
                        );
                    }
                    if !replies[round].is_empty() {
                        stream.write_all(b"RPPairing").await.unwrap();
                        stream
                            .write_all(&(replies[round].len() as u16).to_be_bytes())
                            .await
                            .unwrap();
                        stream.write_all(replies[round]).await.unwrap();
                    }
                }
                stream.shutdown().await.unwrap();
                let mut extra = Vec::new();
                stream.read_to_end(&mut extra).await.unwrap();
                assert!(
                    extra.is_empty(),
                    "no extra setup/retry after terminal error"
                );
            });
            let stream = tokio::net::TcpStream::connect(address).await.unwrap();
            let mut client =
                RemotePairingClient::new(RpPairingSocket::new(stream), "PrepareRegression");
            let mut file = RpPairingFile::generate("PrepareRegression");
            let error = tokio::time::timeout(
                Duration::from_secs(2),
                connect_pairing(&mut client, &mut file),
            )
            .await
            .unwrap()
            .unwrap_err();
            drop(client);
            if explicit_rejection {
                assert!(matches!(
                    error,
                    IdeviceError::RemotePairing(RemotePairingError::PairingRejected(_))
                ));
            } else {
                assert!(matches!(error, IdeviceError::Socket(_)));
            }
            tokio::time::timeout(Duration::from_secs(2), server)
                .await
                .unwrap()
                .unwrap();
        }
    }

    #[tokio::test]
    async fn existing_output_is_not_overwritten_or_followed_by_device_access() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("amber-prepare-{}-{suffix}", std::process::id()));
        let marker = b"existing-private-material";
        std::fs::write(&path, marker).unwrap();
        let args = vec![
            "prepare".into(),
            "not-a-device".into(),
            path.to_str().unwrap().into(),
        ];
        let error = run(&args).await.unwrap_err();
        assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        assert_eq!(std::fs::read(&path).unwrap(), marker);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn diagnostics_keep_codes_and_discard_protocol_and_io_payloads() {
        let error = IdeviceError::UnexpectedResponse("private-pairing-marker".into());
        let text = diagnostic(&error);
        assert!(text.contains(&format!("native={}", error.code())));
        assert!(!text.contains("private-pairing-marker"));
        let error = IdeviceError::Socket(std::io::Error::from_raw_os_error(54));
        let text = diagnostic(&error);
        assert!(text.contains("native=1"));
        assert!(text.contains("ConnectionReset"));
        assert!(text.contains("os=Some(54)"));
        let error = std::io::Error::new(std::io::ErrorKind::AlreadyExists, "private-file-marker");
        let text = diagnostic(&error);
        assert!(text.contains("AlreadyExists"));
        assert!(!text.contains("private-file-marker"));
    }
}
