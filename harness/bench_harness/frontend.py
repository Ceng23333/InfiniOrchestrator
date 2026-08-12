"""Frontend identity for GET /metadata and warehouse path partitioning."""

from __future__ import annotations

import os

FRONTEND_METADATA_KEY = "frontend"
FRONTEND_ENV_VAR = "INFINI_FRONTEND"
FRONTEND_INFINILM = "InfiniLM"
FRONTEND_INFINI_ORCHESTRATOR = "InfiniOrchestrator"
FRONTEND_VLLM = "vLLM"
FRONTEND_OPENAI = "OpenAI"
FRONTEND_VALUES = frozenset(
    {
        FRONTEND_INFINILM,
        FRONTEND_INFINI_ORCHESTRATOR,
        FRONTEND_VLLM,
        FRONTEND_OPENAI,
    }
)


def resolve_frontend() -> str:
    """Return configured frontend from ``INFINI_FRONTEND``, default ``InfiniLM``."""
    val = os.environ.get(FRONTEND_ENV_VAR, "").strip()
    if val in FRONTEND_VALUES:
        return val
    return FRONTEND_INFINILM


def frontend_path_part(value: str) -> str:
    """Filesystem path segment for ``{fe}``; empty or invalid → ``_unknown``."""
    text = str(value or "").strip()
    if text in FRONTEND_VALUES:
        return text
    return "_unknown"
