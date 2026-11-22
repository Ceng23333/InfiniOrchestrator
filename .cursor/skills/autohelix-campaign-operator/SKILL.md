---
name: autohelix-campaign-operator
description: >-
  Operate deterministic InfiniLM/vLLM source-edit spec campaigns from
  InfiniOrchestrator without `autohelix run`. Use to prepare, launch, resume,
  watch, profile, rank, report, diagnose acceptance, restore a stable
  candidate, or publish a startup candidate. Do not use this skill to edit
  InfiniLM source or apply candidate levers.
---

# AutoHelix campaign operator

Operate the promotion control plane. **Cursor owns campaign observation,
evidence, and operator reporting.** **The source-edit spec owns scope,
constraints, metrics, and gates.** **The spec runner owns versioned worktrees,
provenance, iteration, acceptance, rejection, and budget.** **Codex owns one
InfiniLM source lever inside its iteration worktree.** Ship decisions remain
human.

## Canonical paths

On `metax-9-sg`, prefer explicit absolute paths:

```bash
ITW_ROOT=/root/zenghua/workspace/deploy20261113/InfiniTensorWorktree
LM_ROOT="$ITW_ROOT/InfiniLM"
ORCH_ROOT=/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator
SUITE_DIR="$ITW_ROOT/artifacts/promo/suite"
```

`source /root/zenghua/workspace/deploy20261113/autohelix-env.sh` may change the
working directory to `ITW_ROOT`. Start the runner from the campaign checkout
that owns the selected baseline branch and spec.

## Baseline terminology

The comparison baseline is frozen vLLM, normally
`$SUITE_DIR/baseline/vllm/summary.json`. Do not relabel a startup candidate as
the comparison baseline. A reproduced startup candidate can be published as a
branch/tag and recorded under `$SUITE_DIR/startup-candidate/`, while future
walls continue to divide by frozen vLLM.

## Launch or resume

Use the spec runner, not the deprecated AutoHelix controller:

```bash
cd "$LM_ROOT"
export INFINI_TENSOR_WORKTREE="$ITW_ROOT"
export SUITE_DIR="$ITW_ROOT/artifacts/promo/suite"
export PROMO_BASELINE=baseline/vllm/summary.json
python scripts/promo/run_source_spec.py \
  --spec autohelix/source-edit.yaml \
  --max-iterations 2 \
  --baseline-ref campaign/baseline/repro-primary-1.18565275 \
  --baseline-summary "$SUITE_DIR/baseline/vllm/summary.json" \
  --verbose
```

Resume only when `autohelix/source-edit.yaml` has the exact SHA-256 recorded in
`.campaign/state.json`. If the spec changes, archive or reset `.campaign`
instead of silently resuming. Never invoke `autohelix run`.

## Monitor

Use the campaign ledger and worktree manifest, not raw agent output:

```bash
cd "$LM_ROOT"
cat .campaign/state.json
tail -f .campaign/history.jsonl
cat .campaign/worktrees/iter-N/artifacts/worktree_version.json
tail -f .campaign/logs/iter-N/codex.log
```

## Versioned worktree traceability

`autohelix/source-edit.yaml` must declare `source-edit-spec-2` and require:

- `artifacts/worktree_version.json`;
- `artifacts/artifact_hashes.txt`;
- a rejected candidate commit.

The runner writes the worktree manifest at creation, after the source edit,
after constraints, and before acceptance/rejection. It records the spec hash,
run id, baseline ref/commit, parent ref, Git commit, source-scope hashes,
changed files, phase history, and artifact hashes. Accepted source candidates
are committed to `campaign/accepted/`; failed source candidates are committed
to `campaign/rejected/`. A ledger row without these links is not an acceptance
record.

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

Read `.campaign/history.jsonl` and `.campaign/state.json`, not only live agent
output. A source iteration is accepted only when the spec runner records it as
accepted with a matching manifest, artifact hashes, and commit. Promotion
requires a fresh unprofiled primary wall ratio above `1.0` against frozen
vLLM, passing TTFT/correctness guards, and human ship approval.

Stop and restore the stable pinned candidate when any of these occurs:

- `RankWorker stopped`, sampler device assertion, or `/health=503`;
- build artifacts do not match their recorded hashes;
- a source patch changes multiple unrelated mechanisms;
- the runner reaches its agent/iteration timeout without measurement;
- the worktree manifest is missing or does not match the spec hash;
- an accepted or rejected source candidate has no traceable commit;
- the agent proposes deployment-only knob switching without a source diff.

## Boundaries

Do not:

- edit `csrc/`, `python/infinilm/`, `xmake.lua`, or candidate deployment files;
- apply a source lever from the operator side;
- overwrite a frozen vLLM baseline;
- invent `WALL_DECODE_RATIO` or promote from instrumented profiling;
- edit `scripts/promo/` or `autohelix/` in the source repository;
- invoke or resume `autohelix run`.

The Codex counterpart is
`../../../.codex/skills/autohelix-source-engineer/SKILL.md`.
