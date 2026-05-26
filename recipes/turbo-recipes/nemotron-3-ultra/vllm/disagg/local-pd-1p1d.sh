#!/usr/bin/env bash
set -euo pipefail

# Local direct-Docker 1P1D P/D smoke for the Ultra vLLM recipe image.
# It starts etcd, frontend, one TP4 prefill worker, and one TP4 decode worker.
# Set KEEP_RUNNING=1 to leave containers up for a follow-up AIPerf command.

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${RECIPE_DIR}/../../../.." && pwd)"

: "${HOST_MODEL_PATH:?Set HOST_MODEL_PATH to the host path of the Ultra model view}"

IMAGE="${IMAGE:-nemotron-3-ultra-vllm-turbo:dev}"
DOCKER_CMD="${DOCKER_CMD:-docker}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-/tmp/nemotron-ultra/local-pd-1p1d-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_TS="${RUN_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
PREFIX="${CONTAINER_PREFIX:-ultra-vllm-pd1p1d-${RUN_TS}}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"
LEAVE_RUNNING=0

MODEL_VIEW_NAME="$(basename "${HOST_MODEL_PATH}")"
HOST_MODEL_PARENT="$(dirname "${HOST_MODEL_PATH}")"
HOST_MODEL_GRANDPARENT="$(dirname "${HOST_MODEL_PARENT}")"
if [ "$(basename "${HOST_MODEL_PARENT}")" = "patched" ] && [ -d "${HOST_MODEL_GRANDPARENT}/hub" ]; then
  HOST_MODEL_MOUNT_ROOT="${HOST_MODEL_MOUNT_ROOT:-${HOST_MODEL_GRANDPARENT}}"
  CONTAINER_MODEL_MOUNT_ROOT="${CONTAINER_MODEL_MOUNT_ROOT:-/opt/models}"
  CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-${CONTAINER_MODEL_MOUNT_ROOT}/patched/${MODEL_VIEW_NAME}}"
else
  HOST_MODEL_MOUNT_ROOT="${HOST_MODEL_MOUNT_ROOT:-${HOST_MODEL_PATH}}"
  CONTAINER_MODEL_MOUNT_ROOT="${CONTAINER_MODEL_MOUNT_ROOT:-/model}"
  CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-/model}"
fi

FRONTEND_PORT="${FRONTEND_PORT:-18740}"
ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-2379}"
ETCD_PEER_PORT="${ETCD_PEER_PORT:-2380}"
ETCD_IMAGE="${ETCD_IMAGE:-gcr.io/etcd-development/etcd:v3.6.7}"
PREFILL_GPU_SET="${PREFILL_GPU_SET:-0,1,2,3}"
DECODE_GPU_SET="${DECODE_GPU_SET:-4,5,6,7}"
PREFILL_GPU_REQUEST="${PREFILL_GPU_REQUEST:-\"device=${PREFILL_GPU_SET}\"}"
DECODE_GPU_REQUEST="${DECODE_GPU_REQUEST:-\"device=${DECODE_GPU_SET}\"}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-32}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
BLOCK_SIZE="${BLOCK_SIZE:-64}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.9}"
SPEC_METHOD="${SPEC_METHOD:-nemotron_h_mtp}"
SPEC_TOKENS="${SPEC_TOKENS:-1}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-1800}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-10}"

ETCD_CONTAINER="${PREFIX}-etcd"
FRONTEND_CONTAINER="${PREFIX}-frontend"
PREFILL_CONTAINER="${PREFIX}-prefill"
DECODE_CONTAINER="${PREFIX}-decode"

read -r -a docker_cmd <<<"${DOCKER_CMD}"
host_uid="$(id -u)"
host_gid="$(id -g)"

mkdir -p "${ARTIFACT_ROOT}"/{commands,logs,smoke,cleanup}
: >"${ARTIFACT_ROOT}/status.jsonl"
: >"${ARTIFACT_ROOT}/failures.jsonl"

