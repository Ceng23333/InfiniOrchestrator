"""Daily nightly review — disabled in flat compact warehouse refactor."""

from __future__ import annotations

from pathlib import Path
from typing import Any

_REMOVED = "removed in refactor"


def build_daily_review_rows(*args: Any, **kwargs: Any) -> list[dict[str, str]]:
    raise NotImplementedError(_REMOVED)


def render_summary_markdown(*args: Any, **kwargs: Any) -> str:
    raise NotImplementedError(_REMOVED)


def render_summary_index(*args: Any, **kwargs: Any) -> str:
    raise NotImplementedError(_REMOVED)


def write_summary_reports(*args: Any, **kwargs: Any) -> list[Path]:
    raise NotImplementedError(_REMOVED)


def render_daily_review_markdown(*args: Any, **kwargs: Any) -> str:
    raise NotImplementedError(_REMOVED)


def render_daily_review_platform_index(*args: Any, **kwargs: Any) -> str:
    raise NotImplementedError(_REMOVED)


def write_daily_review_reports(*args: Any, **kwargs: Any) -> list[Path]:
    raise NotImplementedError(_REMOVED)
