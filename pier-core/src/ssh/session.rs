use super::{SshConfig, SshAuth};
use russh::*;
use russh::keys::*;
use std::sync::Arc;
use std::collections::HashMap;
use tokio::sync::Mutex;
use tokio::sync::watch;
use tokio::net::TcpListener;

/// SSH session manager.
pub struct SshSession {
    config: SshConfig,
    handle: Option<Arc<Mutex<client::Handle<SshHandler>>>>,
    /// Active port forwards: local_port → cancel sender (send true to stop)
    forwards: HashMap<u16, watch::Sender<bool>>,
}

/// Minimal SSH client handler with host key verification.
struct SshHandler {
    /// Hostname for known_hosts lookup.
    host: String,
    /// Port for known_hosts lookup.
    port: u16,
}

impl client::Handler for SshHandler {
    type Error = anyhow::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        use russh::keys::known_hosts::{check_known_hosts, learn_known_hosts};

        match check_known_hosts(&self.host, self.port, server_public_key) {
            Ok(true) => {
                log::info!("Host key verified for {}:{}", self.host, self.port);
                Ok(true)
            }
            Ok(false) => {
                // Key mismatch — possible MITM attack.
                log::error!(
                    "HOST KEY MISMATCH for {}:{} — possible MITM attack! Connection rejected.",
                    self.host, self.port
                );
                Err(anyhow::anyhow!(
                    "Host key mismatch for {}:{}. The server's key has changed, which could indicate a man-in-the-middle attack. \
                     If you trust this change, remove the old key from ~/.ssh/known_hosts and reconnect.",
                    self.host, self.port
                ))
            }
            Err(_) => {
                // Host not found in known_hosts — Trust On First Use (TOFU).
                log::info!("New host key for {}:{} — adding to known_hosts (TOFU)", self.host, self.port);
                if let Err(e) = learn_known_hosts(&self.host, self.port, server_public_key) {
                    log::warn!("Failed to save host key: {}", e);
                }
                Ok(true)
            }
        }
    }
}

impl SshSession {
    pub fn new(config: SshConfig) -> Self {
        Self {
            config,
            handle: None,
            forwards: HashMap::new(),
        }
    }

    /// Establish an SSH connection.
    pub async fn connect(&mut self) -> Result<(), anyhow::Error> {
        let ssh_config = client::Config::default();
        let handler = SshHandler {
            host: self.config.host.clone(),
            port: self.config.port,
        };

        // 10-second timeout for TCP connect to avoid blocking indefinitely
        // when the target host is unreachable (e.g. network change).
        let mut session = match tokio::time::timeout(
            std::time::Duration::from_secs(10),
            client::connect(
                Arc::new(ssh_config),
                (self.config.host.as_str(), self.config.port),
                handler,
            ),
        ).await {
            Ok(result) => result?,
            Err(_) => return Err(anyhow::anyhow!("SSH connect timed out after 10s")),
        };

        // Authenticate
        let result = match &self.config.auth {
            SshAuth::Password(password) => {
                session
                    .authenticate_password(&self.config.username, password)
                    .await?
            }
            SshAuth::KeyFile { path, passphrase } => {
                let key_pair = load_secret_key(path, passphrase.as_deref())?;
                let pk = PrivateKeyWithHashAlg::new(
                    Arc::new(key_pair),
                    None, // Use default hash algorithm
                );
                session
                    .authenticate_publickey(&self.config.username, pk)
                    .await?
            }
            SshAuth::Agent => {
                // TODO: implement SSH agent forwarding
                return Err(anyhow::anyhow!("SSH Agent auth not yet implemented"));
            }
        };

        match result {
            client::AuthResult::Success => {},
            client::AuthResult::Failure { .. } => {
                return Err(anyhow::anyhow!("SSH authentication failed"));
            }
        }

        self.handle = Some(Arc::new(Mutex::new(session)));
        log::info!("SSH connected to {}:{}", self.config.host, self.config.port);
        Ok(())
    }

    /// Open an interactive shell channel.
    pub async fn open_shell(
        &self,
        cols: u32,
        rows: u32,
    ) -> Result<russh::Channel<client::Msg>, anyhow::Error> {
        let handle = self
            .handle
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Not connected"))?;

        let handle = handle.lock().await;
        let channel = handle.channel_open_session().await?;

        channel
            .request_pty(false, "xterm-256color", cols, rows, 0, 0, &[])
            .await?;
        channel.request_shell(false).await?;

        Ok(channel)
    }

