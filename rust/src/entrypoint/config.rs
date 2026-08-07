//! Configuration for InfiniEntrypoint

use clap::Parser;
use std::path::PathBuf;

#[derive(Parser, Debug, Clone)]
#[command(name = "infini-entrypoint")]
#[command(about = "InfiniEntrypoint for InfiniLM Services")]
pub struct EntrypointConfig {
    /// Service name (auto-generated if not provided)
    #[arg(long)]
    pub name: Option<String>,

    /// Host address
    #[arg(long, default_value = "localhost")]
    pub host: String,

    /// Service port (entrypoint will use port+1)
    /// Required if config_file is not provided
    #[arg(long)]
    pub port: Option<u16>,

    /// Service type: "InfiniLM", "InfiniLM-Rust", "vLLM", "mock", or "command"
    #[arg(long, default_value = "command")]
    pub service_type: String,

    /// Path to config file, model path, or command to run (depending on service_type)
    #[arg(long)]
    pub path: Option<PathBuf>,

    /// Command to run (for service_type="command")
    #[arg(long)]
    pub command: Option<String>,

    /// Command arguments (space-separated, for service_type="command")
    #[arg(long)]
    pub args: Option<String>,

    /// Working directory for the command
    #[arg(long)]
    pub work_dir: Option<PathBuf>,

    /// etcd endpoints (comma-separated). Overrides ETCD_ENDPOINTS env when set.
    #[arg(long, env = "ETCD_ENDPOINTS")]
    pub etcd_endpoints: Option<String>,

    /// Discovery key prefix. Overrides DISCOVERY_PREFIX env when set.
    #[arg(long, env = "DISCOVERY_PREFIX")]
    pub discovery_prefix: Option<String>,

    /// Deprecated: HTTP registry URL (use etcd discovery instead)
    #[arg(long, hide = true)]
    pub registry_url: Option<String>,

    /// Load balancer URL (optional, for future use)
    #[arg(long)]
    pub load_balancer_url: Option<String>,

    /// Deprecated alias for load_balancer_url
    #[arg(long, hide = true)]
    pub router_url: Option<String>,

    /// Maximum number of restarts
    #[arg(long, default_value = "10000")]
    pub max_restarts: u32,

    /// Delay between restarts (seconds)
    #[arg(long, default_value = "5")]
    pub restart_delay: u64,

    /// Heartbeat / lease TTL interval (seconds)
    #[arg(long, default_value = "30")]
    pub heartbeat_interval: u64,

    /// Configuration file (TOML format) - if provided, loads config from file
    #[arg(long)]
    pub config_file: Option<PathBuf>,

    /// Device type (for InfiniLM Python)
    #[arg(long)]
    pub dev: Option<String>,

    /// Number of devices (for InfiniLM Python)
    #[arg(long)]
    pub ndev: Option<u32>,

    /// Max batch size (for InfiniLM Python)
    #[arg(long)]
    pub max_batch: Option<u32>,

    /// Environment variables (key=value pairs, space-separated)
    #[arg(long, value_delimiter = ' ')]
    pub env: Vec<String>,
}

impl EntrypointConfig {
    pub fn service_name(&self) -> String {
        self.name.clone().unwrap_or_else(|| {
            let port_str = self
                .port
                .map(|p| p.to_string())
                .unwrap_or_else(|| "unknown".to_string());
            format!(
                "{}-{}",
                self.service_type.to_lowercase().replace(' ', "-"),
                port_str
            )
        })
    }

    pub fn is_command_based(&self) -> bool {
        self.service_type == "command" || self.command.is_some()
    }

    pub fn discovery_enabled(&self) -> bool {
        self.etcd_endpoints.is_some()
            || std::env::var("ETCD_ENDPOINTS").is_ok()
            || self.registry_url.is_some()
    }
}

pub type BabysitterConfig = EntrypointConfig;
