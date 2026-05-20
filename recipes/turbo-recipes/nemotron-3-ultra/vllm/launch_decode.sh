#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_PATH:?MODEL_PATH must point to the mounted Nemotron Ultra model view}"

export PYTHONHASHSEED="${PYTHONHASHSEED:-0}"
export VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL:-INFO}"
export VLLM_WORKER_MULTIPROC_METHOD="${VLLM_WORKER_MULTIPROC_METHOD:-spawn}"
export VLLM_ALLREDUCE_USE_SYMM_MEM="${VLLM_ALLREDUCE_USE_SYMM_MEM:-0}"
export VLLM_NIXL_SIDE_CHANNEL_HOST="${VLLM_NIXL_SIDE_CHANNEL_HOST:-127.0.0.1}"
export VLLM_NIXL_SIDE_CHANNEL_PORT="${VLLM_NIXL_SIDE_CHANNEL_PORT:-5642}"
export VLLM_SSM_CONV_STATE_LAYOUT="${VLLM_SSM_CONV_STATE_LAYOUT:-DS}"
export VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE="${VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE:-1}"
export DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS="${DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS:-0}"

DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-etcd}"
DYN_REQUEST_PLANE="${DYN_REQUEST_PLANE:-tcp}"
DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-zmq}"
DYN_SYSTEM_PORT="${DYN_SYSTEM_PORT:-19602}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
TP="${TP:-4}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.9}"
VLLM_BLOCK_SIZE="${VLLM_BLOCK_SIZE:-64}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
REASONING_PARSER="${REASONING_PARSER:-nemotron3}"
CUDA_VISIBLE_DEVICES="${DECODE_CVD:-4,5,6,7}"
LOG_DIR="${LOG_DIR:-/tmp/nemotron-ultra}"

if [[ "${DYN_DISCOVERY_BACKEND}" != "file" ]]; then
  unset DYN_FILE_KV
fi

export DYN_SYSTEM_PORT
export CUDA_VISIBLE_DEVICES

mkdir -p "${LOG_DIR}"
exec >"${LOG_DIR}/decode.log" 2>&1

exec python -m dynamo.vllm \
  --discovery-backend "${DYN_DISCOVERY_BACKEND}" \
  --request-plane "${DYN_REQUEST_PLANE}" \
  --event-plane "${DYN_EVENT_PLANE}" \
  --model "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --tensor-parallel-size "${TP}" \
  --trust-remote-code \
  --max-model-len "${MAX_MODEL_LEN}" \
  --max-num-seqs "${MAX_NUM_SEQS}" \
  --max-num-batched-tokens "${MAX_BATCHED_TOKENS}" \
  --gpu-memory-utilization "${VLLM_GPU_MEMORY_UTILIZATION}" \
  --block-size "${VLLM_BLOCK_SIZE}" \
  --enable-expert-parallel \
  --mamba-cache-mode align \
  --enable-prefix-caching \
  --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}' \
  --dyn-tool-call-parser "${TOOL_PARSER}" \
  --dyn-reasoning-parser "${REASONING_PARSER}" \
  --reasoning-parser-plugin "${MODEL_PATH}/ultra_v3_reasoning_parser.py" \
  --reasoning-parser nemotron_v3 \
  --no-disable-hybrid-kv-cache-manager \
  --disaggregation-mode decode
