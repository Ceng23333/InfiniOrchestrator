# Metax 离线友好部署指南

本文将以 **3 个阶段** 部署 `InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325`：

1. 从本地 `InfiniCore/InfiniLM` 源码构建部署/运行镜像（构建过程中不依赖外网）。
2. 在使用 case 自带 `.env` 的前提下，用 `docker-compose` 启动 `master` 与模型 worker。
3. 通过 `validate.sh` 验证：注册中心/路由健康性、模型聚合、经由路由的 `/v1/chat/completions`，以及 embedding `/v1/embeddings` 可用性（required）。

## 目标

使用如下条件部署 `InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325`：

- 使用本地 InfiniCore + InfiniLM 源码作为构建上下文
- 主机上已存在基础镜像：`infinilm-svc:metax-hpcc-1004_218-202602281209`
- 构建/运行过程不发生外网拉取（只使用本地 Docker layer + 本地模型挂载目录）

## 部署前检查（不建议在此处改动代码）

- 确认该 deploy case 的 `.env` 中模型挂载路径正确：
  - `MODEL1_DIR=/path/on/host/9g_8b_thinking_llama`
  - `QWEN3_32B_DIR=/path/on/host/Qwen3-32B`
- （推荐）了解 worker 的 OOM 默认行为：
  - `InferEngine.forward()` 在检测到 OOM-like 异常（allocator / CUDA / PyTorch OOM 等）时，会先 **logger.error** 再以 **exit code 137** 退出进程（默认行为，无需设置环境变量）。
- 确认基础镜像已存在于本地（避免构建时拉取）：
  - `infinilm-svc:metax-hpcc-1004_218-202602281209`

### 离线友好前置条件（推荐）

- 确认你有 `docker-compose` **v1.x** 可用（本仓库的 compose 文件对 v1.x 兼容性做了适配）。
- 除非宿主机目录已存在且包含正确文件，否则不要修改模型路径；至少应包含：
  - `9g_8b_thinking_llama/...`
  - `Qwen3-32B/config.json` 以及权重分片
- 确认你本机能解析并访问验证脚本使用的目标 IP（本指南使用）：
  - `192.168.162.18`

## 第一阶段：从本地源码构建部署镜像

在 `InfiniOrchestrator/container/metax` 目录执行：

```bash
cd "/root/zenghua/20260326/infinilm-svc-refactor/InfiniOrchestrator/container/metax" && \
IMAGE_TAG=infini-orchestrator-metax:local \
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209 \
INFINI_RUNTIME_CONTAINER=__base__ \
DOCKER_BUILD_NO_CACHE=1 \
./build-image.sh
```

### （可选）镜像构建后快速自检（Flash-Attn + ATen + Graph）

如果你想在 `docker-compose up` 之前先快速验证“镜像内的 InfiniCore/InfiniLM + flash-attn + graph 路径基本可跑”，可以用下面的一次性命令做最小冒烟。

说明：

- 该命令会直接启动容器跑 `InfiniLM/examples/jiuge.py`（MetaX），需要把模型目录挂载进容器。
- `env-set.sh` 在某些宿主机上可能不存在，因此这里做了“存在则 source，不存在则跳过”，避免你遇到的 `No such file or directory` 直接失败。

```bash
docker run --rm --privileged --ipc=host --network=host \
  -v /home/zenghua:/home/zenghua \
  -v /data-aisoft/zenghua/models:/models \
  --device /dev/dri:/dev/dri \
  --device /dev/htcd:/dev/htcd \
  --device /dev/infiniband:/dev/infiniband \
  --entrypoint /bin/bash \
  infini-orchestrator-metax:local -lc '
set -eo pipefail
if [ -f /home/zenghua/env-set.sh ]; then source /home/zenghua/env-set.sh; fi

# Prefer the baked-in source trees inside the image.
REPO=/workspace
export PYTHONPATH=$REPO/InfiniLM/python:$REPO/InfiniCore/python:${PYTHONPATH:-}

export TORCH_LIB=$(python -c "import torch, os; print(os.path.join(os.path.dirname(torch.__file__), \"lib\"))")
export LD_LIBRARY_PATH=$TORCH_LIB:/root/.infini/lib:${LD_LIBRARY_PATH:-}

python $REPO/InfiniLM/examples/jiuge.py \
  --metax \
  --model-path /models/Qwen3-32B \
  --tp 4 \
  --max-new-tokens 1024 \
  --attn=flash-attn \
  --enable-graph \
  --enable-paged-attn \
  --prompt "你好，请用一句话介绍PagedKV+Graph自检。"
'
```



## 第二阶段：用 docker-compose 启动（不使用 profiles）

在 case 目录执行：

