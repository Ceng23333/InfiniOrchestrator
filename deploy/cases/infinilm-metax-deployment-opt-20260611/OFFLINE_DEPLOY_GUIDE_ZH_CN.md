# Metax 离线友好部署指南 — infinilm-metax-deployment-opt-20260611

本文以 **零阶段（可选）+ 3 个阶段** 部署 `InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611`：

0. **（离线交付）** 从 tar 包解压源码快照、预加载基础 Docker 镜像（无内网 / 无开发 worktree 时）。
1. 从本地 `InfiniCore/InfiniLM` 源码构建部署/运行镜像（构建过程中不依赖外网）。
2. 在使用 case 自带 `.env` 的前提下，用 `docker-compose` 启动 `master` 与模型 worker。
3. 通过 `validate.sh` 验证：注册中心/路由健康性、模型聚合、经由路由的 `/v1/chat/completions`，以及 embedding `/v1/embeddings` 可用性（required）。

若目标机可直接 rsync 开发 worktree（且已安装 `rsync`），可跳过零阶段，从下文 **「路径 B — 从开发 worktree rsync」** 开始。无 `rsync` 时一律使用 **路径 A** 打包脚本。

## 目标

- 使用本地 InfiniCore + InfiniLM 源码（`prefill_profile` 分支）作为构建上下文
- 主机上已存在基础镜像：`infinilm-svc:metax-hpcc-1004_218-202602281209`
- 构建/运行过程不发生外网拉取（只使用本地 Docker layer + 本地模型挂载目录）
- Master：registry + router + 9g + Qwen3-32B paged + embeddings（[`.env.master.example`](.env.master.example)）
- Slave（主预置）：XiYanSQL-QwenCoder-32B-2504 @ TP=4（[`.env.slave.example`](.env.slave.example)，仅 `<MASTER_IP>` / `<SLAVE_IP>` 占位）

## 工作区路径

### 开发 worktree（源码参考）

monorepo 开发目录（同一 inode）：

- `/home/zenghua/workspace/deployment_202606/deployment_202606`
- `/root/zenghua/workspace/deployment_202606/deployment_202606`

下文以 `DEV_WS` 代指上述路径，仅用于 **rsync 源码快照** 或核对 SHA。

### 离线验证工作区（`WORKSPACE`）

**完整离线场景的回放与 `validate.sh` 必须在全新空白目录中进行**，不得直接在开发 worktree 里跑（避免复用已构建产物、`.env`、`bench_results/`、`.image_tag`、历史容器上下文等）。

下文 **第一阶段至第三阶段** 的 `cd "${WORKSPACE}/..."` 均指该全新目录。镜像在 Phase 1 于 `WORKSPACE` 内首次构建；验证在 Phase 3 于同一 `WORKSPACE` 的 case 目录执行。

#### 路径 A — 从 tar 包解压（离线交付，推荐无外网 / 无 DEV_WS / 无 rsync 时）

目标机**没有**开发 worktree、仅收到 U 盘 / 内网拷贝的 tar 时，用本节。典型交付物：

| 文件 | 内容 | 必需 |
|------|------|------|
| `deployment-src-<IL>-<IC>-<IO>.tar.gz` | `InfiniCore/`、`InfiniLM/`、`InfiniOrchestrator/` + 根目录 `MANIFEST` | 是 |
| `infinilm-svc-metax-hpcc-base.tar.gz` | `docker save` 的基础镜像 `infinilm-svc:metax-hpcc-1004_218-202602281209` | 是（目标机尚无该镜像时） |
| `infinilm-orchestrator-metax-<tag>.tar.gz` | 可选：源端已构建的 orchestrator 镜像（可跳过第一阶段） | 否 |

**源端打包**（在有 git 的开发机或 monorepo worktree 上执行一次）：

```bash
CASE="/opt/offline/infinilm-metax-20260622/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
STAGING="/data-aisoft/zenghua/staging/offline-src-$(date -u +%Y%m%d)"
STAGING="${STAGING}" "${CASE}/bench/pack-offline-worktree.sh"

# 预览 tar 命令与排除项（不写文件）：
# DRY_RUN=1 STAGING=/tmp/offline-pack-test "${CASE}/bench/pack-offline-worktree.sh"

# 基础镜像（约数十 GB，仅需打一次；与源码 tar 分开交付）
docker save infinilm-svc:metax-hpcc-1004_218-202602281209 \
  | gzip > "${STAGING}/infinilm-svc-metax-hpcc-base.tar.gz"

ls -lh "${STAGING}/"
```

将 `${STAGING}/deployment-src-*.tar.gz`（及可选基础镜像 tar）拷贝至目标机（U 盘、scp、站点 NFS 等）。

**打包排除项**（完整列表见 [`bench/pack-offline-excludes.txt`](bench/pack-offline-excludes.txt)）：

| 类别 | 排除路径 / 模式 | 原因 |
|------|-----------------|------|
| VCS / 构建缓存 | `**/.git`、`**/.xmake`、`**/build`、`**/__pycache__` | 体积大；目标机离线构建不需要 |
| 站点 bloat | `bench_results/`、`bisect/`、`benchmarks/`、`scripts/` | 基准结果与开发脚本非部署必需 |
| 大文件 artifact | `**/*.tar`、`**/*.tar.gz`、`**/offline-bundle-test` | 避免把历史 bundle 再打进包 |
| 运行时秘密 | `**/.env`、`**/.image_tag` | 模板 `*.example` 仍保留在包内 |

