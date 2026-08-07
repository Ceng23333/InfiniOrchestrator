#!/usr/bin/env bash
# Resolve host-side HuggingFace tokenizer directory for vLLM bench (not container /models).
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

resolve_tokenizer_dir() {
  local model="${1:?model required}"
  local explicit="${2:-${TOKENIZER_DIR:-}}"

  if [[ -n "${explicit}" && -d "${explicit}" ]] \
    && { [[ -f "${explicit}/config.json" ]] || [[ -f "${explicit}/tokenizer_config.json" ]]; }; then
    echo "${explicit}"
    return 0
  fi

  local candidates=()
  case "${model}" in
    9g_8b_thinking)
      candidates=(
        "${MODEL1_DIR:-}"
        "/data-aisoft/zenghua/models/9g_8b_thinking_llama"
        "/data-aisoft/zenghua/models/9g_8b_thinking"
      )
      ;;
    Qwen3-32B)
      candidates=(
        "${QWEN3_32B_DIR:-}"
        "/data-aisoft/zenghua/models/Qwen3-32B"
        "/root/zenghua/models/Qwen3-32B"
      )
      ;;
    minicpm5|minicpm5.16a3.v0314)
      candidates=(
        "${MINICPM5_TOKENIZER_DIR:-}"
        "${MONOREPO_WORK:-${INFINILM_PREFILL_WORK:-}}/vllm_minicpm5/tokenizer_bytelevel"
        "/data-aisoft/zenghua/models/minicpm5.16a3.v0314"
      )
      ;;
    *)
      echo "[resolve_tokenizer] unsupported model: ${model}" >&2
      return 1
      ;;
  esac

  local d
  for d in "${candidates[@]}"; do
    if [[ -n "${d}" && -d "${d}" ]] \
      && { [[ -f "${d}/config.json" ]] || [[ -f "${d}/tokenizer_config.json" ]]; }; then
      echo "${d}"
      return 0
    fi
  done

  echo "[resolve_tokenizer] no host tokenizer dir for ${model} (tried: ${candidates[*]})" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_tokenizer_dir "${1:?model}" "${2:-}"
fi
