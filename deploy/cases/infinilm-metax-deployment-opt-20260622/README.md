# Case: infinilm-metax-deployment-opt-20260622

Offline Metax deployment on **HPCC ai3.1.0.7 / torch2.6**. Deliverable is a **pre-built Docker image** (`docker save` tarball), launched with `docker-compose up`.

Historical reference: [`infinilm-metax-deployment-opt-20260611`](../infinilm-metax-deployment-opt-20260611/).

## Image tag format

```
infinilm-svc:metax-hpcc-ai3107:<IL_SHA>-<IC_SHA>-<BUILD_TS>
```

## Build (source machine)

```bash
cd InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260622
./build-image.sh
./export-bundle.sh
```

## Deploy (target machine)

```bash
docker load < infinilm-svc-runtime-*.tar.gz
tar -xzf deploy-case-20260622-config.tar.gz -C /opt/offline/infinilm-metax-20260622
cd /opt/offline/infinilm-metax-20260622
cp .env.example .env   # set IMAGE_TAG + model paths
docker-compose up -d
./validate.sh <master_ip> [slave_ip] xiyan
```

See [OFFLINE_DEPLOY_GUIDE_ZH_CN.md](OFFLINE_DEPLOY_GUIDE_ZH_CN.md) and [BUILD_GUIDE.md](BUILD_GUIDE.md).

## Services

**Master:** registry + router  
**Workers:** 9g @ 8100, Qwen3-32B paged @ 8200, embeddings @ 20002  
**Slave:** XiYanSQL-QwenCoder-32B-2504 @ 8200 (remap with `SLAVE_XIYAN_API_PORT=8300` on single host)

Worker containers run **infini-babysitter as PID 1** (`LAUNCH_COMPONENTS=babysitter`).