完整 worktree 可达 40+ GiB；打包后源码 tar 通常约 **100–200 MiB**。

**目标端：解压并设定 WORKSPACE**

方式 1 — helper 脚本（需先从 tar 取出脚本，或随 U 盘拷贝 `bench/unpack-offline-worktree.sh`）：

```bash
OFFLINE_ROOT="/opt/offline/infinilm-metax-20260611"
SRC_TAR="/path/to/deployment-src-ILSHA-ICSHA-IOSHA.tar.gz"
BASE_TAR="/path/to/infinilm-svc-metax-hpcc-base.tar.gz"

# 从 tar 内取出 unpack helper（仅需一次）
HELPER="$(mktemp)"
tar -xzf "${SRC_TAR}" -O \
  InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611/bench/unpack-offline-worktree.sh \
  > "${HELPER}" && chmod +x "${HELPER}"

OFFLINE_ROOT="${OFFLINE_ROOT}" SRC_TAR="${SRC_TAR}" "${HELPER}"
rm -f "${HELPER}"
export WORKSPACE="${OFFLINE_ROOT}"
set -a && source "${WORKSPACE}/MANIFEST" && set +a
```

方式 2 — 手动解压（无 helper 时）：

```bash
OFFLINE_ROOT="/opt/offline/infinilm-metax-20260611"
SRC_TAR="/path/to/deployment-src-ILSHA-ICSHA-IOSHA.tar.gz"
BASE_TAR="/path/to/infinilm-svc-metax-hpcc-base.tar.gz"

rm -rf "${OFFLINE_ROOT}" && mkdir -p "${OFFLINE_ROOT}"
tar -xzf "${SRC_TAR}" -C "${OFFLINE_ROOT}"
export WORKSPACE="${OFFLINE_ROOT}"
set -a && source "${WORKSPACE}/MANIFEST" && set +a
grep -n 'gc.collect' "${WORKSPACE}/InfiniLM/python/infinilm/modeling_utils.py"
test -f "${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611/validate.sh"
```

加载基础镜像（目标机尚无 `infinilm-svc:metax-hpcc-1004_218-202602281209` 时）：

```bash
if ! docker images | grep -q 'infinilm-svc.*metax-hpcc-1004_218-202602281209'; then
  gunzip -c "${BASE_TAR}" | docker load
fi
docker images | grep 'infinilm-svc.*metax-hpcc-1004_218-202602281209'
```

解压完成后 **从「第一阶段」继续**；构建时用 `MANIFEST` 的 `IL_SHA`/`IC_SHA`/`IO_SHA`（见第一阶段注释）。

**更新部署（仅源码刷新）**

收到新的 `deployment-src-*.tar.gz` 后，在现有 `WORKSPACE` 上覆盖解压（或解压到新目录后改 `WORKSPACE`），重新执行第一阶段 `build-image.sh`，更新 case `.env` 中的 `IMAGE_TAG`（或从 `.image_tag` 复制），再：

```bash
cd "${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
# slave 主机同理 force-recreate worker-slave-xiyan-qwencoder-8200
```

无需 rsync 增量同步；每次全量 tar 即可。

**可选 — 跳过第一阶段**（已交付预构建 orchestrator 镜像 tar 时）：

```bash
ORCH_TAR="/path/to/infini-orchestrator-metax-IL-IC-DATE.tar.gz"
gunzip -c "${ORCH_TAR}" | docker load
IMAGE_TAG="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^infini-orchestrator-metax:' | head -1)"
echo "${IMAGE_TAG}" > "${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611/.image_tag"
# 直接进入第二阶段 A
```

#### 无 rsync 环境（离线目标机）

Kylin / RHEL 最小化镜像常见仅有 `tar`、`gzip`、`docker`，**无 `rsync`**。此时：

- **推荐：** 全程使用 **路径 A** — 源端 `pack-offline-worktree.sh`，目标端 `tar -xzf` / `unpack-offline-worktree.sh`；源端与目标端均不需要 rsync。
- **第一阶段 `build-image.sh`**：若主机无 rsync，脚本自动改用 `cp -a`  staging（日志会打印 `offline fallback`）。
- **勿用** `scp -r` 整棵 worktree（会带上 `build/`、`bench_results/` 等 bloat）；始终用打包脚本的排除列表。

#### 路径 B — 从开发 worktree rsync（同机 / 有 DEV_WS 且已安装 rsync）

```bash
DEV_WS="/home/zenghua/workspace/deployment_202606/deployment_202606"   # 或 /root/zenghua/... 下同 inode
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

#### 路径 B′ — 无 rsync 同机 fallback（有 DEV_WS，无 rsync）

同机验证时，用路径 A 打包脚本代替 rsync：

```bash
DEV_WS="/opt/offline/infinilm-metax-20260622"
CASE="${DEV_WS}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
STAGING=/tmp/offline-src
WORKSPACE="/tmp/offline-deploy-verify-$(date -u +%Y%m%d)"

