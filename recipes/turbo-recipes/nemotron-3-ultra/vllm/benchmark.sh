#!/usr/bin/env bash
set -euo pipefail

# Bounded local direct-Docker smoke for the Ultra vLLM recipe image.
#
# This is a wrun-style evidence packet for image/server validation only. It
# does not run AIPerf or create a throughput row.

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${RECIPE_DIR}/../../../.." && pwd)"

BENCHMARK_MODE="${1:-smoke}"
if [ "$#" -gt 0 ]; then
  shift
fi
if [ "${BENCHMARK_MODE}" = "moontrace30-chat-agg1-mtp-c64" ]; then
  ACTION_ID="${ACTION_ID:-VLLM_OLD_BASE_MOONTRACE30_CHAT_AGG1_MTP_C64}"
  AGG_WORKERS="${AGG_WORKERS:-1}"
  GPU_SET="${GPU_SET:-0,1,2,3}"
  MAX_NUM_SEQS="${MAX_NUM_SEQS:-64}"
  MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
  BLOCK_SIZE="${BLOCK_SIZE:-64}"
  SPEC_METHOD="${SPEC_METHOD:-nemotron_h_mtp}"
  SPEC_TOKENS="${SPEC_TOKENS:-1}"
  ENABLE_REASONING_API_PROXY="${ENABLE_REASONING_API_PROXY:-1}"
  MOONTRACE_WORKLOAD="${MOONTRACE_WORKLOAD:-chat_30pct}"
  MOONTRACE_CONCURRENCY="${MOONTRACE_CONCURRENCY:-64}"
  MOONTRACE_REQUEST_COUNT="${MOONTRACE_REQUEST_COUNT:-3546}"
  MOONTRACE_MAX_OSL="${MOONTRACE_MAX_OSL:-1024}"
  MOONTRACE_SHA256="${MOONTRACE_SHA256:-795a54e9f7fb7699e34a724bc7a14ae1ae9b59eb7523c35f4a5043865aa71866}"
fi

: "${HOST_MODEL_PATH:?Set HOST_MODEL_PATH to the host path of the Ultra model view}"

TRACK="${TRACK:-nemotron-ultra-phase0-v3}"
ACTION_ID="${ACTION_ID:-ULTRA_VLLM_RECIPE_LOCAL_SMOKE}"
IMAGE="${IMAGE:-nemotron-3-ultra-vllm-turbo:dev}"
BUILD_IMAGE="${BUILD_IMAGE:-0}"
DOCKER_CMD="${DOCKER_CMD:-docker}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-/tmp/nemotron-ultra/recipe-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"
USER_CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-}"
MODEL_VIEW_NAME="$(basename "${HOST_MODEL_PATH}")"
HOST_MODEL_PARENT="$(dirname "${HOST_MODEL_PATH}")"
HOST_MODEL_GRANDPARENT="$(dirname "${HOST_MODEL_PARENT}")"
if [ -z "${USER_CONTAINER_MODEL_PATH}" ] && [ "$(basename "${HOST_MODEL_PARENT}")" = "patched" ] && [ -d "${HOST_MODEL_GRANDPARENT}/hub" ]; then
  HOST_MODEL_MOUNT_ROOT="${HOST_MODEL_MOUNT_ROOT:-${HOST_MODEL_GRANDPARENT}}"
  CONTAINER_MODEL_MOUNT_ROOT="${CONTAINER_MODEL_MOUNT_ROOT:-/opt/models}"
  CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-${CONTAINER_MODEL_MOUNT_ROOT}/patched/${MODEL_VIEW_NAME}}"
else
  HOST_MODEL_MOUNT_ROOT="${HOST_MODEL_MOUNT_ROOT:-${HOST_MODEL_PATH}}"
  CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-/model}"
  CONTAINER_MODEL_MOUNT_ROOT="${CONTAINER_MODEL_MOUNT_ROOT:-${CONTAINER_MODEL_PATH}}"
fi
GPU_SET="${GPU_SET:-0,1,2,3}"
GPU_DEVICE_REQUEST="${GPU_DEVICE_REQUEST:-\"device=${GPU_SET}\"}"
AGG_WORKERS="${AGG_WORKERS:-1}"
FRONTEND_PORT="${FRONTEND_PORT:-18740}"
ENABLE_REASONING_API_PROXY="${ENABLE_REASONING_API_PROXY:-0}"
INNER_FRONTEND_PORT="${INNER_FRONTEND_PORT:-18741}"
AIPERF_BASE_URL="${AIPERF_BASE_URL:-}"
if [ -z "${AIPERF_BASE_URL}" ]; then
  if [ "${ENABLE_REASONING_API_PROXY}" = "1" ] && [ "${BENCHMARK_MODE}" != "smoke" ]; then
    AIPERF_BASE_URL="http://127.0.0.1:${INNER_FRONTEND_PORT}"
  else
    AIPERF_BASE_URL="http://127.0.0.1:${FRONTEND_PORT}"
  fi
