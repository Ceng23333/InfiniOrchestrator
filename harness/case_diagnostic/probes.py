"""HTTP probe runners with categorized results."""

from __future__ import annotations

import json
import http.client
import re
import time
from urllib.parse import urlsplit
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

from .evidence import write_json, write_text
from .load import ProbeSpec, ServiceSpec

UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.I,
)

CATEGORY_BY_KIND: dict[str, str] = {
    "http_ok": "endpoint_reachability",
    "prometheus": "backend_readiness",
    "metadata_uuid": "backend_readiness",
    "json_snapshot": "backend_readiness",
    "chat_smoke": "routing",
    "services_expect": "routing",
    "json_error": "routing",
    "sse_stream": "streaming",
    "token_usage": "routing",
    "model_match": "routing",
    "cancellation": "cancellation",
    "deadline": "cancellation",
}


@dataclass
class ProbeResult:
    service_id: str
    path: str
    kind: str
    status: str  # pass | fail | skip
    category: str
    latency_ms: int = 0
    message: str = ""
    evidence: str = ""
    body_preview: str = ""


@dataclass
class ProbeContext:
    run_root: Any
    evidence_dirs: dict[str, Any]
    timeout: float = 10.0
    scrape_cache: dict[str, Any] = field(default_factory=dict)


def _request(
    url: str,
    *,
    method: str = "GET",
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 10.0,
) -> tuple[int, str, float]:
    hdrs = {"Accept": "*/*", "User-Agent": "infini-validate-case/0.1"}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            elapsed_ms = int((time.perf_counter() - start) * 1000)
            return resp.status, text, elapsed_ms
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        elapsed_ms = int((time.perf_counter() - start) * 1000)
        return exc.code, text, elapsed_ms


def _full_url(base: str, path: str) -> str:
    if path.startswith("http://") or path.startswith("https://"):
        return path
    return f"{base.rstrip('/')}{path}"


def _chat_request(
    base: str,
    path: str,
    *,
    model: str,
    stream: bool,
    timeout: float,
) -> tuple[int, str, int]:
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": "m2 conformance"}],
            "stream": stream,
            "max_tokens": 8,
        }
    ).encode("utf-8")
    return _request(
        _full_url(base, path),
        method="POST",
        body=body,
        headers={"Content-Type": "application/json"},
        timeout=timeout,
    )


