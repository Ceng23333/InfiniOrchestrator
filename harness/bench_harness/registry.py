"""Bench family and column registry keyed by bench_id prefix."""

from __future__ import annotations

from infinimetadata.frontend import FRONTEND_METADATA_KEY

# JSON columns for deployment-case profile (not per-key warehouse columns).
SERVER_ARGS_COLUMN = "server_args"
BENCH_ARGS_COLUMN = "bench_args"
SERVER_CONFIG_COLUMN = "server_config"
SERVER_RUNTIME_ENV_COLUMN = "server_runtime_env"

BUILD_INFO_COLUMNS = [
    "il_sha",
    "ic_sha",
    "io_sha",
]

RUNTIME_PROBE_COLUMNS = [
    "os_id",
    "os_version",
    "kernel",
    "cpu_model",
    "cpu_count",
    "gpu_driver",
    "gpu_count",
]

SERVER_PROFILE_KEYS = [
    "router_url",
    "metrics_url",
]

BENCH_PROFILE_KEYS = [
    "num_prompts",
    "max_concurrency",
    "num_concurrent",
    "ceval_limit1",
    "input_len_min",
    "input_len_max",
    "output_len",
    "max_gen_toks",
    "longbench_length",
    "max_input_tokens",
    "limit",
]

# Common columns on every row.
BASE_COLUMNS = [
    "server_id",
    "started_at",
    "finished_at",
    "status",
    "base_url",
    "model",
    FRONTEND_METADATA_KEY,
    "worker_container",
    "image_tag",
    "host_id",
    "platform",
    "arch",
    "gpu_model",
    "lan_ip",
    "role",
    "deployment_case",
    SERVER_ARGS_COLUMN,
    *BUILD_INFO_COLUMNS,
    "deploy_tier",
    *RUNTIME_PROBE_COLUMNS,
    SERVER_CONFIG_COLUMN,
    SERVER_RUNTIME_ENV_COLUMN,
    "suite_started_at",
    BENCH_ARGS_COLUMN,
]

_LATENCY_METRIC_COLUMNS = [
    "ttft_p50_ms",
    "ttft_p99_ms",
    "ttft_mean_ms",
    "tpot_p50_ms",
    "tpot_mean_ms",
    "itl_p50_ms",
    "itl_p99_ms",
    "itl_mean_ms",
    "req_per_s",
    "output_tok_per_s",
    "total_tok_per_s",
]

FAMILY_PREFIXES: dict[str, str] = {
    "unexpected_behavior": "resilience",
    "validation": "correctness",
    "random-fixed-length": "latency",
    "mctracer_throughput": "latency",
    "ceval": "accuracy",
    "longbench_v2": "quality_dyn",
}

FAMILY_METRIC_COLUMNS: dict[str, list[str]] = {
    "resilience": ["gate_pass", "step_loop_fatal"],
    "correctness": ["gate_pass"],
    "latency": list(_LATENCY_METRIC_COLUMNS),
    "accuracy": ["ceval_em", "ceval_limit"],
    "quality_dyn": [
        "lb_em",
        "lb_n",
        "lb_limit",
        "lb_pool_n",
        "lb_truncated_n",
        "lb_length",
        "lb_difficulty",
        "workload_scale",
        *_LATENCY_METRIC_COLUMNS,
    ],
}

HISTOGRAM_SRV_COLS = [
    "srv_ttft_p50_ms",
    "srv_ttft_p99_ms",
    "srv_e2e_p50_ms",
    "srv_itl_p50_ms",
]
PERIOD_HISTOGRAM_SUFFIXES = ("_mean", "_median", "_p99")


def _period_histogram_columns() -> list[str]:
    cols: list[str] = []
    for base in HISTOGRAM_SRV_COLS:
        for suffix in PERIOD_HISTOGRAM_SUFFIXES:
            cols.append(f"{base}{suffix}")
    return cols


SERVER_METRIC_COLUMNS = [
    "srv_req_total_ok",
    "srv_req_total_error",
    "srv_req_total_canceled",
    "srv_ttft_p50_ms",
    "srv_ttft_p99_ms",
    "srv_e2e_p50_ms",
    "srv_itl_p50_ms",
    "srv_itl_p99_ms",
    *_period_histogram_columns(),
    "srv_tokens_prompt_total",
    "srv_tokens_completion_total",
    "srv_engine_free_blocks",
    "srv_engine_used_blocks",
    "srv_engine_queue_waiting",
]


