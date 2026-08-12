#!/usr/bin/env bash
# Fetch server_id from Entrypoint GET /metadata, or synthesize stub metadata for
# non-Infini backends (vLLM / OpenAI). HTTP only; no server lifecycle.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

_bench_is_infinilm_backend() {
  case "${BENCH_BACKEND:-infinilm}" in
    infinilm|infiniorchestrator) return 0 ;;
    *) return 1 ;;
  esac
}

_bench_parse_url_host_port() {
  # Sets _pf_host and _pf_port from http(s)://host:port[/...]
  local url="${1%/}"
  local rest="${url#*://}"
  _pf_host="${rest%%[:/]*}"
  local after_host="${rest#"${_pf_host}"}"
  if [[ "${after_host}" == :* ]]; then
    _pf_port="${after_host#:}"
    _pf_port="${_pf_port%%/*}"
  else
    if [[ "${url}" == https://* ]]; then
      _pf_port=443
    else
      _pf_port=80
    fi
  fi
}

_bench_derive_entrypoint_url() {
  # Infer Entrypoint as inference_port+1 when INFERENCE_METADATA_URL unset.
  local base_url="${1%/}"
  local _pf_host _pf_port
  _bench_parse_url_host_port "${base_url}"
  local scheme="http"
  if [[ "${base_url}" == https://* ]]; then
    scheme="https"
  fi
  local ep_port=$((_pf_port + 1))
  printf '%s://%s:%s' "${scheme}" "${_pf_host}" "${ep_port}"
}

_bench_stub_preflight() {
  local base_url="${1:?}"
  local artifact_root="${2:-}"

  local frontend="${BENCH_FRONTEND:-vLLM}"
  local model_id="${MODEL:-${MODELS:-}}"
  local server_id="${INFERENCE_SERVER_ID:-}"
  if [[ -z "${server_id}" ]]; then
    server_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  fi
  export INFERENCE_SERVER_ID="${server_id}"

  local _pf_host _pf_port
  _bench_parse_url_host_port "${base_url}"

  local meta
  meta="$(
    ARCH="${ARCH:-}" GPU_MODEL="${GPU_MODEL:-}" GPU_DRIVER="${GPU_DRIVER:-}" \
    SERVER_ID="${server_id}" FRONTEND="${frontend}" MODEL_ID="${model_id}" \
    HOST="${_pf_host}" PORT="${_pf_port}" \
    python3 - <<'PY'
import json, os
print(json.dumps({
    "server_id": os.environ["SERVER_ID"],
    "frontend": os.environ["FRONTEND"],
    "model_id": os.environ.get("MODEL_ID", ""),
    "host": os.environ["HOST"],
    "port": int(os.environ["PORT"]),
    "build_info": {},
    "runtime_env": {
        "arch": os.environ.get("ARCH", ""),
        "gpu_model": os.environ.get("GPU_MODEL", ""),
        "gpu_driver": os.environ.get("GPU_DRIVER", ""),
    },
    "config": {"startup": {}, "env": {}},
    "startup_args": {},
}, indent=2))
PY
  )"

  if [[ -n "${artifact_root}" ]]; then
    mkdir -p "${artifact_root}"
    printf '%s\n' "${meta}" > "${artifact_root}/metadata.json"
  fi

  echo "[server_preflight] stub backend=${BENCH_BACKEND:-} frontend=${frontend} server_id=${INFERENCE_SERVER_ID} base_url=${base_url}"
  printf '%s\n' "${meta}"
}

server_preflight() {
  local base_url="${1:-${INFERENCE_SERVER_BASE_URL:-${BASE_URL:-}}}"
  local artifact_root="${2:-${SERVER_ARTIFACT_ROOT:-}}"

  if [[ -z "${base_url}" ]]; then
    echo "[server_preflight] INFERENCE_SERVER_BASE_URL or BASE_URL required" >&2
    return 1
  fi

  if ! _bench_is_infinilm_backend; then
    export BENCH_SKIP_SERVER_METRICS="${BENCH_SKIP_SERVER_METRICS:-1}"
    _bench_stub_preflight "${base_url}" "${artifact_root}" >/dev/null
    return 0
  fi

  local metadata_url="${INFERENCE_METADATA_URL:-}"
  if [[ -z "${metadata_url}" ]]; then
    metadata_url="$(_bench_derive_entrypoint_url "${base_url}")"
  fi
  metadata_url="${metadata_url%/}"
  export INFERENCE_METADATA_URL="${metadata_url}"

  cd "${HARNESS_ROOT}"
  local meta
  if ! meta="$(python3 -m bench_harness.server_client preflight --base-url "${metadata_url}" 2>/dev/null)"; then
    # Entrypoint missing /metadata → stub so client-only warehouse emit still works.
    echo "[server_preflight] WARN: GET /metadata failed at ${metadata_url}; using stub metadata" >&2
    export BENCH_SKIP_SERVER_METRICS="${BENCH_SKIP_SERVER_METRICS:-1}"
    _bench_stub_preflight "${base_url}" "${artifact_root}" >/dev/null
    return 0
  fi
  export INFERENCE_SERVER_ID
  INFERENCE_SERVER_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["server_id"])' <<< "${meta}")"
  export INFERENCE_SERVER_ID

  if [[ -n "${artifact_root}" ]]; then
    mkdir -p "${artifact_root}"
    printf '%s\n' "${meta}" > "${artifact_root}/metadata.json"
  fi

  echo "[server_preflight] server_id=${INFERENCE_SERVER_ID} metadata_url=${metadata_url} base_url=${base_url}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  server_preflight "${1:-}" "${2:-}"
fi
