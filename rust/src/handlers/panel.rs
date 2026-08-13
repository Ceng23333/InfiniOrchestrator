//! Operations panel static assets and entity projection endpoint.

use axum::{
    Json,
    extract::{Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

#[derive(Debug, Deserialize)]
struct PlaygroundCaseToml {
    case_id: String,
    category: String,
    n: i64,
    model_id: String,
    hw_profile_id: String,
    hw_abbr: String,
    be_abbr: String,
    worktree: String,
}

use crate::models::aggregator::ModelAggregator;
use crate::load_balancer::load_balancer::LoadBalancer;

const LONGBENCH_METRICS: &[&str] = &[
    "total_tok_per_s",
    "output_tok_per_s",
    "req_per_s",
    "lb_em",
    "ttft_p50_ms",
    "ttft_p99_ms",
    "ttft_mean_ms",
    "tpot_p50_ms",
    "tpot_mean_ms",
    "itl_p50_ms",
    "itl_p99_ms",
    "itl_mean_ms",
    "srv_ttft_p50_ms_mean",
    "srv_e2e_p50_ms_mean",
    "srv_itl_p50_ms_mean",
];

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
        "grafana_url": resolve_grafana_url(&headers),
        "source_status": {
            "dashboard": "live router endpoints",
            "harness": "GET /panel/api/cases/harness",
            "visualization": "GET /panel/api/harness/longbench_v2",
            "playground": "GET /panel/api/cases/playground"
        }
    }))
}

/// Read-only playground case browser (Standalone + Distribution case.toml).
pub async fn panel_cases_playground_handler() -> Json<Value> {
    Json(load_playground_cases_payload())
}

/// Read-only harness suite browser (warehouse.yaml under scenarios/benchmark/cases).
pub async fn panel_cases_harness_handler() -> Json<Value> {
    Json(load_harness_cases_payload())
}

/// LongBenchV2 harness rows from bench-warehouse `raw/*/longbench_v2.tsv`.
pub async fn panel_longbench_v2_handler() -> Json<Value> {
    Json(load_longbench_v2_payload())
}

#[derive(Debug, Deserialize)]
pub struct WarehouseFileQuery {
    path: String,
    line: Option<usize>,
}

