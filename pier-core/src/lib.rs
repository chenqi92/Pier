//! Pier Core — high-performance engine for Pier Terminal
//!
//! Provides terminal emulation, SSH/SFTP, file search, and crypto
//! through a C FFI interface consumed by Swift.

pub mod ffi;
pub mod terminal;
pub mod ssh;
pub mod search;
pub mod crypto;
