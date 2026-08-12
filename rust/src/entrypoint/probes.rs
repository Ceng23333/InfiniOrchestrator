//! Host/build probes for Entrypoint GET /metadata (ported from InfiniMetadata).

use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs;
use std::process::Command;

pub fn resolve_frontend(service_type: &str) -> String {
    if let Ok(val) = std::env::var("INFINI_FRONTEND") {
        let trimmed = val.trim();
        if matches!(
            trimmed,
            "InfiniLM" | "InfiniOrchestrator" | "vLLM" | "OpenAI"
        ) {
            return trimmed.to_string();
        }
    }
    match service_type {
        "vLLM" => "vLLM".to_string(),
        "InfiniLM" | "InfiniLM-Rust" => "InfiniLM".to_string(),
        _ => "InfiniOrchestrator".to_string(),
    }
}

pub fn collect_build_info() -> Map<String, Value> {
    let mut out = Map::new();
    for key in ["IL_SHA", "IC_SHA", "IO_SHA", "BUILD_TS", "IMAGE_TAG"] {
        if let Ok(val) = std::env::var(key) {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                out.insert(key.to_lowercase(), Value::String(trimmed.to_string()));
            }
        }
    }
    if let Ok(build_sha) = std::env::var("INFINI_BUILD_SHA") {
        let trimmed = build_sha.trim();
        if !trimmed.is_empty() {
            out.entry("infinilm_build_sha".to_string())
                .or_insert_with(|| Value::String(trimmed.to_string()));
        }
    }
    let image_tag = out
        .get("image_tag")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| std::env::var("IMAGE_TAG").ok());
    if let Some(tag) = image_tag {
        if !tag.trim().is_empty() {
            out.entry("image_tag".to_string())
                .or_insert_with(|| Value::String(tag.clone()));
            for (k, v) in parse_shas_from_image_tag(&tag) {
                out.entry(k).or_insert(Value::String(v));
            }
        }
    }
    out
}

fn is_hex_sha(s: &str) -> bool {
    (7..=40).contains(&s.len()) && s.chars().all(|c| c.is_ascii_hexdigit())
}

fn parse_shas_from_image_tag(image_tag: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let tag = image_tag.trim();
    // Match suffix: <il_sha>-<ic_sha>[-YYYYMMDD]
    let parts: Vec<&str> = tag.rsplitn(3, '-').collect();
    // rsplitn gives reverse order segments from the end
    if parts.len() >= 2 {
        let maybe_ts = parts[0];
        let (il, ic) = if maybe_ts.len() == 8 && maybe_ts.chars().all(|c| c.is_ascii_digit()) {
            if parts.len() < 3 {
                return out;
            }
            // remaining is ...-il-ic with ts stripped; need il and ic from end
            // parts = [ts, ic, rest_with_il_at_end]
            let ic = parts[1];
            let rest = parts[2];
            let il = rest.rsplit('-').next().unwrap_or("");
            out.insert("build_ts".to_string(), maybe_ts.to_string());
            (il, ic)
        } else {
            // parts = [ic, rest_ending_with_il] when no ts, or more complex
            let ic = parts[0];
            let rest = parts[1];
            let il = rest.rsplit('-').next().unwrap_or("");
            (il, ic)
        };
        if is_hex_sha(il) && is_hex_sha(ic) {
            out.insert("il_sha".to_string(), il.to_string());
            out.insert("ic_sha".to_string(), ic.to_string());
        }
    }
    out
}

pub fn collect_config_env() -> Map<String, Value> {
    let mut out = Map::new();
    let mut keys: Vec<_> = std::env::vars()
        .filter(|(k, v)| k.starts_with("INFINI_") && !v.trim().is_empty())
        .map(|(k, _)| k)
        .collect();
    keys.sort();
    for key in keys {
        if let Ok(val) = std::env::var(&key) {
            out.insert(key, Value::String(val));
        }
    }
    for key in [
        "HPCC_VISIBLE_DEVICES",
        "CUDA_VISIBLE_DEVICES",
        "MACA_VISIBLE_DEVICES",
    ] {
        if let Ok(val) = std::env::var(key) {
            if !val.trim().is_empty() {
                out.insert(key.to_string(), Value::String(val));
            }
        }
    }
    out
}

