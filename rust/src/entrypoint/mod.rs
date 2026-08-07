//! InfiniEntrypoint module for service lifecycle management

pub mod config;
pub mod config_file;
pub mod discovery_client;
pub mod handlers;
pub mod process_manager;

use std::sync::Arc;
use std::time::Instant;
use tokio::sync::RwLock;
use config::EntrypointConfig;
use config_file::EntrypointConfigFile;

/// Shared state for the entrypoint
#[derive(Clone)]
pub struct EntrypointState {
    pub config: EntrypointConfig,
    pub config_file: Option<EntrypointConfigFile>,
    pub process: Arc<RwLock<Option<tokio::process::Child>>>,
    pub service_port: Arc<RwLock<Option<u16>>>,
    pub start_time: Instant,
    pub restart_count: Arc<RwLock<u32>>,
}

impl EntrypointState {
    pub fn entrypoint_port(&self) -> u16 {
        self.config.port.expect("Port must be set") + 1
    }

    pub fn service_target_port(&self) -> u16 {
        self.config.port.expect("Port must be set")
    }
}

// Backward-compatible type alias
pub type BabysitterState = EntrypointState;