STAGING="${STAGING}" "${CASE}/bench/pack-offline-worktree.sh"
mkdir -p "${WORKSPACE}"
tar -xzf "${STAGING}"/deployment-src-*.tar.gz -C "${WORKSPACE}"
```

## 部署前检查

- `docker`（可加载/运行本地镜像）
- `docker-compose` **v1.x**（legacy 二进制；本 case 的 compose 文件针对 v1.x 做了兼容，**不要用** `docker compose` 插件）
- `tar` / `gzip`（路径 A 打包/解压、`docker load` 预加载基础镜像）
- `curl`（验证脚本）
- `git`（可选；路径 B rsync 时用于核对 SHA；路径 A 用 `MANIFEST` 代替）
- `rsync`（**非必需**；路径 B 同机 rsync 时需要；路径 A 与 `build-image.sh` cp fallback 均不需要）

### 端口占用

默认发布端口（本 case 实测 remap）：`8800`（router）、`18000`（registry）、`20003`（embeddings）、`8102/8200`（master workers API）、`8200`（slave XiYanSQL inference）。

部署前确认上述端口未被占用：

```bash
ss -tlnp | grep -E ':8800|:18000|:20003|:8102|:8200' || echo "default ports free"
```

**单机同时跑 master Qwen（8200）与 slave XiYanSQL（默认 8200）时**，在 `.env` 设置：

```
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301
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
| InfiniLM | `prefill_profile` | `8e8b492`（含 `gc.collect()` per-shard，XiYanSQL 必需） |

```bash
cd "${DEV_WS:-${WORKSPACE}}"
git -C InfiniCore rev-parse --short HEAD    # 应为 8c901136
git -C InfiniLM rev-parse --short HEAD      # 应为 8e8b492 或更新（含 gc patch）
grep -n 'gc.collect' InfiniLM/python/infinilm/modeling_utils.py  # 应有多处命中
```

从 **tar 解压** 的 `WORKSPACE` 无 `.git` 时，用 `MANIFEST` 中的 `IL_SHA`/`IC_SHA` 核对，并用 `grep` 代替 `git rev-parse`。

### 模型路径核对（compose 前必做）

模板 [`.env.master.example`](.env.master.example) 中的 NFS 路径在部分站点可能为空目录。启动 compose **前**确认权重可读：

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
# 读模板默认值或已有 .env
QWEN3_32B_DIR="${QWEN3_32B_DIR:-/data-aisoft/zenghua/models/Qwen3-32B}"
EMBEDDING_MODEL_DIR="${EMBEDDING_MODEL_DIR:-/data-aisoft/zenghua/models/embedding-models}"

test -f "${QWEN3_32B_DIR}/config.json" || echo "WARN: QWEN3_32B_DIR empty — set to actual path (e.g. /root/zenghua/models/Qwen3-32B)"
for d in MiniCPM-Embedding-Light MiniCPM-Reranker-Light bce-reranker-base_v1; do
  test -d "${EMBEDDING_MODEL_DIR}/${d}" || test -d "/data-aisoft/zenghua/models/${d}" || echo "WARN: missing embedding subdir ${d}"
done
```

若 `embedding-models/` 为空但三个子目录在父级 `models/` 下，将 `EMBEDDING_MODEL_DIR` 设为父目录（实测 2026-06-25：`/data-aisoft/zenghua/models`）。若 `Qwen3-32B/` 为空，改用本机实际路径后再 `docker-compose up`。见排障 **L) 模型路径为空**。

### 模型目录（宿主机只读挂载）

路径已写入 [`.env.master.example`](.env.master.example) / [`.env.slave.example`](.env.slave.example)，部署前确认目录存在：

| 变量 | 路径（站点默认） | 必需文件 |
|------|------------------|----------|
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

XiYanSQL 有 14 个 ~4.8 GB 分片。镜像内的 `/workspace/InfiniLM` 必须包含 `modeling_utils.py` 中每分片后的 `gc.collect()`（InfiniLM `8e8b492` 已包含）。这是构建时 staging（rsync 或 `cp -a` fallback）进镜像的 Python 源码补丁，**不是** pip 包，也**不是**运行时环境变量。

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

**离线目标机**请使用 `INFINI_RUNTIME_CONTAINER=__base__`（从基础镜像 staging `/root/.infini`）。`infinilm-dev-*` 仅开发机可选。重复构建可省略 `DOCKER_BUILD_NO_CACHE=1` 以加速。

**不要使用** `IMAGE_TAG=...:local`。`BUILD_TS` 为 UTC 日期（`YYYYMMDD`）；同一天重建会覆盖同名 tag，跨日重建需更新 `.env` 中的 `IMAGE_TAG`（或从 `.image_tag` 复制）。

### （可选）镜像构建后快速自检（jiuge.py）

```bash
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

## 第二阶段：双机部署（Master + Slave，推荐）

两台物理机：**Master** 跑 registry + router + 9g + Qwen3-32B + embeddings；**Slave** 仅跑 XiYanSQL @ TP=4。两台均需完成第一阶段镜像构建（或加载同一 `IMAGE_TAG` 的预构建镜像 tar）。

**仅需替换的占位符：** `<MASTER_IP>`、`<SLAVE_IP>`（各自主机 `hostname -I | awk '{print $1}'`）。

