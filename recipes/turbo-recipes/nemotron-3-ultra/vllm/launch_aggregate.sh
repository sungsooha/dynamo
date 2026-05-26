#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_PATH:?MODEL_PATH must point to the mounted Nemotron Ultra model view}"

export DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-etcd}"
export DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
export DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
unset DYN_FILE_KV

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL:-INFO}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"
export VLLM_ALLREDUCE_USE_SYMM_MEM="${VLLM_ALLREDUCE_USE_SYMM_MEM:-0}"
export VLLM_SSM_CONV_STATE_LAYOUT="${VLLM_SSM_CONV_STATE_LAYOUT:-DS}"
export VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE="${VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE:-1}"
export DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS="${DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS:-0}"
export HF_MODULES_CACHE="${HF_MODULES_CACHE:-/tmp/hf_modules}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/cache}"
export TORCH_EXTENSIONS_DIR="${TORCH_EXTENSIONS_DIR:-/tmp/torch_extensions}"
export DYN_LOG="${DYN_LOG:-info,dynamo_kv_router=debug,dynamo_llm::kv_router=debug}"

SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
FRONTEND_PORT="${FRONTEND_PORT:-18740}"
TP="${TP:-4}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-32}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-${GPU_MEMORY_UTILIZATION:-0.9}}"
VLLM_BLOCK_SIZE="${VLLM_BLOCK_SIZE:-${BLOCK_SIZE:-64}}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
REASONING_PARSER="${REASONING_PARSER:-nemotron3}"
MAMBA_CACHE_MODE="${MAMBA_CACHE_MODE:-align}"
SPEC_METHOD="${SPEC_METHOD:-}"
SPEC_MODEL="${SPEC_MODEL:-}"
SPEC_TOKENS="${SPEC_TOKENS:-0}"
AGG_WORKERS="${AGG_WORKERS:-1}"
WORKER0_CVD="${WORKER0_CVD:-${WORKER_CVD:-0,1,2,3}}"
WORKER1_CVD="${WORKER1_CVD:-4,5,6,7}"
WORKER0_SYSTEM_PORT="${WORKER0_SYSTEM_PORT:-${WORKER_SYSTEM_PORT:-19901}}"
WORKER1_SYSTEM_PORT="${WORKER1_SYSTEM_PORT:-19902}"
WORKER0_KV_EVENTS_CONFIG="${WORKER0_KV_EVENTS_CONFIG:-${WORKER_KV_EVENTS_CONFIG:-}}"
WORKER1_KV_EVENTS_CONFIG="${WORKER1_KV_EVENTS_CONFIG:-}"
if [ -z "${WORKER0_KV_EVENTS_CONFIG}" ]; then
  WORKER0_KV_EVENTS_CONFIG='{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:5571","enable_kv_cache_events":true}'
fi
if [ -z "${WORKER1_KV_EVENTS_CONFIG}" ]; then
  WORKER1_KV_EVENTS_CONFIG='{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:5572","enable_kv_cache_events":true}'
fi
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

export MODEL_PATH SERVED_MODEL_NAME FRONTEND_PORT TP MAX_MODEL_LEN MAX_NUM_SEQS
export MAX_BATCHED_TOKENS VLLM_GPU_MEMORY_UTILIZATION VLLM_BLOCK_SIZE
export TOOL_PARSER REASONING_PARSER MAMBA_CACHE_MODE
export SPEC_METHOD SPEC_MODEL SPEC_TOKENS AGG_WORKERS
export WORKER0_CVD WORKER1_CVD WORKER0_SYSTEM_PORT WORKER1_SYSTEM_PORT
export WORKER0_KV_EVENTS_CONFIG WORKER1_KV_EVENTS_CONFIG LOG_DIR

mkdir -p "${LOG_DIR}" "${LOG_DIR}/status"
trap 'jobs -pr | xargs -r kill; wait || true' EXIT

if [ "${AGG_WORKERS}" != "1" ] && [ "${AGG_WORKERS}" != "2" ]; then
  echo "AGG_WORKERS must be 1 or 2, got ${AGG_WORKERS}" >&2
  exit 2
fi

python3 - <<'PY' >"${LOG_DIR}/aggregate_config_probe.log" 2>&1
import json
import os

keys = [
    "MODEL_PATH",
    "SERVED_MODEL_NAME",
    "DYN_DISCOVERY_BACKEND",
    "DYN_REQUEST_PLANE",
    "DYN_EVENT_PLANE",
    "VLLM_SSM_CONV_STATE_LAYOUT",
    "MAX_MODEL_LEN",
    "MAX_NUM_SEQS",
    "MAX_BATCHED_TOKENS",
    "VLLM_BLOCK_SIZE",
    "SPEC_METHOD",
    "SPEC_MODEL",
    "SPEC_TOKENS",
    "AGG_WORKERS",
    "WORKER0_CVD",
    "WORKER1_CVD",
    "WORKER0_SYSTEM_PORT",
    "WORKER1_SYSTEM_PORT",
]
for key in keys:
    print(key, os.environ.get(key))
