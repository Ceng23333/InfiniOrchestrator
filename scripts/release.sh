#!/usr/bin/env bash
# Freeze InfiniTensorWorktree submodule SHAs into an InfiniOrchestrator release commit + annotated tag.
#
# Examples:
#   TAG=v2026.07.31 ./scripts/release.sh --from-current
#   IC_SHA=... IL_SHA=... IM_SHA=... TAG=v2026.07.31 ./scripts/release.sh
#
# Does not push. Prints push commands when done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree_env.sh
source "${SCRIPT_DIR}/worktree_env.sh"

cd "${IO_ROOT}"

TAG="${TAG:-v$(date -u +%Y.%m.%d)}"
PIN_ARGS=()
if [[ "${1:-}" == "--from-current" ]]; then
  PIN_ARGS=(--from-current)
elif [[ $# -gt 0 ]]; then
  echo "usage: TAG=vYYYY.MM.DD $0 [--from-current]" >&2
  echo "  or set IC_SHA IL_SHA IM_SHA" >&2
  exit 1
fi

if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "error: tag already exists: ${TAG}" >&2
  exit 1
fi

mapfile -t dirty < <(git status --porcelain | awk '{print $2}')
for path in "${dirty[@]:-}"; do
  [[ -z "${path}" ]] && continue
  case "${path}" in
    InfiniTensorWorktree/*|.gitmodules|scripts/*|README.md|deploy/*|container/*|docs/*|harness/*|playground/*|.cursor/*) ;;
    *)
      echo "error: unexpected dirty path before release: ${path}" >&2
      echo "  commit or stash unrelated changes first" >&2
      exit 1
      ;;
  esac
done

"${SCRIPT_DIR}/pin_worktree.sh" ${PIN_ARGS[@]+"${PIN_ARGS[@]}"}

# shellcheck source=/dev/null
source "${INFINI_TENSOR_WORKTREE}/MANIFEST"

MSG="release: freeze InfiniTensorWorktree ${TAG}

IC_SHA=${IC_SHA}
IL_SHA=${IL_SHA}
IM_SHA=${IM_SHA}
"

git add InfiniTensorWorktree/MANIFEST \
  InfiniTensorWorktree/InfiniCore \
  InfiniTensorWorktree/InfiniLM \
  InfiniTensorWorktree/InfiniMetadata \
  .gitmodules \
  scripts/worktree_env.sh \
  scripts/pin_worktree.sh \
  scripts/release.sh \
  2>/dev/null || true

git add -u -- scripts README.md deploy container docs harness playground 2>/dev/null || true

if git diff --cached --quiet; then
  echo "error: nothing staged for release commit" >&2
  exit 1
fi

git commit -m "${MSG}"
git tag -a "${TAG}" -m "${MSG}"

IO_SHA="$(git rev-parse HEAD)"
sed -i "s/^IO_SHA=.*/IO_SHA=${IO_SHA}/" "${INFINI_TENSOR_WORKTREE}/MANIFEST"
git add InfiniTensorWorktree/MANIFEST
if ! git diff --cached --quiet; then
  git commit -m "release: record IO_SHA ${IO_SHA} in InfiniTensorWorktree/MANIFEST"
  git tag -d "${TAG}" >/dev/null
  git tag -a "${TAG}" -m "${MSG}"
fi

echo ""
echo "Created commit $(git rev-parse --short HEAD) and tag ${TAG}"
echo ""
echo "Push when ready:"
echo "  git push origin HEAD --tags"
echo "Consumers:"
echo "  git clone --recurse-submodules <url>"
echo "  git checkout ${TAG} && git submodule update --init --recursive"