### 0) 两台主机共同变量（复制后改 IP）

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>
IMAGE_TAG=infini-orchestrator-metax:8fa8b74-b81c5860-20260625
```

### 1) Master 主机

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP=<MASTER_IP>
IMAGE_TAG=infini-orchestrator-metax:8fa8b74-b81c5860-20260625

cd "${CASE}"
cp .env.master.example .env
sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" .env

docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

Master 侧 `.env` 模板见 [`.env.master.example`](.env.master.example)（无 IP 占位符；模型路径已写死为站点 NFS 路径）。

**Master 就绪检查：**

```bash
curl -sf --noproxy "*" "http://${MASTER_IP}:18000/health"
curl -sf --noproxy "*" "http://${MASTER_IP}:8800/health"
curl -sf --noproxy "*" "http://${MASTER_IP}:8800/v1/models"
```

### 2) Slave 主机

将 case 目录 rsync 到 slave（或 tar 解压同一 `WORKSPACE`），然后：

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>
IMAGE_TAG=infini-orchestrator-metax:8fa8b74-b81c5860-20260625

cd "${CASE}"
cp .env.slave.example .env
sed -i \
  -e "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" \
  -e "s|<MASTER_IP>|${MASTER_IP}|g" \
  -e "s|<SLAVE_IP>|${SLAVE_IP}|g" \
  .env

docker-compose up -d --force-recreate worker-slave-xiyan-qwencoder-8200
```

Slave 侧 `.env` 模板见 [`.env.slave.example`](.env.slave.example)（仅含 `<MASTER_IP>` / `<SLAVE_IP>` 占位符）。

**Slave 就绪检查（在 Master 或 Slave 上执行）：**

```bash
curl -sf --noproxy "*" "http://${SLAVE_IP}:8200/v1/models"
curl -sf --noproxy "*" "http://${MASTER_IP}:18000/services" | grep slave-xiyan-qwencoder-32b
```

### 3) 双机全栈验证（在 Master 或任一可访问两台 IP 的主机）

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>

cd "${CASE}"
ROUTER_PORT=8800 EMBEDDING_PORT=20003 \
  ./validate.sh "${MASTER_IP}" "${SLAVE_IP}" xiyan
```

**通过标准：**

| 检查项 | 预期 |
|--------|------|
| Registry `/health` | OK |
| Router `/health` | OK |
| Master 服务 | `master-9g_8b_thinking`, `master-qwen3-32b-paged`, `master-embeddings` |
| Slave 服务 | `slave-xiyan-qwencoder-32b`，registry 中 `host` = `<SLAVE_IP>`，`port` = 8200 |
| 模型聚合 | `9g_8b_thinking`, `Qwen3-32B`, `XiYanSQL-QwenCoder-32B-2504` |
| Chat | 各模型 `/v1/chat/completions` HTTP 200 |
| Embeddings | `http://${MASTER_IP}:20003/v1/embeddings` 返回 `"object": "list"` |

**快速烟雾（双机）：**

```bash
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>

curl -sf --noproxy "*" "http://${MASTER_IP}:8800/health" && echo
curl -sf --noproxy "*" "http://${MASTER_IP}:8800/v1/models"
curl -sf --noproxy "*" "http://${MASTER_IP}:20003/v1/embeddings" \
  -H "Content-Type: application/json" \
  -d '{"model":"text-embedding-ada-002","input":"hello"}'
curl -sf --noproxy "*" -X POST "http://${MASTER_IP}:8800/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"XiYanSQL-QwenCoder-32B-2504","messages":[{"role":"user","content":"Write SQL to select all users where age > 18."}],"stream":false,"max_tokens":128}'
```

说明：

- `SLAVE_ADVERTISE_HOST` 必须是 **Master/router 能访问的 Slave LAN IP**（即 `<SLAVE_IP>`）。
- `SLAVE_REGISTRY_URL` / `SLAVE_ROUTER_URL` 指向 **Master**（`http://<MASTER_IP>:18000` / `:8800`）。
- XiYanSQL 使用 GPU `4,5,6,7`；Slave 主机 GPU 布局不同时改 `config/slave-xiyan-qwencoder-32b.toml`。
- 首次加载 14 个分片 + CG capture 需数分钟；见排障 **D) XiYanSQL slave 未注册 / OOM**。

---

## 第二阶段 A：Master 主机启动（单节参考）

与上文 **「1) Master 主机」** 相同。以下块在 **全新 `WORKSPACE`** 上经 2026-06-25 E2E 验证（unpack → build → validate → slave sim）。

**公共变量**（Phase 2–3 共用；Phase 1 完成后设置 `IMAGE_TAG`）：

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611   # 或 Path A 解压目录
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP="$(hostname -I | awk '{print $1}')"
IMAGE_TAG="$(cat "${CASE}/.image_tag")"          # Phase 1 写入
```

**启动 master 栈**（若端口被占用，先 `cd "${CASE}" && docker-compose down`）：

```bash
cd "${CASE}"
cp .env.master.example .env
sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" .env

# 站点路径修正（模板 NFS 路径为空时）
test -f /data-aisoft/zenghua/models/Qwen3-32B/config.json || \
  sed -i 's|^QWEN3_32B_DIR=.*|QWEN3_32B_DIR=/root/zenghua/models/Qwen3-32B|' .env
test -d /data-aisoft/zenghua/models/embedding-models/MiniCPM-Embedding-Light || \
  sed -i 's|^EMBEDDING_MODEL_DIR=.*|EMBEDDING_MODEL_DIR=/data-aisoft/zenghua/models|' .env

docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

**Worker CG 就绪等待**（`validate.sh` 前必做；Qwen TP=4 可能 30+ 分钟）：