pub fn collect_config(startup_args: Map<String, Value>) -> Value {
    json!({
        "startup": startup_args,
        "env": collect_config_env(),
    })
}

fn run_cmd(args: &[&str]) -> String {
    let mut cmd = Command::new(args[0]);
    if args.len() > 1 {
        cmd.args(&args[1..]);
    }
    match cmd.output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).into_owned(),
        _ => String::new(),
    }
}

fn probe_os() -> HashMap<String, String> {
    let mut out = HashMap::new();
    if let Ok(text) = fs::read_to_string("/etc/os-release") {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || !line.contains('=') {
                continue;
            }
            let (key, val) = line.split_once('=').unwrap();
            let val = val.trim().trim_matches('"');
            if key == "ID" && !val.is_empty() {
                out.insert("os_id".to_string(), val.to_string());
            }
            if key == "VERSION_ID" && !val.is_empty() {
                out.insert("os_version".to_string(), val.to_string());
            }
        }
    }
    if let Ok(uname) = Command::new("uname").arg("-srm").output() {
        if uname.status.success() {
            let text = String::from_utf8_lossy(&uname.stdout);
            let parts: Vec<_> = text.split_whitespace().collect();
            if let Some(sys) = parts.first() {
                out.entry("os_id".to_string())
                    .or_insert_with(|| sys.to_lowercase());
            }
            if parts.len() >= 2 {
                out.insert("kernel".to_string(), parts[1].to_string());
            }
            if parts.len() >= 3 {
                out.insert("arch".to_string(), parts[2].to_string());
            }
        }
    }
    out
}

fn probe_cpu() -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Ok(text) = fs::read_to_string("/proc/cpuinfo") else {
        return out;
    };
    let mut models = Vec::new();
    let mut count = 0u32;
    for line in text.lines() {
        if line.starts_with("processor") {
            count += 1;
        } else {
            let lower = line.to_lowercase();
            if lower.starts_with("model name") || lower.starts_with("cpu implementer") {
                if let Some((_, val)) = line.split_once(':') {
                    let val = val.trim();
                    if !val.is_empty() && !models.iter().any(|m: &String| m == val) {
                        models.push(val.to_string());
                    }
                }
            }
        }
    }
    if let Some(model) = models.first() {
        out.insert("cpu_model".to_string(), model.clone());
    }
    if count > 0 {
        out.insert("cpu_count".to_string(), count.to_string());
    }
    out
}

fn read_hpcc_driver_version() -> String {
    let hpcc_root = std::env::var("HPCC_PATH").unwrap_or_else(|_| "/opt/hpcc".to_string());
    let mut candidates = vec![hpcc_root.clone()];
    if let Ok(real) = fs::canonicalize(&hpcc_root) {
        let s = real.to_string_lossy().into_owned();
        if !candidates.contains(&s) {
            candidates.push(s);
        }
    }
    for root in candidates {
        let path = format!("{root}/Version.txt");
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let lower = text.to_lowercase();
        if let Some(idx) = lower.find("version") {
            let after = &text[idx + "version".len()..];
            let after = after.trim_start_matches([' ', '\t', ':']);
            if let Some(tok) = after.split_whitespace().next() {
                return tok.to_string();
            }
        }
        if let Some((_, rest)) = text.split_once(':') {
            return rest.trim().to_string();
        }
        return text.to_string();
    }
    String::new()
}

