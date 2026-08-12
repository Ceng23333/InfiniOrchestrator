//! Gateway Prometheus metrics for InfiniLoadBalancer (compatible with InfiniMetadata names).

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

const DEFAULT_BUCKETS: &[f64] = &[
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0,
    f64::INFINITY,
];
const MAX_SAMPLES: usize = 4096;

fn escape_label(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('\n', "\\n")
        .replace('"', "\\\"")
}

fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    if sorted.len() == 1 {
        return sorted[0];
    }
    let pos = q * (sorted.len() as f64 - 1.0);
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        let w = pos - lo as f64;
        sorted[lo] * (1.0 - w) + sorted[hi] * w
    }
}

struct Counter {
    name: &'static str,
    help: &'static str,
    label_names: &'static [&'static str],
    values: HashMap<Vec<String>, f64>,
}

impl Counter {
    fn new(name: &'static str, help: &'static str, label_names: &'static [&'static str]) -> Self {
        Self {
            name,
            help,
            label_names,
            values: HashMap::new(),
        }
    }

    fn inc(&mut self, value: f64, labels: &[&str]) {
        let key: Vec<String> = labels.iter().map(|s| (*s).to_string()).collect();
        *self.values.entry(key).or_insert(0.0) += value;
    }

    fn prometheus_lines(&self) -> Vec<String> {
        let mut lines = vec![
            format!("# HELP {} {}", self.name, self.help),
            format!("# TYPE {} counter", self.name),
        ];
        if self.values.is_empty() {
            if self.label_names.is_empty() {
                lines.push(format!("{} 0", self.name));
            } else {
                let label_str = self
                    .label_names
                    .iter()
                    .map(|n| format!("{n}=\"\""))
                    .collect::<Vec<_>>()
                    .join(",");
                lines.push(format!("{}{{{label_str}}} 0", self.name));
            }
            return lines;
        }
        let mut keys: Vec<_> = self.values.keys().cloned().collect();
        keys.sort();
        for key in keys {
            let val = self.values[&key];
            if self.label_names.is_empty() {
                lines.push(format!("{} {val}", self.name));
            } else {
                let parts: Vec<_> = self
                    .label_names
                    .iter()
                    .zip(key.iter())
                    .map(|(n, v)| format!("{n}=\"{}\"", escape_label(v)))
                    .collect();
                lines.push(format!("{}{{{}}} {val}", self.name, parts.join(",")));
            }
        }
        lines
    }
}

struct Histogram {
    name: &'static str,
    help: &'static str,
    buckets: Vec<f64>,
    count: u64,
    sum: f64,
    bucket_counts: HashMap<u64, u64>, // bit-pattern key for f64
    samples: VecDeque<f64>,
}

fn f64_key(v: f64) -> u64 {
    v.to_bits()
}

impl Histogram {
    fn new(name: &'static str, help: &'static str) -> Self {
        let buckets: Vec<f64> = DEFAULT_BUCKETS.to_vec();
        let bucket_counts = buckets.iter().map(|b| (f64_key(*b), 0u64)).collect();
        Self {
            name,
            help,
            buckets,
            count: 0,
            sum: 0.0,
            bucket_counts,
            samples: VecDeque::with_capacity(MAX_SAMPLES),
        }
    }

    fn observe(&mut self, value: f64) {
        self.count += 1;
        self.sum += value;
        if self.samples.len() >= MAX_SAMPLES {
            self.samples.pop_front();
        }
        self.samples.push_back(value);
        for b in &self.buckets {
            if value <= *b {
                *self.bucket_counts.entry(f64_key(*b)).or_insert(0) += 1;
            }
        }
    }

    fn prometheus_lines(&self) -> Vec<String> {
        let mut lines = vec![
            format!("# HELP {} {}", self.name, self.help),
            format!("# TYPE {} histogram", self.name),
        ];
        let mut finite: Vec<f64> = self
            .buckets
            .iter()
            .copied()
            .filter(|b| b.is_finite())
            .collect();
        finite.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        for b in finite {
            // observe() increments every bucket with value <= b, so count is already cumulative.
            let c = self.bucket_counts.get(&f64_key(b)).copied().unwrap_or(0);
            lines.push(format!("{}_bucket{{le=\"{b}\"}} {c}", self.name));
        }
        lines.push(format!("{}_bucket{{le=\"+Inf\"}} {}", self.name, self.count));
        lines.push(format!("{}_sum {}", self.name, self.sum));
        lines.push(format!("{}_count {}", self.name, self.count));
        if self.count > 0 {
            let mut samples: Vec<f64> = self.samples.iter().copied().collect();
            samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let p50 = percentile(&samples, 0.50);
            let p99 = percentile(&samples, 0.99);
            lines.push(format!(
                "# HELP {}_p50 Estimated p50 from recent samples (seconds)",
                self.name
            ));
            lines.push(format!("# TYPE {}_p50 gauge", self.name));
            lines.push(format!("{}_p50 {p50}", self.name));
            lines.push(format!(
                "# HELP {}_p99 Estimated p99 from recent samples (seconds)",
                self.name
            ));
            lines.push(format!("# TYPE {}_p99 gauge", self.name));
            lines.push(format!("{}_p99 {p99}", self.name));
        }
        lines
    }
}

