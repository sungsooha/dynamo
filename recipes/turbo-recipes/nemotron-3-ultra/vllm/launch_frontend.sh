#!/usr/bin/env bash
set -euo pipefail

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export DYN_LOG="${DYN_LOG:-info,dynamo_kv_router=debug,dynamo_llm::kv_router=debug}"

FRONTEND_PORT="${FRONTEND_PORT:-18740}"
DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-etcd}"
DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
VLLM_BLOCK_SIZE="${VLLM_BLOCK_SIZE:-64}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

if [[ "${DYN_DISCOVERY_BACKEND}" != "file" ]]; then
  unset DYN_FILE_KV
fi

mkdir -p "${LOG_DIR}"
exec >"${LOG_DIR}/frontend.log" 2>&1

exec python -m dynamo.frontend \
  --discovery-backend "${DYN_DISCOVERY_BACKEND}" \
  --request-plane "${DYN_REQUEST_PLANE}" \
  --event-plane "${DYN_EVENT_PLANE}" \
  --router-mode kv \
  --router-kv-events \
  --kv-cache-block-size "${VLLM_BLOCK_SIZE}" \
  --router-reset-states \
  --http-host 0.0.0.0 \
  --http-port "${FRONTEND_PORT}"