fi
ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-2379}"
ETCD_PEER_PORT="${ETCD_PEER_PORT:-2380}"
ETCD_IMAGE="${ETCD_IMAGE:-gcr.io/etcd-development/etcd:v3.6.7}"
RUN_TS="${RUN_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
CONTAINER_NAME="${CONTAINER_NAME:-ultra-vllm-recipe-smoke-${RUN_TS}}"
ETCD_CONTAINER="${ETCD_CONTAINER:-ultra-vllm-recipe-smoke-etcd-${RUN_TS}}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-32}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.9}"
BLOCK_SIZE="${BLOCK_SIZE:-64}"
ENFORCE_EAGER="${ENFORCE_EAGER:-0}"
if [ "${ENFORCE_EAGER}" = "1" ]; then
  EVIDENCE_CLASS="${EVIDENCE_CLASS:-debug_eager_only}"
  PROMOTION_ELIGIBLE="${PROMOTION_ELIGIBLE:-false}"
else
  EVIDENCE_CLASS="${EVIDENCE_CLASS:-benchmark_candidate}"
  PROMOTION_ELIGIBLE="${PROMOTION_ELIGIBLE:-true}"
fi
ALLOW_DEBUG_EAGER_BENCHMARK="${ALLOW_DEBUG_EAGER_BENCHMARK:-0}"
SPEC_METHOD="${SPEC_METHOD:-nemotron_h_mtp}"
SPEC_TOKENS="${SPEC_TOKENS:-1}"
RUN_DS_COPY_SELFTEST="${RUN_DS_COPY_SELFTEST:-1}"
WORKER0_CVD="${WORKER0_CVD:-0,1,2,3}"
WORKER1_CVD="${WORKER1_CVD:-4,5,6,7}"
WORKER0_SYSTEM_PORT="${WORKER0_SYSTEM_PORT:-19901}"
WORKER1_SYSTEM_PORT="${WORKER1_SYSTEM_PORT:-19902}"
WORKER0_KV_EVENTS_CONFIG="${WORKER0_KV_EVENTS_CONFIG:-}"
WORKER1_KV_EVENTS_CONFIG="${WORKER1_KV_EVENTS_CONFIG:-}"
if [ -z "${WORKER0_KV_EVENTS_CONFIG}" ]; then
  WORKER0_KV_EVENTS_CONFIG='{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:5571","enable_kv_cache_events":true}'
fi
if [ -z "${WORKER1_KV_EVENTS_CONFIG}" ]; then
  WORKER1_KV_EVENTS_CONFIG='{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:5572","enable_kv_cache_events":true}'
fi
READY_TIMEOUT_S="${READY_TIMEOUT_S:-1800}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-10}"

read -r -a docker_cmd <<<"${DOCKER_CMD}"
DOCKER_BUILD_ARGS="${DOCKER_BUILD_ARGS:-}"
read -r -a docker_build_args <<<"${DOCKER_BUILD_ARGS}"

mkdir -p "${ARTIFACT_ROOT}"/{commands,logs,preflight,smoke,cleanup,status}
: >"${ARTIFACT_ROOT}/status.jsonl"
: >"${ARTIFACT_ROOT}/failures.jsonl"
: >"${ARTIFACT_ROOT}/generated_commands.jsonl"
: >"${ARTIFACT_ROOT}/metrics.jsonl"

status_event() {
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
with open(path, "a") as f:
    f.write(json.dumps(row, sort_keys=True) + "\n")
PY
}

record_failure() {
  local failure_class="$1"; shift
  local stage="$1"; shift
  local message="$*"
  python3 - "$ARTIFACT_ROOT/failures.jsonl" "$failure_class" "$stage" "$message" <<'PY'
import json, sys, time
path, failure_class, stage, message = sys.argv[1:5]
row = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "failure_class": failure_class,
    "stage": stage,
    "message": message,
}
with open(path, "a") as f:
    f.write(json.dumps(row, sort_keys=True) + "\n")
PY
}

write_run_status() {
  local status="$1"
  local failure_class="${2:-none}"
  python3 - "$ARTIFACT_ROOT/run_status.json" "$status" "$failure_class" <<PY
import json, time, sys
path, status, failure_class = sys.argv[1:4]
payload = {
    "track": "${TRACK}",
    "action_id": "${ACTION_ID}",
    "status": status,
    "failure_class": failure_class,
    "artifact_root": "${ARTIFACT_ROOT}",
    "image": "${IMAGE}",
    "docker_build_args": ${DOCKER_BUILD_ARGS@Q},
    "model": "${SERVED_MODEL_NAME}",
    "server_shape_id": "vllm_recipe_${AGG_WORKERS}agg_tp4_maxlen${MAX_MODEL_LEN}_mns${MAX_NUM_SEQS}_mbt${MAX_BATCHED_TOKENS}_block${BLOCK_SIZE}_spec${SPEC_TOKENS}",
    "evidence_class": "${EVIDENCE_CLASS}",
    "promotion_eligible": "${PROMOTION_ELIGIBLE}" == "true",
    "dashboard_row_ready": "no",
    "updated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(path, "w") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\\n")
PY
}

record_command() {
  local command_id="$1"; shift
  local script="${ARTIFACT_ROOT}/commands/${command_id}.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf '%q ' "$@"
    printf '\n'
  } >"${script}"
  chmod +x "${script}"
  python3 - "$ARTIFACT_ROOT/generated_commands.jsonl" "$command_id" "$script" "$@" <<'PY'
import json, sys, time
path, command_id, script, *argv = sys.argv[1:]
row = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "id": command_id,
    "script": script,
    "argv": argv,
}
with open(path, "a") as f:
    f.write(json.dumps(row, sort_keys=True) + "\n")