/// Read-only peek of a warehouse raw TSV, optionally highlighting a 1-based line.
pub async fn panel_warehouse_file_handler(
    Query(query): Query<WarehouseFileQuery>,
) -> Response {
    match read_warehouse_file_peek(&query.path, query.line) {
        Ok(html) => Html(html).into_response(),
        Err((status, message)) => (status, message).into_response(),
    }
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

fn resolve_grafana_url(headers: &HeaderMap) -> String {
    if let Ok(explicit) = std::env::var("GRAFANA_URL") {
        let trimmed = explicit.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("localhost");
    let hostname = host.split(':').next().unwrap_or(host);
    let proto = headers
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("http");
    format!("{proto}://{hostname}:3000")
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

fn load_playground_cases_payload() -> Value {
    let Some(root) = resolve_io_root() else {
        return json!({
            "cases": [],
            "source": {
                "root": Value::Null,
                "status": "InfiniOrchestrator root not found (expected playground/ under IO root)"
            }
        });
    };

    let playground = root.join("playground");
    let mut cases = Vec::new();
    for category in ["Standalone", "Distribution"] {
        let category_dir = playground.join(category);
        let Ok(entries) = fs::read_dir(&category_dir) else {
            continue;
        };
        let mut dirs: Vec<_> = entries.filter_map(|entry| entry.ok()).collect();
        dirs.sort_by_key(|entry| entry.file_name());
        for entry in dirs {
            let case_dir = entry.path();
            if !case_dir.is_dir() {
                continue;
            }
            let case_toml = case_dir.join("case.toml");
            if !case_toml.is_file() {
                continue;
            }
            let Ok(content) = fs::read_to_string(&case_toml) else {
                continue;
            };
            let Ok(parsed) = toml::from_str::<PlaygroundCaseToml>(&content) else {
                continue;
            };
            let case_id = entry.file_name().to_string_lossy().to_string();
            let rel = format!("playground/{category}/{case_id}/case.toml");
            cases.push(json!({
                "kind": "playground",
                "case_id": parsed.case_id,
                "category": parsed.category,
                "n": parsed.n,
                "model_id": parsed.model_id,
                "hw_profile_id": parsed.hw_profile_id,
                "hw_abbr": parsed.hw_abbr,
                "be_abbr": parsed.be_abbr,
                "worktree": parsed.worktree,
                "case_path": rel,
                "has_readme": case_dir.join("README.md").is_file(),
                "has_compose": case_dir.join("docker-compose").is_dir()
                    || case_dir.join("docker-compose.yml").is_file()
                    || case_dir.join("compose.yaml").is_file(),
            }));
        }
    }

    cases.sort_by(|a, b| {
        (
            row_string(a, "category"),
            row_string(a, "case_id"),
        )
            .cmp(&(row_string(b, "category"), row_string(b, "case_id")))
    });

    json!({
        "cases": cases,
        "source": {
            "root": root.display().to_string(),
            "status": "ok"
        }
    })
}

fn load_harness_cases_payload() -> Value {
    let Some(root) = resolve_io_root() else {
        return json!({
            "cases": [],
            "source": {
                "root": Value::Null,
                "status": "InfiniOrchestrator root not found (expected harness/ under IO root)"
            }
        });
    };

    let cases_dir = root.join("harness/scenarios/benchmark/cases");
    let mut cases = Vec::new();
    let Ok(entries) = fs::read_dir(&cases_dir) else {
        return json!({
            "cases": [],
            "source": {
                "root": root.display().to_string(),
                "status": format!("missing {}", cases_dir.display())
            }
        });
    };

    let mut dirs: Vec<_> = entries.filter_map(|entry| entry.ok()).collect();
    dirs.sort_by_key(|entry| entry.file_name());
    for entry in dirs {
        let suite_dir = entry.path();
        if !suite_dir.is_dir() {
            continue;
        }
        let schema = suite_dir.join("schema/warehouse.yaml");
        if !schema.is_file() {
            continue;
        }
        let Ok(content) = fs::read_to_string(&schema) else {
            continue;
        };
        let parsed = parse_warehouse_yaml(&content);
        let suite_id = entry.file_name().to_string_lossy().to_string();
        let runnable = suite_dir.join("scripts/run.sh").is_file();
        let rel = format!("harness/scenarios/benchmark/cases/{suite_id}");
        cases.push(json!({
            "kind": "harness",
            "suite_id": suite_id,
            "suite_prefix": parsed.suite_prefix,
            "family": parsed.family,
            "model_in_bench_id": parsed.model_in_bench_id,
            "metric_columns": parsed.metric_columns,
            "case_path": rel,
            "runnable": runnable,
        }));
    }

    json!({
        "cases": cases,
        "source": {
            "root": root.display().to_string(),
            "status": "ok"
        }
    })
}

#[derive(Debug, Default)]
struct WarehouseYaml {
    suite_prefix: String,
    family: String,
    model_in_bench_id: bool,
    metric_columns: Vec<String>,
}

fn parse_warehouse_yaml(content: &str) -> WarehouseYaml {
    let mut parsed = WarehouseYaml::default();
    let mut in_metrics = false;
    for raw in content.lines() {
        let line = raw.trim_end();
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("suite_prefix:") {
            parsed.suite_prefix = rest.trim().to_string();
            in_metrics = false;
            continue;
        }
        if let Some(rest) = line.strip_prefix("family:") {
            parsed.family = rest.trim().to_string();
            in_metrics = false;
            continue;
        }
        if let Some(rest) = line.strip_prefix("model_in_bench_id:") {
            parsed.model_in_bench_id = rest.trim().eq_ignore_ascii_case("true");
            in_metrics = false;
            continue;
        }
        if line.starts_with("metric_columns:") {
            in_metrics = true;
            continue;
        }
        if in_metrics {
            if let Some(item) = line.trim_start().strip_prefix("- ") {
                parsed.metric_columns.push(item.trim().to_string());
            } else if !line.starts_with(' ') && !line.starts_with('\t') {
                in_metrics = false;
            }
        }
    }
    if parsed.suite_prefix.is_empty() {
        parsed.suite_prefix = parsed.family.clone();
    }
    parsed
}

fn resolve_io_root() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("IO_ROOT") {
        let path = PathBuf::from(explicit);
        if path.join("playground").is_dir() || path.join("harness").is_dir() {
            return Some(path);
        }
    }

    let cwd = std::env::current_dir().ok()?;
    let candidates = [
        cwd.clone(),
        cwd.join("InfiniOrchestrator"),
        cwd.join(".."),
        cwd.join("../InfiniOrchestrator"),
        cwd.join("../.."),
        cwd.join("../../InfiniOrchestrator"),
        PathBuf::from("/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator"),
    ];
    candidates.into_iter().find(|path| {
        path.join("playground").is_dir() || path.join("harness/scenarios/benchmark/cases").is_dir()
    })
}

fn load_longbench_v2_payload() -> Value {
    let Some(repo) = resolve_warehouse_root() else {
        let sync = read_warehouse_sync_status_from_env();
        return json!({
            "category": "harness",
            "harness_id": "longbench_v2",
            "default_metric": "total_tok_per_s",
            "metrics": LONGBENCH_METRICS,
            "filter_options": {
                "models": [],
                "hardware": [],
                "backends": [],
                "dates": [],
                "presets": [],
                "deploy_modes": []
            },
            "rows": [],
            "source": {
                "repo": Value::Null,
                "files": [],
                "github_blob_base": Value::Null,
                "status": "BENCH_WAREHOUSE_REPO not found (set env or place sibling bench-warehouse)",
                "sync": sync
            }
        });
    };

    let github_blob_base = resolve_warehouse_github_blob_base(&repo);
    let sync = read_warehouse_sync_status(&repo);
    let (rows, files) = load_longbench_v2_rows(&repo);
    if rows.is_empty() {
        return json!({
            "category": "harness",
            "harness_id": "longbench_v2",
            "default_metric": "total_tok_per_s",
            "metrics": LONGBENCH_METRICS,
            "filter_options": {
                "models": [],
                "hardware": [],
                "backends": [],
                "dates": [],
                "presets": [],
                "deploy_modes": []
            },
            "rows": [],
            "source": {
                "repo": repo.display().to_string(),
                "files": files,
                "github_blob_base": github_blob_base,
                "status": if files.is_empty() {
                    "no raw/*/longbench_v2.tsv files found"
                } else {
                    "tsv files found but no data rows"
                },
                "sync": sync
            }
        });
    }

    let filter_options = build_filter_options(&rows);
    json!({
        "category": "harness",
        "harness_id": "longbench_v2",
        "default_metric": "total_tok_per_s",
        "metrics": LONGBENCH_METRICS,
        "filter_options": filter_options,
        "rows": rows,
        "source": {
            "repo": repo.display().to_string(),
            "files": files,
            "github_blob_base": github_blob_base,
            "status": "ok",
            "sync": sync
        }
    })
}

/// Sidecar status written by warehouse-sync (`/warehouse/.warehouse-sync-status`).
fn read_warehouse_sync_status(repo: &Path) -> Value {
    read_warehouse_sync_status_file(&repo.join(".warehouse-sync-status"))
}

fn read_warehouse_sync_status_from_env() -> Value {
    let path = std::env::var("BENCH_WAREHOUSE_REPO")
        .ok()
        .map(|root| PathBuf::from(root).join(".warehouse-sync-status"))
        .unwrap_or_else(|| PathBuf::from("/warehouse/.warehouse-sync-status"));
    read_warehouse_sync_status_file(&path)
}

fn read_warehouse_sync_status_file(path: &Path) -> Value {
    let Ok(raw) = fs::read_to_string(path) else {
        return Value::Null;
    };
    match serde_json::from_str::<Value>(raw.trim()) {
        Ok(value) if value.is_object() => value,
        _ => Value::Null,
    }
}

fn resolve_warehouse_github_blob_base(repo: &Path) -> String {
    if let Ok(explicit) = std::env::var("BENCH_WAREHOUSE_GITHUB_BLOB_BASE") {
        let trimmed = explicit.trim().trim_end_matches('/').to_string();
        if !trimmed.is_empty() {
            return trimmed;
        }
    }

    let repo_url = std::env::var("BENCH_WAREHOUSE_GITHUB_URL")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| read_git_https_remote(repo))
        .unwrap_or_else(|| "https://github.com/InfiniTensor/bench-warehouse".to_string());
    let repo_url = repo_url
        .trim_end_matches('/')
        .trim_end_matches(".git")
        .to_string();
    let git_ref = std::env::var("BENCH_WAREHOUSE_GITHUB_REF")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| read_git_current_branch(repo))
        .unwrap_or_else(|| "master".to_string());
    format!("{repo_url}/blob/{git_ref}")
}

