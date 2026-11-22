---
name: autohelix-integration-index
description: >-
  Index for the split AutoHelix promotion skills. Prefer autohelix-campaign-operator
  for Cursor-driven observation and campaign control, or autohelix-source-engineer
  for Codex-driven InfiniLM source patches. This file no longer describes a
  single deployment-only lever loop.
---

# AutoHelix integration index

The old performance-promotion-loop skill mixed campaign operation with
candidate source editing. The AutoHelix integration is now split by role:

- [Cursor: autohelix-campaign-operator](../autohelix-campaign-operator/SKILL.md)
  owns observation, profiling evidence, campaign launch/resume, monitoring, and
  reporting.
- [Codex: autohelix-source-engineer](../../../.codex/skills/autohelix-source-engineer/SKILL.md)
  owns one InfiniLM source mechanism, deterministic rebuild proof, candidate
  launch, functional smoke, and notes.

Both roles preserve the AutoHelix ownership boundary: InfiniOrchestrator
produces deterministic evidence, AutoHelix decides acceptance, and humans decide
ship. Do not use this index to edit InfiniLM source or apply candidate levers.
