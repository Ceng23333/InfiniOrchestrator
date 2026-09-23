#!/usr/bin/env bash
# Optional: seed / refresh MoE Triton JSON aliases for the live Denglin device.
# Usually run inside the wrap image after build; also invoked by build-wrap-image.sh.
set -euo pipefail

CFG_DIR="${1:-/opt/vllm_minicpm5/moe_configs}"
python3 - <<PY
from pathlib import Path
cfg_dir = Path("${CFG_DIR}")
seeds = sorted(cfg_dir.glob("H=2048,E=160,N=512,device_name=*.json"))
if not seeds:
    raise SystemExit(f"no MoE seed JSON under {cfg_dir}")
src = next((p for p in seeds if "Mars_03" in p.name), seeds[0])
payload = src.read_text()
aliases = {"Mars_03", "X203", "QY", "KS38", "Denglin", "denglin"}
try:
    import torch
    if torch.cuda.is_available():
        raw = torch.cuda.get_device_name(0)
        print("device_name=", raw)
        aliases.add(raw.replace(" ", "_"))
        aliases.add(raw.replace(" ", ""))
except Exception as e:
    print("device probe failed:", e)
(cfg_dir / "H=2048").mkdir(parents=True, exist_ok=True)
for dev in sorted(aliases):
    for dst in (
        cfg_dir / f"H=2048,E=160,N=512,device_name={dev}.json",
        cfg_dir / "H=2048" / f"H=2048,E=160,N=512,device_name={dev}.json",
        cfg_dir / f"E=160,N=512,device_name={dev}.json",
    ):
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(payload)
        print("seeded", dst)
print("seed_src=", src)
PY
