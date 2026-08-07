//! HTTP request handlers

use axum::{Router, routing::get};
use std::sync::Arc;

use crate::proxy::handler::proxy_handler;
use crate::load_balancer::load_balancer::LoadBalancer;

mod health;
mod models;
mod panel;
mod services;
mod stats;

/// Create the main router
pub fn create_router(load_balancer: Arc<LoadBalancer>) -> Router {
    Router::new()
        .route("/panel", get(panel::panel_index))
        .route("/panel/", get(panel::panel_index))
        .route("/panel/app.js", get(panel::panel_app_js))
        .route("/panel/styles.css", get(panel::panel_styles_css))
        .route("/panel/api/snapshot", get(panel::panel_snapshot_handler))
        .route("/health", get(health::health_handler))
        .route("/status", get(health::health_handler)) // Alias for /health
        .route("/stats", get(stats::stats_handler))
        .route("/services", get(services::services_handler))
        .route("/models", get(models::models_handler))
        .fallback(proxy_handler)
        .with_state(load_balancer)
}