fn read_git_https_remote(repo: &Path) -> Option<String> {
    let config = fs::read_to_string(repo.join(".git/config")).ok()?;
    let mut in_origin = false;
    for line in config.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_origin = trimmed == "[remote \"origin\"]";
            continue;
        }
        if in_origin {
            if let Some(url) = trimmed.strip_prefix("url =") {
                let url = url.trim();
                if let Some(https) = git_remote_to_https(url) {
                    return Some(https);
                }
            }
        }
    }
    None
}

fn git_remote_to_https(url: &str) -> Option<String> {
    if url.starts_with("https://") || url.starts_with("http://") {
        return Some(url.trim_end_matches('/').trim_end_matches(".git").to_string());
    }
    // git@github.com:Org/repo.git
    if let Some(rest) = url.strip_prefix("git@") {
        let rest = rest.trim_end_matches(".git");
        if let Some((host, path)) = rest.split_once(':') {
            return Some(format!("https://{host}/{path}"));
        }
    }
    // ssh://git@github.com/Org/repo.git
    if let Some(rest) = url.strip_prefix("ssh://git@") {
        let rest = rest.trim_end_matches('/').trim_end_matches(".git");
        return Some(format!("https://{rest}"));
    }
    None
}

fn read_git_current_branch(repo: &Path) -> Option<String> {
    let head = fs::read_to_string(repo.join(".git/HEAD")).ok()?;
    let head = head.trim();
    head.strip_prefix("ref: refs/heads/")
        .map(|branch| branch.trim().to_string())
}

