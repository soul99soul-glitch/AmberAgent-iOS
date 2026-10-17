//! Descriptor faults must be isolated from the other tests and their output.
use super::*;
use std::{process::{Command, Stdio}, time::Instant};

const CHILD_CASE: &str = "AMBER_NATIVE_STDERR_TEST_CASE";

#[test]
fn stderr_failure_keeps_ffi_lifecycle_and_runner_readiness_usable() {
    if let Ok(case) = std::env::var(CHILD_CASE) {
        let (fault, scenario) = case.split_once(':').unwrap();
        break_stderr(fault);
        match scenario {
            "query_failure" => query_failure(),
            "stop" => stop(),
            "runner" => runner(),
            _ => panic!("unknown subprocess scenario"),
        }
        return;
    }

    for fault in ["epipe", "eio"] {
        for scenario in ["query_failure", "stop", "runner"] {
            let case = format!("{fault}:{scenario}");
            let mut child = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "stderr_tests::stderr_failure_keeps_ffi_lifecycle_and_runner_readiness_usable", "--nocapture"])
                .env(CHILD_CASE, &case)
                .stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut expired = false;
            while child.try_wait().unwrap().is_none() {
                if Instant::now() >= deadline {
                    expired = true;
                    child.kill().unwrap();
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            let output = child.wait_with_output().unwrap();
            assert!(!expired && output.status.success(),
                "{case}: timed_out={expired}, status={}, stdout={}, stderr={}",
                output.status, String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
        }
    }
}

fn break_stderr(fault: &str) {
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        let (write_fd, expected_errno) = match fault {
            "epipe" => {
                let mut descriptors = [0; 2];
                assert_eq!(libc::pipe(descriptors.as_mut_ptr()), 0);
                assert_eq!(libc::close(descriptors[0]), 0);
                (descriptors[1], libc::EPIPE)
            }
            "eio" => {
                let (mut master, mut slave) = (0, 0);
                assert_eq!(libc::openpty(&mut master, &mut slave, std::ptr::null_mut(),
                    std::ptr::null_mut(), std::ptr::null_mut()), 0);
                assert_eq!(libc::close(master), 0);
                (slave, libc::EIO)
            }
            _ => panic!("unknown stderr fault"),
        };
        assert_eq!(libc::dup2(write_fd, libc::STDERR_FILENO), libc::STDERR_FILENO);
        assert_eq!(libc::close(write_fd), 0);
        assert_eq!(libc::write(libc::STDERR_FILENO, b"x".as_ptr().cast(), 1), -1);
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(expected_errno));
    }
}

fn take_json(pointer: *mut c_char) -> serde_json::Value {
    assert!(!pointer.is_null());
    let text = unsafe { CStr::from_ptr(pointer) }.to_str().unwrap().to_owned();
    unsafe { amber_iphone_control_string_free(pointer) };
    serde_json::from_str(&text).unwrap()
}

fn query_failure() {
    // Nonempty malformed material passes the ABI size check, then fails on the
    // real worker before any socket can be opened. No phone is involved.
    let material = [1u8];
    let endpoint = CString::new("127.0.0.1:9").unwrap();
    let handle = unsafe { amber_iphone_control_apps_start(material.as_ptr(), material.len(), endpoint.as_ptr(), 0) };
    let deadline = Instant::now() + Duration::from_secs(2);
    let status = loop {
        let status = take_json(unsafe { amber_iphone_control_status_json(handle) });
        if status["phase"] == "failed" || Instant::now() >= deadline { break status; }
        std::thread::sleep(Duration::from_millis(5));
    };
    assert_eq!(status["phase"], "failed");
    assert_eq!(status["code"], "invalid_pairing");
    let apps = take_json(unsafe { amber_iphone_control_apps_copy_json(handle) });
    assert_eq!(apps["state"], "failed");
    assert_eq!(apps["error"]["code"], "invalid_pairing");
    unsafe {
        amber_iphone_control_stop(handle);
        amber_iphone_control_stop(handle);
        assert_eq!(take_json(amber_iphone_control_status_json(handle))["phase"], "failed");
        amber_iphone_control_free(handle);
    }
}

fn session() -> Arc<Session> {
    Arc::new(Session {
        status: Mutex::new(Status::new("starting", "starting", "")),
        started: Notify::new(), pairing_result: Mutex::new(None),
        applications: Mutex::new(applications::CatalogResult::Pending),
    })
}

fn stop() {
    let session = session();
    let (stop, stopped) = watch::channel(false);
    let handle = Box::into_raw(Box::new(AmberIPhoneControlHandle {
        session: session.clone(), stop, thread: None,
    }));
    unsafe {
        amber_iphone_control_stop(handle);
        assert_eq!(take_json(amber_iphone_control_status_json(handle))["phase"], "stopping");
        assert!(*stopped.borrow());
        assert!(!session.status.is_poisoned());
        amber_iphone_control_free(handle);
    }
}

fn runner() {
    let session = session();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let mut listener = Listener(session.clone());
        listener.test_case_did_start("ignored", "anotherTest").await.unwrap();
        assert_eq!(session.status.lock().unwrap().phase, "starting");
        listener.test_case_did_start("ignored", "testServe()").await.unwrap();
        assert_eq!(session.status.lock().unwrap().phase, "running");
        tokio::time::timeout(Duration::from_secs(1), session.started.notified()).await.unwrap();
    });
}
