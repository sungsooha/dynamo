#!/usr/bin/env bash
set -euo pipefail

: "${BASE_URL:?BASE_URL must point to the Dynamo frontend, for example http://127.0.0.1:18740}"

MODEL="${MODEL:-nemotron-ultra-ea}"
TOKENIZER_PATH="${TOKENIZER_PATH:-/opt/models/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/artifacts/aiperf_synthetic_shared_prefix}"
CONCURRENCY="${CONCURRENCY:-16}"
WORKERS_MAX="${WORKERS_MAX:-${CONCURRENCY}}"
REQUEST_COUNT="${REQUEST_COUNT:-64}"
SYSTEM_PROMPT_TOKENS="${SYSTEM_PROMPT_TOKENS:-5734}"
USER_CONTEXT_PROMPT_LENGTH="${USER_CONTEXT_PROMPT_LENGTH:-2432}"
SYNTHETIC_INPUT_TOKENS_MEAN="${SYNTHETIC_INPUT_TOKENS_MEAN:-26}"
OSL="${OSL:-1024}"
RANDOM_SEED="${RANDOM_SEED:-42}"

mkdir -p "${ARTIFACT_DIR}"

COLUMNS=240 exec aiperf profile \
  -m "${MODEL}" \
  -u "${BASE_URL}" \
  --endpoint v1/chat/completions \
  --endpoint-type chat \
  --streaming \
  --concurrency "${CONCURRENCY}" \
  --workers-max "${WORKERS_MAX}" \
  --request-count "${REQUEST_COUNT}" \
  --num-dataset-entries "${REQUEST_COUNT}" \
  --shared-system-prompt-length "${SYSTEM_PROMPT_TOKENS}" \
  --user-context-prompt-length "${USER_CONTEXT_PROMPT_LENGTH}" \
  --synthetic-input-tokens-mean "${SYNTHETIC_INPUT_TOKENS_MEAN}" \
  --synthetic-input-tokens-stddev 0 \
  --output-tokens-mean "${OSL}" \
  --output-tokens-stddev 0 \
  --tokenizer "${TOKENIZER_PATH}" \
  --tokenizer-trust-remote-code \
  --extra-inputs "min_tokens:${OSL}" \
  --extra-inputs ignore_eos:true \
  --use-server-token-count \
  --random-seed "${RANDOM_SEED}" \
  --export-level records \
  --artifact-dir "${ARTIFACT_DIR}"