fn parse_smi_output(text: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if text.is_empty() {
        return out;
    }
    for line in text.lines() {
        let lower = line.to_lowercase();
        if let Some(idx) = lower.find("attached gpus") {
            let after = line[idx + "attached gpus".len()..].trim_start_matches([' ', '\t', ':']);
            if let Some(tok) = after.split_whitespace().next() {
                if tok.chars().all(|c| c.is_ascii_digit()) {
                    out.insert("gpu_count".to_string(), tok.to_string());
                }
            }
        }
        if let Some(idx) = lower.find("driver version") {
            let after = line[idx + "driver version".len()..].trim_start_matches([' ', '\t', ':']);
            if let Some(tok) = after.split_whitespace().next() {
                out.insert("gpu_driver".to_string(), tok.to_string());
            }
        }
    }
    let mut models = Vec::new();
    for line in text.lines() {
        if line.contains("MetaX") || line.contains("NVIDIA") || line.contains("GPU") {
            // crude: | idx NAME |
            let parts: Vec<_> = line.split('|').collect();
            if parts.len() >= 2 {
                let mid = parts[1].trim();
                let tokens: Vec<_> = mid.split_whitespace().collect();
                if tokens.len() >= 2 && tokens[0].chars().all(|c| c.is_ascii_digit()) {
                    let name = tokens[1].to_string();
                    if !name.is_empty() && !models.contains(&name) {
                        models.push(name);
                    }
                }
            }
        }
    }
    if let Some(model) = models.first() {
        out.insert("gpu_model".to_string(), model.clone());
    }
    if !out.contains_key("gpu_count") {
        let gpu_lines = text.lines().filter(|ln| {
            let parts: Vec<_> = ln.split('|').collect();
            parts.len() >= 2
                && parts[1]
                    .trim()
                    .split_whitespace()
                    .next()
                    .is_some_and(|t| t.chars().all(|c| c.is_ascii_digit()))
        });
        let n = gpu_lines.count();
        if n > 0 {
            out.insert("gpu_count".to_string(), n.to_string());
        }
    }
    let visible = std::env::var("HPCC_VISIBLE_DEVICES")
        .ok()
        .or_else(|| std::env::var("MACA_VISIBLE_DEVICES").ok())
        .or_else(|| std::env::var("CUDA_VISIBLE_DEVICES").ok());
    if let Some(v) = visible {
        if !v.trim().is_empty() {
            out.insert("gpu_visible_devices".to_string(), v.trim().to_string());
        }
    }
    out
}

fn probe_gpu() -> HashMap<String, String> {
    let mut out = HashMap::new();
    let hpcc_driver = read_hpcc_driver_version();
    if !hpcc_driver.is_empty() {
        out.insert("gpu_driver".to_string(), hpcc_driver.clone());
    }
    for cmd in [["mx-smi"], ["ht-smi"], ["nvidia-smi"]] {
        let text = run_cmd(&cmd);
        let parsed = parse_smi_output(&text);
        if !parsed.is_empty() {
            for (k, v) in parsed {
                if k == "gpu_driver" && !hpcc_driver.is_empty() {
                    continue;
                }
                if !v.is_empty() {
                    out.insert(k, v);
                }
            }
            return out;
        }
    }
    out
}

pub fn collect_runtime_env() -> Map<String, Value> {
    let mut out = Map::new();
    for probe in [probe_os, probe_cpu, probe_gpu] {
        for (k, v) in probe() {
            if !v.is_empty() {
                out.insert(k, Value::String(v));
            }
        }
    }
    out
}

pub fn startup_args_from_config(
    config: &super::config::EntrypointConfig,
    config_file: Option<&super::config_file::EntrypointConfigFile>,
) -> Map<String, Value> {
    let mut startup = Map::new();
    startup.insert(
        "service_type".to_string(),
        Value::String(config.service_type.clone()),
    );
    if let Some(path) = &config.path {
        startup.insert(
            "path".to_string(),
            Value::String(path.display().to_string()),
        );
    }
    if let Some(command) = &config.command {
        startup.insert("command".to_string(), Value::String(command.clone()));
    }
    if let Some(args) = &config.args {
        startup.insert("args".to_string(), Value::String(args.clone()));
    }
    if let Some(cf) = config_file {
        startup.insert(
            "config_file_name".to_string(),
            Value::String(cf.name.clone().unwrap_or_default()),
        );
        for (k, v) in cf.metadata_json() {
            startup.insert(format!("metadata.{k}"), v);
        }
    }
    startup
}
