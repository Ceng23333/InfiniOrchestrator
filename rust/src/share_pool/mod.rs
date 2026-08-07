//! InfiniSharePool placeholder module

use tracing::info;

/// Placeholder share-pool service configuration
#[derive(Debug, Clone)]
pub struct SharePoolConfig {
    pub port: u16,
}

impl Default for SharePoolConfig {
    fn default() -> Self {
        Self { port: 8082 }
    }
}

/// Log placeholder startup message
pub fn log_placeholder(config: &SharePoolConfig) {
    info!(
        "InfiniSharePool placeholder listening on port {} (/health)",
        config.port
    );
}