```bash
cd "/root/zenghua/20260326/infinilm-svc-refactor/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325" && \
docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

说明：

- 确保该 case 的 `.env` 指向你宿主机的实际模型目录。
- 不要用 `.env.example` 覆盖 `.env`。
- embedding 已纳入 required 验证，请确保 master 侧已启动 `worker-master-embeddings-20002`。

### 第二阶段（可选）：在 slave 主机启动 1x9g + 1xQwen(Flash-Attn + Graph)

当前 case 中的 slave 预置已调整为（命名不再使用 `static` 后缀）：

- `worker-slave-fla-9g-8100` -> `9g_8b_thinking`（`--attn flash-attn --enable-graph`，端口 8100）
- `worker-slave-fla-qwen-8200` -> `Qwen3-32B` paged（`--attn flash-attn --enable-graph`，端口 8200）

在 slave 主机上（同一 case 目录）启动：

```bash
cd "/root/zenghua/20260326/infinilm-svc-refactor/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325" && \
docker-compose up -d --force-recreate \
  worker-slave-fla-9g-8100 worker-slave-fla-qwen-8200
```

说明：

- 若 slave 与 master 不在同一台主机，请在 slave 主机的 `.env` 显式设置：
  - `SLAVE_REGISTRY_URL=http://<master_ip>:18000`
  - `SLAVE_ROUTER_URL=http://<master_ip>:8000`
  - `SLAVE_ADVERTISE_HOST=<slave_ip>`（注册到 registry 的 OpenAI 服务地址必须是 master 能访问的 IP/主机名；`docker-compose.yml` 通过该变量渲染 `BABYSITTER_HOST`，未设置时回退为各 worker 的 Compose 服务名）
- 这两个 slave worker 会向 `SLAVE_REGISTRY_URL/SLAVE_ROUTER_URL` 注册；跨机部署时上述三个变量均建议在 `.env` 显式设置。
- `worker-slave-fla-9g-8100` 依赖 `MODEL1_DIR` 挂载 9g 模型；`worker-slave-fla-qwen-8200` 依赖 `QWEN3_32B_DIR` 挂载 Qwen 模型。
- 若 `Qwen3-32B` 首次加载较慢，`validate.sh` 早期可能看到该 slave 服务尚未注册，等待后重试即可。

## 第三阶段：执行验证（注册中心/路由 + 模型路由）

执行：

```bash
cd "/root/zenghua/20260326/infinilm-svc-refactor/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325" && \
./validate.sh 192.168.163.151 192.168.163.152
```

说明：

- 第 2 个参数是 slave IP；若你当前不验证 slave，可只传 master IP。
- validate 的 embedding 检查为 required，并以 `http://<master_ip>:20002/v1/embeddings` 实测结果为准。

可选快速烟雾（更快的基本检查）：

```bash
curl -s --max-time 5 http://192.168.163.151:8000/health && echo
curl -s --max-time 5 http://192.168.163.151:8000/v1/models
curl -s --max-time 5 http://192.168.163.151:20002/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"text-embedding-ada-002","input":"hello"}'
```

## 预期结果

当部署成功时，`./validate.sh 192.168.163.151 192.168.163.152` 应当通过以下检查：

- Registry `/health` 为 OK
- Router `/health` 为 OK
- 模型聚合能发现以下模型：
  - `9g_8b_thinking`
  - `Qwen3-32B`
- `/v1/chat/completions` 对这两个模型的测试请求均成功
- embedding `/v1/embeddings` 请求成功（返回包含 `"object": "list"`）

在成功运行时，该脚本会以 `exit code 0` 结束，并且 chat + embedding 两类测试都通过。

## 排障（Troubleshooting）

### 通用：查看 worker 容器 babysitter 日志（推荐先做）

当 `validate.sh` 显示 service missing、模型聚合不全、或 worker 反复重启时，第一步建议直接查看对应 worker 的 babysitter 日志（取最新一份并 tail）：

```bash
# Qwen paged worker（8200）
docker exec infiniorch-worker-master-qwen-paged-8200-20260325 bash -lc \
  'f=$(ls -t /app/logs/babysitter_*.log | head -n1); echo "LOG=$f"; tail -n 80 "$f"'

# 9g worker（8100）
docker exec infiniorch-worker-master-9g-8100-20260325 bash -lc \
  'f=$(ls -t /app/logs/babysitter_*.log | head -n1); echo "LOG=$f"; tail -n 80 "$f"'
```

常见日志解读：

- `Heartbeat failed ... 404 Not Found (registry may have restarted)`：
  - 通常表示 registry 重启/清空了已注册的 service，babysitter 会自动 re-register。
  - 如果频繁出现，优先确认 `master`（registry/router）容器是否在重启或不稳定。
