# Metax 离线友好部署指南 — infinilm-metax-deployment-opt-20260611

本文以 **零阶段（可选）+ 3 个阶段** 部署 `InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611`：

0. **（离线交付）** 从 tar 包解压源码快照、预加载基础 Docker 镜像（无内网 / 无开发 worktree 时）。
1. 从本地 `InfiniCore/InfiniLM` 源码构建部署/运行镜像（构建过程中不依赖外网）；slave 分机与 master 相同，见 **第二阶段 B-pre**。
2. 在使用 case 自带 `.env` 的前提下，用 `docker-compose` 启动 `master` 与模型 worker。
3. 通过 `validate.sh` 验证：注册中心/路由健康性、模型聚合、经由路由的 `/v1/chat/completions`，以及 embedding `/v1/embeddings` 可用性（required）。

若目标机可直接 rsync 开发 worktree，可跳过零阶段，从下文 **「从开发 worktree rsync」** 开始。

## 示例配置速查

本节汇总 case 目录下的**可复制示例**（metax-152 / `192.168.163.152` 已验证）。详细步骤见后文各阶段。

### 配置文件一览

| 文件 | 用途 |
|------|------|
| `.env` | compose 插值：镜像 tag、宿主机模型路径、端口、slave 注册地址 |
| `.image_tag` | 第一阶段构建后写入，`.env` 的 `IMAGE_TAG` 应与其一致 |
| `config/master-9g_8b_thinking.toml` | 9g worker（GPU 0，:8100） |
| `config/master-qwen3-32b-paged.toml` | Qwen3-32B paged worker（GPU 4–7，:8200） |
| `config/master-embeddings.toml` | Embeddings worker（:20002） |
| `config/slave-xiyan-qwencoder-32b.toml` | XiYanSQL slave（GPU 4–7，容器 :8200；同机宿主机 remap 8300） |
| `docker-compose.yml` | 服务编排；default 网络 `172.28.0.0/16` |
| `validate.sh` | 第三阶段健康与 chat/embeddings 校验 |

### 服务与端口（默认）

| 服务 | 注册名 | 宿主机端口 | GPU | 模型 ID |
|------|--------|-----------|-----|---------|
| Registry | — | 18000 | — | — |
| Router | — | 8000 | — | — |
| 9g | `master-9g_8b_thinking` | 8100 | 0 | `9g_8b_thinking` |
| Qwen3 | `master-qwen3-32b-paged` | 8200 | 4,5,6,7 | `Qwen3-32B` |
| Embeddings | `master-embeddings` | 20002 | — | `text-embedding-ada-002` 等 |
| XiYan slave | `slave-xiyan-qwencoder-32b` | 8300（同机 remap） | 4,5,6,7 | `XiYanSQL-QwenCoder-32B-2504` |

同机跑 master Qwen 与 XiYan slave 时，XiYan 宿主机 API/babysitter 映射为 **8300/8301**（见 `.env` 中 `SLAVE_XIYAN_*`）。

### 示例 `.env` — 同机全栈（master + XiYan slave）

路径：`InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611/.env`

```bash
IMAGE_TAG=infini-orchestrator-metax:ece9948-8c901136-20260612

REGISTRY_PORT=18000
ROUTER_PORT=8000
EMBEDDING_PORT=20002
CACHE_TYPE_ROUTING_THRESHOLD=51200

# 同 compose 项目：slave 经 Docker DNS 连 master
SLAVE_REGISTRY_URL=http://master:18000
SLAVE_ROUTER_URL=http://master:8000
SLAVE_ADVERTISE_HOST=192.168.163.152

# Qwen 占 8200；XiYan slave 宿主机 remap
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301

MODEL1_DIR=/root/zenghua/models/9g_8b_thinking_llama
QWEN3_32B_DIR=/root/zenghua/models/Qwen3-32B
XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504
EMBEDDING_MODEL_DIR=/root/zenghua/models
```

### 示例 `.env` — 仅 master（Phase 2A）

与「同机全栈」使用**同一份完整 `.env`**（含 `SLAVE_*`、`XIYAN_QWENCODER_DIR`）。`docker-compose` 会解析全文件中的 slave 服务定义，缺项会告警；Phase 2A 仅**不启动** slave 容器即可。

```bash
IMAGE_TAG=infini-orchestrator-metax:ece9948-8c901136-20260612

REGISTRY_PORT=18000
ROUTER_PORT=8000
EMBEDDING_PORT=20002
CACHE_TYPE_ROUTING_THRESHOLD=51200

SLAVE_REGISTRY_URL=http://master:18000
SLAVE_ROUTER_URL=http://master:8000
SLAVE_ADVERTISE_HOST=192.168.163.152
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301

MODEL1_DIR=/root/zenghua/models/9g_8b_thinking_llama
QWEN3_32B_DIR=/root/zenghua/models/Qwen3-32B
XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504
EMBEDDING_MODEL_DIR=/root/zenghua/models
```

验证：`./validate.sh 192.168.163.152`

### 示例 `.env` — 分机 slave（master=151，slave=152）

```bash
IMAGE_TAG=infini-orchestrator-metax:ece9948-8c901136-20260612

SLAVE_REGISTRY_URL=http://192.168.163.151:18000
SLAVE_ROUTER_URL=http://192.168.163.151:8000
SLAVE_ADVERTISE_HOST=192.168.163.152

XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504
```

