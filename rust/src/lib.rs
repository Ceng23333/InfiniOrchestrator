//! InfiniLM-SVC Library
//! Shared modules for load balancer, discovery, entrypoint, and share pool binaries

pub mod config;
pub mod discovery;
pub mod entrypoint;
pub mod handlers;
pub mod load_balancer;
pub mod metrics;
pub mod models;
pub mod proxy;
pub mod registry;
pub mod share_pool;
pub mod utils;

pub use entrypoint::EntrypointState;

// Backward-compatible re-exports
pub use entrypoint::BabysitterState;