PY
}

finalize_commands() {
  python3 - "$ARTIFACT_ROOT/generated_commands.jsonl" "$ARTIFACT_ROOT/generated_commands.json" <<'PY'
import json, pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:3])
rows = [json.loads(line) for line in src.read_text().splitlines() if line.strip()]
dst.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
PY
}

write_manifest() {
  python3 - "$ARTIFACT_ROOT" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
rows = []
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    rel = path.relative_to(root)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    rows.append(f"{rel}\t{path.stat().st_size}\t{digest}")
(root / "manifest.tsv").write_text("\n".join(rows) + "\n")
PY
}

capture_logs() {
  "${docker_cmd[@]}" logs "${CONTAINER_NAME}" >"${ARTIFACT_ROOT}/logs/server_container.log" 2>&1 || true
  "${docker_cmd[@]}" logs "${ETCD_CONTAINER}" >"${ARTIFACT_ROOT}/logs/etcd_container.log" 2>&1 || true
  "${docker_cmd[@]}" cp "${CONTAINER_NAME}:/artifacts/server" "${ARTIFACT_ROOT}/logs/server_artifacts" >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  capture_logs
  "${docker_cmd[@]}" rm -f "${CONTAINER_NAME}" >"${ARTIFACT_ROOT}/cleanup/server_rm.log" 2>&1
  "${docker_cmd[@]}" rm -f "${ETCD_CONTAINER}" >"${ARTIFACT_ROOT}/cleanup/etcd_rm.log" 2>&1
  "${docker_cmd[@]}" ps -a >"${ARTIFACT_ROOT}/cleanup/docker_ps_after.txt" 2>&1
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv \
      >"${ARTIFACT_ROOT}/cleanup/gpu_after_cleanup.csv" 2>&1
  fi
  python3 - "$ARTIFACT_ROOT/cleanup_status.json" "$ARTIFACT_ROOT/cleanup/docker_ps_after.txt" "$ARTIFACT_ROOT/cleanup/gpu_after_cleanup.csv" <<'PY'
import json, os, pathlib, sys, time
out, docker_path, gpu_path = map(pathlib.Path, sys.argv[1:4])
docker_text = docker_path.read_text(errors="ignore") if docker_path.exists() else ""
gpu_text = gpu_path.read_text(errors="ignore") if gpu_path.exists() else ""
gpu_baseline = True
for line in gpu_text.splitlines()[1:]:
    parts = [p.strip() for p in line.split(",")]
    if len(parts) >= 5:
        try:
            mem = int(parts[2].split()[0])
            util = int(parts[4].split()[0])
        except Exception:
            continue
        if mem > 200 or util > 5:
            gpu_baseline = False
payload = {
    "updated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "packet_containers_removed": "ultra-vllm-recipe-smoke" not in docker_text,
    "gpu_baseline": gpu_baseline,
    "docker_ps_after_path": str(docker_path),
    "gpu_after_cleanup_path": str(gpu_path),
}
out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
  finalize_commands
  write_manifest
}

fail() {
  local failure_class="$1"; shift
  local stage="$1"; shift
  local message="$*"
  record_failure "$failure_class" "$stage" "$message"
  status_event BLOCKED "$stage" "$message"
  write_run_status BLOCKED "$failure_class"
  cleanup
  exit 1
}

trap cleanup EXIT

