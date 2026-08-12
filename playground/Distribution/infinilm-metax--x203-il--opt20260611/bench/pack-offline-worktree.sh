#!/usr/bin/env bash
# Pack InfiniOrchestrator + sibling InfiniTensorWorktree for offline deploy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"
require_worktree_repos InfiniCore InfiniLM
EXCLUDES_FILE="${SCRIPT_DIR}/pack-offline-excludes.txt"

STAGING="${STAGING:-/data-aisoft/zenghua/staging/offline-src-$(date -u +%Y%m%d)}"
BASE_IMAGE="${BASE_IMAGE:-infinilm-svc:metax-hpcc-1004_218-202602281209}"
CASE_NAME="infinilm-metax-deployment-opt-20260611"
MONOREPO_ROOT="$(cd "${IO_ROOT}/.." && pwd)"
PACK_PARENT="$(cd "${IO_ROOT}/.." && pwd)"
ITW_BASENAME="$(basename "${INFINI_TENSOR_WORKTREE}")"

git_short_sha() {
  local repo="$1"
  if git -C "${repo}" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "${repo}" rev-parse --short HEAD
  else
    echo "unknown"
  fi
}

IL_SHA="$(git_short_sha "${WORKTREE_ROOT}/InfiniLM")"
IC_SHA="$(git_short_sha "${WORKTREE_ROOT}/InfiniCore")"
ITW_SHA="$(git_short_sha "${WORKTREE_ROOT}")"
BW_SHA="$(git_short_sha "${BENCH_WAREHOUSE_REPO}")"
IO_SHA="$(git_short_sha "${IO_ROOT}")"

if [[ -z "${SRC_TAR:-}" ]]; then
  SRC_TAR="deployment-src-${IL_SHA}-${IC_SHA}-${IO_SHA}.tar.gz"
fi
if [[ "${SRC_TAR}" != /* ]]; then
  SRC_TAR="${STAGING}/${SRC_TAR}"
fi

if [[ ! -f "${EXCLUDES_FILE}" ]]; then
  echo "error: exclude file not found: ${EXCLUDES_FILE}" >&2
  exit 1
fi

if [[ "$(cd "${INFINI_TENSOR_WORKTREE}/.." && pwd)" != "${PACK_PARENT}" ]]; then
  echo "error: InfiniTensorWorktree must be a sibling of InfiniOrchestrator under ${PACK_PARENT}" >&2
  echo "  INFINI_TENSOR_WORKTREE=${INFINI_TENSOR_WORKTREE}" >&2
  exit 1
fi

MANIFEST="${IO_ROOT}/MANIFEST"
PACK_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${MANIFEST}" <<EOF
IL_SHA=${IL_SHA}
IC_SHA=${IC_SHA}
ITW_SHA=${ITW_SHA}
BW_SHA=${BW_SHA}
IO_SHA=${IO_SHA}
WORKTREE_ROOT=${ITW_BASENAME}
PACK_DATE=${PACK_DATE}
BASE_IMAGE=${BASE_IMAGE}
CASE=${CASE_NAME}
EOF

tar_args=(
  -C "${PACK_PARENT}"
  -czf "${SRC_TAR}"
  --exclude-from="${EXCLUDES_FILE}"
  InfiniOrchestrator
  "${ITW_BASENAME}"
)

echo "IO_ROOT=${IO_ROOT}"
echo "WORKTREE_ROOT=${WORKTREE_ROOT}"
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
  rm -f "${MANIFEST}"
  exit 0
fi

mkdir -p "${STAGING}"
tar "${tar_args[@]}"
rm -f "${MANIFEST}"

echo ""
echo "Post-pack gates:"
grep -n 'gc.collect' "${WORKTREE_ROOT}/InfiniLM/python/infinilm/modeling_utils.py"
test -f "${IO_ROOT}/deploy/cases/${CASE_NAME}/validate.sh"
test -f "${IO_ROOT}/container/metax/build-image.sh"

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
