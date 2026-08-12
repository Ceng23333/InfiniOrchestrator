"""Shared OpenAI-compatible HTTP helpers for benchmark case clients."""

from __future__ import annotations

import json
from typing import Any, Dict, Optional
from urllib.request import Request


def chat_completions_url(base_url: str) -> str:
    return f"{base_url.rstrip('/')}/v1/chat/completions"


def chat_completions_payload(
    model: str,
    prompt: str,
    *,
    max_tokens: int = 64,
    stream: bool = False,
    temperature: Optional[float] = None,
    extra_body: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    body: Dict[str, Any] = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": stream,
    }
    if temperature is not None:
        body["temperature"] = temperature
    if extra_body:
        body.update(extra_body)
    return body


def chat_completions_request(
    base_url: str,
    payload: Dict[str, Any],
    *,
    headers: Optional[Dict[str, str]] = None,
) -> Request:
    data = payload if isinstance(payload, (bytes, bytearray)) else json.dumps(payload).encode("utf-8")
    hdrs = {"Content-Type": "application/json"}
    if headers:
        hdrs.update(headers)
    return Request(
        chat_completions_url(base_url),
        data=data,
        headers=hdrs,
        method="POST",
    )