验证：`./validate.sh 192.168.163.151 192.168.163.152 xiyan`

### Worker TOML 关键项（PRD-03 native piecewise）

各 LLM worker 的 `config/*.toml` 中 `[backend]` 与 `[backend.env]` 已预置，一般**无需改 TOML**，只需保证 `.env` 模型路径挂载正确。

| Worker | `num-blocks` | `INFINI_COMPILE_MAX_SEQ` | `INFINI_NATIVE_CG_CAPTURE_BUCKETS` | `HPCC_VISIBLE_DEVICES` |
|--------|-------------|---------------------------|-----------------------------------|-------------------------|
| 9g | 1024 | 8192 | 4096,2048,1024,512 | 0 |
| Qwen3-32B | 1024 | 8192 | 4096,2048,1024,512 | 4,5,6,7 |
| XiYanSQL | 512 | 4096 | 4096,2048,1024,512 | 4,5,6,7 |

共性：`--enable-paged-attn --attn flash-attn --enable-graph`，`INFINI_PREFILL_NATIVE_CG=1`。

Qwen3 / XiYan 推理参数摘录（完整见 `config/*.toml`）：

```toml
# master-qwen3-32b-paged.toml — args 节选
"--model", "/models/Qwen3-32B",
"--num-blocks", "1024",
"--tp", "4",
"--enable-paged-attn", "--attn", "flash-attn", "--enable-graph",

# [backend.env] 节选
INFINI_PREFILL_NATIVE_CG = "1"
INFINI_COMPILE_MAX_SEQ = "8192"
INFINI_NATIVE_CG_CAPTURE_BUCKETS = "4096,2048,1024,512"
HPCC_VISIBLE_DEVICES = "4,5,6,7"
```

```toml
# slave-xiyan-qwencoder-32b.toml — 与 Qwen3 对齐，num-blocks=512，max_seq=4096
"--model", "/models/XiYanSQL-QwenCoder-32B-2504",
"--num-blocks", "512",
"--tp", "4",
INFINI_COMPILE_MAX_SEQ = "4096"
```

### 离线交付 `MANIFEST` 示例

tar 解压后 `WORKSPACE/MANIFEST` 内容示例：

```bash
IL_SHA=ece9948
IC_SHA=8c901136
PACK_DATE=2026-06-15T10:01:00Z
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209
```

### 快速验证命令

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

# 同机全栈
./validate.sh 192.168.163.152 192.168.163.152 xiyan

# 烟雾
curl -s --max-time 5 http://192.168.163.152:8000/health && echo
curl -s --max-time 5 http://192.168.163.152:8000/v1/models
```

---

## 目标

- 使用本地 InfiniCore + InfiniLM 源码（`prefill_profile` 分支）作为构建上下文
- 主机上已存在基础镜像：`infinilm-svc:metax-hpcc-1004_218-202602281209`
- 构建/运行过程不发生外网拉取（只使用本地 Docker layer + 本地模型挂载目录）
- Master：registry + router + 9g + Qwen3-32B paged + embeddings
- Slave（主预置）：XiYanSQL-QwenCoder-32B-2504 @ TP=4

## 工作区路径

### 开发 worktree（源码参考）

monorepo 开发目录（同一 inode）：

- `/home/zenghua/workspace/deployment_202606`
- `/root/zenghua/workspace/deployment_202606`

下文以 `DEV_WS` 代指上述路径，仅用于 **rsync 源码快照** 或核对 SHA。

### 离线验证工作区（`WORKSPACE`）

**完整离线场景的回放与 `validate.sh` 必须在全新空白目录中进行**，不得直接在开发 worktree 里跑（避免复用已构建产物、`.env`、`bench_results/`、`.image_tag`、历史容器上下文等）。

下文 **第一阶段至第三阶段** 的 `cd "${WORKSPACE}/..."` 均指该全新目录。镜像在 Phase 1 于 `WORKSPACE` 内首次构建；验证在 Phase 3 于同一 `WORKSPACE` 的 case 目录执行。

#### 路径 A — 从 tar 包解压（离线交付，推荐无外网 / 无 DEV_WS 时）

目标机**没有**开发 worktree、仅收到 U 盘 / 内网拷贝的 tar 时，用本节。典型交付物：

| 文件 | 内容 | 必需 |
|------|------|------|
| `deployment_20260611-src-<IL>-<IC>.tar.gz` | `InfiniCore/`、`InfiniLM/`、`InfiniOrchestrator/` + 根目录 `MANIFEST` | 是 |
| `infinilm-svc-metax-hpcc-base.tar.gz` | `docker save` 的基础镜像 `infinilm-svc:metax-hpcc-1004_218-202602281209` | 是（目标机尚无该镜像时） |
| `infinilm-orchestrator-metax-<tag>.tar.gz` | 可选：源端已构建的 orchestrator 镜像（可跳过第一阶段） | 否 |

**源端打包**（在有 git 的开发机上执行一次）：

```bash
DEV_WS="/home/zenghua/workspace/deployment_202606"
STAGING="/data-aisoft/zenghua/staging/offline-bundle-$(date -u +%Y%m%d)"
mkdir -p "${STAGING}"

