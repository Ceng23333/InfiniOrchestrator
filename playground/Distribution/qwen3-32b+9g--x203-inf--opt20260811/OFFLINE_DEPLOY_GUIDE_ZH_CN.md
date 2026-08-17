# Metax 离线友好部署指南 — infinilm-metax-deployment-opt-20260811

Dynamo 风格 **InfiniLM** case：`qwen3-32b+9g--x203-inf--opt20260811`（`be_abbr=inf`）。

- 服务：**Frontend**（etcd + loadbalancer）+ **Workers**（9g + Qwen-paged + embeddings）
- **无** XiYan；旧 Master/Slave env 已弃用（见 canonical `opt20260811` 多机配方）
- **无** vLLM babysitter TOML / validate preset / vLLM bench client
- 布局：`image/` + `docker-compose/` + `cache/` + `regression/` + `k8s/`（占位）
- 镜像：Phase 1 runtime-base → Phase 2 product `IMAGE_TAG`

**同架构冷启动（空目录 → 与 InfiniTensorWorktree pin 一致）：** 见 [`COLD_START_GUIDE.md`](COLD_START_GUIDE.md)（Phase 0 克隆钉牌 + Phase 1/2 + compose + validate）。本指南侧重已有镜像/环境后的离线友好 redeploy。

## BASE_IMAGE（厂商 OS/stack，非运行时后端）

Docker ID 钉死 **`1a3cbde5ff2a`**：

```
mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64
```

标签名含 `vllm-mars`（HPCC 基座），**不是**本 case 的 LLM 运行时后端；推理走 InfiniLM SVC entrypoint。Embeddings 与 9g/Qwen 共用产品 `IMAGE_TAG`（TF5 Flask sidecar）；MiniCPM 经 TF5 shim + 数值 smoke，失败则回退 bge-m3（+ BCE rerank）。`EMBEDDING_IMAGE_TAG` 仅作紧急回滚。InfiniLM 暂无原生 embed HTTP，本 case 不并入 InfiniLM。

验收：`docker image inspect 1a3cbde5ff2a` 应解析到上述 tag。

## Phase 1 → Phase 2

```bash
CASE="…/playground/Distribution/qwen3-32b+9g--x203-inf--opt20260811"
cd "${CASE}"
./image/build-image-phase1.sh    # 校验 BASE_IMAGE_ID=1a3cbde5ff2a；写 image/.runtime_base_tag + MANIFEST + .worktree_tag
./image/phase1-smoke.sh
./image/build-image-phase2.sh    # 写 image/.image_tag
./export-bundle.sh               # 可选离线打包（不含 cache/piecewise_inductor）
```

## Compose（Frontend + Workers，同机）

```bash
cd docker-compose
cp .env.frontend.example .env
# Phase 2 完成后：IMAGE_TAG=$(cat ../image/.image_tag)
./compose.sh --profile frontend --profile workers up -d
```

默认端口（与模板一致）：router `8800`、registry `18000`、embeddings API `20002` / entrypoint `20003`、9g API `8102`、Qwen API `8200`。

模型路径（`.env.frontend.example`）：

| 变量 | 示例 |
|------|------|
| `MODEL1_DIR` | `/data-aisoft/zenghua/models/9g_8b_thinking_llama` |
| `QWEN3_32B_DIR` | `/data-aisoft/zenghua/models/Qwen3-32B` |
| `EMBEDDING_MODEL_DIR` | `/data-aisoft/zenghua/models/embedding-models` |
| `PIECEWISE_INDUCTOR_CACHE_DIR` | `../cache/piecewise_inductor` |

网络：`172.28.0.0/16`。MetaX devices：`/dev/dri`、`/dev/htcd`、`/dev/infiniband`。

## 多机 / 单机假多机

真实多机：Frontend 主机用 `.env.frontend.example` + `--profile frontend`；Worker 主机用 [`.env.workers.example`](docker-compose/.env.workers.example)（`FRONTEND_HOST` / `ADVERTISE_HOST` 填 LAN IP，勿用 `127.0.0.1`）+ `--profile workers`。

单机验证跨机路径：

```bash
cd docker-compose
./simulate_multinode_localhost.sh
./validate_multinode_localhost.sh
```

两个 compose 工程：`io-frontend` 与 `io-workers`，经 LAN IP 注册/回连。若 Frontend→worker 经 LAN 不通，检查 bridge/`ip_forward`（与旧 slave-sim 同类问题）。

## 验收

```bash
cd docker-compose
ROUTER_PORT=8800 EMBEDDING_PORT=20002 ./validate.sh localhost
```

期望 registry openai-api 服务名：`master-9g_8b_thinking-server`、`master-qwen3-32b-paged-server`、`master-embeddings-server`（compose 服务为 `worker-*`）。

### Embeddings：冒烟 vs 质量 A/B

`validate.sh` 只做 embeddings API 冒烟（快）。产品路径在 TF5 上为 **bge-m3**（MiniCPM 数值 smoke 失败后跳过）；旧 TF4 镜像 `infini-orchestrator-metax:local` 为 **MiniCPM**。跨模型换芯后向量不会 bit 级一致，质量回归比的是 **排序/偏好一致性**，不是向量相等。

```bash
cd docker-compose
./validate.sh localhost
./regression_embeddings_vs_baseline.sh
# 产物：../results/embeddings-regression-<ts>/{baseline.json,candidate.json,report.json}
# 通过条件：bge-m3 自洽 gate + pairwise agreement ≥ AGREE_THRESHOLD（默认 0.75）
```

脚本会临时在空闲 GPU（默认 `BASELINE_GPU=2`，宿主机端口 `BASELINE_PORT=21002`）拉起旧镜像 MiniCPM，与线上 `:20002` 候选对比后自动拆除；**不**并入 `validate.sh`。

## LongBench 回归

```bash
cd ..   # case root
./regression/run_longbench.sh
# LIMIT=8 ./regression/run_longbench.sh
```

对运行中的 compose router 调用 `InfiniOrchestrator/harness/scenarios/benchmark/cases/longbench_v2/scripts/run.sh`（官方 0-shot，默认 `MODEL=Qwen3-32B`）。

## 相对 20260714 的裁剪

| 保留 | 已移除 |
|------|--------|
| InfiniLM 9g / Qwen / embeddings | XiYan / `.env.slave*` / slave TOML；旧 Master/Slave 拓扑 env |
| `image/` Phase 1/2、`export-bundle.sh`、`phase1-smoke.sh` | `*-vllm.toml` 及一切 `backend_type=vllm` |
| `cache/piecewise_inductor/`、`regression/run_longbench.sh` | 旧 `bench/`、`offline-deps/`、Phase 1.5 stub、vLLM validate presets |

历史双机 XiYan（Master/Slave）说明见上游 case `…-opt20260714`（**已弃用**；新部署请用本 case 的 Frontend+Workers + `.env.workers.example`）。
