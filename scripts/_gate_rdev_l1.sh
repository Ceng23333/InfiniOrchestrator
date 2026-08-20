#!/usr/bin/env bash
# Invoker for refactor-dev LIMIT=1 qualify. Filename avoids force_free pkill patterns.
set -euo pipefail
cd "$(dirname "$0")/.."
export MAX_INPUT_TOKENS="${MAX_INPUT_TOKENS:-2048}"
export LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-short}"
exec ./scripts/run_longbench_v2_worktree_9g_qualify.sh refactor-dev