IL_SHA="$(git -C "${DEV_WS}/InfiniLM" rev-parse --short HEAD)"
IC_SHA="$(git -C "${DEV_WS}/InfiniCore" rev-parse --short HEAD)"
SRC_TAR="${STAGING}/deployment_20260611-src-${IL_SHA}-${IC_SHA}.tar.gz"

cat > "${DEV_WS}/MANIFEST" <<EOF
IL_SHA=${IL_SHA}
IC_SHA=${IC_SHA}
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209
EOF

tar -C "${DEV_WS}" -czf "${SRC_TAR}" \
  --exclude='InfiniCore/.git' --exclude='InfiniCore/.xmake' --exclude='InfiniCore/build' \
  --exclude='InfiniLM/.git' --exclude='InfiniLM/.xmake' --exclude='InfiniLM/build' \
  --exclude='InfiniOrchestrator/.git' \
  --exclude='bench_results' --exclude='.env' --exclude='.image_tag' \
  InfiniCore InfiniLM InfiniOrchestrator MANIFEST
rm -f "${DEV_WS}/MANIFEST"

# 基础镜像（约数十 GB，仅需打一次）
docker save infinilm-svc:metax-hpcc-1004_218-202602281209 \
  | gzip > "${STAGING}/infinilm-svc-metax-hpcc-base.tar.gz"

ls -lh "${STAGING}/"
```

将 `${STAGING}/` 下 tar 拷贝至目标机（U 盘、scp、站点 NFS 等）。

**目标端：解压并设定 WORKSPACE**

```bash
OFFLINE_ROOT="/opt/offline/infinilm-metax-20260611"
SRC_TAR="/data-aisoft/zenghua/staging/offline-bundle-20260615/deployment_20260611-src-ece9948-8c901136.tar.gz"
BASE_TAR="/opt/offline/infinilm-svc-metax-hpcc-base.tar.gz"

rm -rf "${OFFLINE_ROOT}" && mkdir -p "${OFFLINE_ROOT}"
tar -xzf "${SRC_TAR}" -C "${OFFLINE_ROOT}"

WORKSPACE="${OFFLINE_ROOT}"
set -a
# shellcheck source=/dev/null
source "${WORKSPACE}/MANIFEST"
set +a
echo "WORKSPACE=${WORKSPACE} IL_SHA=${IL_SHA} IC_SHA=${IC_SHA}"

if ! docker images | grep -q 'infinilm-svc.*metax-hpcc-1004_218-202602281209'; then
  gunzip -c "${BASE_TAR}" | docker load
fi
docker images | grep 'infinilm-svc.*metax-hpcc-1004_218-202602281209'

grep -n 'gc.collect' "${WORKSPACE}/InfiniLM/python/infinilm/modeling_utils.py"
test -f "${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611/validate.sh"
```

解压完成后 **从「第一阶段」继续**；构建时用 `MANIFEST` 的 `IL_SHA`/`IC_SHA`（见第一阶段注释）。

**可选 — 跳过第一阶段**（已交付预构建 orchestrator 镜像 tar 时）：

```bash
ORCH_TAR="/opt/offline/infini-orchestrator-metax-ece9948-8c901136-20260612.tar.gz"
gunzip -c "${ORCH_TAR}" | docker load
IMAGE_TAG="infini-orchestrator-metax:ece9948-8c901136-20260612"
echo "${IMAGE_TAG}" > "${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611/.image_tag"
# 直接进入第二阶段 A
```

#### 路径 B — 从开发 worktree rsync（同机 / 有 DEV_WS 时）

```bash
DEV_WS="/home/zenghua/workspace/deployment_202606"   # 或 /root/zenghua/workspace/deployment_202606（同 inode）
WORKSPACE="/tmp/offline-deploy-verify-$(date -u +%Y%m%d)"
rm -rf "${WORKSPACE}" && mkdir -p "${WORKSPACE}"

for repo in InfiniCore InfiniLM InfiniOrchestrator; do
  rsync -a \
    --exclude='.git' --exclude='.xmake' --exclude='build' \
    --exclude='bench_results' --exclude='.env' --exclude='.image_tag' \
    "${DEV_WS}/${repo}/" "${WORKSPACE}/${repo}/"
done
```

**不要** rsync / 复制进 `WORKSPACE` 的内容：

- 开发机 `.env`、case `results/` 历史 JSON
- 预构建镜像 tag 文件 `.image_tag`
- `scripts/hpcc_env.sh`、`docker_exec_hpcc.sh` 等 dev 捷径（本指南步骤自洽，不依赖它们）
- 任何已 `docker build` 的中间层或 worktree 内 `InfiniCore/build`、`.xmake` 缓存

## 部署前检查

- `docker`（可加载/运行本地镜像）
- `docker-compose` **v1.x**（legacy 二进制；本 case 的 compose 文件针对 v1.x 做了兼容，**不要用** `docker compose` 插件）
- `git`（路径 B rsync 时用于核对 SHA；路径 A tar 解压可用 `MANIFEST` 代替）
- `curl`（验证脚本）
- `tar` / `gzip`（路径 A 解压交付包、`docker load` 预加载基础镜像）

### 端口占用

默认发布端口：`8000`（router）、`18000`（registry）、`20002`（embeddings）、`8100/8200`（master workers）、`8200`（slave XiYanSQL，与 master Qwen 冲突时需 remap）。

**远程主机注意：** 本 case 的 `docker-compose.yml` 使用**固定 `container_name`**（如 `infiniorch-master-opt-20260611`）。无论从 `/opt/offline/...`、`/tmp/offline-deploy-verify-*` 还是开发 worktree 启动，容器名与宿主机端口相同。在离线 `WORKSPACE` 里执行 `docker-compose down` **只能清理该目录 compose 记录过的容器**；若栈是从**其他目录**起的，端口仍会被 `docker-proxy` 占用。

部署前在**远程主机**执行以下清理（按顺序，直到 `ss` 无输出）：

```bash
# 1) 看谁占着 18000/8000
ss -tlnp | grep -E ':18000|:8000' || echo "ports free"
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E '18000|8000' || echo "no docker publish on 18000/8000"

