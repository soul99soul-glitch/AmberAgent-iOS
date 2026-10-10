//! Session-owned RemotePairing → RSD → XCTest bridge. No device operations
//! occur on the C caller thread. Pairing material is exported only through the
//! explicit first-setup result API, never through status or logs.

use std::{
    ffi::{CStr, CString, c_char},
    net::SocketAddr,
    sync::{Arc, Mutex},
    thread::JoinHandle,
    time::Duration,
};

use idevice::{
    IdeviceError, RsdService,
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    services::{
        dvt::xctest::{TestConfig, XCUITestService, listener::XCUITestListener},
        installation_proxy::InstallationProxyClient,
        lockdown::LockdownClient,
        rsd::RsdHandshake,
    },
};
use serde::Serialize;
use tokio::sync::{Notify, watch};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Clone, Serialize)]
struct Status {
    phase: &'static str,
    code: &'static str,
    message: &'static str,
    #[serde(flatten)]
    native: Option<NativeDiagnostic>,
    pair_verify_error: Option<NativeDiagnostic>,
}

#[derive(Clone, Serialize)]
struct NativeDiagnostic {
    native_error_code: i32,
    native_error_subcode: i32,
    native_io_kind: Option<String>,
    native_os_error_code: Option<i32>,
}

impl NativeDiagnostic {
    fn from_error(error: &IdeviceError) -> Self {
        let (native_io_kind, native_os_error_code) = match error {
            IdeviceError::Socket(io) => (Some(format!("{:?}", io.kind())), io.raw_os_error()),
            _ => (None, None),
        };
        Self { native_error_code: error.code(), native_error_subcode: error.sub_code(), native_io_kind, native_os_error_code }
    }
}

impl Status {
    fn new(phase: &'static str, code: &'static str, message: &'static str) -> Self {
        Self { phase, code, message, native: None, pair_verify_error: None }
    }
}

struct Session {
    status: Mutex<Status>,
    started: Notify,
    pairing_result: Mutex<Option<String>>,
}

impl Session {
    fn set(&self, mut status: Status) {
        let mut current = self.status.lock().unwrap_or_else(|p| p.into_inner());
        // Cancellation is terminal for this generation; late protocol events
        // cannot resurrect the UI while its runtime is shutting down.
        if matches!(current.phase, "stopped" | "failed" | "paired") {
            return;
        }
        if current.phase == "stopping" && status.phase != "stopped" {
            if status.phase == "failed" {
                status = Status::new("stopped", "stopped", "控制会话已停止。");
            } else {
                return;
            }
        }
        if status.pair_verify_error.is_none() {
            status.pair_verify_error = current.pair_verify_error.clone();
        }
        *current = status;
    }

    fn stage(&self, phase: &'static str, message: &'static str) {
        self.set(Status::new(phase, phase, message));
    }

    fn failure(&self, failure: Failure) {
        self.set(Status {
            phase: "failed", code: failure.code, message: failure.message,
            native: failure.native,
            pair_verify_error: None,
        });
    }
}

/// Opaque to C. Only `free` mutates the owner; status/stop access shared state.
pub struct AmberIPhoneControlHandle {
    session: Arc<Session>,
    stop: watch::Sender<bool>,
    thread: Option<JoinHandle<()>>,
}

struct Config {
    pairing: Vec<u8>,
    endpoint: SocketAddr,
    bundle_id: String,
    module: String,
    token: String,
}

enum Operation {
    Control(Config),
    FirstPairing(SocketAddr),
}

impl Operation {
    async fn run(self, session: Arc<Session>) -> Result<(), Failure> {
        match self {
            Self::Control(config) => run_session(config, session).await,
            Self::FirstPairing(endpoint) => run_first_pairing(endpoint, session).await,
        }
    }
}

struct Failure {
    code: &'static str,
    message: &'static str,
    native: Option<NativeDiagnostic>,
}

