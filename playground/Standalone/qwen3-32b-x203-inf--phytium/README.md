# Playground: Qwen3-32B + InfiniLM (Standalone phytium / metax-9)

Serve `Qwen3-32B` via InfiniLM wrapped by **InfiniEntrypoint** (mode 1A `docker run`).

| Pin | Value |
|-----|--------|
| `case_id` | `qwen3-32b-x203-inf--phytium` |
| Host | `metax-9` (Phytium) |
| GPUs | `0,1,2,3` (TP=4) |
| Ports | API `8200` / babysitter `8201` |
| Weights | `/root/zenghua/models/Qwen3-32B` |
| `IMAGE_TAG` | `infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813` |
| Container | `qwen-inf-phytium` |

Product image is the Distribution pin from `qwen3-32b+9g--x203-inf--opt20260811`. Do **not** rebuild Phase 1/2 for this case.

## Launch

```bash
cd InfiniOrchestrator/playground/Standalone/qwen3-32b-x203-inf--phytium
# ensure gitignored pin exists (committed layout expects this on host):
echo 'infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813' > image/.image_tag
./run-wrap.sh
```

Stop: `./stop-wrap.sh`

## LongBench

```bash
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```
