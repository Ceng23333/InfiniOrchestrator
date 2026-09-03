#!/usr/bin/env bash
# A/B mixed 4096 repro: IL baseline (4e0fdd7e) vs fix (94502bf6) on isolated GPUs.
#
# Prereq: Phase 1 native product image built (native-p1 tag) for variant B.
# Uses embedded etcd + entrypoint worker (same layout as lab validation).
#
# Usage:
#   ./regression/run_dev_ab_mixed_4096.sh
#   IMAGE_FIX=infini-orchestrator-metax:94502bf6-6ad5e1c9-20260827-native-p1 ./regression/run_dev_ab_mixed_4096.sh
#   SKIP_VARIANT=A ./regression/run_dev_ab_mixed_4096.sh   # fix only
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"

SOURCE_ROOT="${SOURCE_ROOT:-/root/zenghua/workspace/profiling_20260731/InfiniTensorWorktree-fix-issues-1-2}"
DEV_CONTAINER="${DEV_CONTAINER:-infinilm-dev-hpcc37}"
AB_CONTAINER_PREFIX="${AB_CONTAINER_PREFIX:-infiniorch-ab-mixed4096}"
WORKER_PORT="${WORKER_PORT:-8220}"
ROUTER_PORT="${ROUTER_PORT:-8220}"
HPCC_GPUS="${HPCC_GPUS:-4,5,6,7}"
DEV_CONTAINER_NAME="${DEV_CONTAINER_NAME:-infinilm-dev-refactor-dev}"

IMAGE_BASELINE="${IMAGE_BASELINE:-infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813}"
IMAGE_FIX="${IMAGE_FIX:-infini-orchestrator-metax:94502bf6-6ad5e1c9-20260827-native-p1}"
IL_BASELINE="${IL_BASELINE:-4e0fdd7e}"
IL_FIX="${IL_FIX:-94502bf6}"

QWEN_MODEL_DIR="${QWEN3_32B_DIR:-/root/zenghua/models/Qwen3-32B}"
INDUCTOR_CACHE="${INDUCTOR_CACHE:-${CASE_DIR}/../qwen3-32b+xiyan--x203-inf-disagg--opt20260817/cache/piecewise_inductor}"
WORKER_CONFIG="${WORKER_CONFIG:-${CASE_DIR}/docker-compose/config/qwen3-32b-mixed-4096.toml}"
OUT_ROOT="${OUT_ROOT:-/tmp/ab_mixed4096_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "${OUT_ROOT}"

_stop_ab_containers() {
  docker ps -a --format '{{.Names}}' | grep "^${AB_CONTAINER_PREFIX}-" | xargs -r docker rm -f || true
}

_stop_gpu_competitors() {
  echo "[ab] Stopping containers using HPCC GPUs ${HPCC_GPUS}..."
  local stopped=0
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    [[ "${name}" == "${AB_CONTAINER_PREFIX}-"* ]] && continue
    local hpcc_env
    hpcc_env="$(docker inspect "${name}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | grep -E '^HPCC_VISIBLE_DEVICES=' || true)"
    if [[ -n "${hpcc_env}" ]]; then
      local devs="${hpcc_env#HPCC_VISIBLE_DEVICES=}"
      if [[ "${devs}" == "${HPCC_GPUS}" || "${devs}" == *"${HPCC_GPUS}"* ]]; then
        echo "  stopping ${name} (${hpcc_env})"
        docker stop "${name}" >/dev/null 2>&1 || true
        stopped=$((stopped + 1))
      fi
    fi
  done < <(docker ps --format '{{.Names}}')
  echo "[ab] stopped ${stopped} competing container(s)"
}

_wait_worker_ready() {
  local port="$1"
  local timeout="${2:-3600}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if curl -sf --noproxy "*" "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
      echo "[ab] worker ready on :${port} (${elapsed}s)"
      return 0
    fi
    if curl -sf --noproxy "*" "http://127.0.0.1:${port}/health" 2>/dev/null | grep -q 503; then
      echo "[ab] worker /health returned 503 (${elapsed}s)" >&2
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "[ab] timeout waiting for worker on :${port}" >&2
  return 1
}

