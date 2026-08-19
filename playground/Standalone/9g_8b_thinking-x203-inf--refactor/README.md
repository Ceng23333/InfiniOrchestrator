# Playground: 9g_8b_thinking + InfiniLM (Standalone `--refactor`)

Serve `9g_8b_thinking_llama` via InfiniLM wrapped by **InfiniEntrypoint**.

| Pin | Value |
|-----|--------|
| `case_id` | `9g_8b_thinking-x203-inf--refactor` |
| Worktree | `v2026.08.18-refactor` |
| InfiniCore | `refactor/component-manifest` `2a83578b` |
| InfiniLM | `refactor/adopt-modern-infini-stack` `9439ea60` |
| `BASE_IMAGE_ID` | `1a3cbde5ff2a` |
| Container | `9g-inf-refactor` |

This stack is documented for NVIDIA/Qwen3. If MetaX 9g launch fails, see [`BLOCKED_LAUNCH.md`](BLOCKED_LAUNCH.md) (written only on failure).

## Image

```bash
cd InfiniOrchestrator/playground/Standalone/9g_8b_thinking-x203-inf--refactor
./image/build-image.sh
```

## Launch

```bash
ln -sfn 9g_8b_thinking_llama /root/zenghua/models/9g_8b_thinking
./run-wrap.sh
```

Stop: `./stop-wrap.sh`
