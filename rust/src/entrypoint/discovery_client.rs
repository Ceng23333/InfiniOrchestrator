//! Discovery client for InfiniEntrypoint (etcd-backed)

use crate::discovery::types::{DiscoveryInstance, RegistrationHandle};
use crate::discovery::{parse_etcd_endpoints, DiscoveryBackend, EtcdDiscovery};
use crate::entrypoint::EntrypointState;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::time::{sleep, Duration};
use tracing::{error, info, warn};

pub struct EntrypointDiscoveryClient {
    discovery: Arc<dyn DiscoveryBackend>,
    state: Arc<EntrypointState>,
    entrypoint_handle: Arc<RwLock<Option<RegistrationHandle>>>,
    managed_handle: Arc<RwLock<Option<RegistrationHandle>>>,
    http_client: reqwest::Client,
}

impl EntrypointDiscoveryClient {
    pub async fn new(state: Arc<EntrypointState>) -> anyhow::Result<Self> {
        let config = &state.config;
        let endpoints = if let Some(raw) = &config.etcd_endpoints {
            parse_etcd_endpoints(raw)
        } else if let Ok(raw) = std::env::var("ETCD_ENDPOINTS") {
            parse_etcd_endpoints(&raw)
        } else {
            anyhow::bail!("etcd discovery requires --etcd-endpoints or ETCD_ENDPOINTS");
        };

        let prefix = config
            .discovery_prefix
            .clone()
            .or_else(|| std::env::var("DISCOVERY_PREFIX").ok())
            .unwrap_or_else(|| "/infinilm".to_string());

        let discovery = EtcdDiscovery::connect(endpoints, prefix).await?;
        Ok(Self {
            discovery: Arc::new(discovery),
            state,
            entrypoint_handle: Arc::new(RwLock::new(None)),
            managed_handle: Arc::new(RwLock::new(None)),
            http_client: reqwest::Client::new(),
        })
    }

    pub async fn run(&self) {
        if let Err(e) = self.register_entrypoint().await {
            error!("Failed to register entrypoint: {}", e);
        }

        tokio::spawn({
            let client = self.clone_inner();
            async move {
                client.register_managed_service().await;
            }
        });

        loop {
            sleep(Duration::from_secs(self.state.config.heartbeat_interval)).await;

            if self.entrypoint_handle.read().await.is_some() {
                if let Some(handle) = self.entrypoint_handle.read().await.clone() {
                    if let Err(e) = self.discovery.heartbeat(&handle).await {
                        warn!("Entrypoint heartbeat failed, re-registering: {}", e);
                        let _ = self.register_entrypoint().await;
                    }
                }
            }

            if let Some(port) = *self.state.service_port.read().await {
                if self.managed_handle.read().await.is_none() {
                    let _ = self.do_register_managed_service(port).await;
                } else if let Some(handle) = self.managed_handle.read().await.clone() {
                    if let Err(e) = self.discovery.heartbeat(&handle).await {
                        warn!("Managed service heartbeat failed, re-registering: {}", e);
                        let _ = self.do_register_managed_service(port).await;
                    }
                }
            }
        }
    }

    async fn register_entrypoint(&self) -> anyhow::Result<()> {
        let service_name = self.state.config.service_name();
        let instance = DiscoveryInstance {
            instance_id: service_name.clone(),
            name: service_name,
            host: self.state.config.host.clone(),
            port: self.state.entrypoint_port(),
            hostname: self.state.config.host.clone(),
            url: format!(
                "http://{}:{}",
                self.state.config.host,
                self.state.entrypoint_port()
            ),
            status: "running".to_string(),
            metadata: HashMap::from([
                (
                    "type".to_string(),
                    serde_json::json!(self.state.config.service_type),
                ),
                ("entrypoint".to_string(), serde_json::json!("enhanced")),
                (
                    "server_id".to_string(),
                    serde_json::json!(self.state.server_id),
                ),
            ]),
            weight: 1,
        };

        let handle = self
            .discovery
            .register(&instance, self.state.config.heartbeat_interval as i64)
            .await?;
        *self.entrypoint_handle.write().await = Some(handle);
        info!("Entrypoint registered via etcd discovery");
        Ok(())
    }

