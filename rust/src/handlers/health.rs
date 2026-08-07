//! Health check endpoint handler

use axum::{extract::State, response::Json};
use serde_json::json;
use std::sync::Arc;

use crate::load_balancer::load_balancer::LoadBalancer;

/// Health check endpoint
pub async fn health_handler(
    State(load_balancer): State<Arc<LoadBalancer>>,
) -> Json<serde_json::Value> {
    let services = load_balancer.get_all_services().await;

    // Check health status for all services
    let health_statuses: Vec<bool> =
        futures::future::join_all(services.iter().map(|s| s.is_healthy())).await;

    let healthy_count = health_statuses.iter().filter(|&&h| h).count();
    let total_count = services.len();

    Json(json!({
        "status": if healthy_count > 0 { "healthy" } else { "running" },
        "load_balancer": "running",
        "healthy_services": format!("{}/{}", healthy_count, total_count),
        "discovery_prefix": load_balancer.discovery_prefix,
        "etcd_endpoints": load_balancer.etcd_endpoints,
        "message": if healthy_count == 0 { Some("No healthy services available") } else { None },
        "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
    }))
}
