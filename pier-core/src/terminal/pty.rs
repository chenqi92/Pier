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
        Self::spawn_command(cols, rows, shell, &["-l"])
    }

    /// Spawn a new PTY process running the given command with explicit arguments.
    pub fn spawn_command(cols: u16, rows: u16, program: &str, args: &[&str]) -> Result<Self, std::io::Error> {
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
                // Child process: exec the command with given args
                let program_c = std::ffi::CString::new(program).unwrap();
                let args_c: Vec<std::ffi::CString> = std::iter::once(program.to_string())
                    .chain(args.iter().map(|s| s.to_string()))
                    .map(|s| std::ffi::CString::new(s).unwrap())
                    .collect();
                let args_ptrs: Vec<*const libc::c_char> = args_c.iter()
                    .map(|s| s.as_ptr())
                    .chain(std::iter::once(std::ptr::null()))
                    .collect();

                // Set environment for proper terminal behavior
                let term = std::ffi::CString::new("TERM=xterm-256color").unwrap();
                libc::putenv(term.as_ptr() as *mut _);

                // Set locale for proper UTF-8 handling (prevents <0080> artifacts)
                let lang = std::ffi::CString::new("LANG=en_US.UTF-8").unwrap();
                libc::putenv(lang.as_ptr() as *mut _);
                let lc_all = std::ffi::CString::new("LC_ALL=en_US.UTF-8").unwrap();
                libc::putenv(lc_all.as_ptr() as *mut _);

                libc::execvp(program_c.as_ptr(), args_ptrs.as_ptr());
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
            // Send SIGTERM for graceful shutdown
            libc::kill(self.child_pid, libc::SIGTERM);

            // Wait briefly for graceful exit (non-blocking check)
            let mut status: libc::c_int = 0;
            let waited = libc::waitpid(self.child_pid, &mut status, libc::WNOHANG);

            if waited == 0 {
                // Child still running — give it a moment, then force kill
                std::thread::sleep(std::time::Duration::from_millis(100));
                let waited2 = libc::waitpid(self.child_pid, &mut status, libc::WNOHANG);
                if waited2 == 0 {
                    libc::kill(self.child_pid, libc::SIGKILL);
                    // Blocking wait to ensure zombie is reaped
                    libc::waitpid(self.child_pid, &mut status, 0);
                }
            }
        }
    }
}