write_run_config() {
  python3 - "$ARTIFACT_ROOT/run_config.json" <<PY
import json, time, pathlib, sys
payload = {
    "track": "${TRACK}",
    "action_id": "${ACTION_ID}",
    "model": "${SERVED_MODEL_NAME}",
    "backend": "vllm",
    "image": "${IMAGE}",
    "artifact_root": "${ARTIFACT_ROOT}",
    "repo_root": "${REPO_ROOT}",
    "host_model_path": "${HOST_MODEL_PATH}",
    "host_model_mount_root": "${HOST_MODEL_MOUNT_ROOT}",
    "container_model_path": "${CONTAINER_MODEL_PATH}",
    "container_model_mount_root": "${CONTAINER_MODEL_MOUNT_ROOT}",
    "gpu_set": "${GPU_SET}",
    "docker_gpu_request": ${GPU_DEVICE_REQUEST@Q},
    "topology": "AGG2" if "${AGG_WORKERS}" == "2" else "AGG1",
    "agg_workers": int("${AGG_WORKERS}"),
    "tp_per_worker": 4,
    "max_model_len": int("${MAX_MODEL_LEN}"),
    "max_num_seqs": int("${MAX_NUM_SEQS}"),
    "max_batched_tokens": int("${MAX_BATCHED_TOKENS}"),
    "gpu_memory_utilization": float("${GPU_MEMORY_UTILIZATION}"),
    "block_size": int("${BLOCK_SIZE}"),
    "enforce_eager": "${ENFORCE_EAGER}" == "1",
    "evidence_class": "${EVIDENCE_CLASS}",
    "promotion_eligible": "${PROMOTION_ELIGIBLE}" == "true",
    "allow_debug_eager_benchmark": "${ALLOW_DEBUG_EAGER_BENCHMARK}" == "1",
    "prefix_cache": True,
    "mamba_cache_mode": "align",
    "spec_method": "${SPEC_METHOD}",
    "spec_tokens": int("${SPEC_TOKENS}"),
    "etcd_endpoint": "http://127.0.0.1:${ETCD_CLIENT_PORT}",
    "benchmark_mode": "${BENCHMARK_MODE}",
    "enable_reasoning_api_proxy": "${ENABLE_REASONING_API_PROXY}",
    "recipe_base": "patch06-humming-20260521",
    "inner_frontend_port": int("${INNER_FRONTEND_PORT}"),
    "validation_gate": [
        "optional image build",
        "optional MTP DS-copy selftest",
        "inside-container nvidia-smi proof",
        "/health",
        "/v1/models",
        "exact short chat",
    ],
    "moontrace": {
        "enabled": "${BENCHMARK_MODE}" == "moontrace30-chat-agg1-mtp-c64",
        "trace_file": "${TRACE_FILE:-}",
        "sha256": "${MOONTRACE_SHA256:-}",
        "concurrency": int("${MOONTRACE_CONCURRENCY:-0}"),
        "request_count": int("${MOONTRACE_REQUEST_COUNT:-0}"),
        "max_osl": int("${MOONTRACE_MAX_OSL:-0}"),
        "public_endpoint": "http://127.0.0.1:${FRONTEND_PORT}",
        "aiperf_base_url": "${AIPERF_BASE_URL}",
    },
    "failure_classes": [
        "image_build_failed",
        "image_inspect_failed",
        "model_cache_unavailable",
        "ds_copy_selftest_failed",
        "server_start_failure",
        "health_timeout",
        "models_endpoint_failed",
        "model_context_mismatch",
        "exact_chat_failed",
        "benchmark_trace_unavailable",
        "eager_mode_debug_only",
        "client_tooling_failure",
        "benchmark_metric_regression",
        "cache_evidence_missing",
        "cleanup_failed",
    ],
    "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\\n")
PY
  if [ "${BENCHMARK_MODE}" = "moontrace30-chat-agg1-mtp-c64" ]; then
    printf '{"quality_requested": true, "reason": "bounded Moontrace30 recipe reproduction gate"}\n' \
      >"${ARTIFACT_ROOT}/quality_requested.json"
  else
    printf '{"quality_requested": false, "reason": "bounded recipe image/server smoke; no benchmark traffic"}\n' \
      >"${ARTIFACT_ROOT}/quality_not_requested.json"
  fi
}

status_event RUNNING start "starting Ultra vLLM recipe local smoke"
write_run_config

if [ ! -d "${HOST_MODEL_PATH}" ]; then
  fail "model_cache_unavailable" preflight "HOST_MODEL_PATH is not a directory: ${HOST_MODEL_PATH}"
fi
find "${HOST_MODEL_PATH}" -maxdepth 1 -type f | sort >"${ARTIFACT_ROOT}/preflight/model_files.txt"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv \
    >"${ARTIFACT_ROOT}/preflight/gpu_before.csv" 2>&1 || true
fi

if [ "${BUILD_IMAGE}" = "1" ]; then
  build_cmd=("${docker_cmd[@]}" build "${docker_build_args[@]}" -t "${IMAGE}" -f "${RECIPE_DIR}/Dockerfile" "${RECIPE_DIR}")
  record_command docker_build "${build_cmd[@]}"
  "${build_cmd[@]}" >"${ARTIFACT_ROOT}/logs/docker_build.log" 2>&1 \
    || fail "image_build_failed" image_build "docker build failed"
fi

inspect_cmd=("${docker_cmd[@]}" image inspect "${IMAGE}")
record_command image_inspect "${inspect_cmd[@]}"
"${inspect_cmd[@]}" >"${ARTIFACT_ROOT}/preflight/image_inspect.json" 2>"${ARTIFACT_ROOT}/preflight/image_inspect.err" \
  || fail "image_inspect_failed" preflight "docker image inspect failed"

host_uid="$(id -u)"
host_gid="$(id -g)"

if [ "${RUN_DS_COPY_SELFTEST}" = "1" ] && [ "${SPEC_TOKENS}" != "0" ]; then
  selftest_cmd=(
    "${docker_cmd[@]}" run --rm --gpus "${GPU_DEVICE_REQUEST}"
    --user "${host_uid}:${host_gid}"
    -e HOME=/tmp
    -e USER="$(id -un)"
    -e LOGNAME="$(id -un)"
    -e XDG_CACHE_HOME=/tmp/cache
    -e TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor_cache
    -e TORCH_EXTENSIONS_DIR=/tmp/torch_extensions
    -v "${ARTIFACT_ROOT}:/artifacts" "${IMAGE}"
    python3 /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/scripts/ds_copy_selftest.py
    --out /artifacts/smoke/ds_copy_selftest.json
    --num-spec-tokens "${SPEC_TOKENS}"
  )
  record_command ds_copy_selftest "${selftest_cmd[@]}"
  "${selftest_cmd[@]}" >"${ARTIFACT_ROOT}/logs/ds_copy_selftest.log" 2>&1 \
    || fail "ds_copy_selftest_failed" preflight "DS-copy selftest failed"
fi