# 2) 按固定容器名停掉整套 orchestrator（与启动目录无关，远程主机必跑）
docker ps -a --format '{{.Names}}' | grep '^infiniorch-' | xargs -r docker rm -f

# 3) 若仍有占用，按发布端口逐个停
for port in 18000 8000 8100 8200 8201 20002 8300 8301; do
  for cid in $(docker ps -q --filter "publish=${port}"); do
    docker rm -f "${cid}"
  done
done

# 4) 再从当前 WORKSPACE case 目录 down 一次（清理网络/孤立资源）
WORKSPACE="${WORKSPACE:-/opt/offline/infinilm-metax-20260611}"
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}" && docker-compose down 2>/dev/null || true

# 5) 确认端口已释放后再 Phase 2A
ss -tlnp | grep -E ':18000|:8000' && echo "FAIL: ports still in use — inspect step 1 output" || echo "OK: ports free"
```

**单机同时跑 master Qwen（8200）与 slave XiYanSQL（默认 8200）时**，追加端口 remap（Phase 2B 同机 `.env` 已包含，也可单独执行）：

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
grep -q '^SLAVE_XIYAN_API_PORT=' "${CASE}/.env" 2>/dev/null || cat >> "${CASE}/.env" <<EOF
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301
EOF
```

`REGISTRY_PORT` / `ROUTER_PORT` 同时控制容器内监听端口与宿主机映射；若需 remap 宿主机端口，请保持容器内仍为 `18000`/`8000`（或同步修改 compose 端口映射逻辑）。

**IPv4 路由：** 若模型或权重在 NFS（如 `/data-aisoft` → `172.22.162.46`）上，部署前确认 Docker bridge 未占用 `172.22.0.0/16`；本 case compose 已固定 `172.28.0.0/16`。若 NFS 不可达，见排障 **I) IPv4 路由表冲突**。

### 基础镜像

确认本地已存在（避免构建时拉取）：

```bash
docker images | grep 'infinilm-svc.*metax-hpcc-1004_218-202602281209'
```

若不存在，需先从 tar 预加载或从已有 registry 复制到本机。

### 源码修订（构建前核对）

| Repo | Branch | 预期 SHA |
|------|--------|----------|
| InfiniCore | `prefill_profile` | `8c901136` |
| InfiniLM | `prefill_profile` | `ece9948`（含 `gc.collect()` per-shard + Qwen2 piecewise，XiYanSQL 必需） |

```bash
cd "${DEV_WS:-${WORKSPACE}}"
git -C InfiniCore rev-parse --short HEAD    # 应为 8c901136
git -C InfiniLM rev-parse --short HEAD      # 应为 ece9948 或更新（含 gc + piecewise patch）
grep -n 'gc.collect' InfiniLM/python/infinilm/modeling_utils.py  # 应有多处命中
```

从 **tar 解压** 的 `WORKSPACE` 无 `.git` 时，用 `MANIFEST` 中的 `IL_SHA`/`IC_SHA` 核对，并用 `grep` 代替 `git rev-parse`。

### 模型目录（宿主机只读挂载）

在 `.env` 中配置以下路径，**部署前确认目录存在**：

| 变量 | 示例路径 | 必需文件 |
|------|----------|----------|
| `MODEL1_DIR` | `/data-aisoft/zenghua/models/9g_8b_thinking_llama` | `config.json` + 权重 |
| `QWEN3_32B_DIR` | `/data-aisoft/zenghua/models/Qwen3-32B` | `config.json` + 权重分片 |
| `XIYAN_QWENCODER_DIR` | `/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504` | 14 个 safetensors 分片 |
| `EMBEDDING_MODEL_DIR` | `/data-aisoft/zenghua/models/embedding-models` | 子目录见下 |

`EMBEDDING_MODEL_DIR` 下需包含：

- `MiniCPM-Embedding-Light`
- `MiniCPM-Reranker-Light`
- `bce-reranker-base_v1`

### OOM 默认行为

`InferEngine.forward()` 在 OOM-like 异常时先 `logger.error` 再以 exit code 137 退出（默认，无需额外 env）。

### XiYanSQL 特殊说明