```bash
"${CASE}/bench/wait_worker_capture.sh" infiniorch-worker-master-qwen-paged-8200-20260611 "Qwen paged"
"${CASE}/bench/wait_worker_capture.sh" infiniorch-worker-master-9g-8100-20260611 "9g"

# Embeddings：Flask warmup 约 2–5 分钟，轮询直到 20003 可用
until curl -sf --noproxy "*" "http://${MASTER_IP}:20003/v1/embeddings" \
  -H 'Content-Type: application/json' \
  -d '{"model":"text-embedding-ada-002","input":"hello"}' | grep -q '"object"'; do
  echo "waiting embeddings..."
  sleep 15
done
```

说明：

- 不要用 `.env.example` 覆盖已有 `.env`。
- Qwen3-32B 首次加载较慢（含 CG warmup），未完成 capture 时 `validate.sh` 会报 missing service — 先跑 `wait_worker_capture.sh`。
- Master GPU worker 在 compose 网络内用 Docker DNS 名注册（`BABYSITTER_HOST=worker-master-*`）。

---

## 第二阶段 B：Slave 主机启动（XiYanSQL 主预置）

与上文 **「2) Slave 主机」** 相同；完整 copy-paste 见双机部署节。

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>
IMAGE_TAG=infini-orchestrator-metax:8fa8b74-b81c5860-20260625

cd "${CASE}"
cp .env.slave.example .env
sed -i \
  -e "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" \
  -e "s|<MASTER_IP>|${MASTER_IP}|g" \
  -e "s|<SLAVE_IP>|${SLAVE_IP}|g" \
  .env

docker-compose up -d --force-recreate worker-slave-xiyan-qwencoder-8200
```

### 单机 Slave 模拟（无分机）

在没有第二台物理机时，可在**同一主机**上模拟生产注册路径：master 仅保留 registry + router（停止 9g / Qwen GPU worker），slave 用 **LAN IP**（`SLAVE_ADVERTISE_HOST`）注册，使 router 经 `http://<LAN_IP>:8200` 访问 slave（非 Docker DNS）。

**前提：**

- `XIYAN_QWENCODER_DIR` 已挂载（见 `.env`）
- GPU `4,5,6,7` 空闲（脚本会停止 `worker-master-9g-8100` 与 `worker-master-qwen-paged-8200`）
- `worker-master-embeddings-20002` 保持运行（供 `validate.sh` embedding 步骤）
- 可选：复制 [`.env.slave-sim.example`](.env.slave-sim.example) 为 `.env.slave-sim` 并设置 `SLAVE_SIM_IP`
- Slave 模拟需在 `.env` 中设置 `XIYAN_QWENCODER_DIR`（与双机 slave 相同路径）

**命令：**

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

# 若 master .env 尚无 XiYan 路径（仅 master 栈时）
grep -q '^XIYAN_QWENCODER_DIR=' .env || \
  echo 'XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504' >> .env

./bench/simulate_slave_localhost.sh
./bench/validate_slave_localhost.sh

# 若 slave 已由 simulate 启动，可跳过重复启动：
SLAVE_SIM_SKIP_START=1 ./bench/validate_slave_localhost.sh
```

**通过标准：**

| 检查项 | 预期 |
|--------|------|
| Registry `/services` | `slave-xiyan-qwencoder-32b`，`host` = 本机 LAN IP，`port` = 8200 |
| Router `/models` | 含 `XiYanSQL-QwenCoder-32B-2504` |
| Chat | `SELECT 1` prompt 经 router 返回 HTTP 200 |
| Master → slave 连通 | master 容器内 `curl http://<LAN_IP>:8200/v1/models` 成功 |

结果写入 `${WORKSPACE}/bench_results/slave_sim_<timestamp>/summary.md`（与 case 同级的 monorepo `bench_results/`）。

**恢复 master 全栈：**

```bash
docker-compose stop worker-slave-xiyan-qwencoder-8200   # 释放 8200 端口
docker-compose up -d worker-master-9g-8100 worker-master-qwen-paged-8200
```

**故障排查：**

- Router 无法访问 LAN IP：尝试 docker bridge 网关 `172.28.0.1`（见 compose `subnet: 172.28.0.0/16`），或检查防火墙
- XiYan CG capture 慢（14 分片、TP=4）：默认 `CAPTURE_TIMEOUT_SEC=7200`；超时查看 slave babysitter 日志
- 若需保留 master Qwen 占用 8200：在 `.env` 设置 `SLAVE_XIYAN_API_PORT=8300`（注册端口仍为容器内 8200）

### （可选）FLA slave 预置（bisect 用）

```bash
docker-compose up -d --force-recreate worker-slave-fla-9g-8100 worker-slave-fla-qwen-8200
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>
./validate.sh "${MASTER_IP}" "${SLAVE_IP}" fla
```

---

## 第三阶段：执行验证

在 **同一 `WORKSPACE`** 的 case 目录执行（非 `DEV_WS`）。**须先完成** 第二阶段 A 的 CG / embeddings 就绪等待。

**仅 Master（无 Slave 或 GPU 不足）：**

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP="$(hostname -I | awk '{print $1}')"

cd "${CASE}"
ROUTER_PORT=8800 EMBEDDING_PORT=20003 \
  ./validate.sh "${MASTER_IP}"
```

**双机（Master + Slave）：**

```bash
WORKSPACE=/opt/offline/infinilm-metax-20260611
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>

