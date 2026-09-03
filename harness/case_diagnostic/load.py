"""Load and validate case.toml including optional [spec] block."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

IDENTITY_FIELDS = (
    "case_id",
    "category",
    "n",
    "model_id",
    "hw_profile_id",
    "hw_abbr",
    "be_abbr",
    "worktree",
)

VALID_TOPOLOGIES = frozenset(
    {"direct", "entrypoint_wrap", "frontend_workers", "frontend_workers_etcd"}
)
VALID_ROLES = frozenset(
    {"load_balancer", "registry", "entrypoint", "inference", "etcd", "sharepool"}
)
VALID_PROBE_KINDS = frozenset(
    {
        "http_ok",
        "prometheus",
        "metadata_uuid",
        "json_snapshot",
        "chat_smoke",
        "services_expect",
        "json_error",
        "sse_stream",
        "token_usage",
        "model_match",
        "cancellation",
        "deadline",
    }
)

_ENV_PATTERN = re.compile(
    r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}"
)
_HOST_PATTERN = re.compile(r"\{host\}")


@dataclass
class ProbeSpec:
    path: str
    kind: str
    method: str = "GET"
    expect: str = ""
    expect_nonempty: str = ""
    model: str = ""
    models_from: str = ""
    deadline_seconds: float = 0.0


@dataclass
class ServiceSpec:
    id: str
    role: str
    base_url: str = ""
    optional: bool = False
    depends_on: list[str] = field(default_factory=list)
    expect_services: list[str] = field(default_factory=list)
    probes: list[ProbeSpec] = field(default_factory=list)
    resolved_base_url: str = ""


@dataclass
class CaseSpec:
    version: str
    topology: str
    host_env: str = ""
    services: list[ServiceSpec] = field(default_factory=list)


@dataclass
class CaseDocument:
    path: Path
    identity: dict[str, Any]
    spec: CaseSpec | None = None
    config_errors: list[str] = field(default_factory=list)


class ConfigurationError(Exception):
    def __init__(self, errors: list[str]) -> None:
        self.errors = errors
        super().__init("; ".join(errors))


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as fh:
        return tomllib.load(fh)


def _parse_probe(raw: dict[str, Any]) -> ProbeSpec:
    kind = str(raw.get("kind", "http_ok"))
    if kind not in VALID_PROBE_KINDS:
        raise ValueError(f"unknown probe kind: {kind}")
    return ProbeSpec(
        path=str(raw.get("path", "")),
        kind=kind,
        method=str(raw.get("method", "GET")).upper(),
        expect=str(raw.get("expect", "")),
        expect_nonempty=str(raw.get("expect_nonempty", "")),
        model=str(raw.get("model", "")),
        models_from=str(raw.get("models_from", "")),
        deadline_seconds=float(raw.get("deadline_seconds", 0.0)),
    )


def _parse_service(raw: dict[str, Any]) -> ServiceSpec:
    role = str(raw.get("role", ""))
    if role not in VALID_ROLES:
        raise ValueError(f"unknown service role: {role}")
    probes = [_parse_probe(p) for p in raw.get("probes", [])]
    return ServiceSpec(
        id=str(raw.get("id", "")),
        role=role,
        base_url=str(raw.get("base_url", "")),
        optional=bool(raw.get("optional", False)),
        depends_on=[str(x) for x in raw.get("depends_on", [])],
        expect_services=[str(x) for x in raw.get("expect_services", [])],
        probes=probes,
    )


def _parse_spec(raw: dict[str, Any] | None) -> CaseSpec | None:
    if not raw:
        return None
    topology = str(raw.get("topology", ""))
    if topology not in VALID_TOPOLOGIES:
        raise ValueError(f"unknown topology: {topology}")
    services = [_parse_service(s) for s in raw.get("services", [])]
    return CaseSpec(
        version=str(raw.get("version", "0.1")),
        topology=topology,
        host_env=str(raw.get("host_env", "")),
        services=services,
    )


def validate_identity(doc: CaseDocument) -> list[str]:
    errors: list[str] = []
    ident = doc.identity
    case_dir = doc.path.parent
    parent = case_dir.parent.name

    for key in IDENTITY_FIELDS:
        if key not in ident:
            errors.append(f"missing required field: {key}")

    case_id = str(ident.get("case_id", ""))
    if case_id and case_dir.name != case_id:
        errors.append(f"case_id '{case_id}' != directory name '{case_dir.name}'")

    category = str(ident.get("category", ""))
    if category and parent not in ("Standalone", "Distribution"):
        errors.append(f"case not under Standalone/ or Distribution/: {parent}")
    if category and category != parent:
        errors.append(f"category '{category}' != parent directory '{parent}'")

    n = ident.get("n")
    if category == "Standalone" and n is not None and int(n) != 1:
        errors.append(f"Standalone case must have n=1, got {n}")
    if category == "Distribution" and n is not None and int(n) < 2:
        errors.append(f"Distribution case must have n>=2, got {n}")

    return errors


def validate_spec(spec: CaseSpec | None) -> list[str]:
    if spec is None:
        return ["missing [spec] block"]
    errors: list[str] = []
    if not spec.version:
        errors.append("spec.version required")
    if not spec.services:
        errors.append("spec.services must not be empty")
    seen: set[str] = set()
    for svc in spec.services:
        if not svc.id:
            errors.append("service missing id")
        elif svc.id in seen:
            errors.append(f"duplicate service id: {svc.id}")
        else:
            seen.add(svc.id)
        if not svc.probes and not svc.expect_services:
            errors.append(f"service {svc.id}: probes or expect_services required")
        for dep in svc.depends_on:
            if dep not in seen and dep != svc.id:
                # depends_on may reference earlier services only at parse time;
                # full ordering checked at probe runtime.
                pass
    return errors


def interpolate_url(template: str, host: str, env: dict[str, str]) -> str:
    def env_sub(match: re.Match[str]) -> str:
        name = match.group(1)
        default = match.group(2)
        if name in env and env[name] != "":
            return env[name]
        if default is not None:
            return default
        return os.environ.get(name, "")

    out = _HOST_PATTERN.sub(host, template)
    out = _ENV_PATTERN.sub(env_sub, out)
    return out


def resolve_services(
    spec: CaseSpec, host: str, env: dict[str, str] | None = None
) -> None:
    merged = dict(os.environ)
    if env:
        merged.update(env)
    for svc in spec.services:
        if svc.base_url:
            svc.resolved_base_url = interpolate_url(
                svc.base_url, host, merged
            ).rstrip("/")


def load_case(path: Path, *, require_spec: bool = True) -> CaseDocument:
    path = path.resolve()
    raw = load_toml(path)
    identity = {k: raw[k] for k in IDENTITY_FIELDS if k in raw}
    spec_raw = raw.get("spec")
    spec_errors: list[str] = []
    spec: CaseSpec | None = None
    try:
        spec = _parse_spec(spec_raw)
    except ValueError as exc:
        spec_errors.append(str(exc))

    doc = CaseDocument(path=path, identity=identity, spec=spec)
    doc.config_errors.extend(validate_identity(doc))
    if require_spec:
        doc.config_errors.extend(spec_errors)
        doc.config_errors.extend(validate_spec(spec))
    return doc


def default_host(doc: CaseDocument, explicit: str | None = None) -> str:
    if explicit:
        return explicit
    if doc.spec and doc.spec.host_env:
        val = os.environ.get(doc.spec.host_env, "")
        if val:
            return val
    for key in ("FRONTEND_HOST", "BENCH_TARGET_HOST", "VALIDATE_HOST"):
        val = os.environ.get(key, "")
        if val:
            return val
    return "localhost"


def load_env_file(path: Path | None) -> dict[str, str]:
    if path is None or not path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip().strip('"').strip("'")
    return out
