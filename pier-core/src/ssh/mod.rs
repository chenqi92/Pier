pub mod session;
pub mod sftp;
pub mod service_detector;

/// SSH connection configuration.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct SshConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: SshAuth,
}

/// SSH authentication method.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub enum SshAuth {
    Password(String),
    KeyFile {
        path: String,
        passphrase: Option<String>,
    },
    Agent,
}

impl Default for SshConfig {
    fn default() -> Self {
        Self {
            host: "localhost".to_string(),
            port: 22,
            username: "root".to_string(),
            auth: SshAuth::Agent,
        }
    }
}