cd "${CASE}"
ROUTER_PORT=8800 EMBEDDING_PORT=20003 \
  ./validate.sh "${MASTER_IP}" "${SLAVE_IP}" xiyan
```

单机 GPU 不足时不要启动 `worker-slave-xiyan-qwencoder-8200`；仅 Phase 2A + `./validate.sh <master_ip>` 即可验证 master 全栈。

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

### 验证阶梯（RC-7，master 全栈）

`validate.sh` 通过后，可运行完整 bench 阶梯（**不重启**已部署的 orchestrator 栈）：

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

# 等待 worker 日志出现 LLMEngine initialized + C++ capture complete 后执行
./bench/run_deploy_validation.sh
```

或分步执行：

| 步骤 | 命令 | 模型 |
|------|------|------|
| A 烟雾 | `ROUTER_PORT=8800 EMBEDDING_PORT=20003 ./validate.sh ${MASTER_IP}` | 全部 |
| B 前缀缓存 | `./bench/test_prefix_cache.sh http://localhost:8800 Qwen3-32B` | Qwen |
| C 吞吐 | `MODEL=9g_8b_thinking ./bench/run_deploy_throughput.sh` | 9g |
| C 吞吐 | `MODEL=Qwen3-32B ./bench/run_deploy_throughput.sh` | Qwen |
| D C-Eval | `ROUTER_URL=http://localhost:8800 MODELS=9g_8b_thinking ./bench/run_deploy_ceval.sh` | 9g |
| D C-Eval | `ROUTER_URL=http://localhost:8800 MODELS=Qwen3-32B MAX_GEN_TOKS=1024 ./bench/run_deploy_ceval.sh` | Qwen |

结果目录：`bench_results/deploy_validation_<ts>/`、`deploy_throughput_*`、`deploy_ceval_*`。

**注意：** CG 捕获仅在 worker 启动时发生一次；`INFINI_REQUEST_TIMEOUT_S=600` 仅约束推理计算时长，与启动捕获等待无关。Qwen TP=4 捕获可能需 30+ 分钟。

### 生产环境变量（TOML `[backend.env]`）

| 变量 | 9g | Qwen3-32B | XiYan slave |
|------|-----|-----------|-------------|
| `INFINI_COMPILE_MAX_SEQ` | 65536 | 40960 | 32768 |
| `INFINI_DECODE_CG_TP` | 1 | 1 | 1 |
| `INFINI_REQUEST_TIMEOUT_S` | 600 | 600 | 600 |

前缀缓存默认开启（**不设置** `INFINI_PREFILL_DISABLE_PREFIX_CACHE`）。勿设置 `INFINI_PREFILL_COMPILE` / `INFINI_PREFILL_SHARE_WEIGHTS` / `INFINI_PREFILL_CUDAGRAPH`。

### 快速烟雾

