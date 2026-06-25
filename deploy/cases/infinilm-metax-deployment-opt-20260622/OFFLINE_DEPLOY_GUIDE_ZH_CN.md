# Metax 离线部署指南 — infinilm-metax-deployment-opt-20260622

基于 **HPCC ai3.1.0.7 / torch2.6** 预构建镜像的离线部署。与 20260611 case 不同，本 case **交付物为完整 Docker 镜像 tar**，目标机无需编译源码。

## 目标

- 基础镜像：`cr.metax-tech.com/public-ai-release-wb/hpcc/vllm:hpcc.ai3.1.0.7-torch2.6-py310-kylin2309a-arm64`
- 交付镜像：`infinilm-svc:metax-hpcc-ai3107-<IL_SHA>-<IC_SHA>-<BUILD_TS>`
- 启动：`docker-compose up -d`
- Worker PID 1：`infini-babysitter`（监控 InfiniLM / embedding 后端）
- Master：`infini-registry` + `infini-router`

## 交付物

| 文件 | 内容 |
|------|------|
| `infinilm-svc-runtime-*.tar.gz` | `docker save` 的运行时镜像（必需） |
| `deploy-case-20260622-config.tar.gz` | compose、config、validate.sh、文档 |
| `MANIFEST` | IL_SHA、IC_SHA、IMAGE_TAG |

## 阶段 0：加载镜像

```bash
OFFLINE_ROOT="/opt/offline/infinilm-metax-20260622"
mkdir -p "${OFFLINE_ROOT}"
docker load < /path/to/infinilm-svc-runtime-*.tar.gz
tar -xzf /path/to/deploy-case-20260622-config.tar.gz -C "${OFFLINE_ROOT}"
cd "${OFFLINE_ROOT}"
cat MANIFEST
docker images | grep metax-hpcc-ai3107
```

## 阶段 1：配置

```bash
cp .env.example .env
# 编辑：
#   IMAGE_TAG=<从 MANIFEST 或 .image_tag>
#   MODEL1_DIR=...
#   QWEN3_32B_DIR=...
#   EMBEDDING_MODEL_DIR=...
#   XIYAN_QWENCODER_DIR=...
```

单机同时跑 Qwen（8200）与 XiYanSQL 时：

```
SLAVE_XIYAN_API_PORT=8300
SLAVE_XIYAN_BABYSITTER_PORT=8301
```

部署前检查端口与 NFS 路由（compose 使用 `172.28.0.0/16`，避免与 `172.22.x.x` NFS 冲突）。详见 20260611 指南排障章节 I。

## 阶段 2：启动

```bash
docker-compose up -d
# 或前台日志：
docker-compose up
```

Master 栈：

```bash
docker-compose up -d master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

Slave（XiYanSQL）：

```bash
docker-compose up -d worker-slave-xiyan-qwencoder-8200
```

## 阶段 3：验证

```bash
./validate.sh <master_ip>
./validate.sh <master_ip> <slave_ip> xiyan
```

快速烟雾：

```bash
curl -s http://localhost:8000/health
curl -s http://localhost:18000/health
curl -s http://localhost:20002/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"text-embedding-ada-002","input":"hello"}'
```

验证 worker PID 1：

```bash
docker exec infiniorch-worker-master-9g-8100-20260622 ps -p 1 -o comm=
# 期望: infini-babysitter
```

## 阶段 4：离线代码更新

收到新 `InfiniCore/` + `InfiniLM/` 源码 tar 时，在有 Docker 的维护机上：

```bash
./update-codebase.sh \
  --source-image "$(cat .image_tag)" \
  --infinicore-src /path/to/InfiniCore \
  --infinilm-src /path/to/InfiniLM
# 更新 .env 中 IMAGE_TAG
docker-compose up -d --force-recreate
./validate.sh <master_ip>
```

无需重新 `docker load` 整镜像，除非基础 HPCC 层变更。

## 网络 / 代理

构建脚本在 GitHub 直连失败且 `127.0.0.1:57890` 代理可用时自动启用代理（构建容器使用 `--network host`）。强制代理：`USE_PROXY=1 ./build-image.sh`

若 xmake 无法下载依赖，确保源码树内已含预编译的 `_infinicore` / `_infinilm` `.so`（或从 dev 容器 overlay `/root/.infini`）。

## 源端构建（维护机）

见 [BUILD_GUIDE.md](BUILD_GUIDE.md)：

```bash
./build-image.sh
./export-bundle.sh
```

## 排障

与 20260611 相同（9g paged、Qwen CG、XiYan OOM、NFS 路由），容器名后缀改为 `20260622`。

查看 babysitter 日志：

```bash
docker exec infiniorch-worker-master-qwen-paged-8200-20260622 bash -lc \
  'f=$(ls -t /app/logs/babysitter_*.log | head -n1); tail -n 80 "$f"'
```
