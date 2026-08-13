#!/usr/bin/env bash
set -euo pipefail

CONFIG_SRC="/mnt/mindie-config/config.json"
CONFIG_LLM="/usr/local/Ascend/mindie/2.3.0/mindie-llm/conf/config.json"
CONFIG_SERVICE="/usr/local/Ascend/mindie/2.3.0/mindie-service/conf/config.json"
# Default root: host Ascend driver bind-mount cannot be chown'd for non-root NPU access
RUN_USER="${RUN_USER:-0}"
RUN_GROUP="${RUN_GROUP:-0}"

# Privileged root: open MindIE install tree for the runtime user (no host sudo needed)
chmod a+rx /usr/local/Ascend /usr/local/Ascend/mindie /usr/local/Ascend/atb-models /usr/local/Ascend/nnal 2>/dev/null || true
chmod -R a+rX /usr/local/Ascend/mindie/2.3.0 /usr/local/Ascend/atb-models /usr/local/Ascend/nnal/atb 2>/dev/null || true
# ATB/torch_npu Python checks path owner/group (must match runtime user)
chown -R "${RUN_USER}:${RUN_GROUP}" \
  /usr/local/Ascend/atb-models \
  /usr/local/Ascend/nnal/atb \
  /usr/local/Ascend/cann-8.5.0 \
  /usr/local/Ascend/ascend-toolkit/latest \
  /usr/local/lib64/python3.11/site-packages/torch_npu 2>/dev/null || true
chmod a+rx /usr/local/Ascend/ascend-toolkit/latest/set_env.sh /usr/local/Ascend/atb-models/set_env.sh /usr/local/Ascend/nnal/atb/set_env.sh 2>/dev/null || true
find /usr/local/Ascend/atb-models -type d -exec chmod a+rx {} + 2>/dev/null || true
find /usr/local/Ascend/atb-models -type f -name '*.sh' -exec chmod a+rx {} + 2>/dev/null || true
chmod a+rx /usr/local/Ascend/mindie/2.3.0/mindie-llm/conf \
           /usr/local/Ascend/mindie/2.3.0/mindie-service/conf \
           /usr/local/Ascend/mindie/2.3.0/mindie-service/bin 2>/dev/null || true
chmod a+rx /usr/local/Ascend/mindie/2.3.0/mindie-service/bin/mindieservice_daemon 2>/dev/null || true
# MindIE security: backend .so must be owned by runtime user with mode 440
find /usr/local/Ascend/mindie/2.3.0/mindie-service/lib /usr/local/Ascend/mindie/2.3.0/mindie-llm/lib \
  -type f \( -name '*.so' -o -name '*.so.*' \) -exec chown "${RUN_USER}:${RUN_GROUP}" {} + \
  -exec chmod 440 {} + 2>/dev/null || true
chown "${RUN_USER}:${RUN_GROUP}" /usr/local/Ascend/mindie/2.3.0/mindie-service/bin/mindieservice_daemon 2>/dev/null || true
chmod 550 /usr/local/Ascend/mindie/2.3.0/mindie-service/bin/mindieservice_daemon 2>/dev/null || true
mkdir -p /home/mindie-run/mindie-service-logs
mkdir -p /usr/local/Ascend/mindie/2.3.0/mindie-service/logs 2>/dev/null || true
mount --bind /home/mindie-run/mindie-service-logs /usr/local/Ascend/mindie/2.3.0/mindie-service/logs 2>/dev/null || true
find /usr/local/Ascend/mindie/2.3.0 -type d -exec chmod a+rx {} + 2>/dev/null || true
find /usr/local/Ascend/mindie/2.3.0 -type f -executable -exec chmod a+rx {} + 2>/dev/null || true
chmod -R a+rX /usr/local/lib/python3.11 /usr/local/lib64/python3.11 2>/dev/null || true

# Writable logs dir (install tree is read-only; bind-mount avoids set_env mkdir timeout)
mkdir -p /home/mindie-run/mindie-llm-logs
mkdir -p /usr/local/Ascend/mindie/2.3.0/mindie-llm/logs 2>/dev/null || true
mount --bind /home/mindie-run/mindie-llm-logs /usr/local/Ascend/mindie/2.3.0/mindie-llm/logs 2>/dev/null || \
  ln -sfn /home/mindie-run/mindie-llm-logs /usr/local/Ascend/mindie/2.3.0/mindie-llm/logs 2>/dev/null || true

