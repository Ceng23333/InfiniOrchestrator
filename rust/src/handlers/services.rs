//! Services endpoint handler

use axum::{extract::State, response::Json};
use serde_json::json;
use std::sync::Arc;

use crate::load_balancer::load_balancer::LoadBalancer;

/// Services information endpoint
pub async fn services_handler(
    State(load_balancer): State<Arc<LoadBalancer>>,
) -> Json<serde_json::Value> {
    let services = load_balancer.get_all_services().await;

    let services_info: Vec<_> =
        futures::future::join_all(services.iter().map(|s| s.to_info())).await;

    Json(json!({
        "services": services_info,
        "total": services_info.len(),
        "discovery_prefix": load_balancer.discovery_prefix,
        "etcd_endpoints": load_balancer.etcd_endpoints
    }))
}
