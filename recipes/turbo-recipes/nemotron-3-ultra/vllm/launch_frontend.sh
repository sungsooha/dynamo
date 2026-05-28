#!/usr/bin/env bash
set -euo pipefail

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export DYN_LOG="${DYN_LOG:-info,dynamo_kv_router=debug,dynamo_llm::kv_router=debug}"

FRONTEND_PORT="${FRONTEND_PORT:-18740}"
ENABLE_REASONING_API_PROXY="${ENABLE_REASONING_API_PROXY:-0}"
INNER_FRONTEND_PORT="${INNER_FRONTEND_PORT:-18741}"
FRONTEND_BIND_PORT="${FRONTEND_PORT}"
if [ "${ENABLE_REASONING_API_PROXY}" = "1" ]; then
  FRONTEND_BIND_PORT="${INNER_FRONTEND_PORT}"
fi
DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-etcd}"
DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
VLLM_BLOCK_SIZE="${VLLM_BLOCK_SIZE:-64}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

if [[ "${DYN_DISCOVERY_BACKEND}" != "file" ]]; then
  unset DYN_FILE_KV
fi

mkdir -p "${LOG_DIR}" "${LOG_DIR}/status"
trap 'jobs -pr | xargs -r kill; wait || true' EXIT

frontend_args=(
  --discovery-backend "${DYN_DISCOVERY_BACKEND}" \
  --request-plane "${DYN_REQUEST_PLANE}" \
  --event-plane "${DYN_EVENT_PLANE}" \
  --router-mode kv \
  --router-kv-events \
  --kv-cache-block-size "${VLLM_BLOCK_SIZE}" \
  --router-reset-states \
  --http-host 0.0.0.0 \
  --http-port "${FRONTEND_BIND_PORT}"
)

printf '%q ' python -m dynamo.frontend "${frontend_args[@]}" >"${LOG_DIR}/status/vllm_frontend_command.txt"
printf '\n' >>"${LOG_DIR}/status/vllm_frontend_command.txt"

if [ "${ENABLE_REASONING_API_PROXY}" = "1" ]; then
  printf '%q ' python3 /opt/nemotron-ultra/reasoning_api_compat_proxy.py \
    --listen-host 0.0.0.0 \
    --listen-port "${FRONTEND_PORT}" \
    --upstream "http://127.0.0.1:${FRONTEND_BIND_PORT}" \
    --model-path "${MODEL_PATH:-}" \
    >"${LOG_DIR}/status/reasoning_proxy_command.txt"
  printf '\n' >>"${LOG_DIR}/status/reasoning_proxy_command.txt"

  python -m dynamo.frontend "${frontend_args[@]}" >"${LOG_DIR}/frontend.log" 2>&1 &
  echo "$!" >"${LOG_DIR}/status/vllm_frontend.pid"

  python3 /opt/nemotron-ultra/reasoning_api_compat_proxy.py \
    --listen-host 0.0.0.0 \
    --listen-port "${FRONTEND_PORT}" \
    --upstream "http://127.0.0.1:${FRONTEND_BIND_PORT}" \
    --model-path "${MODEL_PATH:-}" \
    >"${LOG_DIR}/reasoning_proxy.log" 2>&1 &
  echo "$!" >"${LOG_DIR}/status/reasoning_proxy.pid"

  wait -n
else
  exec python -m dynamo.frontend "${frontend_args[@]}" >"${LOG_DIR}/frontend.log" 2>&1
fi