- `Failed to fetch models from service after 50 attempts` / `No models fetched ... cannot register`：
  - 多数情况下是 **后端 inference server 仍在加载权重/尚未对外提供 `/models`**，导致 babysitter 暂时拿不到模型列表。
  - 等待首次加载完成，或查看同一日志里是否有 “Starting API Server ... / load weights ...” 等输出；若长时间无进展再考虑 worker crash/依赖缺失。

### A) 报错：`No healthy services available for model 'Qwen3-32B'`

现象：

- 路由返回 “no healthy services” ，对 Qwen 模型不可用。

可能原因：

- Qwen 的 babysitter 进程崩溃（在启用某些 `--enable-graph` 条件下较常见）。
- worker 仍在加载权重，过早请求可能失败。

处理建议：

1. 查看路由模型列表：
   - `curl -s --max-time 5 http://<ip>:8000/v1/models`
2. 查看注册中心服务健康状态：
   - `curl -s --max-time 5 http://<ip>:18000/services`
3. 拉取 Qwen worker babysitter 日志（找最新一条日志并 tail）：
   - `docker exec infiniorch-worker-master-qwen-paged-8200-*/bash -lc 'f=$(ls -t /app/logs/babysitter_master-qwen3-32b-paged_*.log | head -n1); tail -n 200 "$f"'`

修复思路（结合本工作区观测经验）：

- 如果你最近启用了 `--enable-graph`，可以尝试关闭（改用 flash-attn-only / no-graph 基线）。
- 如有配置调整，建议重建 Qwen worker：
  - `docker-compose up -d --force-recreate worker-master-qwen-paged-8200`

### B) 路由 `/v1/models` 为空或缺少某个模型

现象：

- `/v1/models` 只能看到 `9g_8b_thinking` 或者直接为空。

可能原因：

- `.env` 的模型宿主机路径填写错误（挂载指向了不存在/不完整目录）。
- Qwen 的 `config.json` 没有出现在挂载目录下。

处理建议：

1. 校验 `.env` 路径：
   - `MODEL1_DIR=...`
   - `QWEN3_32B_DIR=...`
2. 校验宿主机文件存在性：
   - `.../Qwen3-32B/config.json`
3. 重建对应 worker：
   - `docker-compose up -d --force-recreate worker-master-qwen-paged-8200`

### C) worker 重启循环 / 容器退出且报 code 134

现象：

- Qwen babysitter 不断重启，同时路由返回 503。

可能原因：

- 当前运行时模式不稳定（本工作区曾观察到图模式下可能出现 `hcErrorIllegalAddress` / `infinicclAllReduce`，并导致进程退出）。

处理建议：

- 用 “flash-attn-only / no-graph” 作为 baseline：
  - 从以下配置中移除 `--enable-graph`：
    - `config/master-qwen3-32b-paged.toml`
    - `config/master-9g_8b_thinking.toml`
- 然后重建：
  - `docker-compose up -d --force-recreate master worker-master-9g-8100 worker-master-qwen-paged-8200`

### D) Embedding 校验失败（`master-embeddings-server` 未注册或 `/v1/embeddings` FAIL）

现象：

- `validate.sh` 第 `[5] Embedding endpoint (required)` 失败。

处理建议：

1. 确认 master 侧启动了 embedding worker：
   - `docker-compose up -d --force-recreate worker-master-embeddings-20002`
2. 检查 `.env`：
   - `EMBEDDING_PORT=20002`
   - `EMBEDDING_MODEL_DIR=/path/to/models`
3. 确认目录存在以下子目录：
   - `MiniCPM-Embedding-Light`
   - `MiniCPM-Reranker-Light`
   - `bce-reranker-base_v1`
4. 查看容器日志：
   - `docker logs -f infiniorch-worker-master-embeddings-20002-20260325`
5. 手工调用 embedding 接口确认：
   - `curl -s http://<master_ip>:20002/v1/embeddings -H "Content-Type: application/json" -d '{"model":"text-embedding-ada-002","input":"hello"}'`

### E) docker-compose 执行失败 / 不支持的 compose 选项

现象：

- 出现 “unsupported config option” 或版本/profile 兼容性相关报错。

修复建议：

- 在此环境使用 `docker-compose`（legacy 二进制），不要用 `docker compose`。
- 确保 compose 文件版本是针对 v1.x 兼容性调优的（本 case 已配置为 v1.x 兼容模式）。

### F) 构建会拉取镜像 / 需要网络

现象：

- `docker build` 尝试下载镜像层。

修复建议：

- 确认基础镜像标签在本地已存在：
  - `infinilm-svc:metax-hpcc-1004_218-202602281209`
- 如果本地没有该基础镜像，你需要先在宿主机预加载它，或临时允许网络访问。
