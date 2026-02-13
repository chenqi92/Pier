use std::os::fd::{FromRawFd, OwnedFd, AsRawFd};

/// Manages a pseudo-terminal (PTY) process on macOS/Unix.
pub struct PtyProcess {
    /// Master file descriptor of the PTY
    master_fd: OwnedFd,
    /// Child process ID
    pub child_pid: libc::pid_t,
}

impl PtyProcess {
    /// Spawn a new PTY process running the given shell.
    pub fn spawn(cols: u16, rows: u16, shell: &str) -> Result<Self, std::io::Error> {
        let mut master_fd: libc::c_int = 0;

        // Set up terminal size
        let mut win_size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        unsafe {
            let child_pid = libc::forkpty(
                &mut master_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut win_size,
            );

            if child_pid < 0 {
                return Err(std::io::Error::last_os_error());
            }

            if child_pid == 0 {
                // Child process: exec the shell
                let shell_c = std::ffi::CString::new(shell).unwrap();
                let args = [shell_c.as_ptr(), std::ptr::null()];

                // Set environment for proper terminal behavior
                let term = std::ffi::CString::new("TERM=xterm-256color").unwrap();
                libc::putenv(term.as_ptr() as *mut _);

                libc::execvp(shell_c.as_ptr(), args.as_ptr());
                // If exec fails, exit
                libc::_exit(1);
            }

            // Parent process
            // Set master fd to non-blocking
            let flags = libc::fcntl(master_fd, libc::F_GETFL);
            libc::fcntl(master_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);

            Ok(Self {
                master_fd: OwnedFd::from_raw_fd(master_fd),
                child_pid,
            })
        }
    }

    /// Resize the PTY.
    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), std::io::Error> {
        let win_size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        let result = unsafe {
            libc::ioctl(self.master_fd.as_raw_fd(), libc::TIOCSWINSZ, &win_size)
        };

        if result < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    /// Write data to the PTY master (sends input to the shell).
    pub fn write(&self, data: &[u8]) -> Result<(), std::io::Error> {
        let fd = self.master_fd.as_raw_fd();
        let result = unsafe {
            libc::write(fd, data.as_ptr() as *const libc::c_void, data.len())
        };
        if result < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    /// Read available data from the PTY master (output from the shell).
    pub fn read(&self) -> Result<Vec<u8>, std::io::Error> {
        let mut buf = vec![0u8; 65536];
        let fd = self.master_fd.as_raw_fd();
        let result = unsafe {
            libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
        };
        if result > 0 {
            buf.truncate(result as usize);
            Ok(buf)
        } else if result == 0 {
            Ok(Vec::new())
        } else {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::WouldBlock {
                Ok(Vec::new())
            } else {
                Err(err)
            }
        }
    }

    /// Get the raw file descriptor for polling/select.
    pub fn raw_fd(&self) -> i32 {
        self.master_fd.as_raw_fd()
    }
}

impl Drop for PtyProcess {
    fn drop(&mut self) {
        unsafe {
            let mut status: libc::c_int = 0;
            libc::kill(self.child_pid, libc::SIGTERM);
            libc::waitpid(self.child_pid, &mut status, libc::WNOHANG);
        }
    }
}
