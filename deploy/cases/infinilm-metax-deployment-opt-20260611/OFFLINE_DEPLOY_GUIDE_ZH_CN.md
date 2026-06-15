# Metax 离线友好部署指南 — infinilm-metax-deployment-opt-20260611

本文以 **3 个阶段** 部署 `InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611`：

1. 从本地 `InfiniCore/InfiniLM` 源码构建部署/运行镜像（构建过程中不依赖外网）。
2. 在使用 case 自带 `.env` 的前提下，用 `docker-compose` 启动 `master` 与模型 worker。
3. 通过 `validate.sh` 验证：注册中心/路由健康性、模型聚合、经由路由的 `/v1/chat/completions`，以及 embedding `/v1/embeddings` 可用性（required）。

## 目标

- 使用本地 InfiniCore + InfiniLM 源码（`prefill_profile` 分支）作为构建上下文
- 主机上已存在基础镜像：`infinilm-svc:metax-hpcc-1004_218-202602281209`
- 构建/运行过程不发生外网拉取（只使用本地 Docker layer + 本地模型挂载目录）
- Master：registry + router + 9g + Qwen3-32B paged + embeddings
- Slave（主预置）：XiYanSQL-QwenCoder-32B-2504 @ TP=4

## 工作区路径

### 开发 worktree（源码参考）

monorepo 开发目录（同一 inode）：

- `/home/zenghua/workspace/deployment_202606/deployment_202606`
- `/root/zenghua/workspace/deployment_202606/deployment_202606`

下文以 `DEV_WS` 代指上述路径，仅用于 **rsync 源码快照** 或核对 SHA。

### 离线验证工作区（`WORKSPACE`）

**完整离线场景的回放与 `validate.sh` 必须在全新空白目录中进行**，不得直接在开发 worktree 里跑（避免复用已构建产物、`.env`、`bench_results/`、`.image_tag`、历史容器上下文等）。

准备步骤（从 `DEV_WS` 仅复制三棵源码树，不含任何构建产物）：

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

下文 **第一阶段至第三阶段** 的 `cd "${WORKSPACE}/..."` 均指该全新目录。镜像在 Phase 1 于 `WORKSPACE` 内首次构建；验证在 Phase 3 于同一 `WORKSPACE` 的 case 目录执行。

## 部署前检查

### 必需工具

- `docker`（可加载/运行本地镜像）
- `docker-compose` **v1.x**（legacy 二进制；本 case 的 compose 文件针对 v1.x 做了兼容，**不要用** `docker compose` 插件）
- `git`（用于确认源码 SHA）
- `curl`（验证脚本）

### 端口占用

默认发布端口：`8000`（router）、`18000`（registry）、`20002`（embeddings）、`8100/8200`（master workers）、`8200`（slave XiYanSQL，与 master Qwen 冲突时需 remap）。

部署前确认上述端口未被占用：

```bash
ss -tlnp | grep -E ':8000|:18000|:20002|:8100|:8200' || echo "default ports free"
```

**单机同时跑 master Qwen（8200）与 slave XiYanSQL（默认 8200）时**，在 `.env` 设置：

```
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301
```

`REGISTRY_PORT` / `ROUTER_PORT` 同时控制容器内监听端口与宿主机映射；若需 remap 宿主机端口，请保持容器内仍为 `18000`/`8000`（或同步修改 compose 端口映射逻辑）。

**IPv4 路由：** 若模型或权重在 NFS（如 `/data-aisoft` → `172.22.162.46`）上，部署前确认 Docker bridge 未占用 `172.22.0.0/16`；本 case compose 已固定 `172.28.0.0/16`。若 NFS 不可达，见排障 **I) IPv4 路由表冲突**。

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
cd "${DEV_WS}"
git -C InfiniCore rev-parse --short HEAD    # 应为 8c901136
git -C InfiniLM rev-parse --short HEAD      # 应为 8e8b492 或更新（含 gc patch）
grep -n 'gc.collect' InfiniLM/python/infinilm/modeling_utils.py  # 应有多处命中
```

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

XiYanSQL 有 14 个 ~4.8 GB 分片。镜像内的 `/workspace/InfiniLM` 必须包含 `modeling_utils.py` 中每分片后的 `gc.collect()`（InfiniLM `8e8b492` 已包含）。这是构建时 rsync 进镜像的 Python 源码补丁，**不是** pip 包，也**不是**运行时环境变量。

---

## 第一阶段：从本地源码构建部署镜像

```bash
cd "${WORKSPACE}/InfiniOrchestrator/container/metax"

