//! Prometheus metrics endpoint for InfiniLoadBalancer

use axum::{
    extract::State,
    http::{header, StatusCode},
    response::IntoResponse,
};
use std::sync::Arc;

use crate::load_balancer::load_balancer::LoadBalancer;

pub async fn metrics_handler(State(load_balancer): State<Arc<LoadBalancer>>) -> impl IntoResponse {
    let body = load_balancer.metrics.prometheus_text();
    (
        StatusCode::OK,
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        body,
    )
}
