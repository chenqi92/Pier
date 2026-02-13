//! Service detection over SSH.
//!
//! Probes a remote server for installed services (MySQL, Redis, Docker, PostgreSQL)
//! by executing lightweight detection commands via SSH exec.

use super::session::SshSession;
use serde::{Deserialize, Serialize};

/// Status of a detected service.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ServiceStatus {
    Running,
    Stopped,
    Installed,
}

/// A service detected on the remote server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectedService {
    pub name: String,
    pub version: String,
    pub status: ServiceStatus,
    pub port: u16,
}

/// Detect all known services on the remote server.
pub async fn detect_all(session: &SshSession) -> Vec<DetectedService> {
    let mut services = Vec::new();

    // Run all detections concurrently
    let (mysql, redis, postgres, docker) = tokio::join!(
        detect_mysql(session),
        detect_redis(session),
        detect_postgresql(session),
        detect_docker(session),
    );

    if let Some(s) = mysql { services.push(s); }
    if let Some(s) = redis { services.push(s); }
    if let Some(s) = postgres { services.push(s); }
    if let Some(s) = docker { services.push(s); }

    log::info!("Detected {} services on remote server", services.len());
    services
}

/// Detect MySQL/MariaDB
async fn detect_mysql(session: &SshSession) -> Option<DetectedService> {
    // Check if mysql or mysqld exists
    let (code, _) = session.exec_command("which mysql 2>/dev/null || which mysqld 2>/dev/null").await.ok()?;
    if code != 0 { return None; }

    // Get version
    let (_, version_out) = session.exec_command("mysql --version 2>/dev/null").await.unwrap_or((-1, String::new()));
    let version = parse_version(&version_out, "mysql");

    // Check if running
    let status = check_service_status(session, &[
        "systemctl is-active mysql 2>/dev/null || systemctl is-active mysqld 2>/dev/null || systemctl is-active mariadb 2>/dev/null",
        "pgrep -x mysqld >/dev/null 2>&1 && echo active",
    ]).await;

    Some(DetectedService {
        name: "mysql".to_string(),
        version,
        status,
        port: 3306,
    })
}

/// Detect Redis
async fn detect_redis(session: &SshSession) -> Option<DetectedService> {
    let (code, _) = session.exec_command("which redis-server 2>/dev/null || which redis-cli 2>/dev/null").await.ok()?;
    if code != 0 { return None; }

    let (_, version_out) = session.exec_command("redis-cli --version 2>/dev/null").await.unwrap_or((-1, String::new()));
    let version = parse_version(&version_out, "redis");

    // Try ping — if it responds, redis is running
    let (ping_code, ping_out) = session.exec_command("redis-cli ping 2>/dev/null").await.unwrap_or((-1, String::new()));
    let status = if ping_code == 0 && ping_out.contains("PONG") {
        ServiceStatus::Running
    } else {
        // Check systemctl / pgrep
        check_service_status(session, &[
            "systemctl is-active redis 2>/dev/null || systemctl is-active redis-server 2>/dev/null",
            "pgrep -x redis-server >/dev/null 2>&1 && echo active",
        ]).await
    };

    Some(DetectedService {
        name: "redis".to_string(),
        version,
        status,
        port: 6379,
    })
}

/// Detect PostgreSQL
async fn detect_postgresql(session: &SshSession) -> Option<DetectedService> {
    let (code, _) = session.exec_command("which psql 2>/dev/null").await.ok()?;
    if code != 0 { return None; }

    let (_, version_out) = session.exec_command("psql --version 2>/dev/null").await.unwrap_or((-1, String::new()));
    let version = parse_version(&version_out, "psql");

    let status = check_service_status(session, &[
        "systemctl is-active postgresql 2>/dev/null",
        "pgrep -x postgres >/dev/null 2>&1 && echo active",
    ]).await;

    Some(DetectedService {
        name: "postgresql".to_string(),
        version,
        status,
        port: 5432,
    })
}

/// Detect Docker
async fn detect_docker(session: &SshSession) -> Option<DetectedService> {
    let (code, _) = session.exec_command("which docker 2>/dev/null").await.ok()?;
    if code != 0 { return None; }

    let (_, version_out) = session.exec_command("docker --version 2>/dev/null").await.unwrap_or((-1, String::new()));
    let version = parse_version(&version_out, "docker");

    // docker info succeeds only if daemon is running
    let (info_code, _) = session.exec_command("docker info >/dev/null 2>&1").await.unwrap_or((-1, String::new()));
    let status = if info_code == 0 {
        ServiceStatus::Running
    } else {
        check_service_status(session, &[
            "systemctl is-active docker 2>/dev/null",
        ]).await
    };

    Some(DetectedService {
        name: "docker".to_string(),
        version,
        status,
        port: 0, // Docker doesn't use a specific tunnel port
    })
}

/// Check if a service is running via multiple fallback commands.
async fn check_service_status(session: &SshSession, commands: &[&str]) -> ServiceStatus {
    for cmd in commands {
        if let Ok((code, output)) = session.exec_command(cmd).await {
            if code == 0 && output.contains("active") {
                return ServiceStatus::Running;
            }
        }
    }
    // Service binary exists but isn't running
    ServiceStatus::Stopped
}

/// Extract version string from command output.
fn parse_version(output: &str, _tool: &str) -> String {
    // Common patterns:
    // - "mysql  Ver 8.0.35 Distrib 8.0.35, ..."
    // - "redis-cli 7.0.11"
    // - "psql (PostgreSQL) 15.4"
    // - "Docker version 24.0.5, ..."

    // Try to extract a version-like pattern (digits.digits.digits)
    for word in output.split_whitespace() {
        let trimmed = word.trim_end_matches(',').trim_end_matches(';');
        if trimmed.chars().next().map_or(false, |c| c.is_ascii_digit())
            && trimmed.contains('.')
        {
            return trimmed.to_string();
        }
    }

    // Fallback: return first line
    output.lines().next().unwrap_or("unknown").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_version_mysql() {
        let output = "mysql  Ver 8.0.35 Distrib 8.0.35, for Linux on x86_64";
        assert_eq!(parse_version(output, "mysql"), "8.0.35");
    }

    #[test]
    fn test_parse_version_redis() {
        let output = "redis-cli 7.0.11";
        assert_eq!(parse_version(output, "redis"), "7.0.11");
    }

    #[test]
    fn test_parse_version_docker() {
        let output = "Docker version 24.0.5, build ced0996";
        assert_eq!(parse_version(output, "docker"), "24.0.5");
    }

    #[test]
    fn test_parse_version_psql() {
        let output = "psql (PostgreSQL) 15.4";
        assert_eq!(parse_version(output, "psql"), "15.4");
    }

    #[test]
    fn test_detected_service_json() {
        let service = DetectedService {
            name: "mysql".to_string(),
            version: "8.0.35".to_string(),
            status: ServiceStatus::Running,
            port: 3306,
        };
        let json = serde_json::to_string(&service).unwrap();
        assert!(json.contains("\"status\":\"running\""));
        assert!(json.contains("\"port\":3306"));
    }
}