event() {
  local status="$1"; shift
  local stage="$1"; shift
  local message="$*"
  python3 - "$ARTIFACT_ROOT/status.jsonl" "$status" "$stage" "$message" <<'PY'
import json, sys, time
path, status, stage, message = sys.argv[1:5]
row = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": status,
    "stage": stage,
    "message": message,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, sort_keys=True) + "\n")
PY
}

write_cmd() {
  local name="$1"; shift
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf '%q ' "$@"
    printf '\n'
  } >"${ARTIFACT_ROOT}/commands/${name}.sh"
  chmod +x "${ARTIFACT_ROOT}/commands/${name}.sh"
}

collect_logs() {
  "${docker_cmd[@]}" logs "${ETCD_CONTAINER}" >"${ARTIFACT_ROOT}/logs/etcd.log" 2>&1 || true
  "${docker_cmd[@]}" logs "${FRONTEND_CONTAINER}" >"${ARTIFACT_ROOT}/logs/frontend.container.log" 2>&1 || true
  "${docker_cmd[@]}" logs "${PREFILL_CONTAINER}" >"${ARTIFACT_ROOT}/logs/prefill.container.log" 2>&1 || true
  "${docker_cmd[@]}" logs "${DECODE_CONTAINER}" >"${ARTIFACT_ROOT}/logs/decode.container.log" 2>&1 || true
}

cleanup() {
  set +e
  collect_logs
  if [ "${LEAVE_RUNNING}" != "1" ]; then
    "${docker_cmd[@]}" rm -f "${DECODE_CONTAINER}" "${PREFILL_CONTAINER}" "${FRONTEND_CONTAINER}" "${ETCD_CONTAINER}" \
      >"${ARTIFACT_ROOT}/cleanup/docker_rm.log" 2>&1
  fi
  "${docker_cmd[@]}" ps -a >"${ARTIFACT_ROOT}/cleanup/docker_ps_after.txt" 2>&1
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv \
      >"${ARTIFACT_ROOT}/cleanup/gpu_after.csv" 2>&1
  fi
}
trap cleanup EXIT

