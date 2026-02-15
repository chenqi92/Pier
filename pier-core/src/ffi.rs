//! C FFI interface for Swift integration.
//!
//! All functions exported here are callable from Swift via the C bridge.
//! Naming convention: pier_<module>_<action>

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use crate::terminal::TerminalSession;
use crate::search;
use crate::ssh::session::SshSession;
use crate::ssh::{SshConfig, SshAuth};
use crate::ssh::service_detector;
use std::sync::OnceLock;

/// Global tokio runtime for async SSH operations.
fn ssh_runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("Failed to create SSH tokio runtime")
    })
}

// ═══════════════════════════════════════════════════════════
// Terminal FFI
// ═══════════════════════════════════════════════════════════

/// Opaque pointer to a TerminalSession.
pub type PierTerminalHandle = *mut TerminalSession;

/// Create a new terminal session.
/// Returns null on failure.
#[no_mangle]
pub extern "C" fn pier_terminal_create(
    cols: u16,
    rows: u16,
    shell: *const c_char,
) -> PierTerminalHandle {
    let shell_str = if shell.is_null() {
        "/bin/zsh"
    } else {
        unsafe { CStr::from_ptr(shell).to_str().unwrap_or("/bin/zsh") }
    };

    match TerminalSession::new(cols, rows, shell_str) {
        Ok(session) => Box::into_raw(Box::new(session)),
        Err(e) => {
            log::error!("Failed to create terminal: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Create a new terminal session running a specific command with arguments.
/// `args` is a C array of `argc` string pointers. args[0] should be the program path.
/// Returns null on failure.
#[no_mangle]
pub extern "C" fn pier_terminal_create_with_args(
    cols: u16,
    rows: u16,
    program: *const c_char,
    args: *const *const c_char,
    argc: u32,
) -> PierTerminalHandle {
    if program.is_null() {
        return std::ptr::null_mut();
    }

    let program_str = unsafe { CStr::from_ptr(program).to_str().unwrap_or("/bin/zsh") };

    let mut arg_strings: Vec<String> = Vec::new();
    if !args.is_null() && argc > 0 {
        for i in 0..argc as usize {
            unsafe {
                let arg_ptr = *args.add(i);
                if !arg_ptr.is_null() {
                    if let Ok(s) = CStr::from_ptr(arg_ptr).to_str() {
                        arg_strings.push(s.to_string());
                    }
                }
            }
        }
    }

    let arg_refs: Vec<&str> = arg_strings.iter().map(|s| s.as_str()).collect();

    match TerminalSession::new_with_command(cols, rows, program_str, &arg_refs) {
        Ok(session) => Box::into_raw(Box::new(session)),
        Err(e) => {
            log::error!("Failed to create terminal with args: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Destroy a terminal session.
#[no_mangle]
pub extern "C" fn pier_terminal_destroy(handle: PierTerminalHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

/// Write user input to the terminal.
/// Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn pier_terminal_write(
    handle: PierTerminalHandle,
    data: *const u8,
    len: usize,
) -> i32 {
    if handle.is_null() || data.is_null() {
        return -1;
    }

    let session = unsafe { &mut *handle };
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };

    match session.write(bytes) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Read output from the terminal.
/// Writes data into the provided buffer and returns the number of bytes read.
/// Returns -1 on failure.
#[no_mangle]
pub extern "C" fn pier_terminal_read(
    handle: PierTerminalHandle,
    buffer: *mut u8,
    buffer_len: usize,
) -> i64 {
    if handle.is_null() || buffer.is_null() {
        return -1;
    }

    let session = unsafe { &mut *handle };

    match session.read() {
        Ok(data) => {
            let copy_len = data.len().min(buffer_len);
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), buffer, copy_len);
            }
            copy_len as i64
        }
        Err(_) => -1,
    }
}

/// Resize the terminal.
#[no_mangle]
pub extern "C" fn pier_terminal_resize(
    handle: PierTerminalHandle,
    cols: u16,
    rows: u16,
) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let session = unsafe { &mut *handle };
    match session.resize(cols, rows) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Get the PTY file descriptor for polling.
#[no_mangle]
pub extern "C" fn pier_terminal_fd(handle: PierTerminalHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let session = unsafe { &*handle };
    session.pty.raw_fd()
}

// ═══════════════════════════════════════════════════════════
// File Search FFI
// ═══════════════════════════════════════════════════════════

/// Search result returned via FFI as a JSON string.
/// Caller must free the returned string with pier_string_free.
#[no_mangle]
pub extern "C" fn pier_search_files(
    root: *const c_char,
    pattern: *const c_char,
    max_results: usize,
) -> *mut c_char {
    if root.is_null() || pattern.is_null() {
        return std::ptr::null_mut();
    }

    let root_str = unsafe { CStr::from_ptr(root).to_str().unwrap_or("") };
    let pattern_str = unsafe { CStr::from_ptr(pattern).to_str().unwrap_or("") };

    let results = search::search_files(root_str, pattern_str, max_results);

    match serde_json::to_string(&results) {
        Ok(json) => CString::new(json).unwrap_or_default().into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// List directory contents. Returns JSON string.
/// Caller must free the returned string with pier_string_free.
#[no_mangle]
pub extern "C" fn pier_list_directory(path: *const c_char) -> *mut c_char {
    if path.is_null() {
        return std::ptr::null_mut();
    }

    let path_str = unsafe { CStr::from_ptr(path).to_str().unwrap_or("") };

    match search::list_directory(path_str) {
        Ok(entries) => {
            match serde_json::to_string(&entries) {
                Ok(json) => CString::new(json).unwrap_or_default().into_raw(),
                Err(_) => std::ptr::null_mut(),
            }
        }
        Err(_) => std::ptr::null_mut(),
    }
}

// ═══════════════════════════════════════════════════════════
// SSH FFI
// ═══════════════════════════════════════════════════════════

/// Opaque pointer to an SSH session.
pub type PierSshHandle = *mut SshSession;

/// Connect to an SSH server.
/// auth_type: 0 = password, 1 = key file
/// credential: password string (auth_type=0) or key file path (auth_type=1)
/// Returns null on failure.
#[no_mangle]
pub extern "C" fn pier_ssh_connect(
    host: *const c_char,
    port: u16,
    username: *const c_char,
    auth_type: i32,
    credential: *const c_char,
) -> PierSshHandle {
    if host.is_null() || username.is_null() || credential.is_null() {
        return std::ptr::null_mut();
    }

    let host_str = unsafe { CStr::from_ptr(host).to_str().unwrap_or("") };
    let username_str = unsafe { CStr::from_ptr(username).to_str().unwrap_or("") };
    let credential_str = unsafe { CStr::from_ptr(credential).to_str().unwrap_or("") };

    let auth = match auth_type {
        0 => SshAuth::Password(credential_str.to_string()),
        1 => SshAuth::KeyFile {
            path: credential_str.to_string(),
            passphrase: None,
        },
        _ => {
            log::error!("Unknown SSH auth type: {}", auth_type);
            return std::ptr::null_mut();
        }
    };

    let config = SshConfig {
        host: host_str.to_string(),
        port,
        username: username_str.to_string(),
        auth,
    };

    let mut session = SshSession::new(config);

    // Block on async connect using the global runtime
    match ssh_runtime().block_on(session.connect()) {
        Ok(()) => {
            log::info!("SSH connected to {}:{}", host_str, port);
            Box::into_raw(Box::new(session))
        }
        Err(e) => {
            log::error!("SSH connect failed: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Disconnect an SSH session and free the handle.
#[no_mangle]
pub extern "C" fn pier_ssh_disconnect(handle: PierSshHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let mut session = unsafe { Box::from_raw(handle) };
    match ssh_runtime().block_on(session.disconnect()) {
        Ok(()) => {
            log::info!("SSH disconnected");
            0
        }
        Err(e) => {
            log::error!("SSH disconnect error: {}", e);
            -1
        }
    }
}

/// Check if SSH session is connected.
/// Returns 1 if connected, 0 if not, -1 on invalid handle.
#[no_mangle]
pub extern "C" fn pier_ssh_is_connected(handle: PierSshHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    // Safety: we only read, handle is valid
    let session = unsafe { &*handle };
    if session.is_connected() { 1 } else { 0 }
}

/// Detect services installed on the remote server.
/// Returns a JSON array of DetectedService.
/// Caller must free with pier_string_free.
#[no_mangle]
pub extern "C" fn pier_ssh_detect_services(handle: PierSshHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let session = unsafe { &*handle };

    // 30-second overall timeout for service detection to prevent blocking
    // when the SSH connection is dead (e.g. network change).
    let services = match ssh_runtime().block_on(
        tokio::time::timeout(
            std::time::Duration::from_secs(30),
            service_detector::detect_all(session),
        )
    ) {
        Ok(services) => services,
        Err(_) => {
            log::warn!("Service detection timed out after 30s");
            Vec::new()
        }
    };

    match serde_json::to_string(&services) {
        Ok(json) => CString::new(json).unwrap_or_default().into_raw(),
        Err(e) => {
            log::error!("Failed to serialize services: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Execute a command on the remote server.
/// Returns JSON: {"exit_code": N, "stdout": "..."}
/// Caller must free with pier_string_free.
#[no_mangle]
pub extern "C" fn pier_ssh_exec(
    handle: PierSshHandle,
    command: *const c_char,
) -> *mut c_char {
    if handle.is_null() || command.is_null() {
        return std::ptr::null_mut();
    }

    let session = unsafe { &*handle };
    let cmd_str = unsafe { CStr::from_ptr(command).to_str().unwrap_or("") };

    // 60-second overall timeout to prevent blocking the FFI thread indefinitely
    // when the SSH connection is dead (e.g. network change).
    match ssh_runtime().block_on(
        tokio::time::timeout(
            std::time::Duration::from_secs(60),
            session.exec_command(cmd_str),
        )
    ) {
        Ok(Ok((exit_code, stdout))) => {
            let result = serde_json::json!({
                "exit_code": exit_code,
                "stdout": stdout,
            });
            match CString::new(result.to_string()) {
                Ok(cs) => cs.into_raw(),
                Err(_) => std::ptr::null_mut(),
            }
        }
        Ok(Err(e)) => {
            log::error!("SSH exec failed: {}", e);
            let err = serde_json::json!({
                "exit_code": -1,
                "stdout": format!("Error: {}", e),
            });
            CString::new(err.to_string()).unwrap_or_default().into_raw()
        }
        Err(_) => {
            log::warn!("SSH exec timed out after 60s for command: {}", cmd_str);
            let err = serde_json::json!({
                "exit_code": -1,
                "stdout": "Error: command timed out after 60s",
            });
            CString::new(err.to_string()).unwrap_or_default().into_raw()
        }
    }
}

// ═══════════════════════════════════════════════════════════
// SSH Port Forwarding FFI
// ═══════════════════════════════════════════════════════════

/// Start local port forwarding: 127.0.0.1:local_port → remote_host:remote_port.
/// Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn pier_ssh_forward_port(
    handle: PierSshHandle,
    local_port: u16,
    remote_host: *const c_char,
    remote_port: u16,
) -> i32 {
    if handle.is_null() || remote_host.is_null() {
        return -1;
    }

    let session = unsafe { &mut *handle };
    let host_str = unsafe { CStr::from_ptr(remote_host).to_str().unwrap_or("") };

    // 10-second timeout: TcpListener::bind + SSH channel setup
    match ssh_runtime().block_on(
        tokio::time::timeout(
            std::time::Duration::from_secs(10),
            session.start_port_forward(local_port, host_str, remote_port),
        )
    ) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            log::error!("Port forward failed: {}", e);
            -1
        }
        Err(_) => {
            log::warn!("Port forward timed out after 10s for port {}", local_port);
            -1
        }
    }
}

/// Stop a local port forward.
/// Returns 0 on success, -1 if no such forward.
#[no_mangle]
pub extern "C" fn pier_ssh_stop_forward(handle: PierSshHandle, local_port: u16) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let session = unsafe { &mut *handle };
    match session.stop_port_forward(local_port) {
        Ok(()) => 0,
        Err(e) => {
            log::error!("Stop forward failed: {}", e);
            -1
        }
    }
}

/// List active forward ports as a JSON array.
/// Caller must free with pier_string_free.
#[no_mangle]
pub extern "C" fn pier_ssh_list_forwards(handle: PierSshHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let session = unsafe { &*handle };
    let ports = session.active_forwards();

    match serde_json::to_string(&ports) {
        Ok(json) => CString::new(json).unwrap_or_default().into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

// ═══════════════════════════════════════════════════════════
// Utility FFI
// ═══════════════════════════════════════════════════════════

/// Free a string allocated by Rust.
#[no_mangle]
pub extern "C" fn pier_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

/// Initialize the Rust logger.
#[no_mangle]
pub extern "C" fn pier_init() {
    let _ = env_logger::try_init();
    log::info!("Pier Core initialized");
}
