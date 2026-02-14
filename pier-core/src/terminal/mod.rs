pub mod emulator;
pub mod pty;

use std::sync::{Arc, Mutex};
use crate::terminal::pty::PtyProcess;

/// Represents a terminal session with a PTY backend and VT parser.
pub struct TerminalSession {
    /// The PTY process backing this terminal
    pub pty: PtyProcess,
    /// Terminal grid dimensions
    pub cols: u16,
    pub rows: u16,
    /// Scrollback buffer: each line is a string of rendered characters
    pub scrollback: Arc<Mutex<Vec<String>>>,
    /// Current screen buffer (rows x cols)
    pub screen: Arc<Mutex<Vec<Vec<char>>>>,
}

impl TerminalSession {
    /// Create a new terminal session with given dimensions.
    pub fn new(cols: u16, rows: u16, shell: &str) -> Result<Self, std::io::Error> {
        let pty = PtyProcess::spawn(cols, rows, shell)?;
        let screen = vec![vec![' '; cols as usize]; rows as usize];
        Ok(Self {
            pty,
            cols,
            rows,
            scrollback: Arc::new(Mutex::new(Vec::new())),
            screen: Arc::new(Mutex::new(screen)),
        })
    }

    /// Create a new terminal session running a specific command with arguments.
    pub fn new_with_command(cols: u16, rows: u16, program: &str, args: &[&str]) -> Result<Self, std::io::Error> {
        let pty = PtyProcess::spawn_command(cols, rows, program, args)?;
        let screen = vec![vec![' '; cols as usize]; rows as usize];
        Ok(Self {
            pty,
            cols,
            rows,
            scrollback: Arc::new(Mutex::new(Vec::new())),
            screen: Arc::new(Mutex::new(screen)),
        })
    }

    /// Resize the terminal.
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), std::io::Error> {
        self.cols = cols;
        self.rows = rows;
        self.pty.resize(cols, rows)?;
        let mut screen = self.screen.lock().unwrap();
        screen.resize(rows as usize, vec![' '; cols as usize]);
        for row in screen.iter_mut() {
            row.resize(cols as usize, ' ');
        }
        Ok(())
    }

    /// Write input bytes to the PTY (user keystrokes).
    pub fn write(&mut self, data: &[u8]) -> Result<(), std::io::Error> {
        self.pty.write(data)
    }

    /// Read available output from the PTY.
    /// Returns the raw bytes for VT parsing.
    pub fn read(&mut self) -> Result<Vec<u8>, std::io::Error> {
        self.pty.read()
    }
}