etcd_cmd=(
  "${docker_cmd[@]}" run -d --network host --name "${ETCD_CONTAINER}" "${ETCD_IMAGE}"
  etcd --name default --data-dir "/tmp/${ETCD_CONTAINER}"
  --listen-client-urls "http://0.0.0.0:${ETCD_CLIENT_PORT}"
  --advertise-client-urls "http://127.0.0.1:${ETCD_CLIENT_PORT}"
  --listen-peer-urls "http://0.0.0.0:${ETCD_PEER_PORT}"
  --initial-advertise-peer-urls "http://127.0.0.1:${ETCD_PEER_PORT}"
  --initial-cluster "default=http://127.0.0.1:${ETCD_PEER_PORT}"
)
record_command etcd_run "${etcd_cmd[@]}"
"${docker_cmd[@]}" rm -f "${ETCD_CONTAINER}" >/dev/null 2>&1 || true
"${etcd_cmd[@]}" >"${ARTIFACT_ROOT}/status/etcd_container_id.txt"
sleep 2

server_cmd=(
  "${docker_cmd[@]}" run -d
  --name "${CONTAINER_NAME}"
  --network host
  --ipc host
  --user "${host_uid}:${host_gid}"
  --gpus "${GPU_DEVICE_REQUEST}"
  --tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
  --tmpfs /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
  --ulimit memlock=-1
  --ulimit stack=67108864
  -v "${HOST_MODEL_MOUNT_ROOT}:${CONTAINER_MODEL_MOUNT_ROOT}:ro"
  -v "${ARTIFACT_ROOT}:/artifacts"
  -e HOME=/tmp
  -e USER="$(id -un)"
  -e LOGNAME="$(id -un)"
  -e MODEL_PATH="${CONTAINER_MODEL_PATH}"
  -e SERVED_MODEL_NAME="${SERVED_MODEL_NAME}"
  -e LOG_DIR=/artifacts/server
  -e FRONTEND_PORT="${FRONTEND_PORT}"
  -e INNER_FRONTEND_PORT="${INNER_FRONTEND_PORT}"
  -e ENABLE_REASONING_API_PROXY="${ENABLE_REASONING_API_PROXY}"
  -e DYN_DISCOVERY_BACKEND=etcd
  -e DYN_REQUEST_PLANE=tcp
  -e DYN_EVENT_PLANE=zmq
  -e ETCD_ENDPOINTS="http://127.0.0.1:${ETCD_CLIENT_PORT}"
  -e MAX_MODEL_LEN="${MAX_MODEL_LEN}"
  -e MAX_NUM_SEQS="${MAX_NUM_SEQS}"
  -e MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS}"
  -e GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION}"
  -e BLOCK_SIZE="${BLOCK_SIZE}"
  -e ENFORCE_EAGER="${ENFORCE_EAGER}"
  -e AGG_WORKERS="${AGG_WORKERS}"
  -e SPEC_METHOD="${SPEC_METHOD}"
  -e SPEC_TOKENS="${SPEC_TOKENS}"
  -e SPEC_CLI_STYLE=legacy
  -e WORKER0_CVD="${WORKER0_CVD}"
  -e WORKER1_CVD="${WORKER1_CVD}"
  -e WORKER0_SYSTEM_PORT="${WORKER0_SYSTEM_PORT}"
  -e WORKER1_SYSTEM_PORT="${WORKER1_SYSTEM_PORT}"
  -e WORKER0_KV_EVENTS_CONFIG="${WORKER0_KV_EVENTS_CONFIG}"
  -e WORKER1_KV_EVENTS_CONFIG="${WORKER1_KV_EVENTS_CONFIG}"
  -e VLLM_SSM_CONV_STATE_LAYOUT=DS
  -e VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE=1
  -e DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS=0
  -e VLLM_WORKER_MULTIPROC_METHOD=spawn
  -e VLLM_ALLREDUCE_USE_SYMM_MEM=0
  -e DYN_LOG=info,dynamo_kv_router=debug,dynamo_llm::kv_router=debug
  -e HF_MODULES_CACHE=/tmp/hf_modules
  -e XDG_CACHE_HOME=/tmp/cache
  -e TORCH_EXTENSIONS_DIR=/tmp/torch_extensions
  "${IMAGE}"
  bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_aggregate.sh
)
record_command docker_run_server "${server_cmd[@]}"
"${docker_cmd[@]}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
"${server_cmd[@]}" >"${ARTIFACT_ROOT}/status/server_container_id.txt"

sleep 3
"${docker_cmd[@]}" exec "${CONTAINER_NAME}" nvidia-smi -L \
  >"${ARTIFACT_ROOT}/smoke/inside_container_nvidia_smi.txt" 2>&1 || true

status_event RUNNING endpoint "waiting for /health"
deadline=$((SECONDS + READY_TIMEOUT_S))
healthy=0
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/health" \
      >"${ARTIFACT_ROOT}/smoke/health.json" 2>"${ARTIFACT_ROOT}/smoke/health.err"; then
    healthy=1
    break
  fi
  if ! "${docker_cmd[@]}" ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    fail "server_start_failure" endpoint "server container exited before /health"
  fi
  sleep "${POLL_INTERVAL_S}"
done
if [ "${healthy}" != "1" ]; then
  fail "health_timeout" endpoint "server did not pass /health before timeout"
fi
status_event PASS endpoint "/health passed"

