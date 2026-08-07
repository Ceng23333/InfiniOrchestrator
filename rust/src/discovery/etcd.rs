//! etcd-backed service discovery via HTTP v3 API (no gRPC/protoc required)

use super::{parse_etcd_endpoints, DiscoveryBackend};
use crate::discovery::types::{DiscoveryInstance, RegistrationHandle, WatchEvent};
use anyhow::{Context, Result};
use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tracing::{debug, warn};

/// etcd discovery backend using the HTTP v3 API
pub struct EtcdDiscovery {
    endpoint: String,
    prefix: String,
    client: Client,
    auth_token: Arc<Mutex<Option<String>>>,
}

impl EtcdDiscovery {
    pub async fn connect(endpoints: Vec<String>, prefix: String) -> Result<Self> {
        let endpoint = endpoints
            .first()
            .cloned()
            .context("At least one etcd endpoint is required")?;

        Ok(Self {
            endpoint: endpoint.trim_end_matches('/').to_string(),
            prefix: prefix.trim_end_matches('/').to_string(),
            client: Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .context("Failed to create etcd HTTP client")?,
            auth_token: Arc::new(Mutex::new(None)),
        })
    }

    pub async fn from_env() -> Result<Self> {
        let endpoints_raw = std::env::var("ETCD_ENDPOINTS")
            .context("ETCD_ENDPOINTS environment variable is required")?;
        let endpoints = parse_etcd_endpoints(&endpoints_raw);
        if endpoints.is_empty() {
            anyhow::bail!("ETCD_ENDPOINTS must contain at least one endpoint");
        }
        let prefix = super::default_discovery_prefix();
        Self::connect(endpoints, prefix).await
    }

    pub fn prefix(&self) -> &str {
        &self.prefix
    }

    fn instances_prefix(&self) -> String {
        format!("{}/instances/", self.prefix)
    }

    fn encode_key(key: &str) -> String {
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, key.as_bytes())
    }

    fn decode_value(value_b64: &str) -> Result<DiscoveryInstance> {
        let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, value_b64)
            .context("Failed to base64-decode etcd value")?;
        serde_json::from_slice(&bytes).context("Failed to parse instance JSON")
    }

    async fn post_json(&self, path: &str, body: serde_json::Value) -> Result<serde_json::Value> {
        let url = format!("{endpoint}{path}", endpoint = self.endpoint);
        let mut req = self.client.post(url).json(&body);
        if let Some(token) = self.auth_token.lock().await.clone() {
            req = req.header("Authorization", token);
        }
        let resp = req.send().await.context("etcd HTTP request failed")?;
        if !resp.status().is_success() {
            anyhow::bail!("etcd HTTP error: {}", resp.status());
        }
        resp.json().await.context("Failed to parse etcd JSON response")
    }

    async fn grant_lease(&self, ttl_secs: i64) -> Result<i64> {
        let resp = self
            .post_json("/v3/lease/grant", json!({ "TTL": ttl_secs }))
            .await?;
        let id = resp
            .get("ID")
            .and_then(|v| {
                v.as_str()
                    .and_then(|s| s.parse::<i64>().ok())
                    .or_else(|| v.as_u64().map(|n| n as i64))
            })
            .context("Invalid lease ID in etcd response")?;
        Ok(id)
    }

    async fn start_keepalive(&self, lease_id: i64) {
        let this = self.clone_inner();
        tokio::spawn(async move {
            loop {
                if let Err(e) = this
                    .post_json("/v3/lease/keepalive", json!({ "ID": lease_id.to_string() }))
                    .await
                {
                    warn!("etcd lease keepalive failed for {}: {}", lease_id, e);
                }
                tokio::time::sleep(Duration::from_secs(10)).await;
            }
        });
    }

    fn clone_inner(&self) -> Self {
        Self {
            endpoint: self.endpoint.clone(),
            prefix: self.prefix.clone(),
            client: self.client.clone(),
            auth_token: self.auth_token.clone(),
        }
    }
}

#[async_trait]
impl DiscoveryBackend for EtcdDiscovery {
    async fn register(
        &self,
        instance: &DiscoveryInstance,
        ttl_secs: i64,
    ) -> Result<RegistrationHandle> {
        let key = DiscoveryInstance::instance_key(&self.prefix, &instance.instance_id);
        let value = serde_json::to_vec(instance)?;
        let lease_id = self.grant_lease(ttl_secs).await?;

        self.post_json(
            "/v3/kv/put",
            json!({
                "key": Self::encode_key(&key),
                "value": base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &value),
                "lease": lease_id.to_string(),
            }),
        )
        .await?;

