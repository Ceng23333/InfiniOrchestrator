# Metax 离线友好部署指南 — infinilm-metax-deployment-opt-20260811

Master-only **InfiniLM** case：`qwen3-32b+9g--x203-il--opt20260811`（`be_abbr=il`）。

- 服务：master + 9g + Qwen-paged + embeddings
- **无** XiYan / slave
- **无** vLLM babysitter TOML / validate preset / vLLM bench client
- 布局：`image/` + `docker-compose/` + `cache/` + `regression/` + `k8s/`（占位）
- 镜像：Phase 1 runtime-base → Phase 2 product `IMAGE_TAG`

## BASE_IMAGE（厂商 OS/stack，非运行时后端）

Docker ID 钉死 **`1a3cbde5ff2a`**：

```
mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64
```

标签名含 `vllm-mars`（HPCC 基座），**不是**本 case 的 LLM 运行时后端；推理走 InfiniLM SVC entrypoint。`EMBEDDING_IMAGE_TAG` 可钉 MiniCPM/TF4.51 镜像，同样不是 vLLM LLM worker。

验收：`docker image inspect 1a3cbde5ff2a` 应解析到上述 tag。

## Phase 1 → Phase 2

```bash
CASE="…/playground/Distribution/qwen3-32b+9g--x203-il--opt20260811"
cd "${CASE}"
./image/build-image-phase1.sh    # 校验 BASE_IMAGE_ID=1a3cbde5ff2a；写 image/.runtime_base_tag + MANIFEST + .worktree_tag
./image/phase1-smoke.sh
./image/build-image-phase2.sh    # 写 image/.image_tag
./export-bundle.sh               # 可选离线打包（不含 cache/piecewise_inductor）
```

## Compose（master-only）

```bash
cd docker-compose
cp .env.master.example .env
# Phase 2 完成后：IMAGE_TAG=$(cat ../image/.image_tag)
docker-compose up -d master \
  worker-master-9g-8100 \
  worker-master-qwen-paged-8200 \
  worker-master-embeddings-20002
```

默认端口（与模板一致）：router `8800`、registry `18000`、embeddings `20003`、9g API `8102`、Qwen API `8200`。

模型路径（`.env.master.example`）：

| 变量 | 示例 |
|------|------|
| `MODEL1_DIR` | `/data-aisoft/zenghua/models/9g_8b_thinking_llama` |
| `QWEN3_32B_DIR` | `/data-aisoft/zenghua/models/Qwen3-32B` |
| `EMBEDDING_MODEL_DIR` | `/data-aisoft/zenghua/models/embedding-models` |
| `PIECEWISE_INDUCTOR_CACHE_DIR` | `../cache/piecewise_inductor` |

网络：`172.28.0.0/16`。MetaX devices：`/dev/dri`、`/dev/htcd`、`/dev/infiniband`。

## 验收

```bash
cd docker-compose
ROUTER_PORT=8800 EMBEDDING_PORT=20003 ./validate.sh localhost
```

期望 registry 服务：`master-9g_8b_thinking`、`master-qwen3-32b-paged`、`master-embeddings`。

## LongBench 回归

```bash
cd ..   # case root
./regression/run_longbench.sh
# LIMIT=8 ./regression/run_longbench.sh
```

对运行中的 compose router 调用 `InfiniOrchestrator/harness/deploy/run_deploy_longbench_v2.sh`（官方 0-shot，默认 `MODEL=Qwen3-32B`）。

## 相对 20260714 的裁剪

| 保留 | 已移除 |
|------|--------|
| InfiniLM 9g / Qwen / embeddings | XiYan slave compose / `.env.slave*` / slave TOML |
| `image/` Phase 1/2、`export-bundle.sh`、`phase1-smoke.sh` | `master-9g_8b_thinking-vllm.toml` 及一切 `backend_type=vllm` |
| `cache/piecewise_inductor/`、`regression/run_longbench.sh` | 旧 `bench/`、`offline-deps/`、Phase 1.5 stub、vLLM validate presets |

历史双机 XiYan 说明见上游 case `…-opt20260714`。