models_cmd=(curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/v1/models")
record_command curl_models "${models_cmd[@]}"
status_event RUNNING endpoint "waiting for /v1/models registration"
models_ready=0
deadline=$((SECONDS + READY_TIMEOUT_S))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if "${models_cmd[@]}" >"${ARTIFACT_ROOT}/smoke/models.json" 2>"${ARTIFACT_ROOT}/smoke/models.err"; then
    if python3 - "$ARTIFACT_ROOT/smoke/models.json" "$SERVED_MODEL_NAME" "$MAX_MODEL_LEN" <<'PY'
import json
import sys

path, expected_model, expected_context = sys.argv[1:4]
payload = json.load(open(path))
models = payload.get("data") or []
for model in models:
    model_id = model.get("id") or model.get("name")
    if model_id != expected_model:
        continue
    context = (
        model.get("context_window")
        or model.get("max_model_len")
        or model.get("max_context_length")
        or model.get("max_sequence_length")
    )
    if context is not None and int(context) != int(expected_context):
        raise SystemExit(2)
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      models_ready=1
      break
    else
      rc=$?
      if [ "${rc}" = "2" ]; then
        fail "model_context_mismatch" endpoint "/v1/models context does not match ${MAX_MODEL_LEN}"
      fi
    fi
  fi
  if ! "${docker_cmd[@]}" ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    fail "server_start_failure" endpoint "server container exited before /v1/models registration"
  fi
  sleep "${POLL_INTERVAL_S}"
done
if [ "${models_ready}" != "1" ]; then
  fail "models_endpoint_failed" endpoint "/v1/models did not expose ${SERVED_MODEL_NAME} before timeout"
fi
status_event PASS endpoint "/v1/models exposed ${SERVED_MODEL_NAME}"

status_event RUNNING exact_chat "running exact short chat"
python3 - "$FRONTEND_PORT" "$SERVED_MODEL_NAME" "$ARTIFACT_ROOT" <<'PY' \
  || fail "exact_chat_failed" exact_chat "exact short chat failed"
import json
import pathlib
import sys
import urllib.request

port, model, root = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
payload = {
    "model": model,
    "messages": [{"role": "user", "content": "Reply with exactly: recipe smoke ok"}],
    "temperature": 0,
    "max_tokens": 32,
    "chat_template_kwargs": {"enable_thinking": False, "force_nonempty_content": True},
}
(root / "smoke" / "chat_request.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n"
)
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"content-type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=120) as resp:
    body = json.loads(resp.read())
(root / "smoke" / "chat_response.json").write_text(
    json.dumps(body, indent=2, sort_keys=True) + "\n"
)
content = body["choices"][0]["message"].get("content", "").strip()
usage = body.get("usage") or {}
if content != "recipe smoke ok":
    raise SystemExit(f"unexpected exact chat content: {content!r}")
if not usage:
    raise SystemExit("missing usage")
PY
status_event PASS exact_chat "exact short chat passed"

if [ "${ENABLE_REASONING_API_PROXY}" = "1" ] && [ "${INNER_FRONTEND_PORT}" != "${FRONTEND_PORT}" ]; then
  inner_health_cmd=(curl -fsS "http://127.0.0.1:${INNER_FRONTEND_PORT}/health")
  record_command curl_inner_health "${inner_health_cmd[@]}"
  "${inner_health_cmd[@]}" >"${ARTIFACT_ROOT}/smoke/inner_health.json" 2>"${ARTIFACT_ROOT}/smoke/inner_health.err" \
    || fail "health_timeout" endpoint "inner /health failed"

  inner_models_cmd=(curl -fsS "http://127.0.0.1:${INNER_FRONTEND_PORT}/v1/models")
  record_command curl_inner_models "${inner_models_cmd[@]}"
  "${inner_models_cmd[@]}" >"${ARTIFACT_ROOT}/smoke/inner_models.json" 2>"${ARTIFACT_ROOT}/smoke/inner_models.err" \
    || fail "models_endpoint_failed" endpoint "inner /v1/models failed"
  python3 - "$ARTIFACT_ROOT/smoke/inner_models.json" "$SERVED_MODEL_NAME" "$MAX_MODEL_LEN" <<'PY' \
    || fail "model_context_mismatch" endpoint "inner /v1/models context does not match"
import json
import sys

path, expected_model, expected_context = sys.argv[1:4]
payload = json.load(open(path))
models = payload.get("data") or []
for model in models:
    model_id = model.get("id") or model.get("name")
    if model_id != expected_model:
        continue
    context = (
        model.get("context_window")
        or model.get("max_model_len")
        or model.get("max_context_length")
        or model.get("max_sequence_length")
    )
    if context is not None and int(context) != int(expected_context):
        raise SystemExit(2)
    raise SystemExit(0)
raise SystemExit(1)
PY

  status_event RUNNING exact_chat "running inner exact short chat"
  python3 - "$INNER_FRONTEND_PORT" "$SERVED_MODEL_NAME" "$ARTIFACT_ROOT" <<'PY' \
    || fail "exact_chat_failed" exact_chat "inner exact short chat failed"
import json
import pathlib
import sys
import urllib.request

port, model, root = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
payload = {
    "model": model,
    "messages": [{"role": "user", "content": "Reply with exactly: recipe smoke ok"}],
    "temperature": 0,
    "max_tokens": 32,
    "chat_template_kwargs": {"enable_thinking": False, "force_nonempty_content": True},
}
(root / "smoke" / "inner_chat_request.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n"
)
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"content-type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=120) as resp:
    body = json.loads(resp.read())
(root / "smoke" / "inner_chat_response.json").write_text(
    json.dumps(body, indent=2, sort_keys=True) + "\n"
)
content = body["choices"][0]["message"].get("content", "").strip()
usage = body.get("usage") or {}
if content != "recipe smoke ok":
    raise SystemExit(f"unexpected exact chat content: {content!r}")
if not usage:
    raise SystemExit("missing usage")
PY
  status_event PASS exact_chat "inner exact short chat passed"
fi

run_moontrace30_chat() {
  if [ "${ENFORCE_EAGER}" = "1" ] && [ "${ALLOW_DEBUG_EAGER_BENCHMARK}" != "1" ]; then
    fail "eager_mode_debug_only" benchmark \
      "ENFORCE_EAGER=1 is debug-only and cannot produce QA/pass/promotion evidence; set ALLOW_DEBUG_EAGER_BENCHMARK=1 only for explicit debug isolation"
  fi
  : "${TRACE_FILE:?Set TRACE_FILE for moontrace30-chat-agg1-mtp-c64}"
  if [ ! -f "${TRACE_FILE}" ]; then
    fail "benchmark_trace_unavailable" benchmark "TRACE_FILE not found: ${TRACE_FILE}"
  fi
  local actual_sha
  actual_sha="$(sha256sum "${TRACE_FILE}" | awk '{print $1}')"
  printf '%s  %s\n' "${actual_sha}" "${TRACE_FILE}" >"${ARTIFACT_ROOT}/preflight/moontrace_trace_sha256.txt"
  if [ "${actual_sha}" != "${MOONTRACE_SHA256}" ]; then
    fail "benchmark_trace_unavailable" benchmark "TRACE_FILE sha256 mismatch: ${actual_sha}"
  fi

  AIPERF_IMAGE="${AIPERF_IMAGE:-nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-aiperf-client-0.8.0-tokenizers-20260522T204015Z@sha256:ebbb3bf5e2e2c09f34e742db18ab7ef6cfb01721050aeec7a4a77473f53fb4d4}"
  local point_dir trace_dir trace_name aiperf_docker_user
  point_dir="${ARTIFACT_ROOT}/benchmark/moontrace30-chat-agg1-mtp-c64"
  trace_dir="$(dirname "${TRACE_FILE}")"
  trace_name="$(basename "${TRACE_FILE}")"
  aiperf_docker_user="${AIPERF_DOCKER_USER:-$(id -u):$(id -g)}"
  mkdir -p "${point_dir}"

  help_cmd=(
    "${docker_cmd[@]}" run --rm --network host
    --user "${aiperf_docker_user}"
    -v "${point_dir}:/out"
    "${AIPERF_IMAGE}"
    bash -lc "aiperf profile --help > /out/aiperf_profile_help.txt"
  )
  record_command aiperf_profile_help "${help_cmd[@]}"
  "${help_cmd[@]}" >"${ARTIFACT_ROOT}/logs/aiperf_profile_help.log" 2>&1 \
    || fail "client_tooling_failure" benchmark "aiperf profile --help failed"

  bench_cmd=(
    "${docker_cmd[@]}" run --rm --network host
    --user "${aiperf_docker_user}"
    -v "${trace_dir}:/traces:ro"
    -v "${HOST_MODEL_MOUNT_ROOT}:${CONTAINER_MODEL_MOUNT_ROOT}:ro"
    -v "${point_dir}:/out"
    "${AIPERF_IMAGE}"
    bash -lc
    "COLUMNS=240 aiperf profile -m '${SERVED_MODEL_NAME}' -u '${AIPERF_BASE_URL}' --endpoint v1/chat/completions --endpoint-type chat --streaming --input-file '/traces/${trace_name}' --custom-dataset-type mooncake-trace --dataset-sampling-strategy sequential --concurrency '${MOONTRACE_CONCURRENCY}' --workers-max '${MOONTRACE_CONCURRENCY}' --request-count '${MOONTRACE_REQUEST_COUNT}' --prompt-input-tokens-block-size 512 --synthesis-max-isl 260608 --synthesis-max-osl '${MOONTRACE_MAX_OSL}' --tokenizer '${CONTAINER_MODEL_PATH}' --tokenizer-trust-remote-code --extra-inputs ignore_eos:true --use-server-token-count --random-seed 42 --export-level records --ui-type none --artifact-dir /out"
  )
  record_command aiperf_moontrace30_chat "${bench_cmd[@]}"
  status_event RUNNING benchmark "running moontrace30 chat c${MOONTRACE_CONCURRENCY}"
  "${bench_cmd[@]}" >"${point_dir}/aiperf.stdout" 2>"${point_dir}/aiperf.stderr" \
    || fail "client_tooling_failure" benchmark "aiperf profile failed"

  python3 - "$point_dir" "$ARTIFACT_ROOT/metrics.jsonl" "$MOONTRACE_REQUEST_COUNT" "$MOONTRACE_CONCURRENCY" <<'PY'
import json, os, pathlib, sys, time
point_dir = pathlib.Path(sys.argv[1])
metrics_path = pathlib.Path(sys.argv[2])
request_count = int(sys.argv[3])
concurrency = int(sys.argv[4])
profile = point_dir / "profile_export_aiperf.json"
if not profile.exists():
    raise SystemExit("profile_export_aiperf.json missing")
payload = json.load(open(profile))

def metric(name):
    value = payload.get(name)
    return value if isinstance(value, dict) else {}

def avg(name, default=None):
    value = metric(name).get("avg", default)
    return float(value) if value is not None else None

def stat(name, key, default=None):
    value = metric(name).get(key, default)
    return float(value) if value is not None else None

def count(name, default=None):
    value = metric(name).get("count", default)
    return int(value) if value is not None else None

def int_avg(name, default=0):
    value = avg(name, default)
    return int(value) if value is not None else default

output_tps = avg("output_token_throughput", 0.0)
request_tps = avg("request_throughput")
gen_tps_user_avg = avg("output_token_throughput_per_user")
e2e_tps_user_avg = avg("e2e_output_token_throughput")
failed = int_avg("error_request_count", 0)
successful = int_avg("request_count", request_count - failed)
records = successful + failed
ttft_p50 = stat("time_to_first_token", "p50")
ttft_p95 = stat("time_to_first_token", "p95")
itl_p50 = stat("inter_token_latency", "p50")
itl_p95 = stat("inter_token_latency", "p95")
lat_p50 = stat("request_latency", "p50")
lat_p95 = stat("request_latency", "p95")
isl_avg = avg("input_sequence_length")
isl_p50 = stat("input_sequence_length", "p50")
isl_p95 = stat("input_sequence_length", "p95")
isl_max = stat("input_sequence_length", "max")
osl_avg = avg("output_sequence_length")
osl_p50 = stat("output_sequence_length", "p50")
osl_p95 = stat("output_sequence_length", "p95")
osl_max = stat("output_sequence_length", "max")
reasoning_tokens_total = int_avg("total_reasoning_tokens", 0)
output_tokens_total = int_avg("total_output_tokens", 0)
warning_rate = failed / request_count if request_count else 0.0

# AIPerf has both generation-only and end-to-end per-user throughput. For
# product gates we keep both explicit; never approximate TPS/user as
# output_tps/concurrency because that is not the AIPerf per-user metric.
metric_suspicious = False
suspicious_reasons = []
if itl_p50 is not None and itl_p50 < 1.0:
    metric_suspicious = True
    suspicious_reasons.append("itl_p50_below_1ms")
if gen_tps_user_avg is not None and gen_tps_user_avg > 10000:
    metric_suspicious = True
    suspicious_reasons.append("gen_tps_user_abnormally_high")
row = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "workload": "moontrace30_chat",
    "topology": "AGG1_MTP1",
    "server_shape_id": "vllm_oldbase_agg1_mtp1_mns64_mbt32768_block64_c64_proxy",
    "aiperf_base_url": "${AIPERF_BASE_URL}",
    "request_count": request_count,
    "profile_records": records,
    "successful_metric_count": successful,
    "failed_count": int(failed),
    "warning_rate": warning_rate,
    "concurrency": concurrency,
    "output_tps": output_tps,
    "tps_gpu": output_tps / 4.0,
    "gen_tps_user_avg": gen_tps_user_avg,
    "e2e_tps_user_avg": e2e_tps_user_avg,
    "request_tps": request_tps,
    "ttft_p50_ms": ttft_p50,
    "ttft_p95_ms": ttft_p95,
    "itl_p50_ms": itl_p50,
    "itl_p95_ms": itl_p95,
    "latency_p50_ms": lat_p50,
    "latency_p95_ms": lat_p95,
    "isl_avg": isl_avg,
    "isl_p50": isl_p50,
    "isl_p95": isl_p95,
    "isl_max": isl_max,
    "osl_avg": osl_avg,
    "osl_p50": osl_p50,
    "osl_p95": osl_p95,
    "osl_max": osl_max,
    "total_reasoning_tokens": reasoning_tokens_total,
    "total_output_tokens": output_tokens_total,
    "metric_suspicious": metric_suspicious,
    "metric_suspicious_reasons": suspicious_reasons,
    "artifact_path": str(point_dir),
    "classification": "pass_with_warnings" if failed else "perf_datapoint",
    "dashboard_row_ready": "no",
}
with metrics_path.open("a") as f:
    f.write(json.dumps(row, sort_keys=True) + "\n")
(point_dir / "normalized_metric.json").write_text(json.dumps(row, indent=2, sort_keys=True) + "\n")
max_warning_rate = float(os.environ.get("AIPERF_MAX_WARNING_RATE", "0.005"))
if row["failed_count"] and warning_rate > max_warning_rate:
    raise SystemExit("benchmark_warning_rate_exceeded")
if row["tps_gpu"] < 170:
    raise SystemExit("benchmark_metric_regression")
PY
  status_event PASS benchmark "moontrace30 chat benchmark passed"
}

if [ "${BENCHMARK_MODE}" = "moontrace30-chat-agg1-mtp-c64" ]; then
  run_moontrace30_chat
fi

capture_logs
if [ "${ENFORCE_EAGER}" = "1" ]; then
  write_run_status PASS_DIAGNOSTIC none
  status_event PASS done "Ultra vLLM recipe ${BENCHMARK_MODE} passed as debug-only eager evidence"
else
  write_run_status PASS none
  status_event PASS done "Ultra vLLM recipe ${BENCHMARK_MODE} passed"
fi
