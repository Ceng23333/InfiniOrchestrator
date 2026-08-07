//! Shared discovery types

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Service instance registered in the discovery backend
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveryInstance {
    pub instance_id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub hostname: String,
    pub url: String,
    #[serde(default = "default_status")]
    pub status: String,
    #[serde(default)]
    pub metadata: HashMap<String, serde_json::Value>,
    #[serde(default = "default_weight")]
    pub weight: u32,
}

fn default_status() -> String {
    "running".to_string()
}

fn default_weight() -> u32 {
    1
}

impl DiscoveryInstance {
    pub fn instance_key(prefix: &str, instance_id: &str) -> String {
        format!(
            "{}/instances/{}",
            prefix.trim_end_matches('/'),
            instance_id
        )
    }

    pub fn is_healthy(&self) -> bool {
        self.status == "running"
    }
}

/// Handle returned after registering an instance (lease-backed)
#[derive(Debug, Clone)]
pub struct RegistrationHandle {
    pub instance_id: String,
    pub key: String,
    pub lease_id: i64,
}

/// Watch events from the discovery backend
#[derive(Debug, Clone)]
pub enum WatchEvent {
    Put(DiscoveryInstance),
    Delete { instance_id: String },
}