XiYanSQL 有 14 个 ~4.8 GB 分片。镜像内的 `/workspace/InfiniLM` 必须包含 `modeling_utils.py` 中每分片后的 `gc.collect()`，且 `qwen2_for_causal_lm.hpp` 使用 `PiecewiseTextCausalLM`（InfiniLM `ece9948` 已包含）。这是构建时 rsync 进镜像的源码补丁，**不是** pip 包，也**不是**运行时环境变量。

---

## 第一阶段：从本地源码构建部署镜像

```bash
cd "${WORKSPACE}/InfiniOrchestrator/container/metax"

# SHA：有 git 时用 rev-parse；tar 解压时用 MANIFEST（路径 A）
if git -C ../../../InfiniLM rev-parse --short HEAD >/dev/null 2>&1; then
  IL_SHA="$(git -C ../../../InfiniLM rev-parse --short HEAD)"
  IC_SHA="$(git -C ../../../InfiniCore rev-parse --short HEAD)"
else
  # shellcheck source=/dev/null
  source "${WORKSPACE}/MANIFEST"
fi
BUILD_TS="$(date -u +%Y%m%d)"
IMAGE_TAG="infini-orchestrator-metax:${IL_SHA}-${IC_SHA}-${BUILD_TS}"

IMAGE_TAG="${IMAGE_TAG}" \
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209 \
INFINI_RUNTIME_CONTAINER=__base__ \
DOCKER_BUILD_NO_CACHE=1 \
./build-image.sh

echo "${IMAGE_TAG}" > ../../deploy/cases/infinilm-metax-deployment-opt-20260611/.image_tag
echo "Built: ${IMAGE_TAG}"
```

**不要使用** `IMAGE_TAG=...:local`。`BUILD_TS` 为 UTC 日期（`YYYYMMDD`）；同一天重建会覆盖同名 tag，跨日重建需更新 `.env` 中的 `IMAGE_TAG`（或从 `.image_tag` 复制）。

### （可选）镜像构建后快速自检（jiuge.py）

```bash
IMAGE_TAG="$(cat "${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611/.image_tag")"
docker run --rm --privileged --ipc=host --network=host \
  -v /data-aisoft/zenghua/models:/models:ro \
  --device /dev/dri:/dev/dri \
  --device /dev/htcd:/dev/htcd \
  --device /dev/infiniband:/dev/infiniband \
  --entrypoint /bin/bash \
  "${IMAGE_TAG}" -lc '
set -eo pipefail
REPO=/workspace
export PYTHONPATH=$REPO/InfiniLM/python:$REPO/InfiniCore/python:${PYTHONPATH:-}
export TORCH_LIB=$(python -c "import torch, os; print(os.path.join(os.path.dirname(torch.__file__), \"lib\"))")
export LD_LIBRARY_PATH=$TORCH_LIB:/root/.infini/lib:${LD_LIBRARY_PATH:-}
python $REPO/InfiniLM/examples/jiuge.py \
  --device metax \
  --model /models/Qwen3-32B \
  --tp 4 \
  --max-new-tokens 64 \
  --attn flash-attn \
  --enable-graph \
  --enable-paged-attn \
  --prompt "你好，请用一句话介绍PagedKV+Graph自检。"
'
```

---

## 第二阶段 A：Master 主机启动

```bash
WORKSPACE="${WORKSPACE:-/opt/offline/infinilm-metax-20260611}"
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

# 远程主机：先停掉所有 infiniorch-*（可能由其他目录的 compose 启动）
docker ps -a --format '{{.Names}}' | grep '^infiniorch-' | xargs -r docker rm -f
ss -tlnp | grep -E ':18000|:8000' && echo "FAIL: stop containers above before continue" || echo "ports free"
docker-compose down 2>/dev/null || true

IMAGE_TAG="$(cat .image_tag)"
cat > .env <<EOF
IMAGE_TAG=${IMAGE_TAG}
REGISTRY_PORT=18000
ROUTER_PORT=8000
EMBEDDING_PORT=20002
CACHE_TYPE_ROUTING_THRESHOLD=51200
SLAVE_REGISTRY_URL=http://master:18000
SLAVE_ROUTER_URL=http://master:8000
SLAVE_ADVERTISE_HOST=192.168.163.152
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301
MODEL1_DIR=/root/zenghua/models/9g_8b_thinking_llama
QWEN3_32B_DIR=/root/zenghua/models/Qwen3-32B
XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504
EMBEDDING_MODEL_DIR=/root/zenghua/models
EOF

docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

说明：

- 必须设置 `WORKSPACE`（tar 解压路径，如 `/opt/offline/infinilm-metax-20260611`）。
- **远程主机**：若 `ss` 在 cleanup 后仍显示 `docker-proxy` 占 18000/8000，说明还有其他目录起的 `infiniorch-*` 容器；执行 `docker ps | grep infiniorch` 后 `docker rm -f <name>`，不要只 `docker-compose down` 当前 `CASE`。
- `.env` 需包含 `SLAVE_*` 与 `XIYAN_QWENCODER_DIR`（compose 解析全文件；Phase 2A 仅不启动 slave 服务）。
- 不要用 `.env.example` 覆盖已有 `.env`。
- Qwen3-32B 首次加载较慢（含 CG warmup），`validate.sh` 早期可能看到服务尚未注册，等待后重试。
- Master GPU worker 在 compose 网络内用 Docker DNS 名注册（`BABYSITTER_HOST=worker-master-*`）。

---

## 第二阶段 B-pre：Slave 主机镜像

分机 slave（`192.168.163.152`）须与 master 使用**同一 `WORKSPACE`**（`/opt/offline/infinilm-metax-20260611`）和**同一 `IMAGE_TAG`**（`IL_SHA` ≥ `ece9948`，XiYan 须 `PiecewiseTextCausalLM`）。

在 slave 上按 master 相同流程操作即可：

1. **路径 A** — 解压 `SRC_TAR`、加载 `BASE_TAR`（slave 尚无 `WORKSPACE` 时）
2. **第一阶段** — 构建 orchestrator 镜像；或路径 A **「可选 — 跳过第一阶段」** 加载预构建 tar；或从 master `docker save` → `scp` → slave `docker load`

完成后 `${CASE}/.image_tag` 应与 master 一致，再进入第二阶段 B。

---

## 第二阶段 B：Slave 主机启动（XiYanSQL 主预置）

在 slave 主机上使用同一 case 目录（或 rsync 整个 case 目录）：

**同机 compose（master + slave 同一 `docker-compose` 项目，metax-152 示例）：**

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

IMAGE_TAG="$(cat .image_tag)"
cat > .env <<EOF
IMAGE_TAG=${IMAGE_TAG}
REGISTRY_PORT=18000
ROUTER_PORT=8000
EMBEDDING_PORT=20002
CACHE_TYPE_ROUTING_THRESHOLD=51200
SLAVE_REGISTRY_URL=http://master:18000
SLAVE_ROUTER_URL=http://master:8000
SLAVE_ADVERTISE_HOST=192.168.163.152
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301
MODEL1_DIR=/root/zenghua/models/9g_8b_thinking_llama
QWEN3_32B_DIR=/root/zenghua/models/Qwen3-32B
XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504
EMBEDDING_MODEL_DIR=/root/zenghua/models
EOF

docker-compose up -d --force-recreate worker-slave-xiyan-qwencoder-8200
```

