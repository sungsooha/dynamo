#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_PATH:?MODEL_PATH must point to the mounted Nemotron Ultra model view}"

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export TRTLLM_NO_USAGE_STATS=1

FRONTEND_PORT="${FRONTEND_PORT:-18000}"
DYN_FILE_KV="${DYN_FILE_KV:-/tmp/dynamo_store_kv_trtllm_a9_${FRONTEND_PORT}}"
DYN_SYSTEM_PORT="${DYN_SYSTEM_PORT:-19082}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
DECODE_CVD="${DECODE_CVD:-4,5,6,7}"
TOOL_PARSER="${TOOL_PARSER:-nemotron_nano}"
REASONING_PARSER="${REASONING_PARSER:-nemotron_nano}"
DECODE_ENGINE_ARGS="${DECODE_ENGINE_ARGS:-/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/configs/decode-reuseprobe.yaml}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

export DYN_FILE_KV
export DYN_SYSTEM_PORT
export CUDA_VISIBLE_DEVICES="${DECODE_CVD}"

mkdir -p "${LOG_DIR}"
exec >"${LOG_DIR}/decode.log" 2>&1

exec python3 -m dynamo.trtllm \
  --discovery-backend file \
  --model-path "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --extra-engine-args "${DECODE_ENGINE_ARGS}" \
  --modality text \
  --disaggregation-mode decode \
  --dyn-tool-call-parser "${TOOL_PARSER}" \
  --dyn-reasoning-parser "${REASONING_PARSER}" \
  --publish-events-and-metrics \
  --kv-block-size 32
