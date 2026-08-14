# Shared Docker Compose fragments (Dynamo-style)

Reusable services for Playground Distribution cases. This host uses **docker-compose 1.28+** (`profiles`, multi-`-f` merge). Compose Spec `include:` is not required.

## Fragments

| File | Profile | Services |
|------|---------|----------|
| [`etcd.yml`](etcd.yml) | `frontend` | `etcd` (no host ports by default) |
| [`frontend.yml`](frontend.yml) | `frontend` | `frontend` (`infini-loadbalancer` → OpenAI + `/panel*` + `/metrics`) |
| [`observability.yml`](observability.yml) | `observability` | `prometheus`, `grafana` |
| [`warehouse-sync.yml`](warehouse-sync.yml) | `warehouse-sync` | `warehouse-sync` (git pull → named volume `bench_warehouse`) |

Provisioning assets live under [`observability/`](observability/). Compose sync script: [`warehouse-sync/sync.sh`](warehouse-sync/sync.sh). Host-native sync script: [`../warehouse-sync-host.sh`](../warehouse-sync-host.sh).

**ops-panel removed** — do not start a second LB-only case. Use an inference case Frontend (e.g. qwen `opt20260811`) with `--profile observability` / `--profile warehouse-sync`.

## Port policy

See [`ports.env.example`](ports.env.example). Locked defaults:

- **Frontend / panel:** `FRONTEND_HOST_PORT` / `ROUTER_PORT` → **8800** (at most one Frontend on a host)
- **etcd:** do not publish unless debugging (`ETCD_HOST_PORT`)
- **Prometheus:** `PROM_HOST_PORT` → **9090**
- **Grafana:** `GRAFANA_HOST_PORT` → **3000**

## Bring-up (multi-`-f`)

Case wrappers (`compose.sh`) set `--project-directory` and `--env-file` to the case `docker-compose/` dir so `.env` resolves correctly even though fragment YAML lives under `frontend/docker-compose/`.

From a case `docker-compose/` directory (qwen example):

```bash
# Inference case: Frontend + workers
./compose.sh --profile frontend --profile workers up -d

# Add Prom/Grafana scraping the case Frontend
./compose.sh --profile observability up -d

# Hot-update bench-warehouse via sidecar (private repo token required)
# ./compose.sh --profile frontend --profile warehouse-sync up -d

# Full stack
./compose.sh --profile frontend --profile workers --profile observability --profile warehouse-sync up -d

# Observability-only against an already-running Frontend on the host
OBS_SCRAPE_TARGET=host.docker.internal:8800 PROM_CONFIG=prometheus-host.yml \
  ./compose.sh --profile observability up -d
```

### warehouse-sync

Warehouse is owned by Frontend fragments (`frontend.yml` sets `BENCH_WAREHOUSE_REPO=/warehouse` and mounts named volume `bench_warehouse:/warehouse:ro`). Cases do **not** bind a host path.

| Env | Default | Role |
|-----|---------|------|
| `BENCH_WAREHOUSE_GIT_URL` | `https://github.com/InfiniTensor/bench-warehouse.git` | clone URL |
| `BENCH_WAREHOUSE_GIT_REF` | `master` | branch |
| `BENCH_WAREHOUSE_SYNC_INTERVAL_SEC` | `300` | pull period |
| `BENCH_WAREHOUSE_GITHUB_TOKEN` | (required for private HTTPS) | bearer via `http.extraHeader` — never logged |

- **Profile off (default):** volume may be empty → LongBench API empty/`not found` until sync runs.
- **Profile on:** sidecar writes `bench_warehouse` (rw); Frontend reads it `:ro`. Status file `/warehouse/.warehouse-sync-status` surfaces as LongBench `source.sync`.
- **Offline / airgap:** use host-native panel ([`run-host-panel.sh`](../run-host-panel.sh) with a sibling `bench-warehouse` clone), or enable sync with a token — not a playground host bind.
- **Host-native FE:** use [`../warehouse-sync-host.sh`](../warehouse-sync-host.sh) instead of the compose sidecar. It sparse-checks out `raw/` into a sibling live checkout, flips the `bench-warehouse` symlink only after a successful sync, and writes `.warehouse-sync-status` for the panel API.

Prefer `http.extraHeader` bearer auth (as in `sync.sh`) over putting the token in the clone URL.

### Host-native panel

```bash
frontend/run-host-panel.sh
# → http://<host-ip>:18880/panel  (default avoids clash with live :8800)
```

Run from repo root. Script path: [`frontend/run-host-panel.sh`](../run-host-panel.sh).

Host-native warehouse refresh:

```bash
BENCH_WAREHOUSE_SYNC_INTERVAL_SEC=300 \
  nohup frontend/warehouse-sync-host.sh > ../warehouse-sync-host.log 2>&1 &
```

Use `BENCH_WAREHOUSE_GITHUB_TOKEN` or a configured Git credential store for the private `bench-warehouse` repo. The helper forces Git HTTP/1.1 because some lab paths fail GitHub HTTP/2 clones.

## Reuse rules

1. An inference case Frontend already serves `/panel` — do **not** start a second LB on the same host ports; only attach `--profile observability` (and optionally `warehouse-sync`).
2. Use a unique `COMPOSE_PROJECT_NAME` per case (wrappers set this). Avoid hard-coded global `container_name` on shared fragments.
3. Host-native panel script defaults to port **18880** so it does not fight a live case Frontend on 8800.
4. Obs-only = same inference case `compose.sh --profile observability` with `PROM_CONFIG=prometheus-host.yml` when scraping a host Frontend.

## Multi-host (Dynamo Frontend + Workers)

Same compose files on every host; **profiles + `.env`** choose what runs.

| Host | Env template (case `docker-compose/`) | Bring-up |
|------|----------------------------------------|----------|
| Frontend | `.env.frontend.example` | `./compose.sh --profile frontend up -d` |
| Workers | `.env.workers.example` (`FRONTEND_HOST` / `ADVERTISE_HOST` = LAN IPs) | `COMPOSE_PROJECT_NAME=io-workers ./compose.sh --profile workers up -d` |

Worker discovery knobs (defaults keep same-host Docker DNS):

- `ROUTER_URL` / `REGISTRY_URL` / `ETCD_ENDPOINTS` → Frontend host
- `ADVERTISE_HOST` → address Frontend uses to reach this worker (LAN IP when remote)

Do **not** use `127.0.0.1` for advertise/router from inside containers. Localhost fake multi-node: case scripts `simulate_multinode_localhost.sh` + `validate_multinode_localhost.sh` (two projects `io-frontend` / `io-workers`).

When the worker host cannot reach the Frontend host directly but the operator PC can reach both, use the PC-anchored SSH tunnel fallback in [`../../docs/ops/kunlun-metax9-febe-validation.md`](../../docs/ops/kunlun-metax9-febe-validation.md). The fallback bridges FE-side etcd and router ports to worker containers; keep both SSH channels alive while validating.

**Deprecated:** Master/Slave env (`SLAVE_REGISTRY_URL`, `.env.slave*`, `worker-slave-*`). Prefer this Frontend+Workers contract ([`opt20260811`](../../playground/Distribution/qwen3-32b+9g--x203-inf--opt20260811/)).

## Dynamo mapping

| Dynamo | This stack |
|--------|------------|
| Frontend | `frontend` service |
| Workers | case-local services (`workers` profile) |
| Prometheus + Grafana | `observability` profile |
| (n/a) | `warehouse-sync` profile — bench-warehouse hot pull |