for key in ["WORKER0_KV_EVENTS_CONFIG", "WORKER1_KV_EVENTS_CONFIG"]:
    raw = os.environ.get(key)
    print(key, raw)
    if raw:
        print(f"{key}_keys", sorted(json.loads(raw)))
PY

common_worker_args=(
  --discovery-backend "${DYN_DISCOVERY_BACKEND}"
  --request-plane "${DYN_REQUEST_PLANE}"
  --event-plane "${DYN_EVENT_PLANE}"
  --model "${MODEL_PATH}"
  --served-model-name "${SERVED_MODEL_NAME}"
  --tensor-parallel-size "${TP}"
  --trust-remote-code
  --max-model-len "${MAX_MODEL_LEN}"
  --max-num-seqs "${MAX_NUM_SEQS}"
  --max-num-batched-tokens "${MAX_BATCHED_TOKENS}"
  --gpu-memory-utilization "${VLLM_GPU_MEMORY_UTILIZATION}"
  --block-size "${VLLM_BLOCK_SIZE}"
  --enable-expert-parallel
  --mamba-cache-mode "${MAMBA_CACHE_MODE}"
  --enable-prefix-caching
  --no-disable-hybrid-kv-cache-manager
  --dyn-tool-call-parser "${TOOL_PARSER}"
  --dyn-reasoning-parser "${REASONING_PARSER}"
  --reasoning-parser-plugin "${MODEL_PATH}/ultra_v3_reasoning_parser.py"
  --reasoning-parser nemotron_v3
)

speculative_args=()
if [ "${SPEC_TOKENS}" != "0" ]; then
  if [ -z "${SPEC_METHOD}" ]; then
    echo "SPEC_METHOD must be set when SPEC_TOKENS=${SPEC_TOKENS}" >&2
    exit 2
  fi
  speculative_args+=(--spec-method "${SPEC_METHOD}" --spec-tokens "${SPEC_TOKENS}")
  if [ -n "${SPEC_MODEL}" ]; then
    speculative_args+=(--spec-model "${SPEC_MODEL}")
  fi
fi

frontend_args=(
  --discovery-backend "${DYN_DISCOVERY_BACKEND}"
  --request-plane "${DYN_REQUEST_PLANE}"
  --event-plane "${DYN_EVENT_PLANE}"
  --router-mode kv
  --router-kv-events
  --kv-cache-block-size "${VLLM_BLOCK_SIZE}"
  --router-reset-states
  --http-host 0.0.0.0
  --http-port "${FRONTEND_PORT}"
)

printf '%q ' python3 -m dynamo.frontend "${frontend_args[@]}" >"${LOG_DIR}/status/vllm_frontend_command.txt"
printf '\n' >>"${LOG_DIR}/status/vllm_frontend_command.txt"
printf '%q ' python3 -m dynamo.vllm "${common_worker_args[@]}" "${speculative_args[@]}" --kv-events-config "${WORKER0_KV_EVENTS_CONFIG}" >"${LOG_DIR}/status/vllm_worker0_command.txt"
printf '\n' >>"${LOG_DIR}/status/vllm_worker0_command.txt"
if [ "${AGG_WORKERS}" = "1" ]; then
  cp "${LOG_DIR}/status/vllm_worker0_command.txt" "${LOG_DIR}/status/vllm_worker_command.txt"
else
  printf '%q ' python3 -m dynamo.vllm "${common_worker_args[@]}" "${speculative_args[@]}" --kv-events-config "${WORKER1_KV_EVENTS_CONFIG}" >"${LOG_DIR}/status/vllm_worker1_command.txt"
  printf '\n' >>"${LOG_DIR}/status/vllm_worker1_command.txt"
fi

python3 -m dynamo.frontend "${frontend_args[@]}" >"${LOG_DIR}/frontend.log" 2>&1 &
echo "$!" >"${LOG_DIR}/status/vllm_frontend.pid"

CUDA_VISIBLE_DEVICES="${WORKER0_CVD}" DYN_SYSTEM_PORT="${WORKER0_SYSTEM_PORT}" \
python3 -m dynamo.vllm "${common_worker_args[@]}" "${speculative_args[@]}" --kv-events-config "${WORKER0_KV_EVENTS_CONFIG}" \
  >"${LOG_DIR}/aggregate_worker0.log" 2>&1 &
echo "$!" >"${LOG_DIR}/status/vllm_worker.pid"
echo "$!" >"${LOG_DIR}/status/vllm_worker0.pid"

if [ "${AGG_WORKERS}" = "2" ]; then
  CUDA_VISIBLE_DEVICES="${WORKER1_CVD}" DYN_SYSTEM_PORT="${WORKER1_SYSTEM_PORT}" \
  python3 -m dynamo.vllm "${common_worker_args[@]}" "${speculative_args[@]}" --kv-events-config "${WORKER1_KV_EVENTS_CONFIG}" \
    >"${LOG_DIR}/aggregate_worker1.log" 2>&1 &
  echo "$!" >"${LOG_DIR}/status/vllm_worker1.pid"
fi

wait -n