impl Failure {
    fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message, native: None }
    }

    fn device(code: &'static str, message: &'static str, error: IdeviceError) -> Self {
        // Upstream error payloads and tracing may include plist/key contents.
        // Retain stable numeric diagnostics, never the arbitrary remote payload.
        Self { code, message, native: Some(NativeDiagnostic::from_error(&error)) }
    }
}

impl Config {
    fn validate(self) -> Result<Self, Failure> {
        if self.pairing.is_empty() || self.pairing.len() > 1024 * 1024 {
            return Err(Failure::new("invalid_pairing", "RemotePairing 文件为空或过大。"));
        }
        if self.endpoint.port() == 0 {
            return Err(Failure::new("invalid_endpoint", "开发服务端口无效。"));
        }
        let bundle_ok = !self.bundle_id.is_empty() && self.bundle_id.len() <= 255
            && self.bundle_id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b));
        let module_ok = !self.module.is_empty() && self.module.len() <= 128
            && self.module.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
        if !bundle_ok || !module_ok {
            return Err(Failure::new("invalid_runner", "Runner 的 bundle ID 或模块名无效。"));
        }
        if !(32..=128).contains(&self.token.len()) || !self.token.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Failure::new("invalid_token", "Runner token 必须是 32 到 128 位十六进制字符串。"));
        }
        Ok(self)
    }
}

/// # Safety
/// Non-null pointers must reference readable data for the documented lengths;
/// string inputs must be NUL-terminated. Inputs are copied synchronously.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn amber_iphone_control_start(
    pairing: *const u8, pairing_length: usize,
    endpoint: *const c_char, runner_bundle_id: *const c_char,
    test_module_name: *const c_char, runner_token: *const c_char,
) -> *mut AmberIPhoneControlHandle {
    let config = unsafe { read_config(pairing, pairing_length, endpoint, runner_bundle_id, test_module_name, runner_token) };
    start_operation(config.map(Operation::Control))
}

/// Explicit first setup only. Performs the documented iOS system consent flow;
/// the verify-only control start API above never calls this function.
/// # Safety
/// Non-null endpoint must be a NUL-terminated UTF-8 IP:port string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn amber_iphone_control_pairing_start(endpoint: *const c_char) -> *mut AmberIPhoneControlHandle {
    let endpoint = unsafe { read_endpoint(endpoint, "127.0.0.1:49152") };
    start_operation(endpoint.map(Operation::FirstPairing))
}

fn start_operation(operation: Result<Operation, Failure>) -> *mut AmberIPhoneControlHandle {
    let session = Arc::new(Session {
        status: Mutex::new(Status::new("connecting", "connecting", "正在连接本机开发服务。")),
        started: Notify::new(),
        pairing_result: Mutex::new(None),
    });
    let (stop, mut stopped) = watch::channel(false);
    let mut handle = Box::new(AmberIPhoneControlHandle { session: session.clone(), stop, thread: None });
    match operation {
        Err(error) => session.failure(error),
        Ok(operation) => {
            let timeout_message = match &operation {
                Operation::Control(_) => "90 秒内未收到 runner 测试启动事件，请检查本机路由、开发服务与签名。",
                Operation::FirstPairing(_) => "90 秒内未完成系统配对确认，本次准备已停止。",
            };
            let task_session = session.clone();
            let thread = std::thread::Builder::new().name("amber-iphone-control".into()).spawn(move || {
                // The upstream protocol library logs pairing plists at debug.
                // A per-thread subscriber blocks those logs even if the host
                // application installs a global tracing subscriber later.
                tracing::subscriber::with_default(tracing::subscriber::NoSubscriber::default(), || {
                    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
                            .map_err(|_| Failure::new("runtime_unavailable", "无法创建开发服务运行环境。"))?;
                        runtime.block_on(async {
                            tokio::select! {
                                biased;
                                _ = stopped.wait_for(|value| *value) => {
                                    task_session.stage("stopped", "控制会话已停止。");
                                    Ok(())
                                }
                                result = operation.run(task_session.clone()) => result,
                                _ = startup_deadline(&task_session.started, STARTUP_TIMEOUT) => {
                                    Err(Failure::new("startup_timeout", timeout_message))
                                }
                            }
                        })
                    }));
                    match outcome {
                        Ok(Ok(())) => task_session.stage("stopped", "控制会话已结束。"),
                        Ok(Err(failure)) => task_session.failure(failure),
                        Err(_) => task_session.failure(Failure::new("runtime_failure", "开发服务运行环境异常退出。")),
                    }
                });
            });
            match thread {
                Ok(thread) => handle.thread = Some(thread),
                Err(_) => session.failure(Failure::new("runtime_unavailable", "无法创建开发服务线程。")),
            }
        }
    }
    Box::into_raw(handle)
}