_grep_worker_signals() {
  local log_file="$1"
  local out_file="$2"
  {
    echo "=== Invalid slice ==="
    grep -n 'Invalid slice' "${log_file}" 2>/dev/null || echo "(none)"
    echo ""
    echo "=== pagedCaching / Xnack / SIGABRT ==="
    grep -nE 'pagedCaching|Xnack|SIGABRT|hcErrorIllegalAddress|slot_mapping.*out of range' \
      "${log_file}" 2>/dev/null || echo "(none)"
  } > "${out_file}"
}

_run_variant() {
  local tag="$1"
  local image="$2"
  local il_sha="$3"
  local ctn="${AB_CONTAINER_PREFIX}-${tag}"

  echo ""
  echo "=========================================="
  echo "A/B variant ${tag}: IL=${il_sha} image=${image}"
  echo "=========================================="

  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "[ab] error: image not found: ${image}" >&2
    return 1
  fi

  docker rm -f "${ctn}" >/dev/null 2>&1 || true

  local -a _etcd_mount=()
  if [[ -x /usr/local/bin/etcd ]]; then
    _etcd_mount=(
      -v /usr/local/bin/etcd:/usr/local/bin/etcd:ro
    )
    [[ -x /usr/local/bin/etcdctl ]] && \
      _etcd_mount+=(-v /usr/local/bin/etcdctl:/usr/local/bin/etcdctl:ro)
  fi

  local -a _py_overlay=()
  if [[ -n "${PROCESSOR_PY_OVERLAY:-}" && -f "${PROCESSOR_PY_OVERLAY}" ]]; then
    _py_overlay=(
      -v "${PROCESSOR_PY_OVERLAY}:/workspace/InfiniLM/python/infinilm/processors/basic_llm_processor.py:ro"
    )
    echo "[ab] overlay processor: ${PROCESSOR_PY_OVERLAY}"
  fi

  local -a _extra_env=()
  if [[ -n "${EXTRA_DOCKER_ENV:-}" ]]; then
    # shellcheck disable=SC2206
    _extra_env=(${EXTRA_DOCKER_ENV})
  fi

  docker run -d \
    --name "${ctn}" \
    --network host \
    --privileged \
    --device /dev/dri \
    --device /dev/htcd \
    --device /dev/kfd \
    -v "${QWEN_MODEL_DIR}:/models/Qwen3-32B:ro" \
    -v "${INDUCTOR_CACHE}:/workspace/piecewise_inductor_cache:rw" \
    -v "$(dirname "${WORKER_CONFIG}"):/config:ro" \
    "${_etcd_mount[@]}" \
    "${_py_overlay[@]}" \
    "${_extra_env[@]}" \
    -e "LAUNCH_COMPONENTS=etcd,entrypoint" \
    -e "ETCD_ENDPOINTS=http://127.0.0.1:2379" \
    -e "BABYSITTER_CONFIGS=/config/$(basename "${WORKER_CONFIG}")" \
    -e "BABYSITTER_HOST=127.0.0.1" \
    -e "ROUTER_PORT=${ROUTER_PORT}" \
    -e "HPCC_VISIBLE_DEVICES=${HPCC_GPUS}" \
    -e "INFINI_DEBUG_PAGED_CACHING=${INFINI_DEBUG_PAGED_CACHING:-1}" \
    --entrypoint /bin/bash \
    "${image}" \
    /app/docker_entrypoint.sh \
    > "${OUT_ROOT}/${tag}-launch.log" 2>&1

  local worker_log="${OUT_ROOT}/${tag}-worker.log"
  docker logs -f "${ctn}" > "${worker_log}" 2>&1 &
  local log_pid=$!

  if ! _wait_worker_ready "${WORKER_PORT}" 3600; then
    kill "${log_pid}" 2>/dev/null || true
    _grep_worker_signals "${worker_log}" "${OUT_ROOT}/${tag}-signals.txt"
    docker rm -f "${ctn}" >/dev/null 2>&1 || true
    echo "[ab] variant ${tag}: FAIL (worker not ready)" >&2
    return 1
  fi

  local harness_out="${OUT_ROOT}/${tag}-evalscope"
  mkdir -p "${harness_out}"
  local rc=0
  set +e
  (
    unset MIN_PROMPT_LENGTH MAX_PROMPT_LENGTH MIN_TOKENS MAX_TOKENS PARALLEL NUMBER 2>/dev/null || true
    export PARALLEL=20 NUMBER=20 MIN_PROMPT_LENGTH=4096 MAX_PROMPT_LENGTH=4096
    export MIN_TOKENS=1024 MAX_TOKENS=1024
    export BENCH_TARGET_URL="http://127.0.0.1:${WORKER_PORT}"
    export ROUTER_URL="${BENCH_TARGET_URL}"
    unset BENCH_CTN_URL 2>/dev/null || true
    export DEV_CONTAINER_NAME="${DEV_CONTAINER_NAME}"
    export INFERENCE_METADATA_URL="http://127.0.0.1:$((WORKER_PORT + 1))"
    export OUT_DIR="${harness_out}"
    export MODEL=Qwen3-32B
    export QWEN3_32B_DIR="${QWEN_MODEL_DIR}"
    cd "${CASE_DIR}"
    ./regression/run_evalscope_mixed_4096.sh
  )
  rc=$?
  set -e

  sleep 2
  kill "${log_pid}" 2>/dev/null || true
  docker logs "${ctn}" >> "${worker_log}" 2>&1 || true
  _grep_worker_signals "${worker_log}" "${OUT_ROOT}/${tag}-signals.txt"

  local eval_log="${harness_out}/evalscope_console.log"
  local success_count="?"
  local failed_count="?"
  if [[ -f "${eval_log}" ]]; then
    if grep -qE 'Total / Success / Failed' "${eval_log}"; then
      read -r _total success_count failed_count _rest < <(
        grep -E 'Total / Success / Failed' "${eval_log}" \
          | tail -1 \
          | sed -n 's/.*│ \([0-9]*\) \/ \([0-9]*\) \/ \([0-9]*\) .*/\1 \2 \3/p'
      )
      echo "[ab] variant ${tag}: evalscope success=${success_count}/${_total} failed=${failed_count}"
      if [[ "${success_count}" != "${NUMBER:-20}" || "${failed_count}" != "0" ]]; then
        echo "[ab] variant ${tag}: FAIL (expected ${NUMBER:-20}/20 success)" >&2
        rc=1
      fi
    fi
  fi

  docker rm -f "${ctn}" >/dev/null 2>&1 || true

  {
    echo "variant=${tag}"
    echo "il_sha=${il_sha}"
    echo "image=${image}"
    echo "evalscope_rc=${rc}"
    echo "evalscope_success=${success_count}"
    echo "evalscope_failed=${failed_count}"
    echo "worker_log=${worker_log}"
    echo "signals=${OUT_ROOT}/${tag}-signals.txt"
    echo "evalscope_out=${harness_out}"
  } > "${OUT_ROOT}/${tag}-summary.txt"

  if [[ ${rc} -ne 0 ]]; then
    echo "[ab] variant ${tag}: EvalScope FAIL (rc=${rc})" >&2
    return 1
  fi
  echo "[ab] variant ${tag}: EvalScope OK"
  return 0
}

