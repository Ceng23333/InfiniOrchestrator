//! InfiniEntrypoint for InfiniLM Services
//! Manages service lifecycle, health monitoring, and etcd discovery

use anyhow::{Context, Result};
use infini_loadbalancer::entrypoint::config::EntrypointConfig;
use infini_loadbalancer::entrypoint::config_file::EntrypointConfigFile;
use infini_loadbalancer::entrypoint::discovery_client::EntrypointDiscoveryClient;
use infini_loadbalancer::entrypoint::handlers::EntrypointHandlers;
use infini_loadbalancer::entrypoint::process_manager::ProcessManager;
use infini_loadbalancer::entrypoint::EntrypointState;
use std::sync::Arc;
use tokio::signal;
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cli_config = <EntrypointConfig as clap::Parser>::parse();

    let (config, config_file): (EntrypointConfig, Option<EntrypointConfigFile>) =
        if let Some(config_file_path) = &cli_config.config_file {
            let file_config = EntrypointConfigFile::from_file(config_file_path)
                .with_context(|| format!("Failed to load config file: {:?}", config_file_path))?;
            let mut merged = file_config.to_cli_config();

            if cli_config.name.is_some() {
                merged.name = cli_config.name.clone();
            }
            if let Some(port) = cli_config.port {
                merged.port = Some(port);
            }
            if cli_config.host != "localhost" && cli_config.host != merged.host {
                merged.host = cli_config.host.clone();
            }
            if cli_config.etcd_endpoints.is_some() {
                merged.etcd_endpoints = cli_config.etcd_endpoints.clone();
            }
            if cli_config.discovery_prefix.is_some() {
                merged.discovery_prefix = cli_config.discovery_prefix.clone();
            }

            (merged, Some(file_config))
        } else {
            if cli_config.port.is_none() {
                anyhow::bail!("--port is required when --config-file is not provided");
            }
            (cli_config, None)
        };

    info!("Starting InfiniEntrypoint");
    info!("Service: {}", config.service_name());
    let port = config.port.expect("Port must be set");
    info!("Port: {} (entrypoint: {})", port, port + 1);
    info!(
        "Discovery: etcd endpoints={:?}, prefix={:?}",
        config.etcd_endpoints, config.discovery_prefix
    );

    let state = Arc::new(EntrypointState::new(config.clone(), config_file));
    info!("server_id={}", state.server_id);

    let handlers = EntrypointHandlers::new(state.clone());
    let server_handle = tokio::spawn(async move {
        if let Err(e) = handlers.start_server().await {
            tracing::error!("HTTP server error: {}", e);
        }
    });

    let process_manager = ProcessManager::new(state.clone());
    let process_handle = tokio::spawn(async move { process_manager.run().await });

    if config.discovery_enabled() {
        let discovery_client = EntrypointDiscoveryClient::new(state.clone()).await?;
        let discovery_handle = tokio::spawn(async move { discovery_client.run().await });

        signal::ctrl_c().await?;
        info!("Received shutdown signal, cleaning up...");
        discovery_handle.abort();
    } else {
        signal::ctrl_c().await?;
        info!("Received shutdown signal, cleaning up...");
    }

    process_handle.abort();
    server_handle.abort();

    info!("InfiniEntrypoint stopped");
    Ok(())
}
