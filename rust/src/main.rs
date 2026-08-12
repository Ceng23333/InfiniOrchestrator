//! InfiniLM Distributed Load Balancer Service
//! High-performance load balancer for distributed InfiniLM services with etcd discovery,
//! health checks, and model-aware routing.

use anyhow::Result;
use clap::Parser;
use std::sync::Arc;
use tokio::signal;
use tracing::{info, warn};

mod config;
mod discovery;
mod handlers;
mod load_balancer;
mod metrics;
mod models;
mod proxy;
mod utils;

use config::Config;
use load_balancer::load_balancer::LoadBalancer;

#[derive(Parser, Debug)]
#[command(name = "infini-loadbalancer")]
#[command(about = "High-performance distributed load balancer for InfiniLM services", long_about = None)]
struct Args {
    /// Load balancer port
    #[arg(long, default_value = "8080")]
    load_balancer_port: u16,

    /// Deprecated alias for --load-balancer-port
    #[arg(long, hide = true)]
    router_port: Option<u16>,

    /// etcd endpoints (comma-separated)
    #[arg(long, env = "ETCD_ENDPOINTS")]
    etcd_endpoints: Option<String>,

    /// Discovery key prefix
    #[arg(long, env = "DISCOVERY_PREFIX")]
    discovery_prefix: Option<String>,

    /// Deprecated: HTTP registry URL (use etcd discovery instead)
    #[arg(long, hide = true)]
    registry_url: Option<String>,

    /// JSON file with static service configurations
    #[arg(long)]
    static_services: Option<String>,

    #[arg(long, default_value = "30")]
    health_interval: u64,

    #[arg(long, default_value = "5")]
    health_timeout: u64,

    #[arg(long, default_value = "3")]
    max_errors: u32,

    #[arg(long, default_value = "10")]
    discovery_sync_interval: u64,

    /// Deprecated alias
    #[arg(long, hide = true)]
    registry_sync_interval: Option<u64>,

    #[arg(long, default_value = "60")]
    service_removal_grace_period: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args = Args::parse();

    if args.registry_url.is_some() {
        warn!("--registry-url is deprecated; use --etcd-endpoints and DISCOVERY_PREFIX");
    }

    let port = args.router_port.unwrap_or(args.load_balancer_port);
    let sync_interval = args
        .registry_sync_interval
        .unwrap_or(args.discovery_sync_interval);

    info!("Starting InfiniLoadBalancer");
    info!("Port: {}", port);
    info!("etcd endpoints: {:?}", args.etcd_endpoints);
    info!("Discovery prefix: {:?}", args.discovery_prefix);

    let config = Config::new(
        port,
        args.etcd_endpoints,
        args.discovery_prefix,
        args.registry_url,
        args.static_services,
        args.health_interval,
        args.health_timeout,
        args.max_errors,
        sync_interval,
        args.service_removal_grace_period,
    )?;

    let load_balancer = Arc::new(LoadBalancer::new(&config).await?);

    let health_checker = load_balancer.clone();
    tokio::spawn(async move {
        health_checker.start_health_checks().await;
    });

    if config.discovery_enabled() {
        let discovery_sync = load_balancer.clone();
        tokio::spawn(async move {
            discovery_sync.start_discovery_sync().await;
        });
    }

    let app = handlers::create_router(load_balancer.clone());

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", config.load_balancer_port)).await?;
    info!(
        "InfiniLoadBalancer listening on http://0.0.0.0:{}",
        config.load_balancer_port
    );

    let shutdown_signal = async {
        let ctrl_c = async {
            signal::ctrl_c()
                .await
                .expect("failed to install Ctrl+C handler");
        };

        #[cfg(unix)]
        let terminate = async {
            signal::unix::signal(signal::unix::SignalKind::terminate())
                .expect("failed to install signal handler")
                .recv()
                .await;
        };

        #[cfg(not(unix))]
        let terminate = std::future::pending::<()>();

        tokio::select! {
            _ = ctrl_c => {},
            _ = terminate => {},
        }
    };

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal)
        .await?;

    info!("InfiniLoadBalancer shutdown complete");
    Ok(())
}
