use std::path::Path;
use russh_sftp::client::SftpSession;
use serde::{Serialize, Deserialize};

/// Represents a remote file entry.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RemoteFileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: Option<u64>,
    pub permissions: Option<u32>,
}

/// SFTP operations wrapper.
pub struct SftpClient {
    session: Option<SftpSession>,
}

impl SftpClient {
    pub fn new() -> Self {
        Self { session: None }
    }

    /// Initialize SFTP session from an existing SSH channel.
    pub async fn init(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
    ) -> Result<(), anyhow::Error> {
        channel.request_subsystem(false, "sftp").await?;
        let sftp = SftpSession::new(channel.into_stream()).await?;
        self.session = Some(sftp);
        Ok(())
    }

    /// List directory contents on the remote server.
    pub async fn list_dir(&self, path: &str) -> Result<Vec<RemoteFileEntry>, anyhow::Error> {
        let sftp = self
            .session
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("SFTP session not initialized"))?;

        let dir = sftp.read_dir(path).await?;
        let mut entries = Vec::new();

        for entry in dir {
            let name = entry.file_name();
            if name == "." || name == ".." {
                continue;
            }
            let file_path = format!("{}/{}", path.trim_end_matches('/'), name);
            let is_dir = entry.file_type().is_dir();
            let size = entry.metadata().size.unwrap_or(0);
            let modified = entry.metadata().mtime.map(|v| v as u64);

            entries.push(RemoteFileEntry {
                name,
                path: file_path,
                is_dir,
                size,
                modified,
                permissions: entry.metadata().permissions,
            });
        }

        // Sort: directories first, then files, alphabetically
        entries.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });

        Ok(entries)
    }

    /// Download a file from remote to local path.
    pub async fn download(
        &self,
        remote_path: &str,
        local_path: &Path,
    ) -> Result<(), anyhow::Error> {
        let sftp = self
            .session
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("SFTP session not initialized"))?;

        let data = sftp.read(remote_path).await?;
        tokio::fs::write(local_path, data).await?;

        log::info!(
            "Downloaded {} -> {}",
            remote_path,
            local_path.display()
        );
        Ok(())
    }

    /// Upload a local file to remote path.
    pub async fn upload(
        &self,
        local_path: &Path,
        remote_path: &str,
    ) -> Result<(), anyhow::Error> {
        let sftp = self
            .session
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("SFTP session not initialized"))?;

        let data = tokio::fs::read(local_path).await?;
        sftp.write(remote_path, &data).await?;

        log::info!(
            "Uploaded {} -> {}",
            local_path.display(),
            remote_path
        );
        Ok(())
    }

    /// Remove a file on the remote server.
    pub async fn remove_file(&self, path: &str) -> Result<(), anyhow::Error> {
        let sftp = self
            .session
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("SFTP session not initialized"))?;
        sftp.remove_file(path).await?;
        Ok(())
    }

    /// Create a directory on the remote server.
    pub async fn create_dir(&self, path: &str) -> Result<(), anyhow::Error> {
        let sftp = self
            .session
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("SFTP session not initialized"))?;
        sftp.create_dir(path).await?;
        Ok(())
    }

    /// Get the current working directory of the SFTP session.
    pub async fn pwd(&self) -> Result<String, anyhow::Error> {
        let sftp = self
            .session
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("SFTP session not initialized"))?;
        let path = sftp.canonicalize(".").await?;
        Ok(path)
    }
}
