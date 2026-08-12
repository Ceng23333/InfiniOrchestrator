//! Load balancer implementation

use crate::config::Config;
use crate::discovery::types::WatchEvent;
use crate::discovery::{DiscoveryBackend, EtcdDiscovery};
use crate::load_balancer::health_checker::HealthChecker;
use crate::load_balancer::service_instance::ServiceInstance;
use crate::metrics::GatewayMetrics;
use crate::utils::errors::RouterError;
use crate::utils::time::current_timestamp;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::time::{sleep, Duration};
use tracing::{error, info, warn};

/// Load balancer for managing service instances
pub struct LoadBalancer {
    services: Arc<RwLock<HashMap<String, ServiceInstance>>>,
    pub discovery_prefix: String,
    pub etcd_endpoints: Option<Vec<String>>,
    /// Deprecated: kept for panel compatibility
    pub registry_url: Option<String>,
    current_index: Arc<RwLock<usize>>,
    health_check_interval: u64,
    discovery_sync_interval: u64,
    service_removal_grace_period: u64,
    #[allow(dead_code)]
    config: Config,
    health_checker: Arc<HealthChecker>,
    discovery: Option<Arc<dyn DiscoveryBackend>>,
    running: Arc<RwLock<bool>>,
    pub metrics: Arc<GatewayMetrics>,
}

