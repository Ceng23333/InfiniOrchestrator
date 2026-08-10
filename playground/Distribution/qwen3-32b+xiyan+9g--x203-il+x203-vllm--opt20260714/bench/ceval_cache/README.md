# Pre-cached CEval / lm-eval assets for **offline** validation.
#
# Populate on a networked host, then pack with the case or bake into the image.
#
# Expected pins (set in README / MANIFEST / run_deploy_ceval.sh env):
#
#   CEVAL_CACHE_ROOT=<case>/bench/ceval_cache   # this directory
#   HF_HOME=${CEVAL_CACHE_ROOT}/hf
#   HF_DATASETS_CACHE=${CEVAL_CACHE_ROOT}/hf/datasets
#   LM_EVAL=${CEVAL_CACHE_ROOT}/lm_eval          # or path to vendored lm_eval tree
#   CEVAL_REPO=${CEVAL_CACHE_ROOT}/repo          # datasets / task overrides root
#
# Gate (after Phase 2 compose up):
#
#   CEVAL_FULL=1 CEVAL_ENABLE_THINKING=0 \
#   HF_HOME=... HF_DATASETS_CACHE=... LM_EVAL=... CEVAL_REPO=... \
#   ROUTER_URL=http://localhost:8800 MODELS=Qwen3-32B \
#     ./bench/run_deploy_ceval.sh
#
# Pass criteria: em > 0.7, no network downloads during the run.
#
# Status: layout stub for pack rules — populate before shipping offline CEval.
