"""Production vs dev tier classification from InfiniOrchestrator SHA metadata."""

from __future__ import annotations

DEPLOY_TIERS = ("production", "dev")

# Interim fallback until orchestrator images inject IO_SHA via build-image.sh.
ORCHESTRATOR_IMAGE_TAG_PREFIX = "infini-orchestrator-metax:"
ORCHESTRATOR_DEPLOYMENT_CASE_PREFIX = "infinilm-metax-deployment-opt-"


def is_orchestrator_production_row(row: dict[str, str]) -> bool:
    """True when row is from an orchestrator product deploy (io_sha or interim signals)."""
    if str(row.get("io_sha", "")).strip():
        return True
    image_tag = str(row.get("image_tag", "")).strip()
    if image_tag.startswith(ORCHESTRATOR_IMAGE_TAG_PREFIX):
        return True
    case = str(row.get("deployment_case", "")).strip()
    if case.startswith(ORCHESTRATOR_DEPLOYMENT_CASE_PREFIX):
        return True
    return False


def classify_deploy_tier(row: dict[str, str]) -> str:
    """``production`` for orchestrator stack; ``dev`` for dev-container / direct InfiniLM."""
    if is_orchestrator_production_row(row):
        return "production"
    return "dev"


def apply_deploy_tier(row: dict[str, str]) -> None:
    row["deploy_tier"] = classify_deploy_tier(row)


def backfill_deploy_tier(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    for row in rows:
        apply_deploy_tier(row)
    return rows


def filter_by_deploy_tier(rows: list[dict[str, str]], tier: str) -> list[dict[str, str]]:
    return [r for r in rows if classify_deploy_tier(r) == tier]
