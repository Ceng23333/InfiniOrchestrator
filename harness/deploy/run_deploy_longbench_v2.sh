#!/usr/bin/env bash
# LongBench-v2 official 0-shot (no CoT / no_context / rag) against a running endpoint.
#
# Usage:
#   BENCH_TARGET_URL=http://host:port MODEL=minicpm5 ./harness/deploy/run_deploy_longbench_v2.sh
#
# Official-0shot defaults (THUDM/LongBench pred.py alignment):
#   LONGBENCH_DIFFICULTY=all LONGBENCH_LENGTH=short,medium LIMIT=0
#   MAX_GEN_TOKS=128  MAX_INPUT_TOKENS=28672  temperature=0.1 (in client)
#   middle-truncate over-cap prompts; extract_answer only
# ENABLE_THINKING=0 (default): no CoT promote — keep MAX_GEN_TOKS=128
# ENABLE_THINKING=1: auto-promotes MAX_GEN_TOKS 128 -> 2048 (CoT path; unused for official A/Bs)
# Workload scale is printed by the client and stored in longbench_summary.json
# (lb_pool_n, lb_truncated_n, lb_length, lb_difficulty, workload_scale).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/client_env.sh"

_bench_client_resolve_urls || exit 1
_bench_client_resolve_paths || exit 1

# Prefer warehouse-owned official adapter; fall back to BENCH_TOOL_ROOT monorepo client.
HARNESS_CLIENT_PY="${HARNESS_ROOT}/clients/longbench_v2_official.py"
LONGBENCH_OFFICIAL_ROOT="${LONGBENCH_OFFICIAL_ROOT:-${BENCH_WAREHOUSE_REPO}/third_party/LongBench}"
if [[ -f "${HARNESS_CLIENT_PY}" ]]; then
  CLIENT_PY="${HARNESS_CLIENT_PY}"
  if [[ ! -f "${LONGBENCH_OFFICIAL_ROOT}/pred.py" || ! -f "${LONGBENCH_OFFICIAL_ROOT}/prompts/0shot.txt" ]]; then
    echo "Error: LONGBENCH_OFFICIAL_ROOT=${LONGBENCH_OFFICIAL_ROOT} missing pred.py or prompts/0shot.txt" >&2
    echo "  Clone: git clone --depth 1 https://github.com/THUDM/LongBench.git \"\${LONGBENCH_OFFICIAL_ROOT}\"" >&2
    exit 1
  fi
  export LONGBENCH_OFFICIAL_ROOT
elif [[ -n "${BENCH_TOOL_ROOT:-}" && -f "${BENCH_TOOL_ROOT}/benchmarks/longbench_v2_client.py" ]]; then
  CLIENT_PY="${BENCH_TOOL_ROOT}/benchmarks/longbench_v2_client.py"
else
  echo "Error: need ${HARNESS_CLIENT_PY} (with LONGBENCH_OFFICIAL_ROOT) or BENCH_TOOL_ROOT/benchmarks/longbench_v2_client.py" >&2
  exit 1
fi

ROUTER_URL="${ROUTER_URL:-${BASE_URL}}"
MODEL="${MODEL:-${MODELS:-}}"
TIMEOUT="${TIMEOUT:-600}"

if [[ -z "${MODEL}" ]]; then
  echo "Error: MODEL is required (minicpm5 | minicpm5.16a3.v0314 | 9g_8b_thinking | Qwen3-32B)" >&2
  exit 1
fi

case "${MODEL}" in
  9g_8b_thinking|Qwen3-32B|minicpm5|minicpm5.16a3.v0314) ;;
  *)
    echo "Error: unsupported MODEL=${MODEL}" >&2
    exit 1
  ;;
esac

LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-short,medium}"
LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY:-all}"
LIMIT="${LIMIT:-0}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-4}"
MAX_INPUT_TOKENS="${MAX_INPUT_TOKENS:-28672}"
TIMEOUT="${TIMEOUT:-600}"

# CoT / gen budget — official 0-shot A/Bs keep ENABLE_THINKING=0 → MAX_GEN_TOKS=128
ENABLE_THINKING="${ENABLE_THINKING:-${LONGBENCH_COT:-0}}"
MAX_GEN_TOKS="${MAX_GEN_TOKS:-128}"
_max_gen_was_default=0
if [[ -z "${MAX_GEN_TOKS_SET:-}" ]]; then
  # Treat unset caller as default 128 for promote rule.
  if [[ "${MAX_GEN_TOKS}" == "128" ]]; then
    _max_gen_was_default=1
  fi