# Stage config owned by model user (matches modelWeightPath security check)
install -d -m 750 "$(dirname "${CONFIG_LLM}")" "$(dirname "${CONFIG_SERVICE}")"
cp -f "${CONFIG_SRC}" "${CONFIG_LLM}"
cp -f "${CONFIG_SRC}" "${CONFIG_SERVICE}"
chown "${RUN_USER}:${RUN_GROUP}" "${CONFIG_LLM}" "${CONFIG_SERVICE}"
chmod 640 "${CONFIG_LLM}" "${CONFIG_SERVICE}"
# Runtime user must traverse conf/ to read config.json via symlink
for conf_dir in "$(dirname "${CONFIG_LLM}")" "$(dirname "${CONFIG_SERVICE}")"; do
  chown "${RUN_USER}:${RUN_GROUP}" "${conf_dir}" 2>/dev/null || true
  chmod 755 "${conf_dir}" 2>/dev/null || true
done
# Symlink for daemon cwd (expects ./config.json in mindie-service root)
ln -sf conf/config.json "${CONFIG_SERVICE%/conf/config.json}/config.json" 2>/dev/null || \
  ln -sf conf/config.json /usr/local/Ascend/mindie/2.3.0/mindie-service/config.json

# HF weights symlinks (exclude model_state.pdparams for ATB safetensors loader)
MODEL_LINK="/home/mindie-run/model_weights"
MODEL_SRC="/models/9g_8b_thinking_llama"
mkdir -p "${MODEL_LINK}"
shopt -s nullglob
for f in "${MODEL_SRC}"/*; do
  base=$(basename "$f")
  case "${base}" in model_state.pdparams|*.pdparams|config.json) continue ;; esac
  ln -sf "$f" "${MODEL_LINK}/${base}" 2>/dev/null || true
done
shopt -u nullglob
# MindIE ATB only supports rope_type in {dynamic,yarn,llama3}; patch LongRoPE config.json
python3 - <<'PY'
import json
from pathlib import Path

src = Path("/models/9g_8b_thinking_llama/config.json")
dst = Path("/home/mindie-run/model_weights/config.json")
cfg = json.loads(src.read_text())
rs = cfg.get("rope_scaling") or {}
if rs.get("type") == "longrope" or rs.get("rope_type") == "longrope":
    cfg["rope_scaling"] = {
        "rope_type": "llama3",
        "factor": rs.get("factor", 1.0),
        "low_freq_factor": 1.0,
        "high_freq_factor": 4.0,
        "original_max_position_embeddings": 8192,
    }
dst.write_text(json.dumps(cfg, indent=2) + "\n")
PY
chown -R "${RUN_USER}:${RUN_GROUP}" "${MODEL_LINK}" 2>/dev/null || true
chmod 640 "${MODEL_LINK}/config.json" 2>/dev/null || true

mkdir -p /home/mindie-run
if [[ -f /mnt/mindie-run-daemon/run-daemon.sh ]]; then
  cp -f /mnt/mindie-run-daemon/run-daemon.sh /home/mindie-run/run-daemon.sh
  chmod 755 /home/mindie-run/run-daemon.sh
fi
chown "${RUN_USER}:${RUN_GROUP}" /home/mindie-run
chown "${RUN_USER}:${RUN_GROUP}" /home/mindie-run/run-daemon.sh 2>/dev/null || true

# Ensure numeric model owner exists in container nss (no host sudo required)
if ! getent passwd "${RUN_USER}" >/dev/null 2>&1; then
  if ! getent group "${RUN_GROUP}" >/dev/null 2>&1; then
    groupadd -g "${RUN_GROUP}" mindie 2>/dev/null || true
  fi
  useradd -u "${RUN_USER}" -g "${RUN_GROUP}" -M -s /bin/bash mindie 2>/dev/null || true
fi

RUN_NAME="$(getent passwd "${RUN_USER}" | cut -d: -f1 || echo "${RUN_USER}")"
export ENTRYPOINT_CONFIGS="${ENTRYPOINT_CONFIGS:-/workspace/InfiniOrchestrator/playground/Standalone/9g_8b_thinking-910b4-mindie/config/master-9g_8b_thinking-mindie.toml}"
exec infini-entrypoint --config-file "${ENTRYPOINT_CONFIGS}"