async fn startup_deadline(started: &Notify, timeout: Duration) {
    if tokio::time::timeout(timeout, started.notified()).await.is_ok() {
        // Readiness cancels only startup timeout. The owned session remains
        // alive until explicit stop, system expiration, or a protocol failure.
        std::future::pending::<()>().await;
    }
}

unsafe fn read_string(pointer: *const c_char) -> Result<String, Failure> {
    if pointer.is_null() {
        return Err(Failure::new("invalid_config", "缺少启动配置。"));
    }
    unsafe { CStr::from_ptr(pointer) }.to_str().map(str::to_owned)
        .map_err(|_| Failure::new("invalid_config", "启动配置不是有效 UTF-8。"))
}

unsafe fn read_endpoint(pointer: *const c_char, default: &str) -> Result<SocketAddr, Failure> {
    let text = if pointer.is_null() { default.to_owned() } else { unsafe { read_string(pointer)? } };
    let endpoint: SocketAddr = text.parse().map_err(|_| Failure::new("invalid_endpoint", "开发服务地址必须是 IP:端口。"))?;
    if endpoint.port() == 0 {
        return Err(Failure::new("invalid_endpoint", "开发服务端口无效。"));
    }
    Ok(endpoint)
}

unsafe fn read_config(
    pairing: *const u8, length: usize, endpoint: *const c_char,
    bundle: *const c_char, module: *const c_char, token: *const c_char,
) -> Result<Config, Failure> {
    if pairing.is_null() || length == 0 || length > 1024 * 1024 {
        return Err(Failure::new("invalid_pairing", "需要已配对的 RemotePairing 文件。"));
    }
    Config {
        pairing: unsafe { std::slice::from_raw_parts(pairing, length) }.to_vec(),
        endpoint: unsafe { read_endpoint(endpoint, "10.7.0.1:49152")? },
        bundle_id: unsafe { read_string(bundle)? }, module: unsafe { read_string(module)? },
        token: unsafe { read_string(token)? },
    }.validate()
}

/// # Safety
/// Handle must be valid and not concurrently freed. NULL returns invalid_handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn amber_iphone_control_status_json(handle: *const AmberIPhoneControlHandle) -> *mut c_char {
    let status = if handle.is_null() {
        Status::new("failed", "invalid_handle", "控制会话不存在。")
    } else {
        unsafe { &*handle }.session.status.lock().unwrap_or_else(|p| p.into_inner()).clone()
    };
    CString::new(serde_json::to_string(&status).expect("status serializes")).expect("JSON has no NUL").into_raw()
}

/// Copies private pairing XML only after successful explicit first setup.
/// # Safety
/// Handle must be valid and not concurrently freed. Free the returned string
/// using string_free; NULL means no completed pairing result is available.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn amber_iphone_control_pairing_copy_plist(handle: *const AmberIPhoneControlHandle) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else { return std::ptr::null_mut(); };
    let status = handle.session.status.lock().unwrap_or_else(|p| p.into_inner());
    if status.phase != "paired" { return std::ptr::null_mut(); }
    handle.session.pairing_result.lock().unwrap_or_else(|p| p.into_inner())
        .as_ref().and_then(|text| CString::new(text.as_str()).ok())
        .map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// Handle must be valid and not concurrently freed. NULL is a no-op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn amber_iphone_control_stop(handle: *const AmberIPhoneControlHandle) {
    if let Some(handle) = unsafe { handle.as_ref() } {
        handle.session.stage("stopping", "正在停止控制会话。");
        let _ = handle.stop.send(true);
    }
}