        self.start_keepalive(lease_id).await;

        debug!(
            "Registered instance {} at key {} (lease {})",
            instance.instance_id, key, lease_id
        );

        Ok(RegistrationHandle {
            instance_id: instance.instance_id.clone(),
            key,
            lease_id,
        })
    }

    async fn heartbeat(&self, handle: &RegistrationHandle) -> Result<()> {
        self.post_json(
            "/v3/lease/keepalive",
            json!({ "ID": handle.lease_id.to_string() }),
        )
        .await?;
        Ok(())
    }

    async fn unregister(&self, handle: &RegistrationHandle) -> Result<()> {
        self.post_json(
            "/v3/kv/deleterange",
            json!({
                "key": Self::encode_key(&handle.key),
                "range_end": Self::encode_key(&format!("{}\x00", handle.key)),
            }),
        )
        .await?;
        let _ = self
            .post_json("/v3/lease/revoke", json!({ "ID": handle.lease_id.to_string() }))
            .await;
        Ok(())
    }

    async fn list_instances(&self) -> Result<Vec<DiscoveryInstance>> {
        let prefix = self.instances_prefix();
        let resp = self
            .post_json(
                "/v3/kv/range",
                json!({
                    "key": Self::encode_key(&prefix),
                    "range_end": Self::encode_key(&prefix_successor(&prefix)),
                }),
            )
            .await?;

        let mut instances = Vec::new();
        if let Some(kvs) = resp.get("kvs").and_then(|v| v.as_array()) {
            for kv in kvs {
                if let (Some(key_b64), Some(val_b64)) = (
                    kv.get("key").and_then(|v| v.as_str()),
                    kv.get("value").and_then(|v| v.as_str()),
                ) {
                    let key = String::from_utf8_lossy(
                        &base64::Engine::decode(
                            &base64::engine::general_purpose::STANDARD,
                            key_b64,
                        )
                        .unwrap_or_default(),
                    )
                    .to_string();
                    if let Ok(mut instance) = Self::decode_value(val_b64) {
                        if instance.instance_id.is_empty() {
                            if let Some(id) = key.rsplit('/').next() {
                                instance.instance_id = id.to_string();
                            }
                        }
                        instances.push(instance);
                    }
                }
            }
        }
        Ok(instances)
    }

    async fn watch_instances(
        &self,
    ) -> Result<tokio::sync::mpsc::Receiver<anyhow::Result<WatchEvent>>> {
        // HTTP watch is complex; use polling channel driven by periodic list diff
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        let this = self.clone_inner();
        tokio::spawn(async move {
            let mut known: std::collections::HashMap<String, DiscoveryInstance> =
                std::collections::HashMap::new();
            loop {
                match this.list_instances().await {
                    Ok(instances) => {
                        let current_ids: std::collections::HashSet<String> =
                            instances.iter().map(|i| i.instance_id.clone()).collect();

                        for instance in &instances {
                            let prev = known.get(&instance.instance_id);
                            if prev.map(|p| p.url.as_str()) != Some(instance.url.as_str())
                                || prev.map(|p| p.status.as_str()) != Some(instance.status.as_str())
                            {
                                let _ = tx.send(Ok(WatchEvent::Put(instance.clone()))).await;
                            }
                        }

                        for id in known.keys() {
                            if !current_ids.contains(id) {
                                let _ = tx
                                    .send(Ok(WatchEvent::Delete {
                                        instance_id: id.clone(),
                                    }))
                                    .await;
                            }
                        }

                        known = instances
                            .into_iter()
                            .map(|i| (i.instance_id.clone(), i))
                            .collect();
                    }
                    Err(e) => {
                        let _ = tx.send(Err(e)).await;
                    }
                }
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        });
        Ok(rx)
    }
}

fn prefix_successor(prefix: &str) -> String {
    let mut bytes = prefix.as_bytes().to_vec();
    if let Some(last) = bytes.last_mut() {
        *last = last.saturating_add(1);
    }
    String::from_utf8(bytes).unwrap_or_else(|_| format!("{prefix}\x00"))
}