**分机部署（slave 独立主机，master=192.168.163.151，slave=192.168.163.152）：**

先完成 **B-pre**（路径 A + 第一阶段，或加载与 master 相同镜像），再执行：

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

IMAGE_TAG="$(cat .image_tag)"
cat > .env <<EOF
IMAGE_TAG=${IMAGE_TAG}
SLAVE_REGISTRY_URL=http://192.168.163.151:18000
SLAVE_ROUTER_URL=http://192.168.163.151:8000
SLAVE_ADVERTISE_HOST=192.168.163.152
XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504
EOF

docker-compose up -d --force-recreate worker-slave-xiyan-qwencoder-8200
```

说明：

- `SLAVE_ADVERTISE_HOST` 必须是 master/router 能访问的 slave LAN IP。
- XiYanSQL 使用 GPU `4,5,6,7`（`HPCC_VISIBLE_DEVICES`）；若 slave 主机 GPU 布局不同，修改 `config/slave-xiyan-qwencoder-32b.toml` 中 `HPCC_VISIBLE_DEVICES`。
- 首次加载 14 个分片需数分钟；等待 `load weights over!` 后再验证。
- **推荐**：slave 与 master 分机部署；单机验证时 Qwen（GPU 4–7）与 XiYanSQL（GPU 4–7）会争抢设备，仅适合 compose/注册冒烟，完整 chat 验证应在 slave 主机执行。

### （可选）FLA slave 预置（bisect 用）

```bash
docker-compose up -d --force-recreate worker-slave-fla-9g-8100 worker-slave-fla-qwen-8200
./validate.sh 192.168.163.151 192.168.163.152 fla
```

---

## 第三阶段：执行验证

在 **同一 `WORKSPACE`** 的 case 目录执行（非 `DEV_WS`）：

**同机全栈（master + XiYan slave，metax-152）：**

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"
./validate.sh 192.168.163.152 192.168.163.152 xiyan
```

**分机部署（master=151，slave=152）：**

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"
./validate.sh 192.168.163.151 192.168.163.152 xiyan
```

仅验证 master（GPU 不足、单机无法同时跑 slave 时）：

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"
./validate.sh 192.168.163.151
```

单机 GPU 不足时不要启动 `worker-slave-xiyan-qwencoder-8200`；仅 Phase 2A + `./validate.sh 192.168.163.152` 即可验证 master 全栈。

### 预期结果

| 检查项 | 预期 |
|--------|------|
| Registry `/health` | OK |
| Router `/health` | OK |
| Master 服务 | `master-9g_8b_thinking`, `master-qwen3-32b-paged`, `master-embeddings` |
| Slave 服务（xiyan） | `slave-xiyan-qwencoder-32b` |
| 模型聚合 | `9g_8b_thinking`, `Qwen3-32B`, `XiYanSQL-QwenCoder-32B-2504` |
| Chat | 各模型 `/v1/chat/completions` HTTP 200 |
| Embeddings | `/v1/embeddings` 返回 `"object": "list"` |

脚本以 `exit code 0` 结束表示 PASS。

### 快速烟雾

```bash
curl -s --max-time 5 http://192.168.163.152:8000/health && echo
curl -s --max-time 5 http://192.168.163.152:8000/v1/models
curl -s --max-time 5 http://192.168.163.152:20002/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"text-embedding-ada-002","input":"hello"}'
```

