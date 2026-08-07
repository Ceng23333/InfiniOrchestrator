//! Service discovery abstraction (etcd-backed)

pub mod etcd;
pub mod types;

pub use etcd::EtcdDiscovery;
pub use types::{DiscoveryInstance, RegistrationHandle, WatchEvent};

use async_trait::async_trait;

#[async_trait]
pub trait DiscoveryBackend: Send + Sync {
    /// Register an instance with a lease TTL (seconds)
    async fn register(
        &self,
        instance: &DiscoveryInstance,
        ttl_secs: i64,
    ) -> anyhow::Result<RegistrationHandle>;

    /// Refresh lease / keepalive for a registration
    async fn heartbeat(&self, handle: &RegistrationHandle) -> anyhow::Result<()>;

    /// Remove an instance registration
    async fn unregister(&self, handle: &RegistrationHandle) -> anyhow::Result<()>;

    /// List all instances under the discovery prefix
    async fn list_instances(&self) -> anyhow::Result<Vec<DiscoveryInstance>>;

    /// Watch instance changes; returns a stream of watch events
    async fn watch_instances(
        &self,
    ) -> anyhow::Result<tokio::sync::mpsc::Receiver<anyhow::Result<WatchEvent>>>;
}

/// Parse ETCD_ENDPOINTS env or comma-separated string into endpoint list
pub fn parse_etcd_endpoints(raw: &str) -> Vec<String> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            if s.starts_with("http://") || s.starts_with("https://") {
                s.to_string()
            } else {
                format!("http://{s}")
            }
        })
        .collect()
}

/// Default discovery prefix when not configured
pub fn default_discovery_prefix() -> String {
    std::env::var("DISCOVERY_PREFIX").unwrap_or_else(|_| "/infinilm".to_string())
}