/// # Safety
/// Handle must be returned from start, freed exactly once, and exclusively owned.
/// NULL is a no-op. Must not be invoked on the UI thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn amber_iphone_control_free(handle: *mut AmberIPhoneControlHandle) {
    if handle.is_null() { return; }
    let mut handle = unsafe { Box::from_raw(handle) };
    let _ = handle.stop.send(true);
    if let Some(thread) = handle.thread.take() { let _ = thread.join(); }
}

/// # Safety
/// Text must be returned from status_json and freed exactly once. NULL is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn amber_iphone_control_string_free(text: *mut c_char) {
    if !text.is_null() { drop(unsafe { CString::from_raw(text) }); }
}

struct Listener(Arc<Session>);

impl XCUITestListener for Listener {
    async fn test_case_did_start(&mut self, _class: &str, method: &str) -> Result<(), IdeviceError> {
        if method == "testServe" || method == "testServe()" {
            self.0.stage("running", "Runner 测试已启动，等待签名接口验证。");
            self.0.started.notify_one();
        }
        Ok(())
    }

    async fn initialization_for_ui_testing_did_fail(&mut self, _description: &str) -> Result<(), IdeviceError> {
        Err(IdeviceError::UnexpectedResponse("UI automation initialization failed".into()))
    }
}

fn configure_runner(cfg: &mut TestConfig, module: &str, token: &str) -> Result<(), Failure> {
    if cfg.config_name() != module {
        return Err(Failure::new("runner_module_mismatch", "已安装 runner 的可执行文件与配置的测试模块不一致。"));
    }
    cfg.product_module_name = Some(module.into());
    cfg.tests_to_run = Some(vec![format!("{module}.RunnerTests/testServe")]);
    cfg.runner_env = Some([
        ("IPU_RUNNER_TOKEN".to_owned(), plist::Value::String(token.into())),
        ("IPU_RUNNER_MJPEG_PORT".to_owned(), plist::Value::String("0".into())),
    ].into_iter().collect());
    Ok(())
}

async fn run_first_pairing(endpoint: SocketAddr, session: Arc<Session>) -> Result<(), Failure> {
    let stream = tokio::net::TcpStream::connect(endpoint).await
        .map_err(|e| Failure::device("connection_failed", "无法连接本机配对服务。", e.into()))?;
    // Per-attempt identity avoids replacing another installation's record when
    // RpPairingFile::generate derives its identifier from the advertised name.
    let name = format!("Amber-{}", uuid::Uuid::new_v4());
    let mut pairing = RpPairingFile::generate(&name);
    let mut remote = RemotePairingClient::new(RpPairingSocket::new(stream), &name);
    // The same ordering as upstream RemotePairingClient.connect, split here so
    // a dead transport during the initial handshake isn't mislabeled as denial
    // of a consent prompt the device never actually presented.
    session.stage("pairing_handshake", "正在与本机配对服务握手。");
    remote.attempt_pair_verify().await
        .map_err(|e| Failure::device("pairing_handshake_failed", "配对服务在初始握手阶段断开或返回错误。", e))?;
    session.stage("verifying_pairing", "正在确认本次配对身份。");
    if let Err(verify_error) = remote.validate_pairing(&mut pairing).await {
        let mut status = Status::new("waiting_for_consent", "waiting_for_consent", "正在请求系统配对确认；如出现提示，请在本机确认。");
        status.pair_verify_error = Some(NativeDiagnostic::from_error(&verify_error));
        session.set(status);
        // Retain the prior numeric/IO error as well: upstream attempts setup
        // after any failed verify, including failures on an already-dead socket.
        remote.pair(&mut pairing, async || "000000".to_owned()).await
            .map_err(|e| Failure::device("pairing_setup_failed", "新的开发配对未完成；请结合系统提示与错误码确认原因。", e))?;
    }
    let xml = String::from_utf8(pairing.to_bytes())
        .map_err(|_| Failure::new("pairing_export_failed", "无法保存已完成的配对结果。"))?;
    *session.pairing_result.lock().unwrap_or_else(|p| p.into_inner()) = Some(xml);
    session.stage("paired", "配对已完成，可以将配对材料保存到本机钥匙串。");
    Ok(())
}