    async fn register_managed_service(&self) {
        loop {
            let service_port = *self.state.service_port.read().await;
            if service_port.is_none() {
                sleep(Duration::from_millis(100)).await;
                continue;
            }
            if self.do_register_managed_service(service_port.unwrap()).await {
                break;
            }
            sleep(Duration::from_secs(2)).await;
        }
    }

    async fn fetch_models(&self, port: u16) -> Vec<serde_json::Value> {
        let urls = [
            format!("http://127.0.0.1:{port}/v1/models"),
            format!("http://127.0.0.1:{port}/models"),
        ];

        for attempt in 0..50 {
            for url in &urls {
                match self.http_client.get(url).send().await {
                    Ok(response) if response.status().is_success() => {
                        if let Ok(data) = response.json::<serde_json::Value>().await {
                            let models = if let Some(models) =
                                data.get("data").and_then(|v| v.as_array())
                            {
                                models.clone()
                            } else if data.is_array() {
                                data.as_array().unwrap().clone()
                            } else {
                                continue;
                            };
                            if !models.is_empty() {
                                info!("Fetched {} models from service via {}", models.len(), url);
                                return models;
                            }
                        }
                    }
                    Ok(_) | Err(_) => {}
                }
            }
            if attempt < 19 {
                sleep(Duration::from_millis(300)).await;
            } else {
                sleep(Duration::from_secs(1)).await;
            }
        }

        warn!("Failed to fetch models from service after 50 attempts");
        vec![]
    }

    async fn do_register_managed_service(&self, service_port: u16) -> bool {
        let models = self.fetch_models(service_port).await;
        if models.is_empty() {
            warn!("No models fetched from service, cannot register");
            return false;
        }

        let service_name = self.state.config.service_name();
        let instance_id = format!("{service_name}-server");

        {
            let mut cache = self.state.models_cache.write().await;
            *cache = models.clone();
        }

        let mut metadata = serde_json::json!({
            "type": "openai-api",
            "parent_service": service_name,
            "entrypoint": "enhanced",
            "server_id": self.state.server_id,
            "models": models.iter().map(|m| m.get("id").and_then(|v| v.as_str()).unwrap_or("")).collect::<Vec<_>>(),
            "models_list": models
        });

        if let Some(ref config_file) = self.state.config_file {
            if let Some(metadata_obj) = metadata.as_object_mut() {
                for (key, value) in config_file.metadata_json() {
                    metadata_obj.insert(key, value);
                }
            }
        }

        let metadata_map: HashMap<String, serde_json::Value> = metadata
            .as_object()
            .map(|obj| obj.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
            .unwrap_or_default();

        let instance = DiscoveryInstance {
            instance_id: instance_id.clone(),
            name: instance_id,
            host: self.state.config.host.clone(),
            port: service_port,
            hostname: self.state.config.host.clone(),
            url: format!("http://{}:{service_port}", self.state.config.host),
            status: "running".to_string(),
            metadata: metadata_map,
            weight: 1,
        };

        match self
            .discovery
            .register(&instance, self.state.config.heartbeat_interval as i64)
            .await
        {
            Ok(handle) => {
                *self.managed_handle.write().await = Some(handle);
                info!(
                    "Managed service registered via etcd discovery ({} models)",
                    models.len()
                );
                true
            }
            Err(e) => {
                error!("Error registering managed service: {}", e);
                false
            }
        }
    }

    fn clone_inner(&self) -> Self {
        Self {
            discovery: self.discovery.clone(),
            state: self.state.clone(),
            entrypoint_handle: self.entrypoint_handle.clone(),
            managed_handle: self.managed_handle.clone(),
            http_client: self.http_client.clone(),
        }
    }
}