struct Inner {
    requests_total: Counter,
    request_tokens_total: Counter,
    request_ttft_seconds: Histogram,
    request_e2e_seconds: Histogram,
    request_itl_seconds: Histogram,
}

impl Inner {
    fn new() -> Self {
        Self {
            requests_total: Counter::new(
                "infinilm_requests_total",
                "Total inference requests by terminal status",
                &["status", "server_id"],
            ),
            request_tokens_total: Counter::new(
                "infinilm_request_tokens_total",
                "Token counts by kind",
                &["kind", "server_id"],
            ),
            request_ttft_seconds: Histogram::new(
                "infinilm_request_ttft_seconds",
                "Time to first token in seconds",
            ),
            request_e2e_seconds: Histogram::new(
                "infinilm_request_e2e_seconds",
                "End-to-end request latency in seconds",
            ),
            request_itl_seconds: Histogram::new(
                "infinilm_request_itl_seconds",
                "Inter-token latency in seconds",
            ),
        }
    }
}

/// Shared gateway metrics registry.
pub struct GatewayMetrics {
    inner: Mutex<Inner>,
}

impl GatewayMetrics {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner::new()),
        }
    }

    pub fn record_request_finish(
        &self,
        status: &str,
        server_id: &str,
        arrival_secs: f64,
        finished_secs: f64,
        first_token_secs: Option<f64>,
        prompt_tokens: u64,
        completion_tokens: u64,
    ) {
        let mut g = self.inner.lock().unwrap();
        g.requests_total.inc(1.0, &[status, server_id]);
        if prompt_tokens > 0 {
            g.request_tokens_total
                .inc(prompt_tokens as f64, &["prompt", server_id]);
        }
        if completion_tokens > 0 {
            g.request_tokens_total
                .inc(completion_tokens as f64, &["completion", server_id]);
        }
        if let Some(ft) = first_token_secs {
            g.request_ttft_seconds
                .observe((ft - arrival_secs).max(0.0));
        }
        g.request_e2e_seconds
            .observe((finished_secs - arrival_secs).max(0.0));
    }

    pub fn record_inter_token_latency(&self, itl_seconds: f64) {
        if itl_seconds > 0.0 {
            self.inner
                .lock()
                .unwrap()
                .request_itl_seconds
                .observe(itl_seconds);
        }
    }

    pub fn prometheus_text(&self) -> String {
        let g = self.inner.lock().unwrap();
        let mut parts = Vec::new();
        parts.extend(g.requests_total.prometheus_lines());
        parts.extend(g.request_ttft_seconds.prometheus_lines());
        parts.extend(g.request_e2e_seconds.prometheus_lines());
        parts.extend(g.request_itl_seconds.prometheus_lines());
        parts.extend(g.request_tokens_total.prometheus_lines());
        parts.join("\n") + "\n"
    }
}

impl Default for GatewayMetrics {
    fn default() -> Self {
        Self::new()
    }
}

/// Per-request timing handle for the proxy path.
#[derive(Debug, Clone)]
pub struct RequestMetricsHandle {
    pub arrival_secs: f64,
    pub first_token_secs: Option<f64>,
    pub last_token_secs: Option<f64>,
    pub server_id: String,
}

impl RequestMetricsHandle {
    pub fn new(server_id: String) -> Self {
        Self {
            arrival_secs: now_secs(),
            first_token_secs: None,
            last_token_secs: None,
            server_id,
        }
    }

    pub fn on_token(&mut self, metrics: &GatewayMetrics) {
        let now = now_secs();
        if self.first_token_secs.is_none() {
            self.first_token_secs = Some(now);
            self.last_token_secs = Some(now);
            return;
        }
        if let Some(last) = self.last_token_secs {
            metrics.record_inter_token_latency(now - last);
        }
        self.last_token_secs = Some(now);
    }
}

pub fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Detect SSE "data:" token chunks (skip role-only / empty deltas when possible).
pub fn sse_chunk_has_token(chunk: &[u8]) -> bool {
    let text = String::from_utf8_lossy(chunk);
    for line in text.lines() {
        let line = line.trim();
        if let Some(payload) = line.strip_prefix("data:") {
            let payload = payload.trim();
            if payload.is_empty() || payload == "[DONE]" {
                continue;
            }
            if payload.contains("\"content\"") || payload.contains("\"text\"") {
                // Prefer content deltas; treat any content-bearing event as a token tick.
                if payload.contains("\"content\":null") {
                    continue;
                }
                return true;
            }
            // Fallback: any non-empty data line counts as progress.
            return true;
        }
    }
    false
}

/// Best-effort usage extraction from a full JSON body or trailing SSE usage chunk.
pub fn parse_usage_tokens(body: &str) -> (u64, u64) {
    // Look for "usage":{...} with prompt_tokens / completion_tokens
    let Some(idx) = body.find("\"usage\"") else {
        return (0, 0);
    };
    let slice = &body[idx..];
    let prompt = extract_u64_field(slice, "prompt_tokens");
    let completion = extract_u64_field(slice, "completion_tokens");
    (prompt, completion)
}

fn extract_u64_field(hay: &str, field: &str) -> u64 {
    let key = format!("\"{field}\"");
    let Some(idx) = hay.find(&key) else {
        return 0;
    };
    let after = &hay[idx + key.len()..];
    let after = after.trim_start().trim_start_matches(':').trim_start();
    let num: String = after
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    num.parse().unwrap_or(0)
}
