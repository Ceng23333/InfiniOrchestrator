#!/usr/bin/env bash
# Release freezes moved to the sibling InfiniTensorWorktree repo.
echo "error: release.sh moved to InfiniTensorWorktree" >&2
echo "  Release tags (vYYYY.MM.DD) lock IC/IL/IM pins in:" >&2
echo "    https://github.com/Ceng23333/InfiniTensorWorktree" >&2
echo "  Run:" >&2
echo "    source scripts/worktree_env.sh" >&2
echo "    TAG=vYYYY.MM.DD \"\${INFINI_TENSOR_WORKTREE}/scripts/release.sh\" --from-current" >&2
exit 1
