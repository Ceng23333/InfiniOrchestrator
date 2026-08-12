#!/usr/bin/env bash
# Repro wrapper → unexpected_behavior case runner.
exec "$(cd "$(dirname "$0")" && pwd)/scenarios/benchmark/cases/unexpected_behavior/scripts/run.sh" "$@"