fn resolve_warehouse_root() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("BENCH_WAREHOUSE_REPO") {
        let path = PathBuf::from(explicit);
        if path.join("raw").is_dir() {
            return Some(path);
        }
    }

    let cwd = std::env::current_dir().ok()?;
    let candidates = [
        cwd.join("bench-warehouse"),
        cwd.join("../bench-warehouse"),
        cwd.join("../../bench-warehouse"),
        cwd.join("../../../bench-warehouse"),
        PathBuf::from("/root/zenghua/workspace/profiling_20260731/bench-warehouse"),
    ];
    candidates.into_iter().find(|path| path.join("raw").is_dir())
}

fn load_longbench_v2_rows(repo: &Path) -> (Vec<Value>, Vec<String>) {
    let raw_dir = repo.join("raw");
    let mut files = Vec::new();
    let mut rows = Vec::new();
    let mut seen_ids: HashMap<String, usize> = HashMap::new();

    let Ok(entries) = fs::read_dir(&raw_dir) else {
        return (rows, files);
    };

    let mut date_dirs: Vec<_> = entries
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().is_dir())
        .collect();
    date_dirs.sort_by_key(|entry| entry.file_name());

    for date_entry in date_dirs {
        let tsv_path = date_entry.path().join("longbench_v2.tsv");
        if !tsv_path.is_file() {
            continue;
        }
        let date_name = date_entry.file_name().to_string_lossy().to_string();
        let rel = format!("raw/{date_name}/longbench_v2.tsv");
        files.push(rel.clone());

        let Ok(content) = fs::read_to_string(&tsv_path) else {
            continue;
        };
        let mut lines = content.lines();
        let Some(header_line) = lines.next() else {
            continue;
        };
        let headers: Vec<&str> = header_line.split('\t').collect();
        let mut line_no = 1usize;
        for line in lines {
            line_no += 1;
            if line.trim().is_empty() {
                continue;
            }
            let cols: Vec<&str> = line.split('\t').collect();
            let mut map = Map::new();
            for (idx, key) in headers.iter().enumerate() {
                let value = cols.get(idx).copied().unwrap_or("");
                map.insert((*key).to_string(), Value::String(value.to_string()));
            }

            let model = first_nonempty_map(&map, &["model", "model_id"]);
            let hw = first_nonempty_map(&map, &["hw_abbr", "hw_profile_id"]);
            let be = normalize_backend(first_nonempty_map(&map, &["be_abbr", "frontend"]));
            let preset = derive_longbench_preset(&map);
            let date = first_nonempty_map(&map, &["date"]).unwrap_or_else(|| date_name.clone());
            let bench_id = first_nonempty_map(&map, &["bench_id"]).unwrap_or_default();
            let server_id = first_nonempty_map(&map, &["server_id"]).unwrap_or_default();
            let started_at = first_nonempty_map(&map, &["started_at"]).unwrap_or_default();

            let mut row_id = format!("{date}|{bench_id}|{server_id}|{started_at}");
            let collision = seen_ids.entry(row_id.clone()).or_insert(0);
            if *collision > 0 {
                row_id = format!("{row_id}|{}", *collision);
            }
            *collision += 1;

            if let Some(model) = model {
                map.insert("model".to_string(), Value::String(model));
            }
            if let Some(hw) = hw {
                map.insert("hw".to_string(), Value::String(hw));
            }
            if let Some(be) = be {
                map.insert("be".to_string(), Value::String(be));
            }
            if let Some(deploy_mode) = first_nonempty_map(&map, &["case_category"]) {
                map.insert("deploy_mode".to_string(), Value::String(deploy_mode));
            }
            map.insert("preset".to_string(), Value::String(preset));
            map.insert("date".to_string(), Value::String(date));
            map.insert("row_id".to_string(), Value::String(row_id));
            map.insert("tsv_path".to_string(), Value::String(rel.clone()));
            map.insert("tsv_line".to_string(), Value::Number(line_no.into()));
            rows.push(Value::Object(map));
        }
    }

    rows.sort_by(|a, b| {
        let a_key = (
            row_string(a, "started_at"),
            row_string(a, "date"),
            row_string(a, "row_id"),
        );
        let b_key = (
            row_string(b, "started_at"),
            row_string(b, "date"),
            row_string(b, "row_id"),
        );
        a_key.cmp(&b_key)
    });

    (rows, files)
}

