//! Operations panel static assets and entity projection endpoint.

use axum::{
    Json,
    extract::State,
    http::{HeaderMap, header},
    response::{Html, IntoResponse, Response},
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use crate::models::aggregator::ModelAggregator;
use crate::load_balancer::load_balancer::LoadBalancer;

const INDEX_HTML: &str = include_str!("../../panel/index.html");
const APP_JS: &str = include_str!("../../panel/app.js");
const STYLES_CSS: &str = include_str!("../../panel/styles.css");

/// Operations panel application shell.
pub async fn panel_index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

/// Operations panel JavaScript bundle.
pub async fn panel_app_js() -> Response {
    asset_response(APP_JS, "application/javascript; charset=utf-8")
}

/// Operations panel stylesheet.
pub async fn panel_styles_css() -> Response {
    asset_response(STYLES_CSS, "text/css; charset=utf-8")
}

/// Project live router state into the operations-panel entity model.
pub async fn panel_snapshot_handler(
    State(load_balancer): State<Arc<LoadBalancer>>,
    headers: HeaderMap,
) -> Json<Value> {
    let services = load_balancer.get_all_services().await;
    let services_info: Vec<_> =
        futures::future::join_all(services.iter().map(|service| service.to_info())).await;
    let models = ModelAggregator::aggregate_models(&load_balancer).await;

    let router_url = request_origin(&headers);
    let discovery_prefix = load_balancer.discovery_prefix.clone();
    let etcd_endpoints = load_balancer.etcd_endpoints.clone();
    let cluster_id = first_metadata_string(&services_info, &["cluster_id", "cluster"])
        .unwrap_or_else(|| "default".to_string());
    let cluster_name = first_metadata_string(&services_info, &["cluster_name", "deploy_case"])
        .unwrap_or_else(|| cluster_id.clone());
    let env = first_metadata_string(&services_info, &["env", "deploy_tier"])
        .unwrap_or_else(|| "dev".to_string());
    let deploy_case = first_metadata_string(&services_info, &["deploy_case"]);
    let router_id = format!("loadbalancer-{}", slugify(&discovery_prefix));

    let mut hosts = BTreeMap::new();
    let servers: Vec<Value> = services_info
        .iter()
        .map(|service| {
            let server_id = metadata_string(&service.metadata, &["server_id", "id", "uuid"])
                .unwrap_or_else(|| service.name.clone());
            let host_id = metadata_string(&service.metadata, &["host_id", "hostname"])
                .unwrap_or_else(|| service.host.clone());
            let service_cluster_id = metadata_string(&service.metadata, &["cluster_id", "cluster"])
                .unwrap_or_else(|| cluster_id.clone());
            let role = metadata_string(&service.metadata, &["role"])
                .unwrap_or_else(|| infer_host_role(&service.name));
            let platform = metadata_string(&service.metadata, &["platform"]);
            let arch = metadata_string(&service.metadata, &["arch"]);
            let gpu_inventory = service.metadata.get("gpu_inventory").cloned();

            let host_record = json!({
                "host_id": host_id.clone(),
                "hostname": service.host.clone(),
                "cluster_id": service_cluster_id.clone(),
                "role": role.clone(),
                "platform": platform.clone(),
                "arch": arch.clone(),
                "gpu_inventory": gpu_inventory.clone(),
            });
            hosts.entry(host_id.clone()).or_insert(host_record);

            json!({
                "server_id": server_id,
                "service_name": service.name.clone(),
                "cluster_id": service_cluster_id.clone(),
                "host_id": metadata_string(&service.metadata, &["host_id", "hostname"]).unwrap_or_else(|| service.host.clone()),
                "router_id": router_id.clone(),
                "url": service.url.clone(),
                "entrypoint_url": service.entrypoint_url.clone(),
                "status": if service.healthy { "healthy" } else { "unhealthy" },
                "healthy": service.healthy,
                "model": service.models.clone(),
                "models": service.models.clone(),
                "weight": service.weight,
                "request_count": service.request_count,
                "error_count": service.error_count,
                "response_time": service.response_time,
                "worktree": service.metadata.get("worktree").cloned(),
                "image_tag": metadata_string(&service.metadata, &["image_tag", "image", "build_tag"]),
                "metadata": service.metadata.clone(),
            })
        })
        .collect();

    let healthy_services = servers
        .iter()
        .filter(|server| {
            server
                .get("healthy")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .count();

    Json(json!({
        "generated_at": chrono::Utc::now().to_rfc3339(),
        "cluster": {
            "cluster_id": cluster_id.clone(),
            "name": cluster_name.clone(),
            "env": env.clone(),
            "discovery_prefix": discovery_prefix.clone(),
            "etcd_endpoints": etcd_endpoints.clone(),
            "deploy_case": deploy_case.clone(),
        },
        "hosts": hosts.into_values().collect::<Vec<_>>(),
        "routers": [{
            "router_id": router_id.clone(),
            "cluster_id": cluster_id.clone(),
            "host_id": null,
            "url": router_url,
            "lb_policy": "weighted_round_robin",
            "healthy": true,
            "models": models,
            "servers": servers.iter().map(|server| {
                json!({
                    "server_id": server.get("server_id").cloned().unwrap_or(Value::Null),
                    "service_name": server.get("service_name").cloned().unwrap_or(Value::Null),
                    "healthy": server.get("healthy").cloned().unwrap_or(Value::Bool(false)),
                    "weight": server.get("weight").cloned().unwrap_or(Value::Null),
                })
            }).collect::<Vec<_>>(),
            "metadata": {
                "discovery_prefix": discovery_prefix.clone(),
                "etcd_endpoints": etcd_endpoints.clone(),
                "projection": "live-loadbalancer"
            },
            "stats_snapshot": {
                "total_services": servers.len(),
                "healthy_services": healthy_services,
            }
        }],
        "servers": servers,
        "benches": builtin_benches(),
        "bench_results": [],
        "source_status": {
            "dashboard": "live router endpoints",
            "benchmark": "bench-warehouse adapter not configured",
            "playground": "control-plane mutations not configured"
        }
    }))
}

fn asset_response(body: &'static str, content_type: &'static str) -> Response {
    ([(header::CONTENT_TYPE, content_type)], body).into_response()
}

fn request_origin(headers: &HeaderMap) -> String {
    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("localhost");
    let proto = headers
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("http");

    format!("{proto}://{host}")
}

fn first_metadata_string<T>(services: &[T], keys: &[&str]) -> Option<String>
where
    T: AsServiceMetadata,
{
    services
        .iter()
        .find_map(|service| metadata_string(service.metadata(), keys))
}

trait AsServiceMetadata {
    fn metadata(&self) -> &HashMap<String, Value>;
}

impl AsServiceMetadata for crate::load_balancer::service_instance::ServiceInfo {
    fn metadata(&self) -> &HashMap<String, Value> {
        &self.metadata
    }
}

fn metadata_string(metadata: &HashMap<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        metadata.get(*key).and_then(|value| match value {
            Value::String(text) if !text.is_empty() => Some(text.clone()),
            Value::Number(number) => Some(number.to_string()),
            Value::Bool(flag) => Some(flag.to_string()),
            _ => None,
        })
    })
}

fn infer_host_role(service_name: &str) -> String {
    let name = service_name.to_ascii_lowercase();
    if name.contains("master") {
        "master".to_string()
    } else if name.contains("slave") || name.contains("worker") {
        "slave".to_string()
    } else {
        "other".to_string()
    }
}

fn slugify(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn builtin_benches() -> Vec<Value> {
    vec![
        json!({
            "bench_id": "deploy_throughput__generic",
            "bench": "deploy_throughput",
            "bench_family": "latency",
            "default_params": {
                "MAX_CONCURRENCY": 16,
                "NUM_PROMPTS": 320
            },
            "runner": "bench-warehouse/harness/run_bench_client.sh",
            "source": "builtin"
        }),
        json!({
            "bench_id": "deploy_ceval__generic",
            "bench": "deploy_ceval",
            "bench_family": "accuracy",
            "default_params": {
                "limit": 100
            },
            "runner": "deploy/cases/<case>/bench/run_deploy_ceval.sh",
            "source": "builtin"
        }),
        json!({
            "bench_id": "unexpected_behavior__cancel_mid_decode",
            "bench": "unexpected_behavior",
            "bench_family": "resilience",
            "default_params": {
                "scenario": "cancel_mid_decode"
            },
            "runner": "bench-warehouse/harness/run_bench_client.sh",
            "source": "builtin"
        }),
    ]
}
