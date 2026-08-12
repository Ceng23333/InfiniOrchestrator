//! InfiniEntrypoint module for service lifecycle management

pub mod config;
pub mod config_file;
pub mod discovery_client;
pub mod handlers;
pub mod probes;
pub mod process_manager;

use std::sync::Arc;
use std::time::Instant;
use tokio::sync::RwLock;
use config::EntrypointConfig;
use config_file::EntrypointConfigFile;
use uuid::Uuid;

/// Shared state for the entrypoint
#[derive(Clone)]
pub struct EntrypointState {
    pub config: EntrypointConfig,
    pub config_file: Option<EntrypointConfigFile>,
    pub process: Arc<RwLock<Option<tokio::process::Child>>>,
    pub service_port: Arc<RwLock<Option<u16>>>,
    pub start_time: Instant,
    pub started_at: String,
    pub server_id: String,
    pub restart_count: Arc<RwLock<u32>>,
    /// Cached models list for /metadata (filled by discovery when available).
    pub models_cache: Arc<RwLock<Vec<serde_json::Value>>>,
}

impl EntrypointState {
    pub fn new(config: EntrypointConfig, config_file: Option<EntrypointConfigFile>) -> Self {
        let started_at = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        Self {
            config,
            config_file,
            process: Arc::new(RwLock::new(None)),
            service_port: Arc::new(RwLock::new(None)),
            start_time: Instant::now(),
            started_at,
            server_id: Uuid::new_v4().to_string(),
            restart_count: Arc::new(RwLock::new(0)),
            models_cache: Arc::new(RwLock::new(Vec::new())),
        }
    }

    pub fn entrypoint_port(&self) -> u16 {
        self.config.port.expect("Port must be set") + 1
    }

    pub fn service_target_port(&self) -> u16 {
        self.config.port.expect("Port must be set")
    }

    pub async fn build_metadata_payload(&self, service_port: Option<u16>) -> serde_json::Value {
        let startup = probes::startup_args_from_config(&self.config, self.config_file.as_ref());
        let models = self.models_cache.read().await.clone();
        let model_id = models
            .first()
            .and_then(|m| m.get("id"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let model_path = self
            .config
            .path
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_default();

        let mut payload = serde_json::json!({
            "server_id": self.server_id,
            "started_at": self.started_at,
            "model_id": model_id,
            "model_path": model_path,
            "host": self.config.host,
            "port": service_port.unwrap_or_else(|| self.service_target_port()),
            "build_info": probes::collect_build_info(),
            "runtime_env": probes::collect_runtime_env(),
            "config": probes::collect_config(startup.clone()),
            "startup_args": startup,
            "artifact_dir": "",
            "frontend": probes::resolve_frontend(&self.config.service_type),
            "entrypoint": "enhanced",
            "service_name": self.config.service_name(),
        });

        if let Some(ref config_file) = self.config_file {
            if let Some(obj) = payload.as_object_mut() {
                for (key, value) in config_file.metadata_json() {
                    obj.insert(key, value);
                }
            }
        }

        if !models.is_empty() {
            if let Some(obj) = payload.as_object_mut() {
                obj.insert(
                    "models".into(),
                    serde_json::Value::Array(
                        models
                            .iter()
                            .filter_map(|m| {
                                m.get("id")
                                    .and_then(|v| v.as_str())
                                    .map(|s| serde_json::Value::String(s.to_string()))
                            })
                            .collect(),
                    ),
                );
                obj.insert("models_list".into(), serde_json::Value::Array(models));
            }
        }

        payload
    }
}

// Backward-compatible type alias
pub type BabysitterState = EntrypointState;