echo "=========================================="
echo "Dev A/B mixed 4096 repro"
echo "  GPUs:        ${HPCC_GPUS}"
echo "  Baseline:    ${IMAGE_BASELINE} (IL ${IL_BASELINE})"
echo "  Fix:         ${IMAGE_FIX} (IL ${IL_FIX})"
echo "  Output:      ${OUT_ROOT}"
echo "=========================================="

_stop_ab_containers
_stop_gpu_competitors

declare -i _failures=0

if [[ "${SKIP_VARIANT:-}" != "A" && "${SKIP_VARIANT:-}" != "a" ]]; then
  if ! _run_variant "A-baseline" "${IMAGE_BASELINE}" "${IL_BASELINE}"; then
    _failures=$((_failures + 1))
  fi
fi

if [[ "${SKIP_VARIANT:-}" != "B" && "${SKIP_VARIANT:-}" != "b" ]]; then
  if ! _run_variant "B-fix" "${IMAGE_FIX}" "${IL_FIX}"; then
    _failures=$((_failures + 1))
  fi
fi

echo ""
echo "=========================================="
echo "A/B summary (${OUT_ROOT})"
echo "=========================================="
for f in "${OUT_ROOT}"/*-summary.txt; do
  [[ -f "${f}" ]] && cat "${f}" && echo ""
done
for f in "${OUT_ROOT}"/*-signals.txt; do
  [[ -f "${f}" ]] && echo "--- $(basename "${f}") ---" && cat "${f}" && echo ""
done

if (( _failures > 0 )); then
  echo "[ab] ${_failures} variant(s) failed" >&2
  exit 1
fi
echo "[ab] all variants passed"