---

## 排障（Troubleshooting）

### 通用：查看 worker babysitter 日志

```bash
# Qwen paged worker（8200）
docker exec infiniorch-worker-master-qwen-paged-8200-20260611 bash -lc \
  'f=$(ls -t /app/logs/babysitter_*.log | head -n1); echo "LOG=$f"; tail -n 80 "$f"'

# XiYanSQL slave（8200）
docker exec infiniorch-worker-slave-xiyan-qwencoder-8200-20260611 bash -lc \
  'f=$(ls -t /app/logs/babysitter_*.log | head -n1); echo "LOG=$f"; tail -n 80 "$f"'
```

常见日志：

- `Heartbeat failed ... 404`：registry 重启后 babysitter 会自动 re-register。
- `Failed to fetch models ... 50 attempts`：inference server 仍在加载权重，等待完成。
- XiYanSQL exit 137 在 shard 14 之前：确认镜像内 `modeling_utils.py` 含 `gc.collect()`（重建镜像）。

### 0) Phase 2A：`SLAVE_* variable is not set` 或 `Bind for 0.0.0.0:18000 failed`

**`SLAVE_REGISTRY_URL` / `SLAVE_ROUTER_URL` / `XIYAN_QWENCODER_DIR` 告警**

`docker-compose` 解析 `docker-compose.yml` 时会校验**全部**服务（含未启动的 slave）。Phase 2A 的 `.env` 须包含完整 slave 变量（见第二阶段 A 示例），或确保 compose 文件已为 slave 变量配置默认值。

**`port is already allocated`（常见 :18000，远程主机）**

`ss` 显示 `docker-proxy` 占 18000/8000，但当前 `CASE` 的 `docker-compose down` 无效——栈往往是从**另一目录**（开发 worktree、`/tmp/offline-deploy-verify-*`）启动的；固定 `container_name` 导致端口冲突。

在远程主机执行（**停整套 orchestrator，与目录无关**）：

```bash
ss -tlnp | grep -E ':18000|:8000'
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E '18000|8000'

# 停掉所有 infiniorch-* 容器
docker ps -a --format '{{.Names}}' | grep '^infiniorch-' | xargs -r docker rm -f

# 兜底：按端口
for port in 18000 8000; do
  for cid in $(docker ps -q --filter "publish=${port}"); do docker rm -f "${cid}"; done
done

ss -tlnp | grep -E ':18000|:8000' || echo "ports free — retry Phase 2A"

WORKSPACE="${WORKSPACE:-/opt/offline/infinilm-metax-20260611}"
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}" && docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

若 `WORKSPACE` 未设置，`cd "${CASE}"` 会落到错误目录；仅 `docker stop infiniorch-master-opt-20260611` 若容器由其他 compose 项目 `restart: unless-stopped` 拉起，也可能瞬间被重建——务必用 `docker rm -f` 并清掉同项目全部 worker。

### A) 9g worker：`invalid paged kv cache config type` / `--max-tokens` unrecognized

现象：9g babysitter 日志在 `load weights over!` 后报 `invalid paged kv cache config type`，或 `Unrecognized arguments: --max-tokens`。

原因：`--attn flash-attn` 在 C++ 侧走 paged KV 分配路径，**必须与 `--enable-paged-attn` 同时使用**；单独 static cache + flash-attn 会触发类型不匹配。case TOML 已统一为 **paged + flash-attn + graph**：`--enable-paged-attn --num-blocks 1024 --attn flash-attn --enable-graph`，并使用 `--max-new-tokens`（非 `--max-tokens`）。

### B) `No healthy services available for model 'Qwen3-32B'`

1. `curl -s http://192.168.163.152:8000/v1/models`
2. `curl -s http://192.168.163.152:18000/services`
3. 查看 Qwen worker babysitter 日志（见上）
4. 重建：`docker-compose up -d --force-recreate worker-master-qwen-paged-8200`

### C) Qwen `hcGraphLaunch` / exit 134 during native CG capture

现象：权重加载完成后，native piecewise CG warmup 报 `hcGraphLaunch: hcErrorInvalidValue`，进程 exit 134，babysitter 重启循环。

处理：

1. 停止 compose，`docker-compose down`
2. 清理 stale GPU 进程（宿主机上 kill 残留 inference/python 占卡进程）
3. 仅启动 master 栈（GPU 不足时不要起 slave）：`docker-compose up -d --force-recreate master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002`
4. 等待 Qwen CG capture 完成（数分钟）后再 `./validate.sh 192.168.163.152`

### D) XiYanSQL slave 未注册 / OOM

1. 确认 `XIYAN_QWENCODER_DIR` 挂载正确（14 个 safetensors）
2. 确认 `SLAVE_ADVERTISE_HOST` 为 master 可达 IP
3. 查看 slave babysitter 日志是否有 exit 137
4. 重建：`docker-compose up -d --force-recreate worker-slave-xiyan-qwencoder-8200`

### E) Embedding 校验失败

1. `docker-compose up -d --force-recreate worker-master-embeddings-20002`
2. 确认 `EMBEDDING_MODEL_DIR` 下三个子目录存在
3. `docker logs -f infiniorch-worker-master-embeddings-20002-20260611`

