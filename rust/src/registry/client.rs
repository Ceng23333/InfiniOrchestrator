//! Deprecated HTTP registry client stub

use anyhow::{bail, Result};

/// Deprecated registry HTTP client
pub struct RegistryClient;

impl RegistryClient {
    pub fn new(_registry_url: String) -> Self {
        Self
    }

    pub async fn fetch_services(&self, _healthy_only: bool) -> Result<RegistryServicesResponse> {
        bail!("HTTP registry has been removed; configure etcd discovery instead")
    }

    pub async fn check_health(&self) -> Result<bool> {
        Ok(false)
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RegistryService {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub url: String,
    pub hostname: String,
    pub status: String,
    pub timestamp: String,
    #[serde(default)]
    pub metadata: std::collections::HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub is_healthy: bool,
    #[serde(default)]
    pub weight: u32,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct RegistryServicesResponse {
    pub services: Vec<RegistryService>,
    #[serde(default)]
    pub total: usize,
}
