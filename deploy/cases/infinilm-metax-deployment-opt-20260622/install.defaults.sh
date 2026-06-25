#!/usr/bin/env bash
# Install-time defaults for infinilm-metax-deployment-opt-20260622.
# Copied into InfiniLM-SVC/deployment/cases/ during build-image.sh.

SETUP_APP_ROOT="${SETUP_APP_ROOT:-true}"
LAUNCH_COMPONENTS="${LAUNCH_COMPONENTS:-none}"

if [[ "${INSTALL_PYTHON_DEPS:-auto}" = "auto" ]]; then
  INSTALL_PYTHON_DEPS=true
fi
if [[ "${INSTALL_INFINICORE:-auto}" = "auto" ]]; then
  INSTALL_INFINICORE=true
fi
if [[ "${INSTALL_INFINILM:-auto}" = "auto" ]]; then
  INSTALL_INFINILM=true
fi

INFINICORE_BUILD_CPP="${INFINICORE_BUILD_CPP:-auto}"
INFINICORE_BUILD_PYTHON="${INFINICORE_BUILD_PYTHON:-auto}"
INFINICORE_BUILD_CMD="${INFINICORE_BUILD_CMD:-python3 scripts/install.py --metax-gpu=y --aten=y --flash-attn=. --graph=y --ccl=y}"

VERIFY_INSTALL="${VERIFY_INSTALL:-true}"
