//! InfiniSharePool process-local KV event sink.
use axum::{extract::State, routing::{get, post}, Json, Router};
use clap::Parser;
use infini_loadbalancer::share_pool::{log_placeholder, IndexSummary, KvEventsRequest, OverlapRequest, OverlapResponse, SharePoolConfig, SharePoolState};
use serde_json::json;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

#[derive(Parser, Debug)]
#[command(name = "infini-sharepool")]
struct Args { #[arg(long, default_value = "8082")] port: u16, #[arg(long, env = "SHAREPOOL_MAX_BLOCKS", default_value = "100000")] max_blocks: usize }

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env()).init();
    let args = Args::parse();
    let config = SharePoolConfig { port: args.port, max_blocks: args.max_blocks };
    log_placeholder(&config);
    let state = Arc::new(RwLock::new(SharePoolState::new(config.max_blocks)));
    let app = Router::new().route("/health", get(health)).route("/v1/kv_events", post(ingest)).route("/v1/kv_index", get(index)).route("/v1/kv_overlap", post(overlap)).with_state(state);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", config.port)).await?;
    info!("InfiniSharePool on http://0.0.0.0:{}", config.port);
    axum::serve(listener, app).await?;
    Ok(())
}
async fn health(State(state): State<Arc<RwLock<SharePoolState>>>) -> Json<serde_json::Value> { let s = state.read().await.summary(); Json(json!({"status":"ok","service":"infini-sharepool","index_entries":s.index_entries,"generation":s.generation})) }
async fn ingest(State(state): State<Arc<RwLock<SharePoolState>>>, Json(request): Json<KvEventsRequest>) -> Json<serde_json::Value> { let count = request.events.len(); let mut state = state.write().await; for event in request.events { state.ingest(event); } Json(json!({"status":"ok","events_ingested":count,"index_entries":state.summary().index_entries})) }
async fn index(State(state): State<Arc<RwLock<SharePoolState>>>) -> Json<IndexSummary> { Json(state.read().await.summary()) }
async fn overlap(State(state): State<Arc<RwLock<SharePoolState>>>, Json(request): Json<OverlapRequest>) -> Json<OverlapResponse> { Json(state.read().await.overlap(&request)) }