fi
if [[ "${ENABLE_THINKING}" == "1" || "${ENABLE_THINKING}" == "true" ]]; then
  if [[ "${_max_gen_was_default}" == "1" || "${MAX_GEN_TOKS}" -le 128 ]]; then
    MAX_GEN_TOKS=2048
  fi
  EXTRA_BODY="${EXTRA_BODY:-}"
else
  # Explicit no-CoT: do not promote gen budget
  ENABLE_THINKING=0
fi

export LONGBENCH_LENGTH LONGBENCH_DIFFICULTY LIMIT MAX_CONCURRENCY MAX_INPUT_TOKENS MAX_GEN_TOKS ENABLE_THINKING

# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/resolve_tokenizer.sh"
_tok_explicit="${TOKENIZER_DIR:-}"
if ! TOKENIZER_DIR="$(resolve_tokenizer_dir "${MODEL}" "${_tok_explicit}" 2>/dev/null)"; then
  TOKENIZER_DIR="${_tok_explicit}"
fi
if [[ -z "${TOKENIZER_DIR}" ]]; then
  echo "Error: TOKENIZER_DIR required for official middle-truncate (no char/4 fallback)" >&2
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${BENCH_RESULTS_ROOT}/longbench_v2_${MODEL}_${TS}}"
mkdir -p "${OUT_DIR}"
export OUT_DIR

STEP_STARTED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "=========================================="
echo "Deploy LongBench-v2 (client)"
echo "=========================================="
echo "Endpoint:        ${ROUTER_URL}"
echo "Model:           ${MODEL}"
echo "Length:          ${LONGBENCH_LENGTH}"
echo "Difficulty:      ${LONGBENCH_DIFFICULTY}"
echo "Limit:           ${LIMIT} (0=full pool; over-cap middle-truncated)"
echo "Max concurrency: ${MAX_CONCURRENCY}"
echo "Max gen toks:    ${MAX_GEN_TOKS}"
echo "Thinking:        ${ENABLE_THINKING} (0=official 0-shot, no CoT promote)"
echo "Max input toks:  ${MAX_INPUT_TOKENS}"
echo "Prompt mode:     official_0shot (temp=0.1, middle-truncate, extract_answer)"
echo "Workload:        length=${LONGBENCH_LENGTH} difficulty=${LONGBENCH_DIFFICULTY} limit=${LIMIT} mc=${MAX_CONCURRENCY} max_gen=${MAX_GEN_TOKS} max_input=${MAX_INPUT_TOKENS} thinking=${ENABLE_THINKING}"
echo "Tokenizer:       ${TOKENIZER_DIR:-none}"
echo "OUT_DIR:         ${OUT_DIR}"
echo ""

if ! curl -s -f --connect-timeout 3 --noproxy "*" "${ROUTER_URL}/health" >/dev/null 2>&1 \
  && ! curl -s -f --connect-timeout 3 --noproxy "*" "${ROUTER_URL}/v1/models" >/dev/null 2>&1; then
  echo "Error: endpoint not reachable at ${ROUTER_URL}/health or /v1/models" >&2
  exit 1
fi

if [[ -z "${INFERENCE_SERVER_ID:-}" ]]; then
  # shellcheck disable=SC1091
  source "${HARNESS_ROOT}/lib/server_preflight.sh"
  server_preflight "${INFERENCE_SERVER_BASE_URL:-${ROUTER_URL}}" "${OUT_DIR}"
fi

SERVER_DIR="${OUT_DIR}/server"
mkdir -p "${SERVER_DIR}"
bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" before "${SERVER_DIR}" || true
bash "${HARNESS_ROOT}/lib/scrape_server_metrics_period.sh" start "${SERVER_DIR}" || true

LOG_FILE="${OUT_DIR}/bench_console.log"
echo "[deploy-longbench] CLIENT_PY=${CLIENT_PY}"
echo "[deploy-longbench] LONGBENCH_OFFICIAL_ROOT=${LONGBENCH_OFFICIAL_ROOT:-}"

_think_flag=()
if [[ "${ENABLE_THINKING}" == "1" || "${ENABLE_THINKING}" == "true" ]]; then
  _think_flag=(--enable-thinking)
fi

_extra=()
if [[ -n "${EXTRA_BODY:-}" ]]; then
  _extra=(--extra-body-json "${EXTRA_BODY}")
