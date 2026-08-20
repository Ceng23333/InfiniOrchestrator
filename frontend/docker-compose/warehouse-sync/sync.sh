#!/bin/sh
# Periodic git pull of bench-warehouse into /warehouse.
# Default URL is SSH (git@). HTTPS may use BENCH_WAREHOUSE_GITHUB_TOKEN via
# http.extraHeader (never logged). SSH path uses plain git (no token).
set -eu

URL="${BENCH_WAREHOUSE_GIT_URL:-git@github.com:InfiniTensor/bench-warehouse.git}"
REF="${BENCH_WAREHOUSE_GIT_REF:-master}"
INTERVAL="${BENCH_WAREHOUSE_SYNC_INTERVAL_SEC:-300}"
STATUS_FILE="/warehouse/.warehouse-sync-status"
TOKEN="${BENCH_WAREHOUSE_GITHUB_TOKEN:-}"

is_ssh_git_url() {
  case "${URL}" in
    git@*|ssh://*) return 0 ;;
    *) return 1 ;;
  esac
}

git_auth() {
  if is_ssh_git_url; then
    git "$@"
  elif [ -n "${TOKEN}" ]; then
    git -c "http.extraHeader=AUTHORIZATION: bearer ${TOKEN}" "$@"
  else
    git "$@"
  fi
}

write_status() {
  _status="$1"
  _ref="$2"
  _sha="$3"
  _pulled_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2016
  printf '%s\n' \
    "{" \
    "  \"status\": \"${_status}\"," \
    "  \"ref\": \"${_ref}\"," \
    "  \"sha\": \"${_sha}\"," \
    "  \"pulled_at\": \"${_pulled_at}\"" \
    "}" >"${STATUS_FILE}.tmp"
  mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

sync_once() {
  if [ ! -d /warehouse/.git ]; then
    echo "[warehouse-sync] cloning ${URL} (ref=${REF}) → /warehouse"
    rm -rf /warehouse/* /warehouse/.[!.]* /warehouse/..?* 2>/dev/null || true
    if ! git_auth clone --depth 1 --branch "${REF}" "${URL}" /warehouse; then
      write_status "error" "${REF}" ""
      echo "[warehouse-sync] clone failed" >&2
      return 1
    fi
  else
    echo "[warehouse-sync] fetching origin/${REF}"
    if ! (
      cd /warehouse
      git_auth fetch origin "${REF}"
      git reset --hard "origin/${REF}"
    ); then
      write_status "error" "${REF}" ""
      echo "[warehouse-sync] fetch/reset failed" >&2
      return 1
    fi
  fi

  _sha="$(cd /warehouse && git rev-parse --short HEAD 2>/dev/null || echo "")"
  write_status "ok" "${REF}" "${_sha}"
  echo "[warehouse-sync] ok ref=${REF} sha=${_sha}"
}

echo "[warehouse-sync] interval=${INTERVAL}s url=${URL} ref=${REF}"
if ! is_ssh_git_url && [ -z "${TOKEN}" ]; then
  echo "[warehouse-sync] warning: HTTPS URL without BENCH_WAREHOUSE_GITHUB_TOKEN (private HTTPS will fail)" >&2
fi

while true; do
  sync_once || true
  sleep "${INTERVAL}"
done
