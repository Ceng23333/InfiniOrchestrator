# Shared Docker Compose fragments (Dynamo-style)

Reusable services for Playground Distribution cases. This host uses **docker-compose 1.28+** (`profiles`, multi-`-f` merge). Compose Spec `include:` is not required.

## Fragments

| File | Profile | Services |
|------|---------|----------|
| [`etcd.yml`](etcd.yml) | `frontend` | `etcd` (no host ports by default) |
| [`frontend.yml`](frontend.yml) | `frontend` | `frontend` (`infini-loadbalancer` → OpenAI + `/panel*` + `/metrics`) |
| [`observability.yml`](observability.yml) | `observability` | `prometheus`, `grafana` |

Provisioning assets live under [`observability/`](observability/).

## Port policy

See [`ports.env.example`](ports.env.example). Locked defaults:

- **Frontend / panel:** `FRONTEND_HOST_PORT` / `ROUTER_PORT` → **8800** (at most one Frontend on a host)
- **etcd:** do not publish unless debugging (`ETCD_HOST_PORT`)
- **Prometheus:** `PROM_HOST_PORT` → **9090**
- **Grafana:** `GRAFANA_HOST_PORT` → **3000**

## Bring-up (multi-`-f`)

Case wrappers (`compose.sh`) set `--project-directory` and `--env-file` to the case `docker-compose/` dir so `.env` resolves correctly even though fragment YAML lives under `deploy/docker-compose/`.

From a case `docker-compose/` directory:

```bash
# Inference case: Frontend + workers
./compose.sh --profile frontend --profile workers up -d

# Add Prom/Grafana scraping the case Frontend
./compose.sh --profile observability up -d

# Ops-panel standalone: Frontend + observability (+ warehouse mount via case override)
./compose.sh --profile frontend --profile observability up -d

# Observability-only against an already-running Frontend on the host
OBS_SCRAPE_TARGET=host.docker.internal:8800 PROM_CONFIG=prometheus-host.yml \
  ./compose.sh --profile observability up -d
```

## Reuse rules

1. An inference case Frontend already serves `/panel` — do **not** start a second LB (ops-panel Frontend) on the same host ports; only attach `--profile observability`.
2. Use a unique `COMPOSE_PROJECT_NAME` per case (wrappers set this). Avoid hard-coded global `container_name` on shared fragments.
3. Host-native panel script defaults to port **18880** so it does not fight a live case Frontend on 8800.

## Dynamo mapping

| Dynamo | This stack |
|--------|------------|
| Frontend | `frontend` service |
| Workers | case-local services (`workers` profile) |
| Prometheus + Grafana | `observability` profile |
