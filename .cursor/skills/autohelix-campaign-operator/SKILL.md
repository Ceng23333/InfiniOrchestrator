---
name: autohelix-campaign-operator
description: >-
  Operate deterministic InfiniLM/vLLM AutoHelix promotion campaigns from
  InfiniOrchestrator. Use to prepare, launch, resume, watch, profile, rank,
  or report a campaign; emit or validate promo-facts; diagnose acceptance;
  or restore the stable candidate after a failed source iteration. Do not use
  this skill to edit InfiniLM source or apply candidate levers.
---

# AutoHelix campaign operator

Operate the promotion control plane. **Cursor owns campaign observation,
evidence, and operator reporting.** **AutoHelix owns iteration, acceptance,
rejection, and budget.** **Codex owns one InfiniLM source lever inside its
iteration worktree.** Ship decisions remain human.

## Canonical paths

On `metax-9-sg`, prefer explicit absolute paths:

```bash
ITW_ROOT=/root/zenghua/workspace/deploy20261113/InfiniTensorWorktree
LM_ROOT="$ITW_ROOT/InfiniLM"
ORCH_ROOT=/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator
SUITE_DIR="$ITW_ROOT/artifacts/promo/suite"
```

`source /root/zenghua/workspace/deploy20261113/autohelix-env.sh` may change the
working directory to `ITW_ROOT`. Therefore always pass explicit `-p` and `-c`
when launching AutoHelix.

## Launch or resume

Use the source-edit AutoHelix project, not the parent deployment checkout:

```bash
source /root/zenghua/workspace/deploy20261113/autohelix-env.sh
autohelix run \
  -p "$LM_ROOT" \
  -c "$LM_ROOT/autohelix/source-edit.yaml" \
  -n 4 --verbose
```

Resume preserves the prior baseline and rejected iterations. Archive state only
when the campaign contract or baseline intentionally changes.

## Monitor

For Codex iterations, use the JSONL-aware watcher:

```bash
cd "$LM_ROOT"
python scripts/promo/watch_codex.py --label autohelix-source-edit
```

Do not use raw `tail -f agent.log` as the primary monitor.

## Observation and evidence

1. Confirm the stable service before a new baseline:
   `curl --noproxy '*' http://127.0.0.1:8000/health`.
2. Require a fresh unprofiled wall comparison under `$SUITE_DIR/compare.json`.
3. Treat profiler output as diagnostic only. It can rank mechanisms; it cannot
   prove promotion.
4. Preserve matched profiler artifacts, failed patches, build hashes, ranker
   output, and server failure context.
5. Use InfiniOrchestrator tools to validate/emit `promo-facts-1` when reporting:
   `"$ORCH_ROOT/harness/bin/parse-promo-facts"`.

## Acceptance and stop conditions

Read `.autohelix/history.jsonl`, not only live UI output. A source iteration is
accepted only when AutoHelix records it as accepted. Promotion requires a fresh
unprofiled primary wall ratio above `1.0`, passing TTFT/correctness guards, and
human ship approval.

Stop and restore the stable pinned candidate when any of these occurs:

- `RankWorker stopped`, sampler device assertion, or `/health=503`;
- build artifacts do not match their recorded hashes;
- a source patch changes multiple unrelated mechanisms;
- AutoHelix reaches its agent/iteration timeout without measurement;
- the agent proposes deployment-only knob switching without a source diff.

## Boundaries

Do not:

- edit `csrc/`, `python/infinilm/`, `xmake.lua`, or candidate deployment files;
- apply a source lever from the operator side;
- overwrite a frozen vLLM baseline;
- invent `WALL_DECODE_RATIO` or promote from instrumented profiling;
- edit `scripts/promo/` or `autohelix/` in either repository.

The Codex counterpart is
`../../../.codex/skills/autohelix-source-engineer/SKILL.md`.
