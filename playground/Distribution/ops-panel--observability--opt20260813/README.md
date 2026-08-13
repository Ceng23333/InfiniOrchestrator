# ops-panel -- observability (opt20260813)

LB-only / observability Playground case. Uses shared Dynamo-style fragments under
[`deploy/docker-compose/`](../../../../deploy/docker-compose/).

## Layout

```text
docker-compose/compose.sh   # multi -f wrapper (profiles)
docker-compose/docker-compose.yml  # case overrides (warehouse mount)
k8s/                        # placeholder
run-host-panel.sh           # host-native Frontend on :18880 by default
```

## Standalone (Frontend + Prom + Grafana)

Do **not** run this Frontend on **8800** while `qwen3-32b+9g--x203-inf--opt20260811` (or any other case) already publishes Frontend there.

```bash
cd docker-compose
cp -n .env.example .env
# If 8800 is taken, set FRONTEND_HOST_PORT / ROUTER_PORT to a free port, or use obs-only mode.
./compose.sh --profile frontend --profile observability up -d
./validate.sh localhost
```

| Service | Default URL |
|---------|-------------|
| Panel (Frontend) | `http://<host-ip>:8800/panel` |
| Prometheus | `http://<host-ip>:9090` |
| Grafana | `http://<host-ip>:3000` |

Dashboard **Open Grafana** uses `GRAFANA_URL` when set on the Frontend process; otherwise it falls back to `http://<panel-host>:3000`.

## Observability-only (reuse existing Frontend)

When an inference case Frontend already serves `/panel` + `/metrics` on 8800:

```bash
cd docker-compose
PROM_CONFIG=prometheus-host.yml ./compose.sh --profile observability up -d
```

## Host-native Frontend

```bash
../run-host-panel.sh
# → http://<host-ip>:18880/panel  (default avoids clash with live :8800)
```

## k8s

See [`k8s/README.md`](k8s/README.md) — placeholder; Compose is the supported path.