    /// Disconnect the SSH session.
    pub async fn disconnect(&mut self) -> Result<(), anyhow::Error> {
        if let Some(handle) = self.handle.take() {
            // 5-second timeout: if the server is unreachable, the disconnect
            // handshake will hang. We'd rather drop the handle than block.
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(5),
                async {
                    let h = handle.lock().await;
                    h.disconnect(Disconnect::ByApplication, "User disconnect", "en")
                        .await
                },
            ).await;
            match result {
                Ok(Ok(())) => {},
                Ok(Err(e)) => log::warn!("SSH disconnect error: {}", e),
                Err(_) => log::warn!("SSH disconnect timed out, dropping handle"),
            }
        }
        Ok(())
    }

    pub fn is_connected(&self) -> bool {
        self.handle.is_some()
    }

    /// Start local port forwarding: 127.0.0.1:local_port → remote_host:remote_port
    ///
    /// Spawns an async TCP listener. Each incoming connection opens
    /// an SSH direct-tcpip channel for bidirectional data transfer.
    pub async fn start_port_forward(
        &mut self,
        local_port: u16,
        remote_host: &str,
        remote_port: u16,
    ) -> Result<(), anyhow::Error> {
        if self.forwards.contains_key(&local_port) {
            return Err(anyhow::anyhow!("Port {} already forwarded", local_port));
        }

        let handle = self
            .handle
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Not connected"))?
            .clone();

        let listener = TcpListener::bind(format!("127.0.0.1:{}", local_port)).await?;
        let (cancel_tx, cancel_rx) = watch::channel(false);
        let rhost = remote_host.to_string();

        log::info!(
            "SSH tunnel: 127.0.0.1:{} → {}:{}",
            local_port, remote_host, remote_port
        );

        tokio::spawn(async move {
            let mut rx = cancel_rx;
            loop {
                tokio::select! {
                    _ = async { loop {
                        if rx.changed().await.is_err() || *rx.borrow() { break; }
                    }} => {
                        log::info!("Port forward on {} cancelled", local_port);
                        break;
                    }
                    result = listener.accept() => {
                        match result {
                            Ok((mut tcp_stream, peer)) => {
                                log::debug!("Tunnel connection from {} on port {}", peer, local_port);
                                let h = handle.clone();
                                let host = rhost.clone();
                                let conn_rx = rx.clone();
                                tokio::spawn(async move {
                                    if let Err(e) = Self::handle_forward_connection(
                                        &h, &mut tcp_stream, &host, remote_port, conn_rx,
                                    ).await {
                                        log::debug!("Tunnel connection ended: {}", e);
                                    }
                                });
                            }
                            Err(e) => {
                                log::error!("Tunnel accept error on port {}: {}", local_port, e);
                            }
                        }
                    }
                }
            }
        });

        self.forwards.insert(local_port, cancel_tx);
        Ok(())
    }

    /// Handle a single forwarded connection.
    async fn handle_forward_connection(
        handle: &Arc<Mutex<client::Handle<SshHandler>>>,
        tcp_stream: &mut tokio::net::TcpStream,
        remote_host: &str,
        remote_port: u16,
        mut cancel_rx: watch::Receiver<bool>,
    ) -> Result<(), anyhow::Error> {
        let h = handle.lock().await;
        let mut channel = h
            .channel_open_direct_tcpip(
                remote_host,
                remote_port as u32,
                "127.0.0.1",
                0, // originator port, not important
            )
            .await?;
        drop(h); // Release the lock

        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (mut tcp_read, mut tcp_write) = tcp_stream.split();
        let mut buf = vec![0u8; 8192];

        loop {
            tokio::select! {
                res = cancel_rx.changed() => {
                    if res.is_err() || *cancel_rx.borrow() { break; }
                }
                // TCP → SSH channel
                n = tcp_read.read(&mut buf) => {
                    match n {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if channel.data(&buf[..n]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
                // SSH channel → TCP
                msg = channel.wait() => {
                    match msg {
                        Some(russh::ChannelMsg::Data { ref data }) => {
                            if tcp_write.write_all(data).await.is_err() {
                                break;
                            }
                        }
                        Some(russh::ChannelMsg::Eof) | None => break,
                        _ => {}
                    }
                }
            }
        }

        Ok(())
    }

    /// Stop a port forward.
    pub fn stop_port_forward(&mut self, local_port: u16) -> Result<(), anyhow::Error> {
        if let Some(tx) = self.forwards.remove(&local_port) {
            let _ = tx.send(true);
            log::info!("Stopped port forward on {}", local_port);
            Ok(())
        } else {
            Err(anyhow::anyhow!("No forward on port {}", local_port))
        }
    }

    /// Stop all port forwards.
    pub fn stop_all_forwards(&mut self) {
        for (port, tx) in self.forwards.drain() {
            let _ = tx.send(true);
            log::info!("Stopped port forward on {}", port);
        }
    }

    /// List active forwarded local ports.
    pub fn active_forwards(&self) -> Vec<u16> {
        self.forwards.keys().copied().collect()
    }

    /// Execute a single command over SSH and return (exit_code, stdout).
    pub async fn exec_command(&self, command: &str) -> Result<(i32, String), anyhow::Error> {
        let handle = self
            .handle
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Not connected"))?;

        let handle = handle.lock().await;
        let mut channel = handle.channel_open_session().await?;
        channel.exec(true, command).await?;

        let mut stdout = Vec::new();
        let mut exit_code: i32 = -1;
        let mut got_eof = false;

        // Overall command timeout: 60 seconds max for the entire command.
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(60);

        loop {
            // Check overall deadline
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                log::warn!("SSH exec overall timeout (60s) for command: {}", command);
                break;
            }

            // Per-message timeout: min of 10s and remaining overall time
            let msg_timeout = remaining.min(std::time::Duration::from_secs(10));
            match tokio::time::timeout(msg_timeout, channel.wait()).await {
                Ok(Some(msg)) => {
                    match msg {
                        russh::ChannelMsg::Data { ref data } => {
                            stdout.extend_from_slice(data);
                        }
                        russh::ChannelMsg::ExtendedData { ref data, .. } => {
                            // stderr — append to stdout for simplicity
                            stdout.extend_from_slice(data);
                        }
                        russh::ChannelMsg::ExitStatus { exit_status } => {
                            exit_code = exit_status as i32;
                            // If we already got EOF, we're done
                            if got_eof { break; }
                        }
                        russh::ChannelMsg::Eof => {
                            got_eof = true;
                            // If we already have an exit code, we're done
                            if exit_code != -1 { break; }
                            // Otherwise continue to wait for ExitStatus
                        }
                        russh::ChannelMsg::Close => {
                            break;
                        }
                        _ => {}
                    }
                }
                Ok(None) => break, // Channel closed
                Err(_) => {
                    // Timeout — command took too long
                    log::warn!("SSH exec timeout for command: {}", command);
                    break;
                }
            }
        }

        let output = String::from_utf8_lossy(&stdout).trim().to_string();
        Ok((exit_code, output))
    }
}