async fn run_session(config: Config, session: Arc<Session>) -> Result<(), Failure> {
    let mut pairing = RpPairingFile::from_bytes(&config.pairing)
        .map_err(|e| Failure::device("invalid_pairing", "无法读取 RemotePairing 文件；普通 lockdown 配对文件不适用于此入口。", e))?;
    let stream = tokio::net::TcpStream::connect(config.endpoint).await
        .map_err(|e| Failure::device("connection_failed", "无法连接本机开发服务，请检查 loopback 路由和服务端口。", e.into()))?;
    session.stage("pairing", "正在验证已有配对。");
    let mut remote = RemotePairingClient::new(RpPairingSocket::new(stream), "Amber");
    remote.attempt_pair_verify().await
        .map_err(|e| Failure::device("pairing_handshake_failed", "开发服务配对握手失败。", e))?;
    // Do not use connect(): it silently falls back to creating a new pairing.
    remote.validate_pairing(&mut pairing).await
        .map_err(|e| Failure::device("pairing_rejected", "设备拒绝已有配对，请重新准备 RemotePairing 文件。", e))?;
    session.stage("tunnel", "正在建立本机开发隧道。");
    let port = remote.create_tcp_listener().await
        .map_err(|e| Failure::device("tunnel_rejected", "设备未允许建立开发隧道。", e))?;
    let tunnel_stream = tokio::net::TcpStream::connect(SocketAddr::new(config.endpoint.ip(), port)).await
        .map_err(|e| Failure::device("tunnel_connection_failed", "无法连接开发隧道。", e.into()))?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, remote.encryption_key()).await
        .map_err(|e| Failure::device("tunnel_handshake_failed", "开发隧道握手失败。", e))?;
    let client_ip = tunnel.info.client_address.parse()
        .map_err(|_| Failure::new("invalid_tunnel_address", "开发隧道返回了无效地址。"))?;
    let server_ip = tunnel.info.server_address.parse()
        .map_err(|_| Failure::new("invalid_tunnel_address", "开发隧道返回了无效地址。"))?;
    let rsd_port = tunnel.info.server_rsd_port;
    let mtu = tunnel.info.mtu as usize;
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    session.stage("discovering", "正在查询开发服务与已安装 runner。");
    let stream = adapter.connect(rsd_port).await
        .map_err(|_| Failure::new("rsd_connection_failed", "无法连接开发服务目录。"))?;
    let mut handshake = RsdHandshake::new(stream).await
        .map_err(|e| Failure::device("rsd_handshake_failed", "开发服务目录握手失败。", e))?;
    let mut lockdown = LockdownClient::connect_rsd(&mut adapter, &mut handshake).await
        .map_err(|e| Failure::device("lockdown_rsd_failed", "无法通过已验证隧道读取设备信息。", e))?;
    let version = lockdown.get_value(Some("ProductVersion"), None).await
        .map_err(|e| Failure::device("version_unavailable", "无法读取设备系统版本。", e))?;
    let major = version.as_string().and_then(|s| s.split('.').next()).and_then(|s| s.parse::<u8>().ok())
        .filter(|v| *v >= 17).ok_or_else(|| Failure::new("unsupported_os", "该启动方式要求 iOS 17 或更高版本。"))?;
    drop(lockdown);
    let mut installation = InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake).await
        .map_err(|e| Failure::device("installation_service_failed", "无法查询 runner 安装信息。", e))?;
    let mut cfg = TestConfig::from_installation_proxy(&mut installation, &config.bundle_id, None).await
        .map_err(|e| Failure::device("runner_unavailable", "Runner 未安装、签名不可用或安装信息不完整。", e))?;
    drop(installation);
    configure_runner(&mut cfg, &config.module, &config.token)?;
    session.stage("starting", "正在启动本机 XCTest 控制会话。");
    // Retain the RemotePairing control socket and software tunnel in this future
    // until the XCTest session completes or its owner cancels it.
    let result = XCUITestService::run_rsd(adapter, handshake, cfg, major, &mut Listener(session), None).await;
    drop(remote);
    result.map_err(|e| Failure::device("xctest_failed", "XCTest 会话失败或连接中断；不会自动重启动作。", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config { pairing: vec![1], endpoint: "10.7.0.1:49152".parse().unwrap(),
            bundle_id: "app.amber.selfcontrol.runner.xctrunner".into(),
            module: "iPhoneUse".into(), token: "ab".repeat(32) }
    }

    #[test]
    fn rejects_mismatched_runner_module_and_preserves_explicit_configuration() {
        let mut cfg = TestConfig {
            runner_bundle_id: "app.amber.selfcontrol.runner.xctrunner".into(),
            runner_app_path: "/Applications/iPhoneUse-Runner.app".into(),
            runner_app_container: "/data/runner".into(), runner_bundle_executable: "iPhoneUse-Runner".into(),
            target_bundle_id: None, target_app_path: None, target_app_env: None, target_app_args: None,
            tests_to_run: None, tests_to_skip: None, runner_env: None, runner_args: None, product_module_name: None,
        };
        assert!(configure_runner(&mut cfg, "WrongModule", &"ab".repeat(32)).is_err());
        configure_runner(&mut cfg, "iPhoneUse", &"ab".repeat(32)).unwrap_or_else(|_| panic!("valid config"));
        let built = cfg.build_xctest_configuration(uuid::Uuid::new_v4(), 27).unwrap();
        assert_eq!(built.product_module_name, "iPhoneUse");
        assert_eq!(built.test_bundle_url, "file:///Applications/iPhoneUse-Runner.app/PlugIns/iPhoneUse.xctest");
        assert_eq!(built.tests_to_run, Some(vec!["iPhoneUse.RunnerTests/testServe".into()]));
        let env = cfg.runner_env.unwrap();
        assert_eq!(env["IPU_RUNNER_TOKEN"].as_string(), Some("ab".repeat(32).as_str()));
        assert_eq!(env["IPU_RUNNER_MJPEG_PORT"].as_string(), Some("0"));
    }

    #[test]
    fn invalid_config_cannot_start_network_and_status_has_no_secrets() {
        let token = CString::new("this-is-a-secret-but-invalid-token").unwrap();
        let bundle = CString::new("app.amber.runner").unwrap();
        let module = CString::new("iPhoneUse").unwrap();
        let pair = b"pairing-sensitive-marker";
        unsafe {
            let handle = amber_iphone_control_start(pair.as_ptr(), pair.len(), std::ptr::null(), bundle.as_ptr(), module.as_ptr(), token.as_ptr());
            assert!((*handle).thread.is_none());
            let json = amber_iphone_control_status_json(handle);
            let text = CStr::from_ptr(json).to_str().unwrap();
            assert!(text.contains("invalid_token"));
            assert!(!text.contains("secret"));
            assert!(!text.contains("sensitive-marker"));
            amber_iphone_control_string_free(json);
            amber_iphone_control_stop(handle);
            amber_iphone_control_stop(handle);
            amber_iphone_control_free(handle);
        }
    }

    #[test]
    fn cancellation_blocks_late_running_callback() {
        let session = Session { status: Mutex::new(Status::new("starting", "starting", "")), started: Notify::new(), pairing_result: Mutex::new(None) };
        session.stage("stopping", "");
        session.stage("running", "");
        assert_eq!(session.status.lock().unwrap().phase, "stopping");
        session.failure(Failure::new("in_flight_error", ""));
        assert_eq!(session.status.lock().unwrap().phase, "stopped");
        session.failure(Failure::new("late_error", ""));
        assert_eq!(session.status.lock().unwrap().phase, "stopped");
    }

    #[tokio::test]
    async fn startup_deadline_expires_but_ready_signal_disarms_it() {
        let started = Notify::new();
        startup_deadline(&started, Duration::from_millis(1)).await;
        started.notify_one();
        assert!(tokio::time::timeout(Duration::from_millis(10), startup_deadline(&started, Duration::from_millis(1))).await.is_err());
    }

    #[tokio::test]
    async fn stop_and_free_close_pending_pairing_socket_and_owned_runtime() {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = CString::new(listener.local_addr().unwrap().to_string()).unwrap();
        let pair = RpPairingFile::generate("AmberUnitTest").to_bytes();
        let bundle = CString::new("app.amber.runner.xctrunner").unwrap();
        let module = CString::new("iPhoneUse").unwrap();
        let token = CString::new("ab".repeat(32)).unwrap();
        let handle = unsafe { amber_iphone_control_start(pair.as_ptr(), pair.len(), endpoint.as_ptr(), bundle.as_ptr(), module.as_ptr(), token.as_ptr()) };
        let (mut stream, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await.unwrap().unwrap();
        let mut bytes = [0u8; 4096];
        let n = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut bytes)).await.unwrap().unwrap();
        assert!(n > 0, "library reached pair-verify, fixture intentionally never replies");
        unsafe {
            amber_iphone_control_stop(handle);
            amber_iphone_control_stop(handle);
            amber_iphone_control_free(handle);
        }
        let eof = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut bytes)).await.unwrap().unwrap();
        assert_eq!(eof, 0, "free closed pending I/O rather than orphaning protocol tasks");
    }

    #[tokio::test]
    async fn first_setup_does_not_export_unaccepted_identity_and_can_be_cancelled() {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = CString::new(listener.local_addr().unwrap().to_string()).unwrap();
        let handle = unsafe { amber_iphone_control_pairing_start(endpoint.as_ptr()) };
        let (mut stream, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await.unwrap().unwrap();
        let mut bytes = [0u8; 4096];
        assert!(tokio::time::timeout(Duration::from_secs(2), stream.read(&mut bytes)).await.unwrap().unwrap() > 0);
        unsafe {
            assert!(amber_iphone_control_pairing_copy_plist(handle).is_null());
            let json = amber_iphone_control_status_json(handle);
            let text = CStr::from_ptr(json).to_str().unwrap();
            assert!(text.contains("pairing_handshake"));
            assert!(!text.contains("private_key"));
            amber_iphone_control_string_free(json);
            amber_iphone_control_stop(handle);
            amber_iphone_control_free(handle);
        }
        assert_eq!(tokio::time::timeout(Duration::from_secs(2), stream.read(&mut bytes)).await.unwrap().unwrap(), 0);
    }

    #[test]
    fn only_completed_pairing_can_export_secrets_separately_from_status() {
        let (stop, _) = watch::channel(false);
        let session = Arc::new(Session {
            status: Mutex::new(Status::new("waiting_for_consent", "waiting_for_consent", "")),
            started: Notify::new(), pairing_result: Mutex::new(Some("<plist>private-test-marker</plist>".into())),
        });
        let handle = Box::into_raw(Box::new(AmberIPhoneControlHandle { session: session.clone(), stop, thread: None }));
        unsafe {
            assert!(amber_iphone_control_pairing_copy_plist(handle).is_null());
            session.stage("paired", "配对已完成。");
            let xml = amber_iphone_control_pairing_copy_plist(handle);
            assert_eq!(CStr::from_ptr(xml).to_str().unwrap(), "<plist>private-test-marker</plist>");
            amber_iphone_control_string_free(xml);
            let json = amber_iphone_control_status_json(handle);
            assert!(!CStr::from_ptr(json).to_str().unwrap().contains("private-test-marker"));
            amber_iphone_control_string_free(json);
            amber_iphone_control_free(handle);
        }
    }

    #[test]
    fn accepts_valid_token_and_rejects_path_in_module() {
        assert!(config().validate().is_ok());
        let mut invalid = config(); invalid.module = "../iPhoneUse".into();
        assert!(invalid.validate().is_err());
    }
}
