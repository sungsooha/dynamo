#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_PATH:?MODEL_PATH must point to the mounted Nemotron Ultra model view}"

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export TRTLLM_NO_USAGE_STATS=1
export HF_MODULES_CACHE="${HF_MODULES_CACHE:-/tmp/hf_modules}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/cache}"
export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-/tmp/torch_extensions}"

FRONTEND_PORT="${FRONTEND_PORT:-18000}"
DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-file}"
DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
DYN_FILE_KV="${DYN_FILE_KV:-/tmp/dynamo_store_kv_trtllm_a9_${FRONTEND_PORT}}"
DYN_SYSTEM_PORT="${DYN_SYSTEM_PORT:-19081}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
PREFILL_CVD="${PREFILL_CVD:-0,1,2,3}"
TOOL_PARSER="${TOOL_PARSER:-nemotron_nano}"
REASONING_PARSER="${REASONING_PARSER:-nemotron_nano}"
PREFILL_ENGINE_ARGS="${PREFILL_ENGINE_ARGS:-/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/configs/prefill-reuseprobe.yaml}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

export DYN_DISCOVERY_BACKEND
export DYN_REQUEST_PLANE
export DYN_EVENT_PLANE
export DYN_FILE_KV
export DYN_SYSTEM_PORT
export CUDA_VISIBLE_DEVICES="${PREFILL_CVD}"

mkdir -p "${LOG_DIR}" "${HF_MODULES_CACHE}" "${XDG_CACHE_HOME}" "${TORCH_EXTENSIONS_DIR}"
exec >"${LOG_DIR}/prefill.log" 2>&1

exec python3 -m dynamo.trtllm \
  --discovery-backend "${DYN_DISCOVERY_BACKEND}" \
  --model-path "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --extra-engine-args "${PREFILL_ENGINE_ARGS}" \
  --modality text \
  --disaggregation-mode prefill \
  --dyn-tool-call-parser "${TOOL_PARSER}" \
  --dyn-reasoning-parser "${REASONING_PARSER}" \
  --publish-events-and-metrics \
  --kv-block-size 32
