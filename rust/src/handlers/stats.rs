//! Statistics endpoint handler

use axum::{extract::State, response::Json};
use serde_json::json;
use std::sync::Arc;

use crate::load_balancer::load_balancer::LoadBalancer;

/// Statistics endpoint
pub async fn stats_handler(
    State(load_balancer): State<Arc<LoadBalancer>>,
) -> Json<serde_json::Value> {
    let services = load_balancer.get_all_services().await;

    // Check health status for all services
    let health_statuses: Vec<bool> =
        futures::future::join_all(services.iter().map(|s| s.is_healthy())).await;

    let healthy_count = health_statuses.iter().filter(|&&h| h).count();

    let services_info: Vec<_> =
        futures::future::join_all(services.iter().map(|s| s.to_info())).await;

    Json(json!({
        "total_services": services.len(),
        "healthy_services": healthy_count,
        "discovery_prefix": load_balancer.discovery_prefix,
        "etcd_endpoints": load_balancer.etcd_endpoints,
        "services": services_info
    }))
}