fi

_official_args=()
if [[ "${CLIENT_PY}" == *"longbench_v2_official.py" ]]; then
  _official_args=(--official-root "${LONGBENCH_OFFICIAL_ROOT}")
fi

_backend="$(echo "${BENCH_BACKEND:-infinilm}" | tr '[:upper:]' '[:lower:]')"
# Run client in-container for vLLM and InfiniLM so AutoTokenizer (transformers) works
# and max_input filtering matches the server tokenizer (host often lacks transformers).
if [[ "${_backend}" == "vllm" || "${_backend}" == "openai" || "${_backend}" == "infinilm" ]]; then
  DEV_CONTAINER="${DEV_CONTAINER_NAME:-infinilm-dev-hpcc37}"
  _default_port=18180
  if [[ "${_backend}" == "infinilm" ]]; then
    _default_port=18190
  fi
  # Prefer explicit in-container URL (compose router on host → docker bridge gateway).
  if [[ -n "${BENCH_CTN_URL:-}" ]]; then
    _bench_url="${BENCH_CTN_URL}"
  elif [[ -n "${ROUTER_URL:-}" && "${ROUTER_URL}" =~ ^https?://(127\.0\.0\.1|localhost)(:[0-9]+)? ]]; then
    _gw="$(docker inspect "${DEV_CONTAINER}" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
    _gw="${_gw:-172.17.0.1}"
    _bench_url="$(echo "${ROUTER_URL}" | sed -E "s#://(127\\.0\\.0\\.1|localhost)#://${_gw}#")"
  else
    _bench_url="http://127.0.0.1:${DEV_PORT:-${_default_port}}"
  fi
  echo "[deploy-longbench] BENCH_BACKEND=${_backend}: client inside ${DEV_CONTAINER} url=${_bench_url}"
  # Map host bind mounts → in-container paths (devcontainer: WORK→/workspace, models→/models).
  _host_to_ctn() {
    local p="$1"
    local work="${INFINILM_PREFILL_WORK:-${MONOREPO_WORK:-}}"
    local ctn="${CONTAINER_REPO:-/workspace}"
    if [[ -n "${work}" && ("${p}" == "${work}" || "${p}" == "${work}/"*) ]]; then
      printf '%s\n' "${ctn}${p#"${work}"}"
      return 0
    fi
    case "${p}" in
      /root/zenghua/models|/root/zenghua/models/*)
        printf '%s\n' "/models${p#/root/zenghua/models}"
        ;;
      /models|/models/*|/workspace|/workspace/*|/extra-models|/extra-models/*)
        printf '%s\n' "${p}"
        ;;
      *)
        printf '%s\n' "${p}"
        ;;
    esac
  }
  _ctn_client="$(_host_to_ctn "${CLIENT_PY}")"
  _ctn_out="$(_host_to_ctn "${OUT_DIR}")"
  _ctn_tok="$(_host_to_ctn "${TOKENIZER_DIR}")"
  _ctn_data=""
  if [[ -n "${LONGBENCH_DATA_JSON:-}" ]]; then
    _ctn_data="$(_host_to_ctn "${LONGBENCH_DATA_JSON}")"
  fi
  _ctn_official=""
  if [[ -n "${LONGBENCH_OFFICIAL_ROOT:-}" ]]; then
    _ctn_official="$(_host_to_ctn "${LONGBENCH_OFFICIAL_ROOT}")"
  fi
  _ctn_hf_cache=""
  if [[ -n "${HF_DATASETS_CACHE:-}" ]]; then
    _ctn_hf_cache="$(_host_to_ctn "${HF_DATASETS_CACHE}")"
  fi
  _ctn_hf_home=""
  if [[ -n "${HF_HOME:-}" ]]; then
    _ctn_hf_home="$(_host_to_ctn "${HF_HOME}")"
  fi
  echo "[deploy-longbench] ctn CLIENT_PY=${_ctn_client} OUT_DIR=${_ctn_out} TOK=${_ctn_tok}"
  _data_json_arg=""
  if [[ -n "${_ctn_data}" ]]; then
    _data_json_arg="--data-json '${_ctn_data}'"
  fi
  _official_arg=""
  if [[ -n "${_ctn_official}" ]]; then
    _official_arg="--official-root '${_ctn_official}'"
  fi
  _think_arg=""
  if [[ ${#_think_flag[@]} -gt 0 ]]; then
    _think_arg="--enable-thinking"
  fi
  _extra_arg=""
  if [[ -n "${EXTRA_BODY:-}" ]]; then
    _extra_escaped="${EXTRA_BODY//\'/\'\\\'\'}"
    _extra_arg="--extra-body-json '${_extra_escaped}'"
  fi
  docker exec \
    -e PYTHONUNBUFFERED=1 \
    -e HF_DATASETS_CACHE="${_ctn_hf_cache}" \
    -e HF_HOME="${_ctn_hf_home}" \
    -e HF_HUB_OFFLINE=1 \
    -e TRANSFORMERS_OFFLINE=1 \
    -e HF_DATASETS_OFFLINE=1 \
    -e LONGBENCH_DATA_JSON="${_ctn_data}" \
    -e LONGBENCH_OFFICIAL_ROOT="${_ctn_official}" \
    -e ENABLE_THINKING="${ENABLE_THINKING}" \
    -e MAX_GEN_TOKS="${MAX_GEN_TOKS}" \
    -e LIMIT="${LIMIT}" \
    -e LONGBENCH_LENGTH="${LONGBENCH_LENGTH}" \
    -e LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY}" \
    "${DEV_CONTAINER}" \
    bash -lc "source /opt/conda/etc/profile.d/conda.sh && conda activate base && \
      python3 '${_ctn_client}' \
        --base-url '${_bench_url}' \
        --model '${MODEL}' \
        --out-dir '${_ctn_out}' \
        --length '${LONGBENCH_LENGTH}' \
        --difficulty '${LONGBENCH_DIFFICULTY}' \
        --limit '${LIMIT}' \
        --max-concurrency '${MAX_CONCURRENCY}' \
        --max-gen-toks '${MAX_GEN_TOKS}' \
        --max-input-tokens '${MAX_INPUT_TOKENS}' \
        --tokenizer-dir '${_ctn_tok}' \
        --timeout-sec '${TIMEOUT}' \
        ${_data_json_arg} \
        ${_official_arg} \
        ${_think_arg} \
        ${_extra_arg}" \
    2>&1 | tee "${LOG_FILE}"
else
  export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
  export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
  export HF_DATASETS_OFFLINE="${HF_DATASETS_OFFLINE:-1}"
  _data_json_args=()
  if [[ -n "${LONGBENCH_DATA_JSON:-}" ]]; then
    _data_json_args=(--data-json "${LONGBENCH_DATA_JSON}")
  fi
  python3 "${CLIENT_PY}" \
    --base-url "${ROUTER_URL}" \
    --model "${MODEL}" \
    --out-dir "${OUT_DIR}" \
    --length "${LONGBENCH_LENGTH}" \
    --difficulty "${LONGBENCH_DIFFICULTY}" \
    --limit "${LIMIT}" \
    --max-concurrency "${MAX_CONCURRENCY}" \
    --max-gen-toks "${MAX_GEN_TOKS}" \
    --max-input-tokens "${MAX_INPUT_TOKENS}" \
    --tokenizer-dir "${TOKENIZER_DIR}" \
    --timeout-sec "${TIMEOUT}" \
    "${_data_json_args[@]}" \
    "${_official_args[@]}" \
    "${_think_flag[@]}" \
    "${_extra[@]}" \
    2>&1 | tee "${LOG_FILE}"
fi

STEP_FINISHED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

bash "${HARNESS_ROOT}/lib/scrape_server_metrics_period.sh" stop "${SERVER_DIR}" || true
bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" after "${SERVER_DIR}" || true

echo ""
echo "Deploy LongBench-v2 complete: ${OUT_DIR}"

BENCH_ID="longbench_v2__${MODEL}"
export BASE_URL="${ROUTER_URL}"
export MODEL
export max_gen_toks="${MAX_GEN_TOKS}"
export max_concurrency="${MAX_CONCURRENCY}"
export longbench_length="${LONGBENCH_LENGTH}"
export longbench_difficulty="${LONGBENCH_DIFFICULTY}"
export max_input_tokens="${MAX_INPUT_TOKENS}"
export limit="${LIMIT}"
bash "${HARNESS_ROOT}/lib/emit_bench.sh" "${BENCH_ID}" "${OUT_DIR}" "${STEP_STARTED}" "${STEP_FINISHED}" || {
  echo "[deploy-longbench] WARN: emit failed for ${BENCH_ID}" >&2
}