fn build_filter_options(rows: &[Value]) -> Value {
    let mut models = BTreeSet::new();
    let mut hardware = BTreeSet::new();
    let mut backends = BTreeSet::new();
    let mut dates = BTreeSet::new();
    let mut presets = BTreeSet::new();
    let mut deploy_modes = BTreeSet::new();

    for row in rows {
        if let Some(value) = nonempty_row(row, "model") {
            models.insert(value);
        }
        if let Some(value) = nonempty_row(row, "hw") {
            hardware.insert(value);
        }
        if let Some(value) = nonempty_row(row, "be") {
            backends.insert(value);
        }
        if let Some(value) = nonempty_row(row, "date") {
            dates.insert(value);
        }
        if let Some(value) = nonempty_row(row, "preset") {
            presets.insert(value);
        }
        if let Some(value) = nonempty_row(row, "deploy_mode") {
            deploy_modes.insert(value);
        }
    }

    json!({
        "models": models.into_iter().collect::<Vec<_>>(),
        "hardware": hardware.into_iter().collect::<Vec<_>>(),
        "backends": backends.into_iter().collect::<Vec<_>>(),
        "dates": dates.into_iter().collect::<Vec<_>>(),
        "presets": presets.into_iter().collect::<Vec<_>>(),
        "deploy_modes": deploy_modes.into_iter().collect::<Vec<_>>(),
    })
}