```bash
MASTER_IP=<MASTER_IP>

curl -sf --noproxy "*" "http://${MASTER_IP}:8800/health" && echo
curl -sf --noproxy "*" "http://${MASTER_IP}:8800/v1/models"
curl -sf --noproxy "*" "http://${MASTER_IP}:20003/v1/embeddings" \
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

### A) 9g worker：`invalid paged kv cache config type` / `--max-tokens` unrecognized

现象：9g babysitter 日志在 `load weights over!` 后报 `invalid paged kv cache config type`，或 `Unrecognized arguments: --max-tokens`。

原因：`--attn flash-attn` 在 C++ 侧走 paged KV 分配路径，**必须与 `--enable-paged-attn` 同时使用**；单独 static cache + flash-attn 会触发类型不匹配。case TOML 已统一为 **paged + flash-attn + graph**：`--enable-paged-attn --attn flash-attn --enable-graph`，并使用 `--max-new-tokens`（非 `--max-tokens`）。`--num-blocks`：9g **1024**；Qwen3-32B / XiYan **512**（Qwen TP=4 在 64 GiB 卡上 1024 会顶满显存，见 `ht-smi`）。

### B) `No healthy services available for model 'Qwen3-32B'`

1. `curl -sf --noproxy "*" "http://${MASTER_IP}:8800/v1/models"`
2. `curl -sf --noproxy "*" "http://${MASTER_IP}:18000/services"`
3. 查看 Qwen worker babysitter 日志（见上）
4. 重建：`docker-compose up -d --force-recreate worker-master-qwen-paged-8200`

### C) Qwen `hcGraphLaunch` / exit 134 during native CG capture

现象：权重加载完成后，native piecewise CG warmup 报 `hcGraphLaunch: hcErrorInvalidValue`，进程 exit 134，babysitter 重启循环。

处理：

1. 停止 compose，`docker-compose down`
2. 清理 stale GPU 进程（宿主机上 kill 残留 inference/python 占卡进程）
3. 仅启动 master 栈（GPU 不足时不要起 slave）：`docker-compose up -d --force-recreate master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002`
4. 等待 Qwen CG capture 完成（数分钟）后再 `ROUTER_PORT=8800 EMBEDDING_PORT=20003 ./validate.sh "${MASTER_IP}"`

### D) XiYanSQL slave 未注册 / OOM

1. 确认 `XIYAN_QWENCODER_DIR` 挂载正确（14 个 safetensors）
2. 确认 `SLAVE_ADVERTISE_HOST` 为 master 可达 IP
3. 查看 slave babysitter 日志是否有 exit 137
4. 重建：`docker-compose up -d --force-recreate worker-slave-xiyan-qwencoder-8200`

### E) Embedding 校验失败 / `validate.sh` embeddings FAIL

现象：`validate.sh` 第 5 步 FAIL，或 `curl :20003/v1/embeddings` 连接被重置。

原因：embeddings worker 仍在加载三个子模型并 **warmup**（约 2–5 分钟）；或 `EMBEDDING_MODEL_DIR` 指向空的 `embedding-models/` 导致 compose 挂载失败。

处理：

1. 确认子目录存在（见 **模型路径核对**）；若子目录在父级 `models/` 下，设 `EMBEDDING_MODEL_DIR=/data-aisoft/zenghua/models`
2. 轮询直至就绪：
   ```bash
   until curl -sf --noproxy "*" "http://${MASTER_IP}:20003/v1/embeddings" \
     -H 'Content-Type: application/json' \
     -d '{"model":"text-embedding-ada-002","input":"hello"}' | grep -q '"object"'; do sleep 15; done
   ```
3. `docker-compose up -d --force-recreate worker-master-embeddings-20002`
4. `docker exec infiniorch-worker-master-embeddings-20002-20260611 bash -lc 'tail -40 $(ls -t /app/logs/babysitter_*.log | head -1)'`

### F) docker-compose 兼容性

- 使用 `docker-compose`（v1.x legacy），不要用 `docker compose` 插件。
- compose 文件 `version: "2.4"` 针对 v1.x 调优。

### G) 构建拉取镜像 / staging

- 确认 `infinilm-svc:metax-hpcc-1004_218-202602281209` 已在本地。
- 构建脚本 staging 使用本地 `InfiniCore/` + `InfiniLM/`：**有 rsync 时用 rsync，无 rsync 时自动 `cp -a` fallback**（日志见 `offline fallback`），不需要外网。

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

### J) Docker bridge 转发 / sysctl（容器 ↔ 宿主机 LAN IP）

与 **I) 路由表冲突** 不同：本节解决内核**不允许 bridge 与物理网卡之间转发**、或 bridge 流量未走 iptables 导致双机/单机模拟注册路径不通。

#### 适用场景

| 流量路径 | 何时需要 |
|----------|----------|
| Master **router 容器** → `http://<SLAVE_IP>:8200` | 双机 Slave 用 LAN IP 注册（`SLAVE_ADVERTISE_HOST`） |
| Slave **容器** → `http://<MASTER_IP>:18000` / `:8800` | 双机 Slave 向 Master registry/router 注册 |
| Master 容器 → 本机 LAN IP（单机 Slave 模拟） | `./bench/simulate_slave_localhost.sh` hairpin 路径 |

**不适用：** Master 栈内 worker 互访（Docker DNS `worker-master-*`）——不经过宿主机 LAN。

#### 现象

- 宿主机 `curl http://<SLAVE_IP>:8200/v1/models` **成功**，但 Master 容器内同样 curl **超时** / `No route to host`
- Slave babysitter 日志：`Connection refused` / `tcp connect error` 访问 `http://<MASTER_IP>:18000/services`
- `./validate.sh` 通过 health，但 XiYan chat 失败或 registry 无 slave 条目
-  hardened 镜像默认 `net.ipv4.ip_forward = 0`（常见于 Kylin / RHEL 加固基线）

#### 诊断（copy-paste）

```bash
MASTER_IP=<MASTER_IP>
SLAVE_IP=<SLAVE_IP>

# 1) 内核转发与 bridge netfilter
sysctl net.ipv4.ip_forward \
       net.bridge.bridge-nf-call-iptables \
       net.bridge.bridge-nf-call-ip6tables
lsmod | grep br_netfilter

# 2) 宿主机 baseline（应成功）
curl -sf --connect-timeout 5 --noproxy "*" "http://${SLAVE_IP}:8200/v1/models"
curl -sf --connect-timeout 5 --noproxy "*" "http://${MASTER_IP}:18000/health"

# 3) Master 容器 → Slave LAN IP（双机 / 单机模拟关键路径）
docker exec infiniorch-master-opt-20260611 \
  curl -sf --connect-timeout 5 --noproxy "*" "http://${SLAVE_IP}:8200/v1/models"

# 4) Slave 容器 → Master registry（双机 Slave 注册路径）
docker exec infiniorch-worker-slave-xiyan-qwencoder-8200-20260611 \
  curl -sf --connect-timeout 5 --noproxy "*" "http://${MASTER_IP}:18000/health"
```

| 步骤 2 | 步骤 3 | 步骤 4 | 可能原因 |
|--------|--------|--------|----------|
| FAIL | — | — | Slave 未启动、防火墙、错误 IP |
| OK | FAIL | — | **本节**：sysctl / iptables FORWARD |
| OK | OK | FAIL | Slave `.env` 中 `SLAVE_REGISTRY_URL` 错误或 Master 防火墙 |
| OK | OK | OK | 检查 `SLAVE_ADVERTISE_HOST`、registry 日志（非内核） |

#### 持久修复：sysctl（宿主机 root，Master 与 Slave 均需检查）

```bash
cat > /etc/sysctl.d/99-docker-bridge-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

modprobe br_netfilter
echo br_netfilter > /etc/modules-load.d/br_netfilter.conf

sysctl -p /etc/sysctl.d/99-docker-bridge-forward.conf

sysctl net.ipv4.ip_forward \
       net.bridge.bridge-nf-call-iptables \
       net.bridge.bridge-nf-call-ip6tables
lsmod | grep br_netfilter
```

