#!/usr/bin/env bash
# Build Denglin wrap image: dl-vllm 0.21 + vllm_minicpm5 MoE plugin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCKER="${DOCKER:-sudo docker}"

# Prefer the image present on this host; override via BASE_IMAGE if needed.
BASE_IMAGE="${BASE_IMAGE:-dl-vllm-v0.21.0-docker-image:MR-4.1.2-202606032315-ubuntu22.04-x86_64-20260603}"
IMAGE_TAG="${IMAGE_TAG:-dl-vllm-minicpm5-16a3-qy:v2026.09.21}"
BUILD_CONTAINER="${BUILD_CONTAINER:-dl-vllm-minicpm5-16a3-qy-build-$$}"
RUNTIME="${RUNTIME:-dlrt}"
# Prefer sibling X203 plugin tree (source of truth); allow override.
VLLM_MINICPM5_HOST="${VLLM_MINICPM5_HOST:-${SCRIPT_DIR}/../minicpm5-x203-vllm/vllm_minicpm5}"
# Optional local overlay patches applied after copy (Denglin API diffs).
PATCH_DIR="${PATCH_DIR:-${SCRIPT_DIR}/patches}"

echo "=========================================="
echo "Build wrap image (dl-vllm 0.21 + minicpm5 MoE plugin)"
echo "=========================================="
echo "BASE_IMAGE:          ${BASE_IMAGE}"
echo "IMAGE_TAG:           ${IMAGE_TAG}"
echo "VLLM_MINICPM5_HOST:  ${VLLM_MINICPM5_HOST}"
echo "RUNTIME:             ${RUNTIME}"
echo ""

if ! ${DOCKER} image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "error: base image not found: ${BASE_IMAGE}" >&2
  exit 1
fi
if [[ ! -d "${VLLM_MINICPM5_HOST}/vllm_minicpm5" ]]; then
  echo "error: VLLM_MINICPM5_HOST missing plugin package: ${VLLM_MINICPM5_HOST}" >&2
  exit 1
fi
if [[ ! -f "${VLLM_MINICPM5_HOST}/pyproject.toml" ]]; then
  echo "error: missing pyproject.toml in ${VLLM_MINICPM5_HOST}" >&2
  exit 1
fi

${DOCKER} rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true
${DOCKER} run -d \
  --name "${BUILD_CONTAINER}" \
  --runtime "${RUNTIME}" \
  --network host \
  -e "DL_DEVICES=all" \
  --workdir /workspace \
  --entrypoint /bin/bash \
  "${BASE_IMAGE}" \
  -c "sleep infinity"

cleanup_on_fail() {
  local ec=$?
  if [[ ${ec} -ne 0 ]]; then
    echo "Build failed (exit ${ec}). Container kept: sudo docker exec -it ${BUILD_CONTAINER} bash" >&2
  fi
}
trap cleanup_on_fail EXIT

echo "Copying vllm_minicpm5 → /opt/vllm_minicpm5 ..."
${DOCKER} exec "${BUILD_CONTAINER}" rm -rf /opt/vllm_minicpm5
${DOCKER} exec "${BUILD_CONTAINER}" mkdir -p /opt/vllm_minicpm5
tar -C "${VLLM_MINICPM5_HOST}" \
  --exclude='.git' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  -cf - . | ${DOCKER} exec -i "${BUILD_CONTAINER}" tar -C /opt/vllm_minicpm5 -xf -

# Apply Denglin vLLM 0.21 API shim to the installed plugin tree.
SHIM="${PATCH_DIR}/apply_denglin_api_shim.py"
if [[ -f "${SHIM}" ]]; then
  echo "Applying Denglin API shim ..."
  ${DOCKER} cp "${SHIM}" "${BUILD_CONTAINER}:/tmp/apply_denglin_api_shim.py"
  ${DOCKER} exec "${BUILD_CONTAINER}" python3 /tmp/apply_denglin_api_shim.py
else
  echo "warning: shim missing at ${SHIM}; continuing without API patch" >&2
fi

echo "Seeding MoE configs for Denglin device aliases ..."
${DOCKER} exec "${BUILD_CONTAINER}" bash -lc '
  set -eo pipefail
  # env.sh references $1; keep nounset off while sourcing.
  set +u
  source /usr/local/dlgpu/sdk/env.sh
  set -u
  export CUDA_HOME=/usr/local/dlgpu/sdk
  python3 - <<'"'"'PY'"'"'
from pathlib import Path
import json
import shutil

cfg_dir = Path("/opt/vllm_minicpm5/moe_configs")
# Prefer Mars_03 seed (closest generic pack shipped with the plugin).
seeds = sorted(cfg_dir.glob("H=2048,E=160,N=512,device_name=*.json"))
if not seeds:
    raise SystemExit("no MoE seed JSON under /opt/vllm_minicpm5/moe_configs")
