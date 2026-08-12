//! HTTP handlers for InfiniEntrypoint

use axum::{extract::State, http::StatusCode, response::Json, routing::get, Router};
use serde_json::json;
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing::{error, info};

use crate::entrypoint::EntrypointState;

pub struct EntrypointHandlers {
    state: Arc<EntrypointState>,
}

impl EntrypointHandlers {
    pub fn new(state: Arc<EntrypointState>) -> Self {
        Self { state }
    }

    pub async fn start_server(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let app = Router::new()
            .route("/health", get(Self::health_handler))
            .route("/models", get(Self::models_handler))
            .route("/info", get(Self::info_handler))
            .route("/metadata", get(Self::metadata_handler))
            .route("/v1/metadata", get(Self::metadata_handler))
            .with_state(self.state.clone());

        let port = self.state.entrypoint_port();
        let addr = format!("0.0.0.0:{}", port);
        let listener = TcpListener::bind(&addr).await?;

        info!("InfiniEntrypoint HTTP server started on port {}", port);

        axum::serve(listener, app).await?;
        Ok(())
    }

    async fn health_handler(
        State(state): State<Arc<EntrypointState>>,
    ) -> Result<Json<serde_json::Value>, StatusCode> {
        let process_running = {
            let process = state.process.read().await;
            process.as_ref().is_some_and(|_p| true)
        };

        let service_port = *state.service_port.read().await;

        Ok(Json(json!({
            "status": "healthy",
            "service": state.config.service_name(),
            "entrypoint": "enhanced",
            "server_id": state.server_id,
            "infinilm_server_running": process_running,
            "infinilm_server_port": service_port,
            "timestamp": std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs()
        })))
    }

    async fn models_handler(
        State(state): State<Arc<EntrypointState>>,
    ) -> Result<Json<serde_json::Value>, StatusCode> {
        let service_port = *state.service_port.read().await;

        if service_port.is_none() {
            return Err(StatusCode::SERVICE_UNAVAILABLE);
        }

        let url = format!(
            "http://{}:{}/models",
            state.config.host,
            service_port.unwrap()
        );

        match reqwest::get(&url).await {
            Ok(response) if response.status().is_success() => match response.json().await {
                Ok(data) => Ok(Json(data)),
                Err(e) => {
                    error!("Failed to parse models response: {}", e);
                    Err(StatusCode::INTERNAL_SERVER_ERROR)
                }
            },
            Ok(_) => Err(StatusCode::SERVICE_UNAVAILABLE),
            Err(e) => {
                error!("Error proxying models request: {}", e);
                Err(StatusCode::SERVICE_UNAVAILABLE)
            }
        }
    }

    async fn info_handler(
        State(state): State<Arc<EntrypointState>>,
    ) -> Result<Json<serde_json::Value>, StatusCode> {
        let service_port = *state.service_port.read().await;
        let restart_count = *state.restart_count.read().await;
        let uptime = state.start_time.elapsed().as_secs();

        Ok(Json(json!({
            "name": state.config.service_name(),
            "host": state.config.host,
            "port": state.entrypoint_port(),
            "url": format!("http://{}:{}", state.config.host, state.entrypoint_port()),
            "service_type": state.config.service_type,
            "server_id": state.server_id,
            "infinilm_server_port": service_port,
            "uptime": uptime,
            "restart_count": restart_count
        })))
    }

    async fn metadata_handler(
        State(state): State<Arc<EntrypointState>>,
    ) -> Result<Json<serde_json::Value>, StatusCode> {
        let service_port = *state.service_port.read().await;
        Ok(Json(state.build_metadata_payload(service_port).await))
    }
}

pub type BabysitterHandlers = EntrypointHandlers;
