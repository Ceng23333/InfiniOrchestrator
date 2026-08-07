#!/usr/bin/env bash
# Per-step emit wrapper: calls bench_harness.emit with bench_id slug.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

bench_id="${1:?bench_id required}"
staging_dir="${2:-${SUMMARY_DIR:-}}"
started_at="${3:-}"
finished_at="${4:-}"
# Only treat argv[5+] as passthrough; do not re-pass positional 1–4.
if (( $# > 4 )); then
  extra_args=("${@:5}")
else
  extra_args=()
fi

if [[ -z "${staging_dir}" ]]; then
  echo "[emit_bench] SUMMARY_DIR or staging_dir required" >&2
  exit 1
fi

export INFERENCE_SERVER_ID="${INFERENCE_SERVER_ID:-}"
if [[ -z "${INFERENCE_SERVER_ID}" ]]; then
  echo "[emit_bench] INFERENCE_SERVER_ID required (run server_preflight.sh first)" >&2
  exit 1
fi
export HOST_ID="${HOST_ID:-metax-152}"
export PLATFORM="${PLATFORM:-hpcc}"

args=(
  python3 -m bench_harness.emit
  --server-id "${INFERENCE_SERVER_ID}"
  --host-id "${HOST_ID}"
  --platform "${PLATFORM}"
  --bench-id "${bench_id}"
  --staging-dir "${staging_dir}"
  --repo-root "${BENCH_WAREHOUSE_REPO}"
)

if [[ -n "${started_at}" ]]; then
  args+=(--started-at "${started_at}")
fi
if [[ -n "${finished_at}" ]]; then
  args+=(--finished-at "${finished_at}")
fi
if [[ -n "${SUITE_STARTED_AT:-}" ]]; then
  args+=(--suite-started-at "${SUITE_STARTED_AT}")
fi
if [[ -n "${IMAGE_TAG:-}" ]]; then
  args+=(--image-tag "${IMAGE_TAG}")
fi
if [[ -n "${BASE_URL:-}" ]]; then
  args+=(--base-url "${BASE_URL}")
fi
if [[ -n "${MODEL:-}" ]]; then
  args+=(--model "${MODEL}")
fi
if [[ -f "${staging_dir}/metadata.json" ]]; then
  args+=(--metadata-json "${staging_dir}/metadata.json")
elif [[ -f "${staging_dir%/unexpected_behavior}/metadata.json" ]]; then
  args+=(--metadata-json "${staging_dir%/unexpected_behavior}/metadata.json")
fi
if [[ ${#extra_args[@]} -gt 0 ]]; then
  args+=("${extra_args[@]}")
fi

cd "${BENCH_WAREHOUSE_REPO}"
"${args[@]}"