def _cancel_stream(
    url: str,
    *,
    model: str,
    timeout: float,
) -> tuple[int, str, int]:
    """Read the first streaming bytes, then close the client connection."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError(f"unsupported cancellation URL: {url}")
    connection_type = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
    port = parts.port or (443 if parts.scheme == "https" else 80)
    conn = connection_type(parts.hostname, port, timeout=timeout)
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": "m2 cancellation"}],
            "stream": True,
            "max_tokens": 128,
        }
    ).encode("utf-8")
    path = parts.path or "/"
    if parts.query:
        path = f"{path}?{parts.query}"
    start = time.perf_counter()
    try:
        conn.request(
            "POST",
            path,
            body=body,
            headers={
                "Accept": "text/event-stream",
                "Content-Type": "application/json",
                "User-Agent": "infini-validate-case/0.1",
            },
        )
        response = conn.getresponse()
        first_chunk = response.read(256).decode("utf-8", errors="replace")
        elapsed_ms = int((time.perf_counter() - start) * 1000)
        return response.status, first_chunk, elapsed_ms
    finally:
        conn.close()


def _evidence_path(ctx: ProbeContext, svc: ServiceSpec, probe: ProbeSpec, suffix: str) -> str:
    safe = probe.path.strip("/").replace("/", "_") or "root"
    fname = f"{svc.id}_{safe}.{suffix}"
    return str(ctx.evidence_dirs["evidence"] / fname)


def run_probe(
    svc: ServiceSpec,
    probe: ProbeSpec,
    ctx: ProbeContext,
    *,
    services_json: dict[str, Any] | None = None,
) -> ProbeResult:
    category = CATEGORY_BY_KIND.get(probe.kind, "endpoint_reachability")
    base = svc.resolved_base_url
    url = _full_url(base, probe.path) if base else probe.path
    result = ProbeResult(
        service_id=svc.id,
        path=probe.path,
        kind=probe.kind,
        status="fail",
        category=category,
    )

    try:
        if probe.kind == "http_ok":
            status, body, latency = _request(url, timeout=ctx.timeout)
            result.latency_ms = latency
            result.body_preview = body[:500]
            if 200 <= status < 300:
                result.status = "pass"
            else:
                result.message = f"HTTP {status}"
            ev = _evidence_path(ctx, svc, probe, "txt")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev

        elif probe.kind == "prometheus":
            status, body, latency = _request(url, timeout=ctx.timeout)
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "prom")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            if status >= 400:
                result.message = f"HTTP {status}"
            elif probe.expect and probe.expect not in body:
                result.message = f"missing metric {probe.expect}"
            else:
                result.status = "pass"

        elif probe.kind == "metadata_uuid":
            status, body, latency = _request(url, timeout=ctx.timeout)
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "json")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            if status >= 400:
                result.message = f"HTTP {status}"
            else:
                try:
                    meta = json.loads(body)
                except json.JSONDecodeError:
                    result.message = "invalid JSON"
                else:
                    sid = str(meta.get("server_id", ""))
                    if UUID_RE.match(sid):
                        result.status = "pass"
                        ctx.scrape_cache[f"{svc.id}/metadata"] = meta
                    else:
                        result.message = "server_id missing or not UUID"

        elif probe.kind == "json_snapshot":
            status, body, latency = _request(url, timeout=ctx.timeout)
            result.latency_ms = latency
            result.body_preview = body[:500]
            fname = probe.path.strip("/").replace("/", "_") or "snapshot"
            ev = f"evidence/{fname}.json"
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            if status >= 400:
                result.message = f"HTTP {status}"
            elif probe.expect_nonempty:
                try:
                    payload = json.loads(body)
                except json.JSONDecodeError:
                    result.message = "invalid JSON"
                else:
                    key = probe.expect_nonempty
                    val = payload.get(key) if isinstance(payload, dict) else None
                    if isinstance(val, list) and len(val) > 0:
                        result.status = "pass"
                    elif isinstance(val, dict) and len(val) > 0:
                        result.status = "pass"
                    else:
                        result.message = f"{key} empty or missing"
            else:
                result.status = "pass"
            ctx.scrape_cache[f"{svc.id}{probe.path}"] = body

        elif probe.kind == "services_expect":
            if services_json is None:
                status, body, latency = _request(
                    _full_url(base, "/services"), timeout=ctx.timeout
                )
                result.latency_ms = latency
                try:
                    services_json = json.loads(body)
                except json.JSONDecodeError:
                    result.message = "invalid /services JSON"
                    return result
            write_json(
                ctx.run_root / "evidence" / "services.json",
                services_json,
            )
            result.evidence = "evidence/services.json"
            expected = svc.expect_services or []
            names = {
                s.get("name", "")
                for s in services_json.get("services", [])
                if isinstance(s, dict)
            }
            missing = [n for n in expected if n not in names]
            if missing:
                result.message = f"missing services: {', '.join(missing)}"
            else:
                result.status = "pass"

        elif probe.kind == "json_error":
            status, body, latency = _chat_request(
                base,
                probe.path,
                model=probe.model or "__m2_invalid_model__",
                stream=False,
                timeout=ctx.timeout,
            )
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "json")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                payload = None
            if status >= 400 and isinstance(payload, dict) and payload.get("error"):
                result.status = "pass"
            else:
                result.message = "expected HTTP error with JSON error object"

        elif probe.kind == "sse_stream":
            status, body, latency = _chat_request(
                base,
                probe.path,
                model=probe.model or "9g_8b_thinking",
                stream=True,
                timeout=max(ctx.timeout, 120.0),
            )
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "sse")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            if status < 400 and "data:" in body and "[DONE]" in body:
                result.status = "pass"
            else:
                result.message = "expected SSE data chunks and [DONE]"

        elif probe.kind == "token_usage":
            status, body, latency = _chat_request(
                base,
                probe.path,
                model=probe.model or "9g_8b_thinking",
                stream=False,
                timeout=max(ctx.timeout, 120.0),
            )
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "json")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            try:
                payload = json.loads(body)
                usage = payload.get("usage", {})
            except json.JSONDecodeError:
                usage = {}
            if status < 400 and all(
                isinstance(usage.get(key), int)
                for key in ("prompt_tokens", "completion_tokens", "total_tokens")
            ):
                result.status = "pass"
            else:
                result.message = "usage.prompt_tokens/completion_tokens/total_tokens missing"

        elif probe.kind == "model_match":
            status, body, latency = _request(
                _full_url(base, probe.path), timeout=ctx.timeout
            )
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "json")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            expected = probe.model
            try:
                payload = json.loads(body)
                models = payload.get("data", payload.get("models", []))
                ids = {
                    str(item.get("id"))
                    for item in models
                    if isinstance(item, dict) and item.get("id")
                }
            except json.JSONDecodeError:
                ids = set()
            if status < 400 and expected and expected in ids:
                result.status = "pass"
            else:
                result.message = f"model {expected!r} missing from model listing"

        elif probe.kind == "deadline":
            deadline = probe.deadline_seconds or ctx.timeout
            status, body, latency = _request(url, timeout=deadline)
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "txt")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            if status < 400 and latency <= int(deadline * 1000):
                result.status = "pass"
            else:
                result.message = f"request exceeded {deadline:.3f}s deadline or returned HTTP {status}"

        elif probe.kind == "cancellation":
            status, body, latency = _cancel_stream(
                url,
                model=probe.model or "9g_8b_thinking",
                timeout=max(ctx.timeout, 10.0),
            )
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "sse")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            if status < 400 and body:
                result.status = "pass"
            else:
                result.message = "stream did not yield bytes before client cancellation"

        elif probe.kind == "chat_smoke":
            models: list[str] = []
            if probe.model:
                models = [probe.model]
            elif probe.models_from:
                cache_key = f"{svc.id}{probe.models_from}"
                body = ctx.scrape_cache.get(cache_key)
                if body is None:
                    _, body, _ = _request(
                        _full_url(base, probe.models_from), timeout=ctx.timeout
                    )
                try:
                    payload = json.loads(body)
                    data = payload.get("data", payload.get("models", []))
                    for item in data:
                        if isinstance(item, dict) and item.get("id"):
                            mid = str(item["id"])
                            if not mid.startswith("modelperm-"):
                                models.append(mid)
                except json.JSONDecodeError:
                    pass
            if not models:
                models = ["9g_8b_thinking"]
            model = models[0]
            req_body = json.dumps(
                {
                    "model": model,
                    "messages": [{"role": "user", "content": "Hello"}],
                    "stream": False,
                    "max_tokens": 32,
                }
            ).encode("utf-8")
            status, body, latency = _request(
                _full_url(base, probe.path),
                method=probe.method or "POST",
                body=req_body,
                headers={"Content-Type": "application/json"},
                timeout=max(ctx.timeout, 120.0),
            )
            result.latency_ms = latency
            result.body_preview = body[:500]
            ev = _evidence_path(ctx, svc, probe, "json")
            write_text(ctx.run_root / ev, body)
            result.evidence = ev
            if status >= 400:
                result.message = f"HTTP {status} model={model}"
            elif '"object"' in body or '"choices"' in body:
                result.status = "pass"
            else:
                result.message = f"unexpected chat response model={model}"

        else:
            result.message = f"unknown probe kind {probe.kind}"

    except urllib.error.URLError as exc:
        result.message = str(exc.reason)
    except TimeoutError:
        result.message = "timeout"
    except OSError as exc:
        result.message = str(exc)

    return result


def run_all_probes(
    services: list[ServiceSpec],
    ctx: ProbeContext,
) -> list[ProbeResult]:
    results: list[ProbeResult] = []
    passed_ids: set[str] = set()
    services_json: dict[str, Any] | None = None
    service_by_id = {svc.id: svc for svc in services}

    for svc in services:
        # Dependency-only probes inherit the endpoint of their first resolved dependency.
        if not svc.resolved_base_url:
            for dependency in svc.depends_on:
                dependency_service = service_by_id.get(dependency)
                if dependency_service and dependency_service.resolved_base_url:
                    svc.resolved_base_url = dependency_service.resolved_base_url
                    break
        if svc.depends_on and not all(d in passed_ids for d in svc.depends_on):
            for probe in svc.probes:
                results.append(
                    ProbeResult(
                        service_id=svc.id,
                        path=probe.path,
                        kind=probe.kind,
                        status="skip",
                        category=CATEGORY_BY_KIND.get(probe.kind, "endpoint_reachability"),
                        message=f"depends_on not satisfied: {svc.depends_on}",
                    )
                )
            continue

        for probe in svc.probes:
            if probe.kind == "services_expect" and services_json is None:
                for prior in results:
                    if prior.path == "/services" and prior.status == "pass":
                        try:
                            services_json = json.loads(
                                (ctx.run_root / prior.evidence).read_text(encoding="utf-8")
                            )
                        except (OSError, json.JSONDecodeError):
                            pass
            res = run_probe(svc, probe, ctx, services_json=services_json)
            if res.status == "fail" and svc.optional:
                res.status = "skip"
                res.message = f"optional service: {res.message}"
            results.append(res)
            if res.status == "pass" and probe.kind == "json_snapshot" and probe.path == "/services":
                try:
                    services_json = json.loads(
                        (ctx.run_root / res.evidence).read_text(encoding="utf-8")
                    )
                except (OSError, json.JSONDecodeError):
                    pass

        if all(r.status in ("pass", "skip") for r in results if r.service_id == svc.id):
            passed_ids.add(svc.id)

    return results
