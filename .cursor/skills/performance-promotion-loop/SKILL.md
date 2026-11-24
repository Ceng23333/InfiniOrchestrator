---
name: performance-promotion-loop
description: >-
  Index for InfiniLM vs vLLM promotion skills. Prefer autohelix-campaign-operator
  for Cursor soft-harness loops driven by AutoHelix 0.1.1 yaml (no autohelix run
  / Codex). Supporting facts/reference/scripts remain under this folder.
---

# Performance promotion loop (index)

The closed loop is no longer “AutoHelix harness + Codex agent” for Cursor
campaigns. Prefer the yaml soft-harness:

- [Cursor: autohelix-campaign-operator](../autohelix-campaign-operator/SKILL.md)
  — load AutoHelix 0.1.1 yaml; Cursor runs observe → one `top_path` lever
  (**InfiniLM source** when `graph.*` / source-scoped; not deploy knobs only) →
  hard constraints → metric gates. Do not invoke `autohelix run` or Codex.

Evidence helpers (not the controller):

- [facts.md](facts.md) — `promo-facts-1` envelope
- [reference.md](reference.md) — device-track / lever map
- [scripts/parse_promo_facts.py](scripts/parse_promo_facts.py)
- [review.md](review.md) — offline HTML review

Normative design remains
[`docs/design/performance-promotion-e2e.md`](../../../docs/design/performance-promotion-e2e.md).
Surpass / ship stays human after unprofiled primary wall ratio > 1.0.
