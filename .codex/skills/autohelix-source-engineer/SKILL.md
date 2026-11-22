---
name: autohelix-source-engineer
description: >-
  Apply, rebuild, launch, and measure one safe InfiniLM source lever inside an
  AutoHelix iteration worktree. Use when AutoHelix assigns a source-edit
  iteration for Mars/Qwen3 serving, when investigating graph replay or sampler
  failures, or when turning InfiniProfiler evidence into a candidate patch.
  Do not use this skill to operate the campaign, edit InfiniOrchestrator, or
  promote from profiled evidence.
---

# AutoHelix source engineer

Work only in the current InfiniLM AutoHelix worktree. The full source tree is
the editability boundary. AutoHelix owns acceptance; this skill owns one
candidate source mechanism and its build/restart proof.

## Context before editing

Read, in order:

1. the rendered AutoHelix prompt;
2. `.autohelix/hints.md`;
3. `.autohelix/notes/iter-*.md`;
4. `.autohelix/observations/iter-*/`;
5. the current `promotion_backlog.json` and matched InfiniProfiler artifacts.

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
.autohelix/
deployment/infinilm-prod/
```

If the evidence is insufficient to choose one safe source mechanism, stop,
write notes, and leave the tree unchanged.

## Build and prove artifacts

Run:

```bash
bash scripts/promo/build_candidate.sh
bash scripts/promo/verify_source_rebuild.sh
```

These commands require a source diff, rebuild `infinicore_runtime`,
`_infinicore`, and `_infinilm`, and verify artifact hashes. If build caching
hides the edited source, stop and report the reproducibility problem rather
than relabeling a stale binary.

## Launch and functionally smoke

Run:

```bash
bash scripts/promo/launch_candidate.sh
```

Health alone is insufficient. Before wall measurement, make one bounded chat
completion and require HTTP 200, non-empty content, no RankWorker exception,
and continued `/health` success. If generation hangs or the RankWorker stops,
record the server context, stop, and reject the mechanism.

## Measure and record

Run:

```bash
python scripts/promo/observe_source.py
```

Then write:

```text
.autohelix/notes/iter-N.md
.autohelix/commit_summary.txt
```

The note must state the mechanism, source files, expected signal, actual
measurement, correctness result, and whether the mechanism moved. Do not claim
promotion from profiler evidence.

## Boundaries

Do not:

- operate or relaunch the campaign;
- edit InfiniOrchestrator;
- change multiple unrelated levers;
- overwrite the frozen vLLM baseline;
- edit metrics, constraints, scope, or AutoHelix configuration;
- ship after surpass without explicit human approval.

The Cursor counterpart is
`../../../.cursor/skills/autohelix-campaign-operator/SKILL.md`.
