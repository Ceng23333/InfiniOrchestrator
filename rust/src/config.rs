//! Configuration management for InfiniLoadBalancer

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

/// Load balancer configuration
#[derive(Debug, Clone)]
pub struct Config {
    pub load_balancer_port: u16,
    pub etcd_endpoints: Option<Vec<String>>,
    pub discovery_prefix: String,
    /// Deprecated: HTTP registry URL
    pub registry_url: Option<String>,
    pub static_services: Option<Vec<StaticService>>,
    pub health_check_interval: u64,
    pub health_check_timeout: u64,
    pub max_errors: u32,
    pub discovery_sync_interval: u64,
    pub service_removal_grace_period: u64,
}

/// Static service configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaticService {
    pub name: String,
    pub host: String,
    pub port: u16,
    #[serde(default = "default_weight")]
    pub weight: u32,
    #[serde(default)]
    pub metadata: serde_json::Value,
}

fn default_weight() -> u32 {
    1
}

impl Config {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        load_balancer_port: u16,
        etcd_endpoints: Option<String>,
        discovery_prefix: Option<String>,
        registry_url: Option<String>,
        static_services_file: Option<String>,
        health_check_interval: u64,
        health_check_timeout: u64,
        max_errors: u32,
        discovery_sync_interval: u64,
        service_removal_grace_period: u64,
    ) -> Result<Self> {
        let static_services = if let Some(file_path) = static_services_file {
            Some(Self::load_static_services(&file_path)?)
        } else {
            None
        };

        let parsed_endpoints = etcd_endpoints.map(|raw| {
            crate::discovery::parse_etcd_endpoints(&raw)
        }).filter(|v| !v.is_empty());

        Ok(Config {
            load_balancer_port,
            etcd_endpoints: parsed_endpoints,
            discovery_prefix: discovery_prefix
                .or_else(|| std::env::var("DISCOVERY_PREFIX").ok())
                .unwrap_or_else(|| "/infinilm".to_string()),
            registry_url,
            static_services,
            health_check_interval,
            health_check_timeout,
            max_errors,
            discovery_sync_interval,
            service_removal_grace_period,
        })
    }

    pub fn discovery_enabled(&self) -> bool {
        self.etcd_endpoints.as_ref().is_some_and(|e| !e.is_empty())
            || std::env::var("ETCD_ENDPOINTS").is_ok()
    }

    /// Backward-compatible alias
    pub fn router_port(&self) -> u16 {
        self.load_balancer_port
    }

    fn load_static_services<P: AsRef<Path>>(file_path: P) -> Result<Vec<StaticService>> {
        let content = fs::read_to_string(&file_path).with_context(|| {
            format!(
                "Failed to read static services file: {:?}",
                file_path.as_ref()
            )
        })?;

        let config: serde_json::Value =
            serde_json::from_str(&content).context("Failed to parse static services JSON")?;

        let services = if let Some(services_array) = config
            .get("static_services")
            .and_then(|v| v.get("services"))
            .and_then(|v| v.as_array())
        {
            services_array
        } else if let Some(services_array) = config.get("services").and_then(|v| v.as_array()) {
            services_array
        } else if let Some(services_array) = config.as_array() {
            services_array
        } else {
            anyhow::bail!("Invalid static services format: expected array or object with 'services' or 'static_services.services' key");
        };

        let static_services: Vec<StaticService> =
            serde_json::from_value(serde_json::Value::Array(services.clone()))
                .context("Failed to deserialize static services")?;

        Ok(static_services)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_static_services() {
        let json = r#"
        {
            "services": [
                {
                    "name": "test-service",
                    "host": "localhost",
                    "port": 8080,
                    "weight": 1
                }
            ]
        }
        "#;

        let temp_file = std::env::temp_dir().join("test_services.json");
        std::fs::write(&temp_file, json).unwrap();

        let services = Config::load_static_services(&temp_file).unwrap();
        assert_eq!(services.len(), 1);
        assert_eq!(services[0].name, "test-service");

        std::fs::remove_file(&temp_file).unwrap();
    }
}
