#!/usr/bin/env bash
set -euo pipefail

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export DYN_LOG="${DYN_LOG:-info,dynamo_kv_router=debug,dynamo_llm::kv_router=debug}"

FRONTEND_PORT="${FRONTEND_PORT:-18880}"
DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-etcd}"
DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
FRONTEND_ROUTER_MODE="${FRONTEND_ROUTER_MODE:-kv}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

if [[ "${DYN_DISCOVERY_BACKEND}" != "file" ]]; then
  unset DYN_FILE_KV
fi

mkdir -p "${LOG_DIR}"
exec >"${LOG_DIR}/frontend.log" 2>&1

exec python3 -m dynamo.frontend \
  --discovery-backend "${DYN_DISCOVERY_BACKEND}" \
  --request-plane "${DYN_REQUEST_PLANE}" \
  --event-plane "${DYN_EVENT_PLANE}" \
  --router-mode "${FRONTEND_ROUTER_MODE}" \
  --router-kv-events \
  --http-host 0.0.0.0 \
  --http-port "${FRONTEND_PORT}"
