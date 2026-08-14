#!/usr/bin/env bash
# Host-native bench-warehouse sync for frontend/run-host-panel.sh.
#
# Compose warehouse-sync writes to a Docker named volume. This helper is for a
# host-native Frontend where BENCH_WAREHOUSE_REPO points at a sibling path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${IO_ROOT}/.." && pwd)"

LIVE="${BENCH_WAREHOUSE_LIVE_REPO:-${ROOT}/bench-warehouse-sync-live}"
PANEL_LINK="${BENCH_WAREHOUSE_PANEL_LINK:-${ROOT}/bench-warehouse}"
URL="${BENCH_WAREHOUSE_GIT_URL:-https://github.com/InfiniTensor/bench-warehouse.git}"
REF="${BENCH_WAREHOUSE_GIT_REF:-master}"
INTERVAL="${BENCH_WAREHOUSE_SYNC_INTERVAL_SEC:-300}"
TOKEN="${BENCH_WAREHOUSE_GITHUB_TOKEN:-}"
LOCK_DIR="${ROOT}/.warehouse-sync-host.lock"

git_auth() {
  if [ -n "${TOKEN}" ]; then
    git -c http.version=HTTP/1.1 -c "http.extraHeader=AUTHORIZATION: bearer ${TOKEN}" "$@"
  else
    git -c http.version=HTTP/1.1 -c credential.helper=store "$@"
  fi
}

write_status() {
  local status="$1"
  local sha="${2:-}"
  local message="${3:-}"
  local pulled_at status_dir
  pulled_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  status_dir="${ROOT}"
  if [ -d "${LIVE}/.git" ]; then
    status_dir="${LIVE}"
  fi
  cat >"${status_dir}/.warehouse-sync-status.tmp" <<EOF
{
  "status": "${status}",
  "ref": "${REF}",
  "sha": "${sha}",
  "pulled_at": "${pulled_at}",
  "mode": "host-native",
  "message": "${message}"
}
EOF
  mv "${status_dir}/.warehouse-sync-status.tmp" "${status_dir}/.warehouse-sync-status" 2>/dev/null || true
}

point_panel_at_live() {
  if [ -L "${PANEL_LINK}" ]; then
    ln -sfn "${LIVE}" "${PANEL_LINK}"
  elif [ ! -e "${PANEL_LINK}" ]; then
    ln -s "${LIVE}" "${PANEL_LINK}"
  else
    echo "[warehouse-sync-host] warning: ${PANEL_LINK} exists and is not a symlink; leaving it unchanged" >&2
  fi
}

clone_sparse_raw() {
  local tmp="$1"
  git_auth clone --depth 1 --filter=blob:none --sparse --branch "${REF}" "${URL}" "${tmp}" || return 1
  git_auth -C "${tmp}" config http.version HTTP/1.1
  if [ -z "${TOKEN}" ]; then
    git_auth -C "${tmp}" config credential.helper store
  fi
  git_auth -C "${tmp}" sparse-checkout set raw
}

sync_once() {
  echo "[warehouse-sync-host] sync start url=${URL} ref=${REF} live=${LIVE}"
  if [ ! -d "${LIVE}/.git" ]; then
    if [ -e "${LIVE}" ]; then
      echo "[warehouse-sync-host] ${LIVE} exists but is not a git checkout" >&2
      write_status "error" "" "live path exists but is not a git checkout"
      return 1
    fi
    local tmp="${LIVE}.tmp.$(date +%Y%m%d%H%M%S).$$"
    if ! clone_sparse_raw "${tmp}"; then
      write_status "error" "" "clone failed"
      echo "[warehouse-sync-host] clone failed" >&2
      return 1
    fi
    mv "${tmp}" "${LIVE}"
  else
    if ! (
      git_auth -C "${LIVE}" fetch --depth 1 --filter=blob:none origin "${REF}"
      git_auth -C "${LIVE}" reset --hard "origin/${REF}"
      git_auth -C "${LIVE}" sparse-checkout set raw
    ); then
      write_status "error" "" "fetch/reset failed"
      echo "[warehouse-sync-host] fetch/reset failed" >&2
      return 1
    fi
  fi

  local sha
  sha="$(cd "${LIVE}" && git rev-parse --short HEAD 2>/dev/null || echo "")"
  write_status "ok" "${sha}" "synced raw/"
  point_panel_at_live
  echo "[warehouse-sync-host] ok ref=${REF} sha=${sha}"
}

main() {
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "[warehouse-sync-host] already running or stale lock at ${LOCK_DIR}" >&2
    exit 1
  fi
  trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

  echo "[warehouse-sync-host] interval=${INTERVAL}s"
  while true; do
    sync_once || true
    sleep "${INTERVAL}"
  done
}

main "$@"