python3 - "$ARTIFACT_ROOT/run_config.json" <<PY
import json, time
payload = {
  "artifact_root": "${ARTIFACT_ROOT}",
  "image": "${IMAGE}",
  "model": "${SERVED_MODEL_NAME}",
  "topology": "PD_1P1D",
  "tp_per_worker": 4,
  "prefill_gpu_set": "${PREFILL_GPU_SET}",
  "decode_gpu_set": "${DECODE_GPU_SET}",
  "max_model_len": int("${MAX_MODEL_LEN}"),
  "max_num_seqs": int("${MAX_NUM_SEQS}"),
  "max_batched_tokens": int("${MAX_BATCHED_TOKENS}"),
  "block_size": int("${BLOCK_SIZE}"),
  "spec_method": "${SPEC_METHOD}",
  "spec_tokens": int("${SPEC_TOKENS}"),
  "kv_transfer": "NixlConnector kv_both",
  "mamba_cache_mode": "align",
  "prefix_cache": True,
  "updated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
open("${ARTIFACT_ROOT}/run_config.json", "w", encoding="utf-8").write(
    json.dumps(payload, indent=2, sort_keys=True) + "\\n"
)
PY

"${docker_cmd[@]}" rm -f "${DECODE_CONTAINER}" "${PREFILL_CONTAINER}" "${FRONTEND_CONTAINER}" "${ETCD_CONTAINER}" >/dev/null 2>&1 || true

etcd_cmd=(
  "${docker_cmd[@]}" run -d --network host --name "${ETCD_CONTAINER}" "${ETCD_IMAGE}"
  etcd --name default --data-dir "/tmp/${ETCD_CONTAINER}"
  --listen-client-urls "http://0.0.0.0:${ETCD_CLIENT_PORT}"
  --advertise-client-urls "http://127.0.0.1:${ETCD_CLIENT_PORT}"
  --listen-peer-urls "http://0.0.0.0:${ETCD_PEER_PORT}"
  --initial-advertise-peer-urls "http://127.0.0.1:${ETCD_PEER_PORT}"
  --initial-cluster "default=http://127.0.0.1:${ETCD_PEER_PORT}"
)
write_cmd etcd "${etcd_cmd[@]}"
"${etcd_cmd[@]}" >"${ARTIFACT_ROOT}/logs/etcd.container_id"
sleep 2

common_env=(
  -e HOME=/tmp
  -e USER="$(id -un)"
  -e LOGNAME="$(id -un)"
  -e MODEL_PATH="${CONTAINER_MODEL_PATH}"
  -e SERVED_MODEL_NAME="${SERVED_MODEL_NAME}"
  -e DYN_DISCOVERY_BACKEND=etcd
  -e DYN_REQUEST_PLANE=tcp
  -e DYN_EVENT_PLANE=zmq
  -e ETCD_ENDPOINTS="http://127.0.0.1:${ETCD_CLIENT_PORT}"
  -e MAX_MODEL_LEN="${MAX_MODEL_LEN}"
  -e MAX_NUM_SEQS="${MAX_NUM_SEQS}"
  -e MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS}"
  -e VLLM_GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION}"
  -e VLLM_BLOCK_SIZE="${BLOCK_SIZE}"
  -e SPEC_METHOD="${SPEC_METHOD}"
  -e SPEC_TOKENS="${SPEC_TOKENS}"
  -e VLLM_SSM_CONV_STATE_LAYOUT=DS
  -e VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE=1
  -e DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS=0
  -e VLLM_WORKER_MULTIPROC_METHOD=spawn
  -e VLLM_ALLREDUCE_USE_SYMM_MEM=0
  -e DYN_LOG=info,dynamo_kv_router=debug,dynamo_llm::kv_router=debug
  -e HF_MODULES_CACHE=/tmp/hf_modules
  -e XDG_CACHE_HOME=/tmp/cache
  -e TORCH_EXTENSIONS_DIR=/tmp/torch_extensions
  -v "${HOST_MODEL_MOUNT_ROOT}:${CONTAINER_MODEL_MOUNT_ROOT}:ro"
  -v "${ARTIFACT_ROOT}:/artifacts"
)

frontend_cmd=(
  "${docker_cmd[@]}" run -d --name "${FRONTEND_CONTAINER}" --network host
  -e FRONTEND_PORT="${FRONTEND_PORT}"
  -e LOG_DIR=/artifacts/frontend
  -e DYN_DISCOVERY_BACKEND=etcd
  -e DYN_REQUEST_PLANE=tcp
  -e DYN_EVENT_PLANE=zmq
  -e ETCD_ENDPOINTS="http://127.0.0.1:${ETCD_CLIENT_PORT}"
  -e VLLM_BLOCK_SIZE="${BLOCK_SIZE}"
  -v "${ARTIFACT_ROOT}:/artifacts"
  "${IMAGE}" bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_frontend.sh
)
write_cmd frontend "${frontend_cmd[@]}"
"${frontend_cmd[@]}" >"${ARTIFACT_ROOT}/logs/frontend.container_id"

prefill_cmd=(
  "${docker_cmd[@]}" run -d --name "${PREFILL_CONTAINER}" --network host --ipc host
  --user "${host_uid}:${host_gid}" --gpus "${PREFILL_GPU_REQUEST}"
  --tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
  --tmpfs /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
  --ulimit memlock=-1 --ulimit stack=67108864 --cap-add IPC_LOCK --cap-add SYS_RESOURCE
  "${common_env[@]}"
  -e PREFILL_CVD="${PREFILL_GPU_SET}"
  -e DYN_SYSTEM_PORT=19601
  -e VLLM_NIXL_SIDE_CHANNEL_PORT=5641
  -e LOG_DIR=/artifacts/prefill
  "${IMAGE}" bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_prefill.sh
)
write_cmd prefill "${prefill_cmd[@]}"
"${prefill_cmd[@]}" >"${ARTIFACT_ROOT}/logs/prefill.container_id"

