# Playground: 9g_8b_thinking + vLLM (Standalone, MetaX C550)

Serve `9g_8b_thinking` via stock **vllm-metax** amd64 wrapped by **InfiniEntrypoint** on MetaX C550 hosts (e.g. node2).

Case id: `9g_8b_thinking-c550-vllm` (`case.toml`).

## Quickstart

```bash
cd InfiniOrchestrator/playground/Standalone/9g_8b_thinking-c550-vllm

ln -sfn 9g_8b_thinking_llama /root/zenghua/models/9g_8b_thinking   # if needed
./smoke-wrap.sh
```

Or step by step:

```bash
./build-wrap-image.sh
./run-wrap.sh
export CASE_PATH=$PWD/case.toml
HOST=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 9g-vllm-c550)
InfiniOrchestrator/harness/bin/validate-case --host "$HOST" --container 9g-vllm-c550
```

Stop: `./stop-wrap.sh`

## Defaults

| Setting | Default |
|---------|---------|
| `BASE_IMAGE` | `cr.metax-tech.com/.../vllm-metax:0.17.0-maca.ai3.5.3.307-...` |
| `CONTAINER_NAME` | `9g-vllm-c550` |
| Inference | `:18180` |
| Entrypoint | `:18181` |

See [case-diagnostic-contract.md](../../../docs/design/case-diagnostic-contract.md) for the M0 `[spec]` / manifest contract.