### F) docker-compose 兼容性

- 使用 `docker-compose`（v1.x legacy），不要用 `docker compose` 插件。
- compose 文件 `version: "2.4"` 针对 v1.x 调优。

### G) 构建拉取镜像

- 确认 `infinilm-svc:metax-hpcc-1004_218-202602281209` 已在本地。
- 构建脚本只 rsync 本地 `InfiniCore/` + `InfiniLM/`，不需要网络。

### H) 构建失败 `hcComplex.h: No such file or directory`

现象：镜像内 `xmake build` 编译 `aten_adaptor.cc` 时找不到 `hcComplex.h`。

原因：`cuComplex.h`（cu-bridge）通过 `#include "hcComplex.h"` 引用头文件，实际位于 `/opt/hpcc/include/common/hcComplex.h`。

处理：`Dockerfile.orchestrator-runtime` 已将 HPCC 头文件目录（`include/hcr`、`include/common`、`include/hcsparse`、`include/hcblas`、`include/hcsolver`）加入 `C_INCLUDE_PATH`（与 `scripts/hpcc_env.sh` 一致）。若使用旧 Dockerfile，请同步更新后重建。

### I) IPv4 路由表冲突（Docker bridge 抢占 NFS/LAN 网段）

现象：

- `docker-compose up` 后 **`/data-aisoft` 卡住**（`ls`/`stat` 超时），或模型路径在 NFS 上不可读
- `ping 172.22.162.46` 100% 丢包（站点 NFS 服务器）
- `ip route get 172.22.162.46` 显示走 **`dev br-...`**（Docker bridge），而非物理网卡
- 路由表出现类似条目：`172.22.0.0/16 dev br-<id> scope link`

原因：Docker Compose 默认 bridge 子网常为 **`172.22.0.0/16`**。若站点 NFS/LAN 地址（如 **`172.22.162.46`**）落在同一 `/16` 内，Linux 会把发往 NFS 的流量导向 **DOWN 或不可达的 Docker bridge**，而不是经物理网关（如 `192.168.163.1`）出网。

本 case 的 [`docker-compose.yml`](docker-compose.yml) 已将 default 网络固定为 **`172.28.0.0/16`**，避免与 `172.22.x.x` 冲突。但若宿主机上仍存在**旧 compose 项目**创建的 `172.22.0.0/16` bridge，或 compose 文件未含 `networks` 段，问题仍会复现。

#### 诊断

```bash
# 1) 查 NFS 实际走哪条路由
ip route get 172.22.162.46

# 2) 查是否有 172.22/16 被 Docker bridge 占用
ip -4 route show | grep -E '172\.22\.|br-'

# 3) 查 compose 项目网络子网（项目名通常为 case 目录名）
docker network ls | grep infinilm-metax-deployment-opt-20260611
docker network inspect infinilm-metax-deployment-opt-20260611_default \
  | python3 -c "import sys,json; c=json.load(sys.stdin)[0]['IPAM']['Config']; print(c)"

# 4) NFS 挂载是否 stale
timeout 3 ls /data-aisoft/zenghua || echo "NFS hang or unreachable"
```

#### 即时修复（宿主机，需 root）

将 NFS 服务器地址**显式指向物理网关**（网卡名以 `ip route` 为准，metax-152 上常为 `enp36s0f0`）：

```bash
GW=192.168.163.1          # 站点默认网关，按实际修改
DEV=enp36s0f0             # 物理网卡，ip addr 确认
NFS=172.22.162.46         # NFS 服务器 IP

# 若尚未存在 host 路由则添加（已存在会报错，可忽略）
ip route add "${NFS}" via "${GW}" dev "${DEV}" 2>/dev/null || true

# 验证
ip route get "${NFS}"
ping -c 2 -W 2 "${NFS}"

# 若 /data-aisoft 已 hung，lazy unmount 后重挂
umount -l /data-aisoft && mount /data-aisoft
timeout 5 ls /data-aisoft/zenghua
```

**注意：** 上述 `ip route add` 在**重启后失效**。长期方案见下节。

#### 根治：重建 compose 网络为 172.28/16

确认 [`docker-compose.yml`](docker-compose.yml) 含：

```yaml
networks:
  default:
    ipam:
      config:
        - subnet: 172.28.0.0/16
```

然后**删除旧网络并重建栈**（会短暂中断服务）：

```bash
cd "${CASE}"
docker-compose down
# 可选：删除残留的旧 bridge 网络（仅当 inspect 显示 172.22.0.0/16 时）
# docker network rm infinilm-metax-deployment-opt-20260611_default 2>/dev/null || true
docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002

# 确认新子网
docker network inspect infinilm-metax-deployment-opt-20260611_default \
  | grep -A2 Subnet
ip -4 route show | grep 172.28
```

#### 可选：持久 host 路由（无法改 Docker 子网时）

在 `/etc/sysconfig/network-scripts/route-${DEV}`（RHEL/CentOS/Kylin 系）或 netplan/systemd-networkd 中增加：

```
172.22.162.46/32 via 192.168.163.1 dev enp36s0f0
```

部署前仍建议优先使用 compose 内 **`172.28.0.0/16`**，避免整段 `/16` 与站点内网重叠。
