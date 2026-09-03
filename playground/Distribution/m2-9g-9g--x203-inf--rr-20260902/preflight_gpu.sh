#!/usr/bin/env bash
set -euo pipefail

host="${M2_TARGET_HOST:-$(hostname -s)}"
case "$host" in
  metax-9)
    command -v ht-smi >/dev/null || { echo "ht-smi is required on metax-9" >&2; exit 2; }
    exec ht-smi
    ;;
  metax-49|node2)
    command -v mx-smi >/dev/null || { echo "mx-smi is required on metax-49" >&2; exit 2; }
    exec mx-smi
    ;;
  *)
    echo "unsupported host: $host (expected metax-9 or metax-49)" >&2
    exit 2
    ;;
esac
