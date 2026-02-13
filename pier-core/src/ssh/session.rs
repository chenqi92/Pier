use super::{SshConfig, SshAuth};
use russh::*;
use russh::keys::*;
use std::sync::Arc;
use tokio::sync::Mutex;

/// SSH session manager.
pub struct SshSession {
    config: SshConfig,
    handle: Option<Arc<Mutex<client::Handle<SshHandler>>>>,
}

/// Minimal SSH client handler.
struct SshHandler;

impl client::Handler for SshHandler {
    type Error = anyhow::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // TODO: implement known_hosts checking for security
        // For now, accept all keys (INSECURE - must be fixed before release)
        log::warn!("Accepting server key without verification - implement known_hosts!");
        Ok(true)
    }
}

impl SshSession {
    pub fn new(config: SshConfig) -> Self {
        Self {
            config,
            handle: None,
        }
    }

    /// Establish an SSH connection.
    pub async fn connect(&mut self) -> Result<(), anyhow::Error> {
        let ssh_config = client::Config::default();
        let handler = SshHandler;

        let mut session = client::connect(
            Arc::new(ssh_config),
            (self.config.host.as_str(), self.config.port),
            handler,
        )
        .await?;

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
            let h = handle.lock().await;
            h.disconnect(Disconnect::ByApplication, "User disconnect", "en")
                .await?;
        }
        Ok(())
    }

    pub fn is_connected(&self) -> bool {
        self.handle.is_some()
    }
}
