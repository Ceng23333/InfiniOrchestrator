#!/usr/bin/env bash
# Pack InfiniCore + InfiniLM + InfiniOrchestrator for offline deploy (source-only tar).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MONOREPO_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
EXCLUDES_FILE="${SCRIPT_DIR}/pack-offline-excludes.txt"

STAGING="${STAGING:-/data-aisoft/zenghua/staging/offline-src-$(date -u +%Y%m%d)}"
BASE_IMAGE="${BASE_IMAGE:-infinilm-svc:metax-hpcc-1004_218-202602281209}"
CASE_NAME="infinilm-metax-deployment-opt-20260611"

git_short_sha() {
  local repo="$1"
  if git -C "${repo}" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "${repo}" rev-parse --short HEAD
  else
    echo "unknown"
  fi
}

IL_SHA="$(git_short_sha "${MONOREPO_ROOT}/InfiniLM")"
IC_SHA="$(git_short_sha "${MONOREPO_ROOT}/InfiniCore")"
IO_SHA="$(git_short_sha "${MONOREPO_ROOT}/InfiniOrchestrator")"

if [[ -z "${SRC_TAR:-}" ]]; then
  SRC_TAR="deployment-src-${IL_SHA}-${IC_SHA}-${IO_SHA}.tar.gz"
fi
if [[ "${SRC_TAR}" != /* ]]; then
  SRC_TAR="${STAGING}/${SRC_TAR}"
fi

for d in InfiniCore InfiniLM InfiniOrchestrator; do
  if [[ ! -d "${MONOREPO_ROOT}/${d}" ]]; then
    echo "error: expected directory ${MONOREPO_ROOT}/${d}" >&2
    exit 1
  fi
done

if [[ ! -f "${EXCLUDES_FILE}" ]]; then
  echo "error: exclude file not found: ${EXCLUDES_FILE}" >&2
  exit 1
fi

MANIFEST="${MONOREPO_ROOT}/MANIFEST"
PACK_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${MANIFEST}" <<EOF
IL_SHA=${IL_SHA}
IC_SHA=${IC_SHA}
IO_SHA=${IO_SHA}
PACK_DATE=${PACK_DATE}
BASE_IMAGE=${BASE_IMAGE}
CASE=${CASE_NAME}
EOF

cleanup_manifest() {
  rm -f "${MANIFEST}"
}
trap cleanup_manifest EXIT

tar_args=(
  -C "${MONOREPO_ROOT}"
  -czf "${SRC_TAR}"
  --exclude-from="${EXCLUDES_FILE}"
  InfiniCore InfiniLM InfiniOrchestrator MANIFEST
)

echo "MONOREPO_ROOT=${MONOREPO_ROOT}"
echo "STAGING output: ${SRC_TAR}"
echo "MANIFEST:"
cat "${MANIFEST}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ""
  echo "DRY_RUN=1 — would run:"
  printf '  tar'
  for arg in "${tar_args[@]}"; do
    printf ' %q' "${arg}"
  done
  printf '\n'
  echo ""
  echo "Exclude patterns (${EXCLUDES_FILE}):"
  grep -v '^#' "${EXCLUDES_FILE}" | grep -v '^[[:space:]]*$' || true
  exit 0
fi

mkdir -p "${STAGING}"
tar "${tar_args[@]}"

echo ""
echo "Post-pack gates:"
grep -n 'gc.collect' "${MONOREPO_ROOT}/InfiniLM/python/infinilm/modeling_utils.py"
test -f "${MONOREPO_ROOT}/InfiniOrchestrator/deploy/cases/${CASE_NAME}/validate.sh"
test -f "${MONOREPO_ROOT}/InfiniOrchestrator/container/metax/build-image.sh"

echo ""
echo "Packed: ${SRC_TAR}"
ls -lh "${SRC_TAR}"

file_count="$(tar -tzf "${SRC_TAR}" | wc -l | tr -d ' ')"
echo "Archive entries: ${file_count}"

if gzip -l "${SRC_TAR}" >/dev/null 2>&1; then
  uncompressed="$(gzip -l "${SRC_TAR}" | tail -1 | awk '{print $2}')"
  if [[ -n "${uncompressed}" && "${uncompressed}" != "0" ]]; then
    echo "Estimated uncompressed size: $(numfmt --to=iec-i --suffix=B "${uncompressed}" 2>/dev/null || echo "${uncompressed} bytes")"
  fi
fi

echo "Done."
