# Playground scheme

Case tree is the source of identity for harness **emit**. Warehouse column names live in `bench-warehouse/bench_warehouse/registry.py` (`CASE_META_COLUMNS`); field meanings and layout live here.

Machine-readable field list: [`case.schema.toml`](case.schema.toml).

## Layout

```text
playground/
  case.schema.toml          # field contract for case.toml → emit
  backends.md               # be_abbr catalog (vllm|sgl|inf|oai)
  Standalone/               # category; n = 1
    <case_id>/
      case.toml             # required
      README.md             # recommended
      …                     # run scripts, config, compose, …
  Distribution/             # category; n >= 2 (deploy / multi-service)
    <case_id>/
      case.toml
      …
```

- `category` in `case.toml` **must** match the parent dir (`Standalone` | `Distribution`).
- `case_id` **must** match the case directory name.
- Do not invent a second case tree under `frontend/`; packaging overlays reference a playground case id.

## Naming

- **Simple (usually Standalone):** `{model_id}-{hw_abbr}-{be_abbr}`
  e.g. `minicpm5-x203-vllm`
- **Complex (usually Distribution):** `{model_expr}--{band}[+{band}...][--{qualifier}]`
  e.g. `qwen3-32b+9g--x203-inf--opt20260811`
- Service count is expressed by category + `n` in `case.toml` (no `n{N}` prefix).

`be_abbr` values: see [`backends.md`](backends.md) (`vllm`, `sgl`, `inf`, `oai`).

`hw_profile_id` is a host **IP** (major id) or optional stable **alias** `id` from `HARDWARE_PROFILE_REPO/profiles/{vendor}-{gpu.model}.yaml`.

## `case.toml` → emit

Set `CASE_PATH` to the case’s `case.toml` before running harness emit (or set the env overrides listed in `case.schema.toml`).

| case.toml key | emit / warehouse column | notes |
|---------------|-------------------------|--------|
| `case_id` | `case_id` | = directory name |
| `category` | `case_category` | = `Standalone` or `Distribution` |
| `n` | `n` | Standalone `1`; Distribution `>= 2` |
| `model_id` | `model_id` | primary model |
| `hw_profile_id` | `hw_profile_id` | host IP or alias id; resolves `prof_*` |
| `hw_abbr` | `hw_abbr` | must match profile `abbr` |
| `be_abbr` | `be_abbr` | backend abbr; see `backends.md` |
| `worktree` | `worktree` | InfiniTensorWorktree pin tag (e.g. `v2026.08.12`); env `WORKTREE` / `ITW_TAG` |

Also recorded on the row (not from `case.toml`): `case_path` (= `CASE_PATH`).

Minimal example:

```toml
case_id = "minicpm5-x203-vllm"
category = "Standalone"
n = 1
model_id = "minicpm5"
hw_profile_id = "metax-x203-hpcc"
hw_abbr = "x203"
be_abbr = "vllm"
worktree = "v2026.08.12"
```

## Harness wiring

```bash
export CASE_PATH="${IO_ROOT}/playground/Standalone/minicpm5-x203-vllm/case.toml"
# optional: CASE_ID / CASE_CATEGORY / HW_* / BE_ABBR override toml
"${IO_ROOT}/harness/run_bench_client.sh" longbench
```

Emit implementation: `bench-warehouse/bench_warehouse/emit.py` (`_apply_case_metadata`).
