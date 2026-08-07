//! InfiniSharePool placeholder binary

use axum::{routing::get, Json, Router};
use clap::Parser;
use infini_loadbalancer::share_pool::{log_placeholder, SharePoolConfig};
use serde_json::json;
use tracing::info;

#[derive(Parser, Debug)]
#[command(name = "infini-sharepool")]
#[command(about = "InfiniSharePool placeholder service")]
struct Args {
    /// HTTP port for health endpoint
    #[arg(long, default_value = "8082")]
    port: u16,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args = Args::parse();
    let config = SharePoolConfig { port: args.port };
    log_placeholder(&config);

    let app = Router::new().route(
        "/health",
        get(|| async { Json(json!({"status": "ok", "service": "infini-sharepool"})) }),
    );

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", config.port)).await?;
    info!("InfiniSharePool placeholder on http://0.0.0.0:{}", config.port);

    axum::serve(listener, app).await?;
    Ok(())
}
