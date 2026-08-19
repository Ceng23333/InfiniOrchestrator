# BLOCKED_LAUNCH --refactor

ITW `v2026.08.18-refactor` (InfiniCore `refactor/component-manifest` `2a83578b`, InfiniLM `refactor/adopt-modern-infini-stack` `9439ea60`) cannot launch 9g on MetaX.

Phase 1 FROM vendor BASE `1a3cbde5ff2a` with xmake seeded from `infinilm-dev-hpcc37` (`xmake v2.9.9+20250523`) and `FORCE_XMAKE_BUILD=true` failed (**rc=255**). InfiniCore on this pin is an InfiniRT / InfiniOps / InfiniCCL submodule manifest — **no** traditional `xmake.lua` / MetaX InfiniCore option set. InfiniLM `adopt-modern-infini-stack` wants `build_infini_stack.py --cuda-arch sm_80` (NVIDIA) and only instantiates `qwen3`. NVIDIA stack was not attempted.

| Field | Value |
|-------|--------|
| SOURCE_ROOT | `InfiniTensorWorktree` @ `v2026.08.18-refactor` |
| Attempted runtime-base tag | `infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-refactor-20260818` (not committed) |
| Deploy runtime-base | **unchanged** `infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-20260813` |
| Phase 1 log | `image/phase1-from-base.log` |

## Hard fail

```
[phase1] Building InfiniCore (PRD-03 HPCC flags, no --use-mc)...
$ xmake f --metax-gpu=y --aten=y --flash-attn=. --graph=y --ccl=y -y -cv
error: Invalid option: --metax-gpu=y
```

`xmake.lua` is absent at InfiniCore root, so MetaX project flags are unknown. No `_infinicore` rebuild.

Campaign LongBench for this qualifier is **skipped**.
