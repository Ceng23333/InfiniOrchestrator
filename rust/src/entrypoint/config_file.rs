//! Configuration file support for InfiniEntrypoint

use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use toml::Value as TomlValue;

/// Entrypoint configuration file structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntrypointConfigFile {
    pub name: Option<String>,

    #[serde(default = "default_host")]
    pub host: String,

    pub port: u16,

    pub etcd_endpoints: Option<String>,
    pub discovery_prefix: Option<String>,

    /// Deprecated: HTTP registry URL
    pub registry_url: Option<String>,

    pub load_balancer_url: Option<String>,
    pub router_url: Option<String>,

    #[serde(default, alias = "babysitter")]
    pub entrypoint: EntrypointSettings,

    pub backend: BackendConfig,

    #[serde(default)]
    pub metadata: HashMap<String, TomlValue>,
}

fn default_host() -> String {
    "localhost".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntrypointSettings {
    #[serde(default = "default_max_restarts")]
    pub max_restarts: u32,

    #[serde(default = "default_restart_delay")]
    pub restart_delay: u64,

    #[serde(default = "default_heartbeat_interval")]
    pub heartbeat_interval: u64,
}

fn default_max_restarts() -> u32 {
    10000
}

fn default_restart_delay() -> u64 {
    5
}

fn default_heartbeat_interval() -> u64 {
    30
}

impl Default for EntrypointSettings {
    fn default() -> Self {
        Self {
            max_restarts: default_max_restarts(),
            restart_delay: default_restart_delay(),
            heartbeat_interval: default_heartbeat_interval(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum BackendConfig {
    #[serde(rename = "command")]
    Command {
        command: String,
        #[serde(default)]
        args: Vec<String>,
        work_dir: Option<PathBuf>,
        #[serde(default)]
        env: HashMap<String, String>,
    },

    #[serde(rename = "vllm")]
    #[allow(clippy::upper_case_acronyms)]
    VLLM {
        model: PathBuf,
        #[serde(default)]
        args: Vec<String>,
        work_dir: Option<PathBuf>,
        #[serde(default)]
        env: HashMap<String, String>,
    },

    #[serde(rename = "mock")]
    Mock {
        models: Vec<String>,
    },

    #[serde(rename = "infinilm-rust")]
    InfiniLMRust {
        config_file: PathBuf,
        work_dir: Option<PathBuf>,
    },

    #[serde(rename = "infinilm")]
    InfiniLM {
        model_path: PathBuf,
        #[serde(default)]
        args: Vec<String>,
        work_dir: Option<PathBuf>,
        #[serde(default)]
        env: HashMap<String, String>,
    },
}

impl EntrypointConfigFile {
    pub fn from_file<P: AsRef<std::path::Path>>(path: P) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path.as_ref())
            .with_context(|| format!("Failed to read config file: {:?}", path.as_ref()))?;

        let config: EntrypointConfigFile = toml::from_str(&content)
            .with_context(|| format!("Failed to parse TOML config file: {:?}", path.as_ref()))?;

        Ok(config)
    }

    pub fn to_cli_config(&self) -> super::config::EntrypointConfig {
        use super::config::EntrypointConfig;

        EntrypointConfig {
            name: self.name.clone(),
            host: self.host.clone(),
            port: Some(self.port),
            service_type: self.backend.service_type_name().to_string(),
            path: self.backend.path(),
            command: self.backend.command(),
            args: self.backend.args_string(),
            work_dir: self.backend.work_dir(),
            etcd_endpoints: self.etcd_endpoints.clone(),
            discovery_prefix: self.discovery_prefix.clone(),
            registry_url: self.registry_url.clone(),
            load_balancer_url: self
                .load_balancer_url
                .clone()
                .or_else(|| self.router_url.clone()),
            router_url: self.router_url.clone(),
            max_restarts: self.entrypoint.max_restarts,
            restart_delay: self.entrypoint.restart_delay,
            heartbeat_interval: self.entrypoint.heartbeat_interval,
            config_file: None,
            dev: None,
            ndev: None,
            max_batch: None,
            env: vec![],
        }
    }

    pub fn backend_env(&self) -> HashMap<String, String> {
        self.backend.env()
    }

    pub fn metadata_json(&self) -> HashMap<String, serde_json::Value> {
        self.metadata
            .iter()
            .filter_map(|(k, v)| toml_to_json_value(v).ok().map(|json_val| (k.clone(), json_val)))
            .collect()
    }
}

pub type BabysitterConfigFile = EntrypointConfigFile;

fn toml_to_json_value(toml_val: &TomlValue) -> Result<serde_json::Value, serde_json::Error> {
    match toml_val {
        TomlValue::String(s) => Ok(serde_json::Value::String(s.clone())),
        TomlValue::Integer(i) => Ok(serde_json::Value::Number(serde_json::Number::from(*i))),
        TomlValue::Float(f) => serde_json::Number::from_f64(*f)
            .map(serde_json::Value::Number)
            .ok_or_else(|| {
                serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Invalid float",
                ))
            }),
        TomlValue::Boolean(b) => Ok(serde_json::Value::Bool(*b)),
        TomlValue::Datetime(dt) => Ok(serde_json::Value::String(dt.to_string())),
        TomlValue::Array(arr) => arr
            .iter()
            .map(toml_to_json_value)
            .collect::<Result<Vec<_>, _>>()
            .map(serde_json::Value::Array),
        TomlValue::Table(table) => table
            .iter()
            .map(|(k, v)| toml_to_json_value(v).map(|val| (k.clone(), val)))
            .collect::<Result<HashMap<String, _>, _>>()
            .map(|map| serde_json::Value::Object(map.into_iter().collect())),
    }
}

impl BackendConfig {
    fn service_type_name(&self) -> &'static str {
        match self {
            BackendConfig::Command { .. } => "command",
            BackendConfig::VLLM { .. } => "vLLM",
            BackendConfig::Mock { .. } => "mock",
            BackendConfig::InfiniLMRust { .. } => "InfiniLM-Rust",
            BackendConfig::InfiniLM { .. } => "InfiniLM",
        }
    }

    fn path(&self) -> Option<PathBuf> {
        match self {
            BackendConfig::VLLM { model, .. } => Some(model.clone()),
            BackendConfig::InfiniLMRust { config_file, .. } => Some(config_file.clone()),
            BackendConfig::InfiniLM { model_path, .. } => Some(model_path.clone()),
            _ => None,
        }
    }

    fn command(&self) -> Option<String> {
        match self {
            BackendConfig::Command { command, .. } => Some(command.clone()),
            _ => None,
        }
    }

    fn args_string(&self) -> Option<String> {
        match self {
            BackendConfig::Command { args, .. }
            | BackendConfig::VLLM { args, .. }
            | BackendConfig::InfiniLM { args, .. } => {
                if args.is_empty() {
                    None
                } else {
                    Some(args.join(" "))
                }
            }
            BackendConfig::Mock { models } => Some(models.join(",")),
            _ => None,
        }
    }

    fn work_dir(&self) -> Option<PathBuf> {
        match self {
            BackendConfig::Command { work_dir, .. }
            | BackendConfig::VLLM { work_dir, .. }
            | BackendConfig::InfiniLMRust { work_dir, .. }
            | BackendConfig::InfiniLM { work_dir, .. } => work_dir.clone(),
            _ => None,
        }
    }

    pub fn env(&self) -> HashMap<String, String> {
        match self {
            BackendConfig::Command { env, .. }
            | BackendConfig::VLLM { env, .. }
            | BackendConfig::InfiniLM { env, .. } => env.clone(),
            _ => HashMap::new(),
        }
    }
}
