#!/usr/bin/env bash
# Checkout pinned SHAs in InfiniOrchestrator/worktree submodules and stage gitlinks.
#
# Env (optional unless --from-current):
#   IC_SHA IL_SHA IM_SHA BW_SHA
# Or:
#   ./pin_worktree.sh --from-current   # use each submodule HEAD
#
# Writes WORKTREE_MANIFEST at InfiniOrchestrator root and stages:
#   .gitmodules worktree/* WORKTREE_MANIFEST
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree_env.sh
source "${SCRIPT_DIR}/worktree_env.sh"

FROM_CURRENT=0
if [[ "${1:-}" == "--from-current" ]]; then
  FROM_CURRENT=1
fi

IC_URL="https://github.com/Ceng23333/InfiniCore.git"
IL_URL="https://github.com/Ceng23333/InfiniLM.git"
IM_URL="https://github.com/InfiniTensor/InfiniMetadata.git"
BW_URL="https://github.com/InfiniTensor/bench-warehouse.git"

require_worktree_repos InfiniCore InfiniLM InfiniMetadata bench-warehouse

pin_one() {
  local name="$1" sha="$2"
  local path="${WORKTREE_ROOT}/${name}"
  echo "Pinning ${name} → ${sha} ..."
  git -C "${path}" fetch --all --tags
  git -C "${path}" checkout --detach "${sha}"
  if [[ -f "${path}/.gitmodules" ]]; then
    git -C "${path}" submodule update --init --recursive
  fi
}

if [[ "${FROM_CURRENT}" -eq 1 ]]; then
  IC_SHA="$(git -C "${WORKTREE_ROOT}/InfiniCore" rev-parse HEAD)"
  IL_SHA="$(git -C "${WORKTREE_ROOT}/InfiniLM" rev-parse HEAD)"
  IM_SHA="$(git -C "${WORKTREE_ROOT}/InfiniMetadata" rev-parse HEAD)"
  BW_SHA="$(git -C "${WORKTREE_ROOT}/bench-warehouse" rev-parse HEAD)"
else
  : "${IC_SHA:?set IC_SHA or pass --from-current}"
  : "${IL_SHA:?set IL_SHA or pass --from-current}"
  : "${IM_SHA:?set IM_SHA or pass --from-current}"
  : "${BW_SHA:?set BW_SHA or pass --from-current}"
  pin_one InfiniCore "${IC_SHA}"
  pin_one InfiniLM "${IL_SHA}"
  pin_one InfiniMetadata "${IM_SHA}"
  pin_one bench-warehouse "${BW_SHA}"
fi

# Normalize to full SHAs after checkout / --from-current
IC_SHA="$(git -C "${WORKTREE_ROOT}/InfiniCore" rev-parse HEAD)"
IL_SHA="$(git -C "${WORKTREE_ROOT}/InfiniLM" rev-parse HEAD)"
IM_SHA="$(git -C "${WORKTREE_ROOT}/InfiniMetadata" rev-parse HEAD)"
BW_SHA="$(git -C "${WORKTREE_ROOT}/bench-warehouse" rev-parse HEAD)"
IO_SHA="$(git -C "${IO_ROOT}" rev-parse HEAD)"
PIN_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MANIFEST="${IO_ROOT}/WORKTREE_MANIFEST"
cat > "${MANIFEST}" <<EOF
IO_SHA=${IO_SHA}
IC_SHA=${IC_SHA}
IL_SHA=${IL_SHA}
IM_SHA=${IM_SHA}
BW_SHA=${BW_SHA}
IC_URL=${IC_URL}
IL_URL=${IL_URL}
IM_URL=${IM_URL}
BW_URL=${BW_URL}
PIN_DATE=${PIN_DATE}
EOF

cd "${IO_ROOT}"
git add \
  worktree/InfiniCore \
  worktree/InfiniLM \
  worktree/InfiniMetadata \
  worktree/bench-warehouse \
  WORKTREE_MANIFEST
if [[ -f .gitmodules ]]; then
  git add .gitmodules
fi

echo ""
echo "WORKTREE_MANIFEST:"
cat "${MANIFEST}"
echo ""
echo "Staged gitlinks. Review with: git status && git diff --cached --submodule"
