"""Campaign config loader: AutoHelix-compatible protocol + promo_loop extensions."""

from __future__ import annotations

from pathlib import Path

import yaml


class CampaignError(RuntimeError):
    pass


def _require(mapping: dict, key: str, ctx: str):
    if not isinstance(mapping, dict) or key not in mapping or mapping[key] in (None, "", [], {}):
        raise CampaignError(f"{ctx}: missing required key '{key}'")
    return mapping[key]


def load_campaign(path: str | Path) -> dict:
    path = Path(path).resolve()
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        raise CampaignError(f"{path}: top level must be a mapping")

    goal = str(_require(doc, "goal", path.name)).strip()
    run = doc.get("run") or {}
    host_key = _require(run, "host", "run")
    repo = Path(str(_require(run, "repo", "run"))).expanduser().resolve()
    hosts = _require(doc, "hosts", path.name)
    if host_key not in hosts:
        raise CampaignError(f"hosts: no entry '{host_key}'")
    host = hosts[host_key]
    if isinstance(host, str):
        host = {"ssh": host}
    _require(host, "workspace", f"hosts.{host_key}")

    where_default = (doc.get("defaults") or {}).get("where", "host")
    constraints = []
    for i, c in enumerate(doc.get("constraints") or []):
        constraints.append({
            "command": str(_require(c, "command", f"constraints[{i}]")),
            "timeout": int(c.get("timeout", 600)),
            "where": c.get("where", where_default),
            "label": c.get("label") or f"constraint-{i + 1}",
        })
    apply_steps = []
    for i, c in enumerate(doc.get("apply") or []):
        apply_steps.append({
            "command": str(_require(c, "command", f"apply[{i}]")),
            "timeout": int(c.get("timeout", 900)),
            "where": c.get("where", "host"),
            "label": c.get("label") or f"apply-{i + 1}",
        })
    observables = []
    for i, o in enumerate(doc.get("observables") or []):
        observables.append({
            "command": str(_require(o, "command", f"observables[{i}]")),
            "values": {str(k): str(v) for k, v in (o.get("values") or {}).items()},
            "timeout": int(o.get("timeout", 900)),
            "where": o.get("where", where_default),
            "label": o.get("label") or f"observable-{i + 1}",
        })
    if not observables:
        raise CampaignError("observables: at least one entry required")

    gates = (doc.get("acceptance") or {}).get("metric_gates") or []
    agent = doc.get("agent") or {}
    budget = doc.get("budget") or {}
    stop = doc.get("stop") or {}
    dash = doc.get("dashboard") or {}
    editable = doc.get("editable") or (doc.get("scope") or {}).get("editable") or []

    return {
        "path": path,
        "goal": goal,
        "run": {"repo": repo, "host": host_key},
        "hosts": {host_key: host},
        "editable": [str(p) for p in editable],
        "apply": apply_steps,
        "constraints": constraints,
        "observables": observables,
        "acceptance": {
            "metric_gates": [
                {"metric": str(g["metric"]), "max_regression_pct": float(g.get("max_regression_pct", 10))}
                for g in gates
            ]
        },
        "stop": {
            "surpass_metric": stop.get("surpass_metric"),
            "surpass_threshold": float(stop.get("surpass_threshold", 1.0)),
        },
        "dashboard": {
            "publish_dir": Path(str(dash["publish_dir"])).expanduser() if dash.get("publish_dir") else None,
        },
        "agent": {
            "type": agent.get("type", "codex"),
            "command": agent.get("command"),
            "model": agent.get("model"),
            "reasoning_effort": agent.get("reasoning_effort"),
            "timeout_seconds": int(agent.get("timeout_seconds", 2700)),
            "extra_args": [str(a) for a in (agent.get("extra_args") or [])],
        },
        "budget": {"iterations": int(budget.get("iterations", 5))},
    }
