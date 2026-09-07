//! Process-local KV cache event index used by the pre-M6 sharepool sink.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use tracing::info;

#[derive(Debug, Clone)]
pub struct SharePoolConfig {
    pub port: u16,
    pub max_blocks: usize,
}
impl Default for SharePoolConfig {
    fn default() -> Self {
        Self {
            port: 8082,
            max_blocks: 100_000,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct KvEventsRequest {
    pub events: Vec<KvEvent>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum KvEvent {
    BlockStored {
        worker_id: String,
        generation: u64,
        model_id: String,
        page_size: u32,
        block_keys: Vec<String>,
        #[serde(default)]
        tier: Option<String>,
    },
    BlockRemoved {
        worker_id: String,
        generation: u64,
        block_keys: Vec<String>,
    },
    AllBlocksCleared {
        worker_id: String,
        generation: u64,
    },
}
#[derive(Debug, Clone, Deserialize)]
pub struct OverlapRequest {
    pub model_id: String,
    pub page_size: u32,
    pub block_keys: Vec<String>,
}
#[derive(Debug, Clone, Serialize)]
pub struct IndexSummary {
    pub index_entries: usize,
    pub generation: u64,
    pub workers: HashMap<String, usize>,
}
#[derive(Debug, Clone, Serialize)]
pub struct OverlapResponse {
    pub model_id: String,
    pub page_size: u32,
    pub longest_prefix_by_worker: HashMap<String, usize>,
}

#[derive(Debug, Clone, Hash, PartialEq, Eq)]
struct BlockId {
    model_id: String,
    page_size: u32,
    block_key: String,
}
#[derive(Debug, Clone, Hash, PartialEq, Eq)]
struct WorkerGeneration {
    worker_id: String,
    generation: u64,
}
#[derive(Debug)]
pub struct SharePoolState {
    blocks: HashMap<BlockId, HashSet<WorkerGeneration>>,
    generations: HashMap<String, u64>,
    max_blocks: usize,
}

impl SharePoolState {
    pub fn new(max_blocks: usize) -> Self {
        Self {
            blocks: HashMap::new(),
            generations: HashMap::new(),
            max_blocks,
        }
    }
    fn generation_is_current(&self, worker: &str, generation: u64) -> bool {
        self.generations.get(worker).copied().unwrap_or(0) <= generation
    }
    fn clear_worker(&mut self, worker: &str, generation: u64) {
        if !self.generation_is_current(worker, generation) {
            return;
        }
        self.generations.insert(worker.to_owned(), generation);
        self.blocks.retain(|_, owners| {
            owners.retain(|owner| owner.worker_id != worker);
            !owners.is_empty()
        });
    }
    pub fn ingest(&mut self, event: KvEvent) {
        match event {
            KvEvent::AllBlocksCleared {
                worker_id,
                generation,
            } => self.clear_worker(&worker_id, generation),
            KvEvent::BlockStored {
                worker_id,
                generation,
                model_id,
                page_size,
                block_keys,
                ..
            } => {
                if !self.generation_is_current(&worker_id, generation) {
                    return;
                }
                self.generations
                    .entry(worker_id.clone())
                    .or_insert(generation);
                let owner = WorkerGeneration {
                    worker_id,
                    generation,
                };
                for block_key in block_keys {
                    let id = BlockId {
                        model_id: model_id.clone(),
                        page_size,
                        block_key,
                    };
                    if self.blocks.len() >= self.max_blocks && !self.blocks.contains_key(&id) {
                        break;
                    }
                    self.blocks.entry(id).or_default().insert(owner.clone());
                }
            }
            KvEvent::BlockRemoved {
                worker_id,
                generation,
                block_keys,
            } => {
                if !self.generation_is_current(&worker_id, generation) {
                    return;
                }
                for id in self
                    .blocks
                    .keys()
                    .filter(|id| block_keys.contains(&id.block_key))
                    .cloned()
                    .collect::<Vec<_>>()
                {
                    if let Some(owners) = self.blocks.get_mut(&id) {
                        owners.retain(|owner| {
                            !(owner.worker_id == worker_id && owner.generation == generation)
                        });
                    }
                }
                self.blocks.retain(|_, owners| !owners.is_empty());
            }
        }
    }
    pub fn summary(&self) -> IndexSummary {
        let mut workers = HashMap::new();
        for owners in self.blocks.values() {
            for owner in owners {
                *workers.entry(owner.worker_id.clone()).or_insert(0) += 1;
            }
        }
        IndexSummary {
            index_entries: self.blocks.len(),
            generation: self.generations.values().copied().max().unwrap_or(0),
            workers,
        }
    }
    pub fn overlap(&self, request: &OverlapRequest) -> OverlapResponse {
        let mut result = HashMap::new();
        let workers: HashSet<String> = self
            .blocks
            .values()
            .flat_map(|owners| owners.iter().map(|o| o.worker_id.clone()))
            .collect();
        for worker in workers {
            let mut length = 0;
            for key in &request.block_keys {
                let id = BlockId {
                    model_id: request.model_id.clone(),
                    page_size: request.page_size,
                    block_key: key.clone(),
                };
                if self
                    .blocks
                    .get(&id)
                    .is_some_and(|owners| owners.iter().any(|o| o.worker_id == worker))
                {
                    length += 1;
                } else {
                    break;
                }
            }
            result.insert(worker, length);
        }
        OverlapResponse {
            model_id: request.model_id.clone(),
            page_size: request.page_size,
            longest_prefix_by_worker: result,
        }
    }
}
pub fn log_placeholder(config: &SharePoolConfig) {
    info!(
        "InfiniSharePool listening on port {} (max_blocks={})",
        config.port, config.max_blocks
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clear_fences_old_events_and_reduces_overlap() {
        let mut state = SharePoolState::new(100);
        state.ingest(KvEvent::BlockStored {
            worker_id: "a".into(),
            generation: 1,
            model_id: "m".into(),
            page_size: 16,
            block_keys: vec!["x".into(), "y".into()],
            tier: None,
        });
        let query = OverlapRequest {
            model_id: "m".into(),
            page_size: 16,
            block_keys: vec!["x".into(), "y".into()],
        };
        assert_eq!(state.overlap(&query).longest_prefix_by_worker["a"], 2);
        state.ingest(KvEvent::AllBlocksCleared {
            worker_id: "a".into(),
            generation: 2,
        });
        state.ingest(KvEvent::BlockStored {
            worker_id: "a".into(),
            generation: 1,
            model_id: "m".into(),
            page_size: 16,
            block_keys: vec!["x".into()],
            tier: None,
        });
        assert!(state.overlap(&query).longest_prefix_by_worker.is_empty());
    }
}
