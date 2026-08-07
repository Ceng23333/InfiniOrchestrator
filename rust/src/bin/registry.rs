//! Deprecated HTTP registry stub

fn main() {
    eprintln!("infini-registry has been removed; use etcd discovery instead.");
    eprintln!("Set ETCD_ENDPOINTS and DISCOVERY_PREFIX for InfiniEntrypoint and InfiniLoadBalancer.");
    std::process::exit(1);
}