src = next((p for p in seeds if "Mars_03" in p.name), seeds[0])
payload = src.read_text()

aliases = {"Mars_03", "X203"}
try:
    import torch
    if torch.cuda.is_available():
        raw = torch.cuda.get_device_name(0)
        print("device_name=", raw)
        aliases.add(raw.replace(" ", "_"))
        aliases.add(raw.replace(" ", ""))
        for token in ("QY", "KS38", "DENGLIN", "DL", "C610", "Iluvatar", "BI"):
            if token.lower() in raw.replace(" ", "").lower():
                aliases.add(token)
    else:
        print("cuda unavailable during build; seeding generic aliases only")
except Exception as e:
    print("device probe failed:", e)

# Common Denglin / KS38 fallbacks when CUDA probe is unavailable at build time.
# Live probe on this host reported: torch.cuda.get_device_name(0) == "KS38 QUAD-3"
aliases.update({
    "QY",
    "KS38",
    "KS38_QUAD-3",
    "KS38QUAD-3",
    "Denglin",
    "denglin",
})

(cfg_dir / "H=2048").mkdir(parents=True, exist_ok=True)
for dev in sorted(aliases):
    flat = cfg_dir / f"H=2048,E=160,N=512,device_name={dev}.json"
    nested = cfg_dir / "H=2048" / flat.name
    eflat = cfg_dir / f"E=160,N=512,device_name={dev}.json"
    for dst in (flat, nested, eflat):
        dst.write_text(payload)
        print("seeded", dst)
print("seed_src=", src)
PY
'

echo "Installing MoE JSON into Denglin dl_fused_moe configs path ..."
${DOCKER} exec "${BUILD_CONTAINER}" bash -lc '
  set -euo pipefail
  # Denglin get_moe_configs expects flat {batch: {BLOCK_SIZE_M,...}}.
  # MetaX seeds use {batch: {stage1, stage2}}; flatten stage1 for DL.
  python3 - <<'"'"'PY'"'"'
import json
from pathlib import Path
src = Path("/opt/vllm_minicpm5/moe_configs")
dst = Path("/usr/local/lib/python3.12/dist-packages/vllm/plugins/dl_platform_plugin/ops/configs")
dst.mkdir(parents=True, exist_ok=True)
for f in sorted(src.glob("E=160,N=512,device_name=*.json")):
    data = json.loads(f.read_text())
    flat = {}
    for key, val in data.items():
        if isinstance(val, dict) and "stage1" in val and isinstance(val["stage1"], dict):
            flat[key] = dict(val["stage1"])
        else:
            flat[key] = val
    out = dst / f.name
    out.write_text(json.dumps(flat, indent=2) + "\n")
    sample = next(iter(flat.values())) if flat else {}
    print("installed", out.name, "BLOCK_SIZE_M=", sample.get("BLOCK_SIZE_M"))
print("done", len(list(dst.glob("E=160,N=512,device_name=*.json"))))
PY
'

echo "pip install -e /opt/vllm_minicpm5 ..."
${DOCKER} exec "${BUILD_CONTAINER}" bash -lc '
  set -eo pipefail
  # env.sh references $1; keep nounset off while sourcing.
  set +u
  source /usr/local/dlgpu/sdk/env.sh
  set -u
  export CUDA_HOME=/usr/local/dlgpu/sdk
  if ! python3 -m pip install --no-build-isolation -e /opt/vllm_minicpm5; then
    python3 -m pip install -e /opt/vllm_minicpm5
  fi
  python3 - <<'"'"'PY'"'"'
import vllm, vllm_minicpm5
from pathlib import Path
print("vllm", vllm.__version__)
print("plugin", vllm_minicpm5.__file__)
assert Path("/opt/vllm_minicpm5/tokenizer_bytelevel").is_dir()
assert Path("/opt/vllm_minicpm5/moe_configs").is_dir()
# Confirm plugin entry registers without import errors.
from vllm_minicpm5 import register
register()
print("register ok")
PY
'

IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TS="$(date -u +%Y%m%d)"

${DOCKER} commit \
  --change 'WORKDIR /workspace' \
  --change 'ENTRYPOINT ["/bin/bash"]' \
  --change 'CMD ["-lc","sleep infinity"]' \
  --change "LABEL deployment.wrap=dl-vllm-minicpm5-16a3-qy" \
  --change "ENV IO_SHA=${IO_SHA}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  --change 'ENV VLLM_TUNED_CONFIG_FOLDER=/opt/vllm_minicpm5/moe_configs' \
  "${BUILD_CONTAINER}" \
  "${IMAGE_TAG}"

trap - EXIT
${DOCKER} rm -f "${BUILD_CONTAINER}" >/dev/null

echo "${IMAGE_TAG}" > "${SCRIPT_DIR}/.image_tag"
echo ""
echo "Built: ${IMAGE_TAG}"
echo "Next: ${SCRIPT_DIR}/run-wrap.sh"
