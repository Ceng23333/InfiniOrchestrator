#!/bin/bash
# MindIE 2.3 official env order: https://www.hiascend.com/document/detail/zh/mindie/230/quickstart/mindie_quickstart_0004.html
set +e
source /usr/local/Ascend/ascend-toolkit/latest/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh
source /usr/local/Ascend/atb-models/set_env.sh
source /usr/local/Ascend/mindie/2.3.0/mindie-llm/set_env.sh
source /usr/local/Ascend/mindie/2.3.0/mindie-service/set_env.sh
# set_env scripts may leave errexit disabled; restore before startup steps
set -euo pipefail

export MINDIE_LOG_TO_STDOUT=1
export MINDIE_LLM_PYTHON_LOG_TO_STDOUT=1
export MINDIE_LLM_PYTHON_LOG_TO_FILE=0
export MINDIE_LLM_PYTHON_LOG_PATH=/home/mindie-run/logs

SERVICE_ROOT="/usr/local/Ascend/mindie/2.3.0/mindie-service"
mkdir -p /home/mindie-run/logs

# Daemon expects ./config.json in service root; entrypoint creates it as root
cd "${SERVICE_ROOT}"
if [[ ! -e config.json ]]; then
  ln -sf conf/config.json config.json
fi

# Writable ATB/cache dirs under home (install tree is read-only)
export HOME=/home/mindie-run
export ASCEND_RT_VISIBLE_DEVICES="${ASCEND_RT_VISIBLE_DEVICES:-0,1}"
export ASCEND_VISIBLE_DEVICES="${ASCEND_VISIBLE_DEVICES:-${ASCEND_RT_VISIBLE_DEVICES}}"
mkdir -p "${HOME}/.cache" "${HOME}/kernel_meta"
shopt -s nullglob
rm -f /dev/shm/* 2>/dev/null || true
shopt -u nullglob

exec ./bin/mindieservice_daemon
