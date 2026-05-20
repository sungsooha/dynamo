#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_PATH:?MODEL_PATH must point to the mounted Nemotron Ultra model view}"

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export SGLANG_DISABLE_DEEP_GEMM="${SGLANG_DISABLE_DEEP_GEMM:-1}"
export SGLANG_APPLY_CONFIG_BACKUP="${SGLANG_APPLY_CONFIG_BACKUP:-none}"

DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-etcd}"
DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
DYN_SYSTEM_PORT="${DYN_SYSTEM_PORT:-19782}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
TP="${TP:-4}"
SGLANG_EP_SIZE="${SGLANG_EP_SIZE:-4}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
SGLANG_MEM_FRACTION_STATIC="${SGLANG_MEM_FRACTION_STATIC:-0.85}"
SGLANG_FP8_GEMM_BACKEND="${SGLANG_FP8_GEMM_BACKEND:-triton}"
SGLANG_FP4_GEMM_BACKEND="${SGLANG_FP4_GEMM_BACKEND:-auto}"
SGLANG_MOE_A2A_BACKEND="${SGLANG_MOE_A2A_BACKEND:-none}"
SGLANG_MOE_RUNNER_BACKEND="${SGLANG_MOE_RUNNER_BACKEND:-flashinfer_trtllm}"
SGLANG_MAMBA_SCHEDULER_STRATEGY="${SGLANG_MAMBA_SCHEDULER_STRATEGY:-no_buffer}"
TOOL_PARSER="${SGLANG_DYN_TOOL_CALL_PARSER:-qwen3_coder}"
REASONING_PARSER="${SGLANG_DYN_REASONING_PARSER:-nemotron3}"
CUDA_VISIBLE_DEVICES="${DECODE_CVD:-4,5,6,7}"
BOOTSTRAP_PORT="${BOOTSTRAP_PORT:-12345}"
SGLANG_DECODE_PORT="${SGLANG_DECODE_PORT:-40001}"
SGLANG_DECODE_KV_EVENTS_CONFIG="${SGLANG_DECODE_KV_EVENTS_CONFIG:-{\"publisher\":\"zmq\",\"topic\":\"kv-events\",\"endpoint\":\"tcp://*:5560\"}}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

if [[ "${DYN_DISCOVERY_BACKEND}" != "file" ]]; then
  unset DYN_FILE_KV
fi

export DYN_SYSTEM_PORT
export CUDA_VISIBLE_DEVICES

mkdir -p "${LOG_DIR}"
if [[ -n "${SGLANG_FLASHINFER_TMPFS:-}" ]]; then
  mkdir -p "${SGLANG_FLASHINFER_TMPFS}"
  touch "${SGLANG_FLASHINFER_TMPFS}/write_probe"
  rm -f "${SGLANG_FLASHINFER_TMPFS}/write_probe"
fi

exec >"${LOG_DIR}/decode.log" 2>&1

exec python3 -m dynamo.sglang \
  --discovery-backend "${DYN_DISCOVERY_BACKEND}" \
  --request-plane "${DYN_REQUEST_PLANE}" \
  --event-plane "${DYN_EVENT_PLANE}" \
  --model-path "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --tp-size "${TP}" \
  --ep-size "${SGLANG_EP_SIZE}" \
  --trust-remote-code \
  --host 0.0.0.0 \
  --context-length "${MAX_MODEL_LEN}" \
  --mem-fraction-static "${SGLANG_MEM_FRACTION_STATIC}" \
  --chunked-prefill-size "${MAX_BATCHED_TOKENS}" \
  --mamba-scheduler-strategy "${SGLANG_MAMBA_SCHEDULER_STRATEGY}" \
  --fp8-gemm-backend "${SGLANG_FP8_GEMM_BACKEND}" \
  --fp4-gemm-backend "${SGLANG_FP4_GEMM_BACKEND}" \
  --moe-a2a-backend "${SGLANG_MOE_A2A_BACKEND}" \
  --moe-runner-backend "${SGLANG_MOE_RUNNER_BACKEND}" \
  --enable-metrics \
  --dyn-tool-call-parser "${TOOL_PARSER}" \
  --dyn-reasoning-parser "${REASONING_PARSER}" \
  --disaggregation-mode decode \
  --disaggregation-bootstrap-port "${BOOTSTRAP_PORT}" \
  --disaggregation-transfer-backend nixl \
  --port "${SGLANG_DECODE_PORT}" \
  --kv-events-config "${SGLANG_DECODE_KV_EVENTS_CONFIG}"
