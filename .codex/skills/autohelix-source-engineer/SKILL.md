---
name: autohelix-source-engineer
description: >-
  Apply one safe InfiniLM source lever inside a source-edit campaign worktree.
  Use when the spec runner assigns a Mars/Qwen3 iteration, when investigating
  graph replay or sampler failures, or when turning InfiniProfiler evidence
  into a candidate patch. Do not use this skill to operate the campaign, run
  its constraints, edit InfiniOrchestrator, or promote from profiled evidence.
---

# Source-edit engineer

Work only in the current versioned InfiniLM campaign worktree. The editable
scope in `autohelix/source-edit.yaml` is the source boundary. The spec runner
owns acceptance, provenance, constraints, and budget; this skill owns one
candidate source mechanism and leaves the build/restart proof to the runner.

## Context before editing

Read, in order:

1. the rendered prompt;
2. `artifacts/worktree_version.json`;
3. `.campaign/history.jsonl`;
4. the current `promotion_backlog.json`;
5. matched artifacts from
   [InfiniProfiler](https://github.com/Ceng23333/InfiniProfiler).

Known failed approach: enabling a Qwen3-8B TP4 P64 Mars MHA graph-capture
allowlist alone passed startup but crashed the first real generation. The
sampler received logits whose device was not `kMetax`; the RankWorker stopped
and health became 503. Do not reapply that patch without fixing graph-replay
tensor device/lifetime.

Relevant source:

```text
csrc/infinicore/src/ops/mha_kvcache/mha_kvcache.cc
csrc/infinicore/src/ops/mha_kvcache/mha_kvcache_infiniops.cc
csrc/infinicore/src/graph/graph.cc
csrc/infinicore/src/ops/random_sample/random_sample_metax.cc
python/infinilm/
```

InfiniProfiler artifacts are diagnostic evidence for choosing one lever; they
do not prove acceptance or promotion.

## One-lever contract

Apply exactly one coherent source mechanism under:

```text
csrc/
python/infinilm/
xmake.lua
```

A deployment-only environment, manifest, policy, or runtime-pin change is not
an acceptable source lever. Do not edit:

```text
scripts/promo/
autohelix/
.campaign/
deployment/infinilm-prod/
```

Do not edit `artifacts/worktree_version.json`. The runner writes it at worktree
creation, after the source edit, after each constraint, and before acceptance
or rejection. A failed source candidate is committed to
`campaign/rejected/<run>-iter-<n>`, so its version remains traceable even when
the build or measurement fails.

If the evidence is insufficient to choose one safe source mechanism, stop,
write notes, and leave the tree unchanged.

## Runner-owned proof

After the agent stops, the spec runner records provenance, rebuilds and
verifies `infinicore_runtime`, `_infinicore`, and `_infinilm`, launches the
candidate, performs a real-generation smoke, observes an unprofiled wall, and
writes final provenance. Do not relabel a stale binary or claim acceptance from
agent output.

## Boundaries

Do not:

- operate or relaunch the campaign;
- edit InfiniOrchestrator;
- change multiple unrelated levers;
- overwrite the frozen vLLM comparison baseline;
- edit metrics, constraints, scope, or AutoHelix configuration;
- edit `artifacts/worktree_version.json` or accepted/rejected branches;
- ship after surpass without explicit human approval.

The Cursor counterpart is
`../../../.cursor/skills/autohelix-campaign-operator/SKILL.md`.