impl LoadBalancer {
    /// Create a new load balancer
    #[allow(clippy::too_many_arguments)]
    pub async fn new(config: &Config) -> Result<Self, RouterError> {
        let mut services = HashMap::new();

        // Add static services if configured
        if let Some(ref static_services) = config.static_services {
            for service_config in static_services {
                let metadata: HashMap<String, serde_json::Value> = service_config
                    .metadata
                    .as_object()
                    .map(|obj| obj.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
                    .unwrap_or_default();

                let service = ServiceInstance::new(
                    service_config.name.clone(),
                    service_config.host.clone(),
                    service_config.port,
                    service_config.weight,
                    metadata,
                );

                info!("Added static service: {} at {}", service.name, service.url);
                services.insert(service_config.name.clone(), service);
            }
        }

        let health_checker = Arc::new(HealthChecker::new(
            Duration::from_secs(config.health_check_timeout),
            config.max_errors,
        ));

        let discovery = if config.discovery_enabled() {
            let endpoints = config.etcd_endpoints.clone().or_else(|| {
                std::env::var("ETCD_ENDPOINTS")
                    .ok()
                    .map(|raw| crate::discovery::parse_etcd_endpoints(&raw))
            });
            if let Some(endpoints) = endpoints.filter(|e| !e.is_empty()) {
                match EtcdDiscovery::connect(endpoints, config.discovery_prefix.clone()).await {
                    Ok(backend) => Some(Arc::new(backend) as Arc<dyn DiscoveryBackend>),
                    Err(e) => {
                        warn!("Failed to connect to etcd: {}", e);
                        None
                    }
                }
            } else {
                None
            }
        } else {
            None
        };

        Ok(LoadBalancer {
            services: Arc::new(RwLock::new(services)),
            discovery_prefix: config.discovery_prefix.clone(),
            etcd_endpoints: config.etcd_endpoints.clone(),
            registry_url: config.registry_url.clone(),
            current_index: Arc::new(RwLock::new(0)),
            health_check_interval: config.health_check_interval,
            discovery_sync_interval: config.discovery_sync_interval,
            service_removal_grace_period: config.service_removal_grace_period,
            config: config.clone(),
            health_checker,
            discovery,
            running: Arc::new(RwLock::new(true)),
            metrics: Arc::new(GatewayMetrics::new()),
        })
    }

    /// Get next healthy service using weighted round-robin
    #[allow(dead_code)]
    pub async fn get_next_healthy_service(&self) -> Option<ServiceInstance> {
        let services = self.services.read().await;
        let all_services: Vec<_> = services.values().cloned().collect();
        drop(services); // Release the lock

        // Check health status for all services
        let health_checks: Vec<bool> =
            futures::future::join_all(all_services.iter().map(|s| s.is_healthy())).await;

        let healthy_services: Vec<_> = all_services
            .into_iter()
            .zip(health_checks)
            .filter(|(_, healthy)| *healthy)
            .map(|(service, _)| service)
            .collect();

        if healthy_services.is_empty() {
            error!("No healthy services available");
            return None;
        }

        // Weighted round-robin selection
        let total_weight: u32 = healthy_services.iter().map(|s| s.weight).sum();
        if total_weight == 0 {
            // Fallback to simple round-robin
            let mut index = self.current_index.write().await;
            let service = healthy_services[*index % healthy_services.len()].clone();
            *index += 1;
            service.increment_request_count().await;
            return Some(service);
        }

        // Weighted selection
        let mut current_index = self.current_index.write().await;
        let target_weight = (*current_index % total_weight as usize) as u32;
        *current_index += 1;
        drop(current_index); // Release the lock

        let mut current_weight = 0;
        for service in &healthy_services {
            current_weight += service.weight;
            if current_weight > target_weight {
                service.increment_request_count().await;
                return Some(service.clone());
            }
        }

        // Fallback
        let service = healthy_services[0].clone();
        service.increment_request_count().await;
        Some(service)
    }

    /// Get next healthy service by model ID
    pub async fn get_next_healthy_service_by_model(
        &self,
        model_id: Option<&str>,
    ) -> Option<ServiceInstance> {
        let services = self.services.read().await;
        let all_services: Vec<_> = services.values().cloned().collect();
        drop(services); // Release the lock

        // Check health status for all services
        let health_checks: Vec<bool> =
            futures::future::join_all(all_services.iter().map(|s| s.is_healthy())).await;

        let mut healthy_services: Vec<_> = all_services
            .into_iter()
            .zip(health_checks)
            .filter(|(_, healthy)| *healthy)
            .map(|(service, _)| service)
            .collect();

        // Filter by model if specified
        if let Some(model_id) = model_id {
            let mut filtered_services = Vec::new();
            for service in &healthy_services {
                let models = service.models.read().await;
                if models.contains(&model_id.to_string()) {
                    filtered_services.push(service.clone());
                }
            }
            healthy_services = filtered_services;

            if healthy_services.is_empty() {
                warn!("No healthy services available for model '{}'", model_id);
                return None;
            }
        }

        if healthy_services.is_empty() {
            error!("No healthy services available");
            return None;
        }

        // Weighted round-robin selection (same as get_next_healthy_service)
        let total_weight: u32 = healthy_services.iter().map(|s| s.weight).sum();
        if total_weight == 0 {
            let mut index = self.current_index.write().await;
            let service = healthy_services[*index % healthy_services.len()].clone();
            *index += 1;
            service.increment_request_count().await;
            return Some(service);
        }

        let mut current_index = self.current_index.write().await;
        let target_weight = (*current_index % total_weight as usize) as u32;
        *current_index += 1;
        drop(current_index); // Release the lock

        let mut current_weight = 0;
        for service in &healthy_services {
            current_weight += service.weight;
            if current_weight > target_weight {
                service.increment_request_count().await;
                return Some(service.clone());
            }
        }

        let service = healthy_services[0].clone();
        service.increment_request_count().await;
        Some(service)
    }

    /// Get service by session key using consistent hashing
    /// Uses hash of session_key to deterministically map to a service from the available healthy services
    /// This ensures the same session always routes to the same service (when healthy)
    pub async fn get_service_by_session(
        &self,
        session_key: &str,
        model_id: Option<&str>,
    ) -> Option<ServiceInstance> {
        // Get all healthy services that support the model
        let services = self.services.read().await;
        let all_services: Vec<_> = services.values().cloned().collect();
        drop(services);

        // Check health status for all services
        let health_checks: Vec<bool> =
            futures::future::join_all(all_services.iter().map(|s| s.is_healthy())).await;

        let mut healthy_services: Vec<_> = all_services
            .into_iter()
            .zip(health_checks)
            .filter(|(_, healthy)| *healthy)
            .map(|(service, _)| service)
            .collect();

        // Filter by model if specified
        if let Some(model_id) = model_id {
            let mut filtered_services = Vec::new();
            for service in &healthy_services {
                let models = service.models.read().await;
                if models.contains(&model_id.to_string()) {
                    filtered_services.push(service.clone());
                }
            }
            healthy_services = filtered_services;

            if healthy_services.is_empty() {
                warn!("No healthy services available for model '{}'", model_id);
                return None;
            }
        }

        if healthy_services.is_empty() {
            error!("No healthy services available");
            return None;
        }

        // Use hash of session_key to deterministically select a service
        // This ensures the same session always routes to the same service
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        session_key.hash(&mut hasher);
        let hash_value = hasher.finish();
        let service_index = (hash_value as usize) % healthy_services.len();

        let selected_service = healthy_services[service_index].clone();
        selected_service.increment_request_count().await;
        Some(selected_service)
    }

    /// Get service by cache type using weighted round-robin
    /// Filters healthy services by cache_type metadata and optionally by model_id
    /// Returns None if no matching healthy services are available
    pub async fn get_service_by_cache_type(
        &self,
        cache_type: &str,
        model_id: Option<&str>,
    ) -> Option<ServiceInstance> {
        // Get all healthy services
        let services = self.services.read().await;
        let all_services: Vec<_> = services.values().cloned().collect();
        drop(services);

        // Check health status for all services
        let health_checks: Vec<bool> =
            futures::future::join_all(all_services.iter().map(|s| s.is_healthy())).await;

        let mut healthy_services: Vec<_> = all_services
            .into_iter()
            .zip(health_checks)
            .filter(|(_, healthy)| *healthy)
            .map(|(service, _)| service)
            .collect();

        // Filter by cache_type metadata
        let mut filtered_services = Vec::new();
        for service in &healthy_services {
            if let Some(metadata_cache_type) = service
                .metadata
                .get("cache_type")
                .and_then(|v| v.as_str())
            {
                if metadata_cache_type == cache_type {
                    filtered_services.push(service.clone());
                }
            }
        }
        healthy_services = filtered_services;

        if healthy_services.is_empty() {
            warn!(
                "No healthy services available with cache_type '{}'",
                cache_type
            );
            return None;
        }

        // Filter by model if specified
        if let Some(model_id) = model_id {
            let mut filtered_services = Vec::new();
            for service in &healthy_services {
                let models = service.models.read().await;
                if models.contains(&model_id.to_string()) {
                    filtered_services.push(service.clone());
                }
            }
            healthy_services = filtered_services;

            if healthy_services.is_empty() {
                warn!(
                    "No healthy services available for model '{}' with cache_type '{}'",
                    model_id, cache_type
                );
                return None;
            }
        }

        // Weighted round-robin selection
        let total_weight: u32 = healthy_services.iter().map(|s| s.weight).sum();
        if total_weight == 0 {
            let mut index = self.current_index.write().await;
            let service = healthy_services[*index % healthy_services.len()].clone();
            *index += 1;
            service.increment_request_count().await;
            return Some(service);
        }

        let mut current_index = self.current_index.write().await;
        let target_weight = (*current_index % total_weight as usize) as u32;
        *current_index += 1;
        drop(current_index); // Release the lock

        let mut current_weight = 0;
        for service in &healthy_services {
            current_weight += service.weight;
            if current_weight > target_weight {
                service.increment_request_count().await;
                return Some(service.clone());
            }
        }

        let service = healthy_services[0].clone();
        service.increment_request_count().await;
        Some(service)
    }

    /// Start health check background task
    pub async fn start_health_checks(&self) {
        let services = self.services.clone();
        let health_checker = self.health_checker.clone();
        let interval = self.health_check_interval;
        let running = self.running.clone();

        info!("Health check task started (interval: {}s)", interval);

        std::mem::drop(tokio::spawn(async move {
            while *running.read().await {
                let services_clone = services.clone();
                let health_checker_clone = health_checker.clone();

                std::mem::drop(tokio::spawn(async move {
                    let services_guard = services_clone.read().await;
                    let services_list: Vec<_> = services_guard.values().cloned().collect();
                    drop(services_guard);

                    if !services_list.is_empty() {
                        // Perform health checks in parallel
                        let health_results: Vec<bool> =
                            futures::future::join_all(services_list.iter().map(|service| {
                                let health_checker = health_checker_clone.clone();
                                let service = service.clone();
                                async move { health_checker.check_health(&service).await }
                            }))
                            .await;

                        let healthy_count = health_results.iter().filter(|&&h| h).count();
                        info!(
                            "Health check completed: {}/{} services healthy",
                            healthy_count,
                            services_list.len()
                        );

                        // Log unhealthy services
                        for service in &services_list {
                            let error_count = *service.error_count.read().await;
                            let is_healthy = service.is_healthy().await;
                            if !is_healthy && error_count >= health_checker_clone.max_errors {
                                warn!(
                                    "Service {} is unhealthy (errors: {})",
                                    service.name, error_count
                                );
                            }
                        }
                    }
                }));

                sleep(Duration::from_secs(interval)).await;
            }
        }));
    }

    /// Start etcd discovery sync (list + watch + periodic refresh)
    pub async fn start_discovery_sync(&self) {
        let discovery = match &self.discovery {
            Some(client) => client.clone(),
            None => {
                warn!("Discovery sync requested but etcd is not configured");
                return;
            }
        };

        let services = self.services.clone();
        let interval = self.discovery_sync_interval;
        let grace_period = self.service_removal_grace_period;
        let running = self.running.clone();

        info!("Discovery sync task started (interval: {}s)", interval);

        if let Ok(instances) = discovery.list_instances().await {
            Self::apply_discovery_instances(&services, &instances, grace_period).await;
        }

        if let Ok(mut watch_rx) = discovery.watch_instances().await {
            let services_watch = services.clone();
            let grace = grace_period;
            tokio::spawn(async move {
                while let Some(event) = watch_rx.recv().await {
                    match event {
                        Ok(WatchEvent::Put(instance)) => {
                            Self::apply_discovery_instances(
                                &services_watch,
                                std::slice::from_ref(&instance),
                                grace,
                            )
                            .await;
                        }
                        Ok(WatchEvent::Delete { instance_id }) => {
                            let mut guard = services_watch.write().await;
                            if let Some(service) = guard.get(&instance_id) {
                                let is_static = service
                                    .metadata
                                    .get("static")
                                    .and_then(|v| v.as_bool())
                                    .unwrap_or(false);
                                if !is_static {
                                    guard.remove(&instance_id);
                                    info!("Removed service from discovery watch: {}", instance_id);
                                }
                            }
                        }
                        Err(e) => warn!("Discovery watch error: {}", e),
                    }
                }
            });
        }

        std::mem::drop(tokio::spawn(async move {
            while *running.read().await {
                if let Ok(instances) = discovery.list_instances().await {
                    Self::apply_discovery_instances(&services, &instances, grace_period).await;
                }
                sleep(Duration::from_secs(interval)).await;
            }
        }));
    }

    async fn apply_discovery_instances(
        services: &Arc<RwLock<HashMap<String, ServiceInstance>>>,
        instances: &[crate::discovery::types::DiscoveryInstance],
        grace_period: u64,
    ) {
        let mut services_guard = services.write().await;
        let current_time = current_timestamp();
        let discovered_names: HashSet<String> = instances
            .iter()
            .filter(|inst| {
                inst.metadata
                    .get("type")
                    .and_then(|v| v.as_str())
                    .map(|s| s == "openai-api")
                    .unwrap_or(false)
            })
            .map(|inst| inst.name.clone())
            .collect();

        for instance in instances {
            let service_metadata = instance.metadata.clone();
            if !service_metadata
                .get("type")
                .and_then(|v| v.as_str())
                .map(|s| s == "openai-api")
                .unwrap_or(false)
            {
                continue;
            }

            let service_name = instance.name.clone();

            if let Some(existing_service) = services_guard.get_mut(&service_name) {
                existing_service.host = instance.host.clone();
                existing_service.port = instance.port;
                existing_service.url = instance.url.clone();
                existing_service
                    .set_healthy(instance.is_healthy())
                    .await;
                existing_service.metadata = service_metadata.clone();
                existing_service.update_last_seen().await;

                let models: Vec<String> = service_metadata
                    .get("models")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default();
                *existing_service.models.write().await = models;

                let entrypoint_port = existing_service.port + 1;
                existing_service.entrypoint_url = format!(
                    "http://{}:{}",
                    existing_service.host, entrypoint_port
                );
            } else {
                let models: Vec<String> = service_metadata
                    .get("models")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default();

                let models_for_log = models.clone();
                let new_service = ServiceInstance::new(
                    instance.name.clone(),
                    instance.host.clone(),
                    instance.port,
                    instance.weight,
                    service_metadata,
                );

                *new_service.models.write().await = models;
                new_service.set_healthy(instance.is_healthy()).await;
                new_service.update_last_seen().await;

                info!(
                    "Added OpenAI API service from discovery: {} at {} (entrypoint: {}, models: {:?})",
                    new_service.name, new_service.url, new_service.entrypoint_url, models_for_log
                );

                services_guard.insert(service_name, new_service);
            }
        }

        let mut services_to_remove = Vec::new();
        for (name, service) in services_guard.iter() {
            if !discovered_names.contains(name) {
                let is_static = service
                    .metadata
                    .get("static")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                if !is_static {
                    let last_seen = *service.last_seen.read().await;
                    let time_since_last_seen = current_time - last_seen;
                    if time_since_last_seen >= grace_period as f64 {
                        services_to_remove.push(name.clone());
                    }
                }
            }
        }

        for service_name in services_to_remove {
            services_guard.remove(&service_name);
            info!(
                "Removed service from discovery (after {}s grace period): {}",
                grace_period, service_name
            );
        }
    }

    /// Stop background tasks
    #[allow(dead_code)]
    pub async fn stop(&self) {
        let mut running = self.running.write().await;
        *running = false;
    }

    /// Get all services
    pub async fn get_all_services(&self) -> Vec<ServiceInstance> {
        let services = self.services.read().await;
        services.values().cloned().collect()
    }
}
