"""Period sample aggregation and percentile helpers."""

from __future__ import annotations


def percentile(values: list[float], q: float) -> float:
    """Linear-interpolation percentile; ``q`` in 0..1 or 0..100 (auto-detected)."""
    if not values:
        raise ValueError("empty values")
    pct = q if q > 1.0 else q * 100.0
    sorted_vals = sorted(values)
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * pct / 100.0
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    return sorted_vals[f] + (k - f) * (sorted_vals[c] - sorted_vals[f])


def _parse_float(val: str | None) -> float | None:
    if val is None or val == "":
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def summarize_period_samples(
    samples: list[dict[str, str]],
    *,
    histogram_cols: list[str],
    counter_cols: list[str],
    period_suffixes: tuple[str, ...] = ("_mean", "_median", "_p99"),
) -> dict[str, str]:
    """Summarize poll samples into flat period columns (mean/median/p99 + counter max)."""
    out: dict[str, str] = {}
    for col in histogram_cols:
        nums = [_parse_float(s.get(col)) for s in samples]
        values = [v for v in nums if v is not None]
        if not values:
            continue
        suffix_mean, suffix_median, suffix_p99 = period_suffixes
        out[f"{col}{suffix_mean}"] = str(sum(values) / len(values))
        out[f"{col}{suffix_median}"] = str(percentile(values, 50.0))
        out[f"{col}{suffix_p99}"] = str(percentile(values, 99.0))
    for col in counter_cols:
        nums = [_parse_float(s.get(col)) for s in samples]
        values = [v for v in nums if v is not None]
        if values:
            best = max(values)
            out[col] = str(int(best)) if best == int(best) else str(best)
    return out
