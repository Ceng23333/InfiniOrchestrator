---
name: source-edit-campaign-integration-index
description: >-
  Index for the split source-edit promotion skills. Prefer autohelix-campaign-operator
  for Cursor-driven observation and spec-runner control, or autohelix-source-engineer
  for Codex-driven InfiniLM source patches. This file no longer describes a
  single deployment-only lever loop or AutoHelix controller.
---

# Source-edit campaign integration index

The old performance-promotion-loop skill mixed campaign operation with
candidate source editing. The source-edit campaign integration is now split by
role:

- [Cursor: autohelix-campaign-operator](../autohelix-campaign-operator/SKILL.md)
  owns observation, profiling evidence, spec-runner launch/resume, monitoring,
  versioned-worktree provenance, and reporting.
- [Codex: autohelix-source-engineer](../../../.codex/skills/autohelix-source-engineer/SKILL.md)
  owns one InfiniLM source mechanism inside the editable scope.

Both roles preserve the ownership boundary: InfiniOrchestrator produces
deterministic evidence, the spec runner decides iteration acceptance, and
humans decide ship. Do not invoke `autohelix run`, edit InfiniLM source from
the operator role, or apply candidate levers from the operator role.