重启后再次执行诊断步骤 3、4 确认。

#### 若 sysctl 已正确仍失败：iptables / firewalld

部分站点 `FORWARD` 链默认 `DROP`（如 kube-router 共存环境）：

```bash
iptables -L FORWARD -n -v | head -15
iptables -L DOCKER-USER -n -v
```

需由站点运维在 `DOCKER-USER` 或 firewalld 中放行 Docker bridge ↔ LAN 的转发；**不要**在生产环境盲目 `iptables -P FORWARD ACCEPT`。

检查 firewalld 是否拦截 published 端口：

```bash
firewall-cmd --list-ports 2>/dev/null || true
# 典型需开放：18000/tcp 8800/tcp 8200/tcp（按实际 remap 调整）
```

#### 与 I) 的关系

| 章节 | 问题类型 | 典型 `ip route get` |
|------|----------|---------------------|
| **I)** | 路由指向错误 bridge | `dev br-...` 去往 NFS/LAN |
| **J)** | 转发被禁用或 iptables 拦截 | 路由正确，但容器 curl 仍失败 |

两节可同时需要：先确认 **I)** 路由正确，再按 **J)** 检查 sysctl 与 FORWARD。

### K) 端口冲突 / 旧栈未清理

现象：`docker-compose up` 报 `port is already allocated`，或 `validate.sh` 连到旧 registry 数据。

处理：

```bash
ss -tlnp | grep -E ':8800|:18000|:20003|:8102|:8200'
cd "${CASE}" && docker-compose down
# 若在其他目录曾部署同 case，对该 WORKSPACE 也 down
docker ps --format '{{.Names}}' | grep infiniorch
```

E2E 验证前须停止所有 `infiniorch-*-opt-20260611` 容器。

### L) 模型路径为空 / compose 挂载失败

现象：`Cannot start service worker-master-embeddings-20002: chown ... embedding-models: operation not permitted`；或 Qwen worker 日志找不到权重。

原因：`.env.master.example` 中 `QWEN3_32B_DIR` / `EMBEDDING_MODEL_DIR` 指向 **空目录**（NFS 上仅有占位路径）。

处理（metax-151 实测 2026-06-25）：

```bash
# Qwen 权重在 /root/zenghua/models/Qwen3-32B
sed -i 's|^QWEN3_32B_DIR=.*|QWEN3_32B_DIR=/root/zenghua/models/Qwen3-32B|' .env

# embedding 三子目录在 models/ 父级而非 embedding-models/
sed -i 's|^EMBEDDING_MODEL_DIR=.*|EMBEDDING_MODEL_DIR=/data-aisoft/zenghua/models|' .env

docker-compose up -d --force-recreate worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

部署前用 **模型路径核对** 节的 `test -f config.json` / `test -d` 检查。

### M) cancel/disconnect 后 `sampled token count mismatch`（worker 退出）

**现象：** 9g / Qwen babysitter 日志先出现 `Request … was cancelled`，随后 `Error in step loop: sampled token count mismatch: got 1 expected 0`，`_step_loop` 退出，worker 不再响应 `/health`。

**原因：** 客户端断开、路由探活超时或 streaming 提前关闭，与 GPU forward 完成采样存在竞态。v1 row scheduler 的 `_update_requests_from_rows` 在 aborted 行上仍收到 GPU 采样 token，但旧逻辑将 `expected_tokens` 计为 0，触发 `RuntimeError` 并杀死整个 inference worker。

**处理：**

1. 升级含 cancel-fix 的镜像（InfiniLM `llm.py` 对 aborted 行丢弃 orphan sample，且 step loop 不因 recoverable mismatch 退出）。
2. 临时规避：避免对 worker 使用极短 `curl --max-time`、并发 abort 探针；路由 health check 使用独立短 prompt 或非 streaming 请求。

**复现 / 回归（完整 worktree，不在 offline src tar 内）：**

```bash
# 完整 worktree 根目录
export INFINILM_PREFILL_WORK=/path/to/deployment_worktree

# 全场景
./scripts/run_unexpected_behavior_bench.sh

# 仅 cancel 复现
SCENARIOS=cancel_mid_decode ./scripts/repro_cancel_token_mismatch.sh

# 经 router
./scripts/run_unexpected_behavior_bench.sh --via-router
```

场景说明见 [`scripts/unexpected_behavior/README.md`](../../../../scripts/unexpected_behavior/README.md)。

**日志核对：**

```bash
docker exec infiniorch-worker-master-9g-8100-20260611 bash -lc \
  'grep -E "cancelled|sampled token count mismatch|Error in step loop" \
   $(ls -t /app/logs/babysitter_*.log | head -1) | tail -20'
```

修复后应看到 `aborted by client, skipping update`，**不应**再出现 `Error in step loop`。

#### 备选（不推荐为本 case 默认）

[`InfiniLM-SVC/integration-validation`](../../../../InfiniLM-SVC/deployment/cases/integration-validation/README.md) 使用 `--network host` 可绕过 bridge NAT，在 `ip_forward=0` 时仍可工作，但需占用宿主机端口且与本 compose 默认 bridge 模式不同。**双机生产部署优先 sysctl + 正确 `.env.slave.example`，而非改 network mode。**