IL_SHA="$(git -C ../../../InfiniLM rev-parse --short HEAD)"
IC_SHA="$(git -C ../../../InfiniCore rev-parse --short HEAD)"
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
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

cp .env.example .env
# 编辑 .env：
#   IMAGE_TAG=<从 .image_tag 复制>
#   MODEL1_DIR=...
#   QWEN3_32B_DIR=...
#   EMBEDDING_MODEL_DIR=...

docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

说明：

- 不要用 `.env.example` 覆盖已有 `.env`。
- Qwen3-32B 首次加载较慢（含 CG warmup），`validate.sh` 早期可能看到服务尚未注册，等待后重试。
- Master GPU worker 在 compose 网络内用 Docker DNS 名注册（`BABYSITTER_HOST=worker-master-*`）。

---

## 第二阶段 B：Slave 主机启动（XiYanSQL 主预置）

在 slave 主机上使用同一 case 目录（或 rsync 整个 case 目录）：

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"

# 编辑 .env（slave 侧）：
#   IMAGE_TAG=<与 master 相同>
#   XIYAN_QWENCODER_DIR=/data-aisoft/zenghua/models/XGenerationLab/XiYanSQL-QwenCoder-32B-2504
#   SLAVE_REGISTRY_URL=http://<master_ip>:18000
#   SLAVE_ROUTER_URL=http://<master_ip>:8000
#   SLAVE_ADVERTISE_HOST=<slave_ip>

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
./validate.sh <master_ip> <slave_ip> fla
```

---

## 第三阶段：执行验证

在 **同一 `WORKSPACE`** 的 case 目录执行（非 `DEV_WS`）：

```bash
CASE="${WORKSPACE}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260611"
cd "${CASE}"
./validate.sh <master_ip> <slave_ip> xiyan
```

仅验证 master（GPU 不足、单机无法同时跑 slave 时）：

```bash
./validate.sh <master_ip>
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

### 快速烟雾

```bash
curl -s --max-time 5 http://<master_ip>:8000/health && echo
curl -s --max-time 5 http://<master_ip>:8000/v1/models
curl -s --max-time 5 http://<master_ip>:20002/v1/embeddings \
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

原因：`--attn flash-attn` 在 C++ 侧走 paged KV 分配路径，**必须与 `--enable-paged-attn` 同时使用**；单独 static cache + flash-attn 会触发类型不匹配。case TOML 已统一为 **paged + flash-attn + graph**：`--enable-paged-attn --num-blocks 1024 --attn flash-attn --enable-graph`，并使用 `--max-new-tokens`（非 `--max-tokens`）。

### B) `No healthy services available for model 'Qwen3-32B'`

1. `curl -s http://<ip>:8000/v1/models`
2. `curl -s http://<ip>:18000/services`
3. 查看 Qwen worker babysitter 日志（见上）
4. 重建：`docker-compose up -d --force-recreate worker-master-qwen-paged-8200`

### C) Qwen `hcGraphLaunch` / exit 134 during native CG capture

现象：权重加载完成后，native piecewise CG warmup 报 `hcGraphLaunch: hcErrorInvalidValue`，进程 exit 134，babysitter 重启循环。

处理：

1. 停止 compose，`docker-compose down`
2. 清理 stale GPU 进程（宿主机上 kill 残留 inference/python 占卡进程）
3. 仅启动 master 栈（GPU 不足时不要起 slave）：`docker-compose up -d --force-recreate master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002`
4. 等待 Qwen CG capture 完成（数分钟）后再 `./validate.sh <master_ip>`

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