def suite_prefix(bench_id: str) -> str:
    """Return suite prefix before ``__``."""
    if "__" in bench_id:
        return bench_id.split("__", 1)[0]
    return bench_id


def bench_family(bench_id: str) -> str:
    prefix = suite_prefix(bench_id)
    return FAMILY_PREFIXES.get(prefix, "unknown")


def data_columns(bench_id: str) -> list[str]:
    family = bench_family(bench_id)
    metrics = FAMILY_METRIC_COLUMNS.get(family, [])
    return BASE_COLUMNS + metrics + SERVER_METRIC_COLUMNS


# Case metadata (from CASE_ID / case.toml + hardware-profile catalog).
CASE_META_COLUMNS = [
    "case_id",
    "case_category",
    "case_path",
    "n",
    "model_id",
    "hw_profile_id",
    "hw_abbr",
    "be_abbr",
    "prof_gpu_vendor",
    "prof_gpu_model",
    "prof_gpu_arch",
    "prof_gpu_driver",
    "prof_gpu_memory_gb",
    "prof_cpu_vendor",
    "prof_cpu_model",
    "prof_cpu_arch",
    "prof_cpu_cores",
    "prof_os_name",
    "prof_os_version",
    "prof_os_kernel",
    "prof_host_platform",
    "prof_host_class",
    "prof_interconnect_type",
]

# Harness + partition context on compact facts rows.
PARTITION_META_COLUMNS = [
    "bench_id",
    "bench",
    "model",
    FRONTEND_METADATA_KEY,
    "bench_family",
    "platform",
    "date",
    "hw_profile",
]

# Server + deployment metadata (required on warehouse rows and model reports).
SERVER_META_COLUMNS = [
    "server_id",
    "host_id",
    "base_url",
    "model",
    "worker_container",
    "image_tag",
    "arch",
    "gpu_model",
    "lan_ip",
    "role",
    "deployment_case",
    SERVER_ARGS_COLUMN,
    *BUILD_INFO_COLUMNS,
    "deploy_tier",
    *RUNTIME_PROBE_COLUMNS,
    SERVER_CONFIG_COLUMN,
    SERVER_RUNTIME_ENV_COLUMN,
]

# Bench run timing + profile metadata (required alongside server metadata).
BENCH_RUN_META_COLUMNS = [
    "started_at",
    "finished_at",
    "suite_started_at",
    "status",
    BENCH_ARGS_COLUMN,
]


def _ordered_unique(columns: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for col in columns:
        if col not in seen:
            seen.add(col)
            out.append(col)
    return out


def all_family_metric_columns() -> list[str]:
    seen: set[str] = set()
    cols: list[str] = []
    for metrics in FAMILY_METRIC_COLUMNS.values():
        for col in metrics:
            if col not in seen:
                seen.add(col)
                cols.append(col)
    return cols


def harness_raw_columns(bench_id: str) -> list[str]:
    """Column contract for one harness raw file ``raw/<date>/<suite_prefix>.tsv``.

    Shared meta + **that family's** metrics only (not the union of all families).
    Compact facts keep the wider ``warehouse_facts_columns()`` union.
    """
    family = bench_family(bench_id)
    metrics = FAMILY_METRIC_COLUMNS.get(family, [])
    return _ordered_unique(
        CASE_META_COLUMNS
        + PARTITION_META_COLUMNS
        + SERVER_META_COLUMNS
        + BENCH_RUN_META_COLUMNS
        + list(metrics)
        + SERVER_METRIC_COLUMNS
    )


def warehouse_facts_columns() -> list[str]:
    """Stable column order for compact ``facts.tsv`` (union of all family metrics).

    Raw per-harness files use ``harness_raw_columns(bench_id)`` instead.
    """
    return _ordered_unique(
        CASE_META_COLUMNS
        + PARTITION_META_COLUMNS
        + SERVER_META_COLUMNS
        + BENCH_RUN_META_COLUMNS
        + all_family_metric_columns()
        + SERVER_METRIC_COLUMNS
    )