decode_cmd=(
  "${docker_cmd[@]}" run -d --name "${DECODE_CONTAINER}" --network host --ipc host
  --user "${host_uid}:${host_gid}" --gpus "${DECODE_GPU_REQUEST}"
  --tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
  --tmpfs /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
  --ulimit memlock=-1 --ulimit stack=67108864 --cap-add IPC_LOCK --cap-add SYS_RESOURCE
  "${common_env[@]}"
  -e DECODE_CVD="${DECODE_GPU_SET}"
  -e DYN_SYSTEM_PORT=19602
  -e VLLM_NIXL_SIDE_CHANNEL_PORT=5642
  -e LOG_DIR=/artifacts/decode
  "${IMAGE}" bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_decode.sh
)
write_cmd decode "${decode_cmd[@]}"
"${decode_cmd[@]}" >"${ARTIFACT_ROOT}/logs/decode.container_id"

event RUNNING endpoint "waiting for /health"
deadline=$((SECONDS + READY_TIMEOUT_S))
healthy=0
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/health" >"${ARTIFACT_ROOT}/smoke/health.json"; then
    event PASS endpoint "/health passed"
    healthy=1
    break
  fi
  for name in "${FRONTEND_CONTAINER}" "${PREFILL_CONTAINER}" "${DECODE_CONTAINER}"; do
    if ! "${docker_cmd[@]}" ps --format '{{.Names}}' | grep -qx "${name}"; then
      event FAIL endpoint "container exited before health: ${name}"
      exit 1
    fi
  done
  sleep "${POLL_INTERVAL_S}"
done
if [ "${healthy}" != "1" ]; then
  event FAIL endpoint "/health timeout"
  exit 1
fi

curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/v1/models" >"${ARTIFACT_ROOT}/smoke/models.json"
python3 - "${ARTIFACT_ROOT}/smoke/models.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
model = data["data"][0]
assert model.get("id") == "nemotron-ultra-ea", model
assert int(model.get("max_model_len") or model.get("context_window") or 0) == 262144, model
PY
event PASS endpoint "/v1/models passed"

cat >"${ARTIFACT_ROOT}/smoke/chat_payload.json" <<'JSON'
{"model":"nemotron-ultra-ea","messages":[{"role":"user","content":"Reply exactly: recipe pd smoke ok"}],"max_tokens":64,"temperature":0}
JSON
curl -fsS -H 'Content-Type: application/json' \
  -d @"${ARTIFACT_ROOT}/smoke/chat_payload.json" \
  "http://127.0.0.1:${FRONTEND_PORT}/v1/chat/completions" \
  >"${ARTIFACT_ROOT}/smoke/chat_response.json"
event PASS endpoint "short chat passed"

python3 - "$ARTIFACT_ROOT/run_status.json" <<PY
import json, time, sys
payload = {
  "status": "PASS",
  "failure_class": "none",
  "artifact_root": "${ARTIFACT_ROOT}",
  "topology": "PD_1P1D",
  "image": "${IMAGE}",
  "dashboard_row_ready": "no",
  "keep_running": "${KEEP_RUNNING}",
  "updated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(payload, indent=2, sort_keys=True) + "\\n")
PY

if [ "${KEEP_RUNNING}" = "1" ]; then
  LEAVE_RUNNING=1
  trap - EXIT
  collect_logs
  cat <<EOF
P/D 1P1D server is running.
Frontend: http://127.0.0.1:${FRONTEND_PORT}
Artifact root: ${ARTIFACT_ROOT}
Cleanup:
  ${DOCKER_CMD} rm -f ${DECODE_CONTAINER} ${PREFILL_CONTAINER} ${FRONTEND_CONTAINER} ${ETCD_CONTAINER}
EOF
else
  event PASS cleanup "KEEP_RUNNING=0; cleanup will run on exit"
fi
