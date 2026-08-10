#!/usr/bin/env bash
# Pin/release freezes moved to the sibling InfiniTensorWorktree repo.
echo "error: pin_worktree.sh moved to InfiniTensorWorktree" >&2
echo "  source scripts/worktree_env.sh  # resolves sibling INFINI_TENSOR_WORKTREE" >&2
echo "  \"\${INFINI_TENSOR_WORKTREE}/scripts/pin_worktree.sh\" \"\$@\"" >&2
exit 1
