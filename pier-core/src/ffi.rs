//! C FFI interface for Swift integration.
//!
//! All functions exported here are callable from Swift via the C bridge.
//! Naming convention: pier_<module>_<action>

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use crate::terminal::TerminalSession;
use crate::search;

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