fn derive_longbench_preset(map: &Map<String, Value>) -> String {
    let length = first_nonempty_map(map, &["lb_length"])
        .unwrap_or_else(|| "unknown".to_string())
        .replace(',', "-");
    let difficulty = first_nonempty_map(map, &["lb_difficulty"]).unwrap_or_else(|| "all".to_string());
    let cot = {
        let scale = first_nonempty_map(map, &["workload_scale"]).unwrap_or_default();
        let thinking = first_nonempty_map(map, &["bench_args"]).unwrap_or_default();
        if scale.split(';').any(|part| part == "cot")
            || thinking.contains("\"enable_thinking\":\"true\"")
            || thinking.contains("\"enable_thinking\": \"true\"")
        {
            "cot"
        } else {
            "nocot"
        }
    };
    format!("{length}_{difficulty}_{cot}")
}

fn normalize_backend(value: Option<String>) -> Option<String> {
    value.map(|raw| {
        let lower = raw.to_ascii_lowercase();
        match lower.as_str() {
            "vllm" => "vllm".to_string(),
            "infinilm" | "inf" => "InfiniLM".to_string(),
            "mindie" => "MindIE".to_string(),
            "infiniorchestrator" => "InfiniOrchestrator".to_string(),
            _ => raw,
        }
    })
}

fn first_nonempty_map(map: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        map.get(*key).and_then(|value| match value {
            Value::String(text) if !text.trim().is_empty() => Some(text.trim().to_string()),
            Value::Number(number) => Some(number.to_string()),
            _ => None,
        })
    })
}

fn nonempty_row(row: &Value, key: &str) -> Option<String> {
    row.get(key).and_then(|value| match value {
        Value::String(text) if !text.trim().is_empty() => Some(text.trim().to_string()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    })
}

fn row_string(row: &Value, key: &str) -> String {
    nonempty_row(row, key).unwrap_or_default()
}

fn read_warehouse_file_peek(
    rel_path: &str,
    line: Option<usize>,
) -> Result<String, (StatusCode, String)> {
    let repo = resolve_warehouse_root().ok_or((
        StatusCode::SERVICE_UNAVAILABLE,
        "BENCH_WAREHOUSE_REPO not found".to_string(),
    ))?;

    let safe = sanitize_raw_rel_path(rel_path).ok_or((
        StatusCode::BAD_REQUEST,
        "path must be under raw/ without ..".to_string(),
    ))?;
    let full = repo.join(&safe);
    if !full.is_file() {
        return Err((StatusCode::NOT_FOUND, format!("file not found: {safe}")));
    }

    let content = fs::read_to_string(&full).map_err(|err| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to read file: {err}"),
        )
    })?;

    let target = line.unwrap_or(0);
    let mut body = String::from(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Warehouse peek</title>",
    );
    body.push_str(
        "<style>body{font:14px/1.4 ui-monospace,monospace;margin:16px;background:#f7f8fb;color:#18202f}\
         .meta{margin-bottom:12px;color:#647084}\
         pre{white-space:pre-wrap;background:#fff;border:1px solid #d9e0ea;border-radius:8px;padding:12px}\
         .ln{display:inline-block;min-width:3.5rem;color:#94a3b8;user-select:none}\
         .hit{background:#fff3bf}</style></head><body>",
    );
    body.push_str(&format!(
        "<div class=\"meta\">{}{}</div><pre>",
        html_escape(&safe),
        line.map(|n| format!(":{n}")).unwrap_or_default()
    ));
    for (idx, text) in content.lines().enumerate() {
        let n = idx + 1;
        let cls = if target == n { " class=\"hit\"" } else { "" };
        body.push_str(&format!(
            "<div{cls} id=\"L{n}\"><span class=\"ln\">{n}</span>{}</div>",
            html_escape(text)
        ));
    }
    body.push_str("</pre>");
    if target > 0 {
        body.push_str(&format!(
            "<script>document.getElementById('L{target}')?.scrollIntoView({{block:'center'}});</script>"
        ));
    }
    body.push_str("</body></html>");
    Ok(body)
}

fn sanitize_raw_rel_path(rel_path: &str) -> Option<String> {
    let trimmed = rel_path.trim().trim_start_matches('/');
    if trimmed.is_empty() || trimmed.contains('\0') {
        return None;
    }
    let path = Path::new(trimmed);
    if !trimmed.starts_with("raw/") {
        return None;
    }
    for component in path.components() {
        match component {
            Component::Normal(_) => {}
            _ => return None,
        }
    }
    Some(trimmed.to_string())
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
