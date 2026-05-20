#!/usr/bin/env bash
set -euo pipefail

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export DYN_LOG="${DYN_LOG:-info,dynamo_kv_router=debug,dynamo_llm::kv_router=debug}"

FRONTEND_PORT="${FRONTEND_PORT:-18000}"
DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-file}"
DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
DYN_FILE_KV="${DYN_FILE_KV:-/tmp/dynamo_store_kv_trtllm_a9_${FRONTEND_PORT}}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

export DYN_DISCOVERY_BACKEND
export DYN_REQUEST_PLANE
export DYN_EVENT_PLANE
export DYN_FILE_KV
rm -rf "${DYN_FILE_KV}"
mkdir -p "${LOG_DIR}"
exec >"${LOG_DIR}/frontend.log" 2>&1

exec python3 -m dynamo.frontend \
  --discovery-backend "${DYN_DISCOVERY_BACKEND}" \
  --router-mode kv \
  --router-kv-events \
  --kv-cache-block-size 32 \
  --router-kv-overlap-score-weight 1.0 \
  --router-temperature 0.0 \
  --http-host 0.0.0.0 \
  --http-port "${FRONTEND_PORT}"
