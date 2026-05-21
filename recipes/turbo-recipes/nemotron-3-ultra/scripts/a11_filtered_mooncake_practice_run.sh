#!/usr/bin/env bash
set -euo pipefail

# Filtered Mooncake AIPerf practice canary for Nemotron-3-Ultra recipes.
# This is a bounded client/tooling canary, not an official A11 sweep. Run one
# backend/workload per fresh server and use filtered trace JSONL only.

: "${ARTIFACT_ROOT:?set ARTIFACT_ROOT}"
: "${BACKEND:?set BACKEND to vllm, sglang, or trtllm}"
: "${WORKLOAD:?set WORKLOAD to chat or swe}"
: "${IMAGE:?set IMAGE to a locally-built recipe image or accepted staging image}"
: "${PREP_ARTIFACT:?set PREP_ARTIFACT to the filtered Mooncake prep artifact copied into ARTIFACT_ROOT}"
: "${HF_CACHE_ROOT:?set HF_CACHE_ROOT to the full Hugging Face cache root mounted as /hf-cache}"
: "${MODEL_VIEW_HOST:?set MODEL_VIEW_HOST to the tokenizer-patched model view on the host}"

TRACK="${TRACK:-nemotron-ultra-phase0}"
ACTION_GROUP="${ACTION_GROUP:-A11_MOONCAKE_FILTERED_PRACTICE}"
NODE="${NODE:-umb-b200-203.cl1u1.colossus.nvidia.com}"
AIPERF_IMAGE="${AIPERF_IMAGE:-nvcr.io/nvidia/ai-dynamo/aiperf:0.8.0}"
DOCKER_CMD="${DOCKER_CMD:-sudo -n docker}"
MODEL_PATH="${MODEL_PATH:-/hf-cache/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844}"
TOKENIZER_PATH_IN_CONTAINER="${TOKENIZER_PATH_IN_CONTAINER:-$MODEL_PATH}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
EXPECTED_IMAGE_DIGEST="${EXPECTED_IMAGE_DIGEST:-}"

PREFILL_CVD="${PREFILL_CVD:-0,1,2,3}"
DECODE_CVD="${DECODE_CVD:-4,5,6,7}"
TP="${TP:-4}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
REQUEST_COUNT="${REQUEST_COUNT:-8}"
WARMUP_REQUEST_COUNT="${WARMUP_REQUEST_COUNT:-2}"
POINT_CONCURRENCY="${POINT_CONCURRENCY:-1}"
WARMUP_CONCURRENCY="${WARMUP_CONCURRENCY:-1}"

case "$BACKEND" in
  vllm)
    SERVER_SHAPE_ID="${SERVER_SHAPE_ID:-vllm_patch05_recipe_tp4_1p1d_65k}"
    FRONTEND_PORT="${FRONTEND_PORT:-18740}"
    DYN_SYSTEM_PORT1="${DYN_SYSTEM_PORT1:-19601}"
    DYN_SYSTEM_PORT2="${DYN_SYSTEM_PORT2:-19602}"
    ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-22879}"
    ETCD_PEER_PORT="${ETCD_PEER_PORT:-22880}"
    VLLM_PREFILL_NIXL_PORT="${VLLM_PREFILL_NIXL_PORT:-5641}"
    VLLM_DECODE_NIXL_PORT="${VLLM_DECODE_NIXL_PORT:-5642}"
    BLOCK_SIZE="${BLOCK_SIZE:-64}"
    VLLM_FLASHINFER_TMPFS="${VLLM_FLASHINFER_TMPFS:-/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer}"
    FRONTEND_SCRIPT="${FRONTEND_SCRIPT:-/artifacts/source_recipe/vllm/launch_frontend.sh}"
    PREFILL_SCRIPT="${PREFILL_SCRIPT:-/artifacts/source_recipe/vllm/launch_prefill.sh}"
    DECODE_SCRIPT="${DECODE_SCRIPT:-/artifacts/source_recipe/vllm/launch_decode.sh}"
    ;;
  sglang)
    SERVER_SHAPE_ID="${SERVER_SHAPE_ID:-sglang_recipe_tp4_ep4_1p1d_65k}"
    FRONTEND_PORT="${FRONTEND_PORT:-18880}"
    DYN_SYSTEM_PORT1="${DYN_SYSTEM_PORT1:-19781}"
    DYN_SYSTEM_PORT2="${DYN_SYSTEM_PORT2:-19782}"
    ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-22979}"
    ETCD_PEER_PORT="${ETCD_PEER_PORT:-22980}"
    BOOTSTRAP_PORT="${BOOTSTRAP_PORT:-12345}"
    SGLANG_PREFILL_PORT="${SGLANG_PREFILL_PORT:-40000}"
    SGLANG_DECODE_PORT="${SGLANG_DECODE_PORT:-40001}"
    SGLANG_FLASHINFER_TMPFS="${SGLANG_FLASHINFER_TMPFS:-/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer}"
    FRONTEND_SCRIPT="${FRONTEND_SCRIPT:-/artifacts/source_recipe/sglang/launch_frontend.sh}"
    PREFILL_SCRIPT="${PREFILL_SCRIPT:-/artifacts/source_recipe/sglang/launch_prefill.sh}"
    DECODE_SCRIPT="${DECODE_SCRIPT:-/artifacts/source_recipe/sglang/launch_decode.sh}"
    ;;
  trtllm)
    SERVER_SHAPE_ID="${SERVER_SHAPE_ID:-trtllm_recipe_t5_4_tp4_1p1d_bounded_reuse_65k}"
    FRONTEND_PORT="${FRONTEND_PORT:-18000}"
    DYN_SYSTEM_PORT1="${DYN_SYSTEM_PORT1:-19081}"
    DYN_SYSTEM_PORT2="${DYN_SYSTEM_PORT2:-19082}"
    DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-file}"
    DYN_FILE_KV="${DYN_FILE_KV:-/tmp/dynamo_store_kv_trtllm_a11_${ARTIFACT_ROOT##*/}_${FRONTEND_PORT}}"
    FRONTEND_SCRIPT="${FRONTEND_SCRIPT:-/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_frontend.sh}"
    PREFILL_SCRIPT="${PREFILL_SCRIPT:-/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_prefill.sh}"
    DECODE_SCRIPT="${DECODE_SCRIPT:-/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_decode.sh}"
    ;;
  *)
    echo "unsupported BACKEND=$BACKEND" >&2
    exit 2
    ;;
esac

case "$WORKLOAD" in
  chat)
    WORKLOAD_SCRIPT="commands/run_a11_chat_mooncake_msl65536_oslcap1024_c1_r64.sh"
    FILTERED_TRACE="filtered_traces/chat_maxlen65536_oslcap1024_margin512.jsonl"
    ;;
  swe)
    WORKLOAD_SCRIPT="commands/run_a11_swe_mooncake_msl65536_oslcap400_c1_r64.sh"
    FILTERED_TRACE="filtered_traces/swe_maxlen65536_oslcap400_margin512.jsonl"
    ;;
  *)
    echo "unsupported WORKLOAD=$WORKLOAD" >&2
    exit 2
    ;;
esac

POINT_ID="${POINT_ID:-${BACKEND}_${WORKLOAD}_c1_r8_filtered}"
ACTION_ID="${ACTION_ID:-A11_${BACKEND^^}_${WORKLOAD^^}_FILTERED_MOONCAKE_C1_R8_PRACTICE}"
CONTAINER="${CONTAINER:-ultra-a11-${BACKEND}-${WORKLOAD}-${ARTIFACT_ROOT##*/}}"
ETCD_CONTAINER="${ETCD_CONTAINER:-ultra-a11-etcd-${BACKEND}-${WORKLOAD}-${ARTIFACT_ROOT##*/}}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HOST_USER="$(id -un)"

mkdir -p "$ARTIFACT_ROOT"/{preflight,status,logs,backend_smoke,client_setup,aiperf/mooncake/"$WORKLOAD"/points/"$POINT_ID",cache_routing_diagnostic,cleanup,analysis,commands}
: > "$ARTIFACT_ROOT/status.jsonl"
: > "$ARTIFACT_ROOT/failures.jsonl"
: > "$ARTIFACT_ROOT/metrics.jsonl"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'; }
status_event() {
  local status="$1" stage="$2" msg="${3:-}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","track":"%s","action_group":"%s","action_id":"%s","status":"%s","stage":"%s","message":"%s","artifact_root":"%s"}\n' \
    "$now" "$TRACK" "$ACTION_GROUP" "$ACTION_ID" "$status" "$stage" "$(printf '%s' "$msg" | json_escape)" "$ARTIFACT_ROOT" >> "$ARTIFACT_ROOT/status.jsonl"
}

write_run_status() {
  local status="$1" failure_class="${2:-}" stage="${3:-complete}" cache_verification="${4:-not_available}"
  python3 - "$ARTIFACT_ROOT/run_status.json" <<PY
import json, sys
fc = "$failure_class" or None
obj = {
  "track": "$TRACK",
  "action_group": "$ACTION_GROUP",
  "action_id": "$ACTION_ID",
  "status": "$status",
  "stage": "$stage",
  "failure_class": fc,
  "backend": "$BACKEND",
  "workload": "$WORKLOAD",
  "point_id": "$POINT_ID",
  "image": "$IMAGE",
  "expected_image_digest": "$EXPECTED_IMAGE_DIGEST",
  "node": "$NODE",
  "artifact_root": "$ARTIFACT_ROOT",
  "prep_artifact": "$PREP_ARTIFACT",
  "server_shape_id": "$SERVER_SHAPE_ID",
  "server_reuse_preserved": False,
  "fresh_server_per_workload": True,
  "client_image": "$AIPERF_IMAGE",
  "cache_verification": "$cache_verification",
  "dashboard_row_ready": False,
}
open(sys.argv[1], "w").write(json.dumps(obj, indent=2) + "\n")
PY
}

finalize_manifest() {
  (cd "$ARTIFACT_ROOT" && find . -type f -printf '%P\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\n' | sort > manifest.tsv)
}

cleanup() {
  set +e
  mkdir -p "$ARTIFACT_ROOT/cleanup"
  $DOCKER_CMD logs --tail 1000 "$CONTAINER" > "$ARTIFACT_ROOT/logs/container_tail_cleanup.log" 2>&1
  $DOCKER_CMD rm -f "$CONTAINER" > "$ARTIFACT_ROOT/cleanup/model_container_rm.log" 2>&1
  if [[ "$BACKEND" != "trtllm" ]]; then
    $DOCKER_CMD rm -f "$ETCD_CONTAINER" > "$ARTIFACT_ROOT/cleanup/etcd_container_rm.log" 2>&1
  fi
  if [[ "$BACKEND" == "trtllm" ]]; then
    rm -rf "$DYN_FILE_KV"
  fi
  nvidia-smi > "$ARTIFACT_ROOT/cleanup/nvidia_smi_after_cleanup.txt" 2>&1
  nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu --format=csv > "$ARTIFACT_ROOT/cleanup/gpu_after_cleanup.csv" 2>&1
  $DOCKER_CMD ps --no-trunc > "$ARTIFACT_ROOT/cleanup/docker_ps_after_cleanup.txt" 2>&1
  python3 - "$ARTIFACT_ROOT/cleanup/gpu_after_cleanup.csv" "$ARTIFACT_ROOT/cleanup_status.json" <<'PY'
import csv, json, re, sys
rows = []
try:
    for row in csv.DictReader(open(sys.argv[1])):
        mem = int(re.search(r"\d+", row.get("memory.used [MiB]", "0")).group())
        rows.append({"index": row.get("index"), "memory_used_mib": mem})
    baseline = all(row["memory_used_mib"] <= 1024 for row in rows)
    obj = {"cleanup_recorded": True, "gpu_baseline_le_1024_mib": baseline, "gpus": rows}
except Exception as exc:
    obj = {"cleanup_recorded": False, "error": str(exc)}
open(sys.argv[2], "w").write(json.dumps(obj, indent=2) + "\n")
PY
  set -e
}

fail() {
  local cls="$1" stage="$2" msg="${3:-}"
  status_event "FAIL" "$stage" "$cls: $msg"
  printf '{"failure_class":"%s","stage":"%s","message":"%s"}\n' "$cls" "$stage" "$(printf '%s' "$msg" | json_escape)" >> "$ARTIFACT_ROOT/failures.jsonl"
  write_run_status "FAIL" "$cls" "$stage"
  cleanup || true
  finalize_manifest || true
  exit 1
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then status_event "FAIL" "trap" "unexpected exit $rc"; cleanup || true; finalize_manifest || true; fi' EXIT

write_run_status "RUNNING" "" "start"
status_event "RUNNING" "preflight" "capturing baseline and validating inputs"
cat > "$ARTIFACT_ROOT/run_config.json" <<JSON
{
  "track": "$TRACK",
  "action_group": "$ACTION_GROUP",
  "action_id": "$ACTION_ID",
  "backend": "$BACKEND",
  "workload": "$WORKLOAD",
  "point_id": "$POINT_ID",
  "image": "$IMAGE",
  "expected_image_digest": "$EXPECTED_IMAGE_DIGEST",
  "node": "$NODE",
  "artifact_root": "$ARTIFACT_ROOT",
  "prep_artifact": "$PREP_ARTIFACT",
  "hf_cache_root": "$HF_CACHE_ROOT",
  "model_view_host": "$MODEL_VIEW_HOST",
  "server_shape_id": "$SERVER_SHAPE_ID",
  "server_reuse_preserved": false,
  "fresh_server_per_workload": true,
  "frontend_port": $FRONTEND_PORT,
  "prefill_cvd": "$PREFILL_CVD",
  "decode_cvd": "$DECODE_CVD",
  "tp": $TP,
  "max_model_len": $MAX_MODEL_LEN,
  "max_num_seqs": $MAX_NUM_SEQS,
  "max_batched_tokens": $MAX_BATCHED_TOKENS,
  "trace_mode": "mooncake-trace",
  "filtered_trace": "$FILTERED_TRACE",
  "quality_requested": false,
  "dashboard_row_ready": false,
  "request_count": $REQUEST_COUNT,
  "warmup_request_count": $WARMUP_REQUEST_COUNT,
  "concurrency": $POINT_CONCURRENCY
}
JSON
cat > "$ARTIFACT_ROOT/quality_not_requested.json" <<JSON
{"quality_requested": false, "reason": "A11 filtered Mooncake AIPerf practice canary only; no quality evaluation requested"}
JSON

$DOCKER_CMD ps --no-trunc > "$ARTIFACT_ROOT/preflight/docker_ps_before.txt"
$DOCKER_CMD ps -a --no-trunc > "$ARTIFACT_ROOT/preflight/docker_ps_all_before.txt"
nvidia-smi > "$ARTIFACT_ROOT/preflight/nvidia_smi_before.txt"
nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu --format=csv > "$ARTIFACT_ROOT/preflight/gpu_before.csv"
ss -ltnp > "$ARTIFACT_ROOT/preflight/ss_ltnp_before.txt" 2>&1 || true

test -r "$MODEL_VIEW_HOST/config.json" || fail "model_cache_unavailable" "preflight" "$MODEL_VIEW_HOST/config.json unreadable"
test -d "$PREP_ARTIFACT" || fail "mooncake_trace_filter_missing" "preflight" "$PREP_ARTIFACT missing"
test -r "$ARTIFACT_ROOT/$FILTERED_TRACE" || fail "mooncake_trace_filter_missing" "preflight" "$FILTERED_TRACE unreadable"
grep -q -- "--synthesis-max-isl" "$ARTIFACT_ROOT/$WORKLOAD_SCRIPT" || fail "mooncake_trace_filter_missing" "preflight" "$WORKLOAD_SCRIPT missing --synthesis-max-isl"
grep -q -- "/artifacts/$FILTERED_TRACE" "$ARTIFACT_ROOT/$WORKLOAD_SCRIPT" || fail "mooncake_trace_filter_missing" "preflight" "$WORKLOAD_SCRIPT does not reference filtered trace"

python3 - "$ARTIFACT_ROOT/preflight/gpu_before.csv" <<'PY' || fail "stale_gpu_owner" "preflight" "GPU memory above baseline before launch"
import csv, re, sys
busy = []
for row in csv.DictReader(open(sys.argv[1])):
    mem = int(re.search(r"\d+", row.get("memory.used [MiB]", "0")).group())
    if mem > 1024:
        busy.append((row.get("index"), mem))
if busy:
    print("busy_gpus", busy)
    raise SystemExit(1)
PY

for port in "$FRONTEND_PORT" "${DYN_SYSTEM_PORT1:-}" "${DYN_SYSTEM_PORT2:-}" "${ETCD_CLIENT_PORT:-}" "${ETCD_PEER_PORT:-}" "${VLLM_PREFILL_NIXL_PORT:-}" "${VLLM_DECODE_NIXL_PORT:-}" "${BOOTSTRAP_PORT:-}" "${SGLANG_PREFILL_PORT:-}" "${SGLANG_DECODE_PORT:-}"; do
  [[ -n "$port" ]] || continue
  if ss -ltn | awk '{print $4}' | grep -Eq ":${port}$"; then
    fail "port_in_use" "preflight" "port $port is already listening"
  fi
done

$DOCKER_CMD image inspect "$IMAGE" > "$ARTIFACT_ROOT/preflight/server_image_inspect.json" || fail "image_unavailable" "preflight" "$IMAGE inspect failed"
$DOCKER_CMD image inspect "$IMAGE" --format '{{.Id}}' > "$ARTIFACT_ROOT/preflight/server_image_id.txt"
SERVER_IMAGE_ID="$(cat "$ARTIFACT_ROOT/preflight/server_image_id.txt")"
if [[ -n "$EXPECTED_IMAGE_DIGEST" && "$SERVER_IMAGE_ID" != "$EXPECTED_IMAGE_DIGEST" ]]; then
  fail "image_digest_mismatch_preflight" "preflight" "got $SERVER_IMAGE_ID expected $EXPECTED_IMAGE_DIGEST"
fi
$DOCKER_CMD image inspect "$AIPERF_IMAGE" > "$ARTIFACT_ROOT/preflight/aiperf_image_inspect.json" || fail "client_tooling_failure" "preflight" "AIPerf image unavailable"
$DOCKER_CMD image inspect "$AIPERF_IMAGE" --format '{{.Id}}' > "$ARTIFACT_ROOT/preflight/aiperf_image_id.txt"

status_event "PASS" "preflight" "baseline/images/filtered command OK"

status_event "RUNNING" "client_setup" "probing AIPerf and tokenizer"
$DOCKER_CMD run --rm --network host --user "${HOST_UID}:${HOST_GID}" -e HOME=/tmp -e USER="$HOST_USER" -e LOGNAME="$HOST_USER" -v "$ARTIFACT_ROOT:/artifacts" --entrypoint bash "$AIPERF_IMAGE" -lc 'COLUMNS=260 aiperf profile --help' > "$ARTIFACT_ROOT/client_setup/aiperf_profile_help.txt" 2>&1 || fail "client_tooling_failure" "client_setup" "aiperf profile --help failed"
python3 - "$ARTIFACT_ROOT/client_setup/aiperf_profile_help.txt" "$ARTIFACT_ROOT/client_setup/aiperf_capability.json" <<'PY' || fail "aiperf_mooncake_trace_unsupported" "client_setup" "AIPerf missing Mooncake trace flags"
import json, sys
text = open(sys.argv[1]).read()
need = ["--input-file", "--custom-dataset-type", "mooncake-trace", "--synthesis-max-isl", "--synthesis-max-osl"]
found = {key: key in text for key in need}
open(sys.argv[2], "w").write(json.dumps({"required_flags": found, "pass": all(found.values())}, indent=2) + "\n")
if not all(found.values()):
    raise SystemExit(1)
PY
$DOCKER_CMD run --rm --network host --user "${HOST_UID}:${HOST_GID}" -e HOME=/tmp -e USER="$HOST_USER" -e LOGNAME="$HOST_USER" -v "$HF_CACHE_ROOT:/hf-cache:ro" --entrypoint bash "$AIPERF_IMAGE" -lc 'python3 - <<PY
from transformers import AutoTokenizer
p = "'$TOKENIZER_PATH_IN_CONTAINER'"
tok = AutoTokenizer.from_pretrained(p, trust_remote_code=True)
ids = tok.encode("disagg smoke ok")
print("tokenizer_path", p)
print("token_count", len(ids))
print("ids", ids[:20])
PY' > "$ARTIFACT_ROOT/client_setup/tokenizer_smoke.log" 2>&1 || fail "client_tooling_failure" "client_setup" "tokenizer smoke failed"
status_event "PASS" "client_setup" "AIPerf help/tokenizer OK"

status_event "RUNNING" "server_launch" "starting $BACKEND endpoint"
$DOCKER_CMD rm -f "$CONTAINER" "$ETCD_CONTAINER" > "$ARTIFACT_ROOT/logs/docker_rm_stale.log" 2>&1 || true

if [[ "$BACKEND" != "trtllm" ]]; then
  $DOCKER_CMD run -d --name "$ETCD_CONTAINER" --network host gcr.io/etcd-development/etcd:v3.6.7 \
    /usr/local/bin/etcd --name "ultra-a11-${BACKEND}-${WORKLOAD}" --data-dir "/tmp/ultra-a11-etcd-${ARTIFACT_ROOT##*/}" \
    --listen-client-urls "http://0.0.0.0:${ETCD_CLIENT_PORT}" --advertise-client-urls "http://127.0.0.1:${ETCD_CLIENT_PORT}" \
    --listen-peer-urls "http://0.0.0.0:${ETCD_PEER_PORT}" --initial-advertise-peer-urls "http://127.0.0.1:${ETCD_PEER_PORT}" \
    --initial-cluster "ultra-a11-${BACKEND}-${WORKLOAD}=http://127.0.0.1:${ETCD_PEER_PORT}" --initial-cluster-state new \
    > "$ARTIFACT_ROOT/logs/etcd_docker_run.txt"
  sleep 3
  $DOCKER_CMD logs "$ETCD_CONTAINER" > "$ARTIFACT_ROOT/logs/etcd_start.log" 2>&1 || true
fi

DOCKER_EXTRA=()
if [[ "$BACKEND" == "vllm" ]]; then
  DOCKER_EXTRA+=(--tmpfs "${VLLM_FLASHINFER_TMPFS}:rw,exec,mode=1777")
elif [[ "$BACKEND" == "sglang" ]]; then
  DOCKER_EXTRA+=(--tmpfs "${SGLANG_FLASHINFER_TMPFS}:rw,exec,mode=1777")
fi

$DOCKER_CMD run -d --name "$CONTAINER" --network host --ipc host --gpus all --shm-size 16g \
  --user "${HOST_UID}:${HOST_GID}" -e HOME=/tmp -e USER="$HOST_USER" -e LOGNAME="$HOST_USER" \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  "${DOCKER_EXTRA[@]}" \
  -v "$HF_CACHE_ROOT:/hf-cache:ro" -v "$ARTIFACT_ROOT:/artifacts" \
  -e ARTIFACT_ROOT=/artifacts -e LOG_DIR=/artifacts/logs \
  -e HF_HOME=/hf-cache -e HF_HUB_CACHE=/hf-cache/hub -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e HF_DATASETS_OFFLINE=1 \
  -e XDG_CACHE_HOME=/tmp/cache -e TORCH_EXTENSIONS_DIR=/tmp/torch_extensions -e TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor -e TRITON_CACHE_DIR=/tmp/triton \
  -e HF_MODULES_CACHE=/tmp/hf_modules \
  -e MODEL_PATH="$MODEL_PATH" -e SERVED_MODEL_NAME="$SERVED_MODEL_NAME" \
  -e FRONTEND_PORT="$FRONTEND_PORT" -e DYN_SYSTEM_PORT1="${DYN_SYSTEM_PORT1:-}" -e DYN_SYSTEM_PORT2="${DYN_SYSTEM_PORT2:-}" \
  -e PREFILL_CVD="$PREFILL_CVD" -e DECODE_CVD="$DECODE_CVD" -e TP="$TP" \
  -e MAX_MODEL_LEN="$MAX_MODEL_LEN" -e MAX_NUM_SEQS="$MAX_NUM_SEQS" -e MAX_BATCHED_TOKENS="$MAX_BATCHED_TOKENS" \
  -e DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-etcd}" -e DYN_REQUEST_PLANE=tcp -e DYN_EVENT_PLANE=zmq \
  -e ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://127.0.0.1:${ETCD_CLIENT_PORT:-0}}" \
  -e DYN_FILE_KV="${DYN_FILE_KV:-}" \
  -e VLLM_NIXL_SIDE_CHANNEL_HOST=127.0.0.1 -e VLLM_PREFILL_NIXL_PORT="${VLLM_PREFILL_NIXL_PORT:-}" -e VLLM_DECODE_NIXL_PORT="${VLLM_DECODE_NIXL_PORT:-}" \
  -e VLLM_FLASHINFER_TMPFS="${VLLM_FLASHINFER_TMPFS:-}" \
  -e VLLM_BLOCK_SIZE="${BLOCK_SIZE:-64}" -e VLLM_GPU_MEMORY_UTILIZATION=0.9 \
  -e VLLM_SSM_CONV_STATE_LAYOUT=DS -e VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE=1 -e DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS=0 \
  -e VLLM_WORKER_MULTIPROC_METHOD=spawn -e VLLM_ALLREDUCE_USE_SYMM_MEM=0 \
  -e SGLANG_EP_SIZE=4 -e SGLANG_MEM_FRACTION_STATIC=0.85 -e SGLANG_FP8_GEMM_BACKEND=triton -e SGLANG_FP4_GEMM_BACKEND=auto \
  -e SGLANG_MOE_A2A_BACKEND=none -e SGLANG_MOE_RUNNER_BACKEND=flashinfer_trtllm -e SGLANG_MAMBA_SCHEDULER_STRATEGY=no_buffer \
  -e BOOTSTRAP_PORT="${BOOTSTRAP_PORT:-}" -e SGLANG_PREFILL_PORT="${SGLANG_PREFILL_PORT:-}" -e SGLANG_DECODE_PORT="${SGLANG_DECODE_PORT:-}" -e SGLANG_FLASHINFER_TMPFS="${SGLANG_FLASHINFER_TMPFS:-}" \
  -e TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}" -e REASONING_PARSER="${REASONING_PARSER:-nemotron3}" \
  -e SGLANG_DYN_TOOL_CALL_PARSER=qwen3_coder -e SGLANG_DYN_REASONING_PARSER=nemotron3 \
  "$IMAGE" sleep infinity > "$ARTIFACT_ROOT/logs/model_docker_run.txt"

$DOCKER_CMD exec "$CONTAINER" bash -lc 'set -e; id; test -r "$MODEL_PATH/config.json"; test -w /artifacts; mkdir -p /tmp/hf_modules /tmp/cache /tmp/torch_extensions; test -w /tmp/hf_modules' > "$ARTIFACT_ROOT/preflight/container_mount_probe.log" 2>&1 || fail "container_mount_probe_failed" "server_launch" "container mount probe failed"
if [[ "$BACKEND" != "trtllm" ]]; then
  $DOCKER_CMD exec "$CONTAINER" bash -lc "test -x '$FRONTEND_SCRIPT' && test -x '$PREFILL_SCRIPT' && test -x '$DECODE_SCRIPT'" >> "$ARTIFACT_ROOT/preflight/container_mount_probe.log" 2>&1 || fail "recipe_script_path_mismatch" "server_launch" "recipe scripts missing in container"
else
  $DOCKER_CMD exec "$CONTAINER" bash -lc "test -x '$FRONTEND_SCRIPT' && test -x '$PREFILL_SCRIPT' && test -x '$DECODE_SCRIPT'" >> "$ARTIFACT_ROOT/preflight/container_mount_probe.log" 2>&1 || fail "recipe_script_path_mismatch" "server_launch" "embedded TRT recipe scripts missing"
fi

cat > "$ARTIFACT_ROOT/generated_commands.json" <<JSON
{
  "container": "$CONTAINER",
  "etcd_container": "$ETCD_CONTAINER",
  "frontend": "docker exec -d $CONTAINER bash $FRONTEND_SCRIPT",
  "prefill": "docker exec -d $CONTAINER bash $PREFILL_SCRIPT",
  "decode": "docker exec -d $CONTAINER bash $DECODE_SCRIPT",
  "point": "POINT_ID=$POINT_ID REQUEST_COUNT=$REQUEST_COUNT WARMUP_REQUEST_COUNT=$WARMUP_REQUEST_COUNT bash $WORKLOAD_SCRIPT"
}
JSON

if [[ "$BACKEND" == "vllm" ]]; then
  $DOCKER_CMD exec -d -e DYN_SYSTEM_PORT="$DYN_SYSTEM_PORT1" -e PREFILL_CVD="$PREFILL_CVD" -e VLLM_NIXL_SIDE_CHANNEL_PORT="$VLLM_PREFILL_NIXL_PORT" "$CONTAINER" bash "$PREFILL_SCRIPT"
  $DOCKER_CMD exec -d -e DYN_SYSTEM_PORT="$DYN_SYSTEM_PORT2" -e DECODE_CVD="$DECODE_CVD" -e VLLM_NIXL_SIDE_CHANNEL_PORT="$VLLM_DECODE_NIXL_PORT" "$CONTAINER" bash "$DECODE_SCRIPT"
  $DOCKER_CMD exec -d -e FRONTEND_PORT="$FRONTEND_PORT" "$CONTAINER" bash "$FRONTEND_SCRIPT"
elif [[ "$BACKEND" == "sglang" ]]; then
  $DOCKER_CMD exec -d -e DYN_SYSTEM_PORT="$DYN_SYSTEM_PORT1" -e PREFILL_CVD="$PREFILL_CVD" "$CONTAINER" bash "$PREFILL_SCRIPT"
  $DOCKER_CMD exec -d -e DYN_SYSTEM_PORT="$DYN_SYSTEM_PORT2" -e DECODE_CVD="$DECODE_CVD" "$CONTAINER" bash "$DECODE_SCRIPT"
  $DOCKER_CMD exec -d -e FRONTEND_PORT="$FRONTEND_PORT" "$CONTAINER" bash "$FRONTEND_SCRIPT"
else
  $DOCKER_CMD exec -d -e DYN_SYSTEM_PORT="$DYN_SYSTEM_PORT1" -e PREFILL_CVD="$PREFILL_CVD" "$CONTAINER" bash "$PREFILL_SCRIPT"
  $DOCKER_CMD exec -d -e DYN_SYSTEM_PORT="$DYN_SYSTEM_PORT2" -e DECODE_CVD="$DECODE_CVD" "$CONTAINER" bash "$DECODE_SCRIPT"
  $DOCKER_CMD exec -d -e FRONTEND_PORT="$FRONTEND_PORT" "$CONTAINER" bash "$FRONTEND_SCRIPT"
fi

sleep 5
status_event "RUNNING" "endpoint_smoke" "waiting for health/models/short chat"

write_curl_request() {
  local name="$1" method="$2" path="$3" body="${4:-}"
  mkdir -p "$ARTIFACT_ROOT/backend_smoke/raw_requests" "$ARTIFACT_ROOT/backend_smoke/raw_responses"
  printf '%s %s\n%s\n' "$method" "$path" "$body" > "$ARTIFACT_ROOT/backend_smoke/raw_requests/${name}.txt"
  if [[ -n "$body" ]]; then
    printf '%s\n' "$body" > "$ARTIFACT_ROOT/backend_smoke/raw_requests/${name}.json"
  fi
}

wait_health() {
  write_curl_request health GET /health
  local deadline=$((SECONDS + 3600)) code=000
  while (( SECONDS < deadline )); do
    code="$(curl -sS --max-time 10 -o "$ARTIFACT_ROOT/backend_smoke/raw_responses/health.txt" -w '%{http_code}' "http://127.0.0.1:${FRONTEND_PORT}/health" 2> "$ARTIFACT_ROOT/backend_smoke/raw_responses/health.err" || true)"
    echo "$code" > "$ARTIFACT_ROOT/backend_smoke/health.status"
    [[ "$code" == "200" ]] && return 0
    $DOCKER_CMD ps --filter "name=$CONTAINER" --format '{{.Status}}' > "$ARTIFACT_ROOT/status/model_container_status.txt" 2>&1 || true
    $DOCKER_CMD exec "$CONTAINER" bash -lc 'for f in /artifacts/logs/*.log; do [ -f "$f" ] && echo "===== $f =====" && tail -n 80 "$f"; done' > "$ARTIFACT_ROOT/logs/wait_health_logs_tail.txt" 2>&1 || true
    sleep 20
  done
  return 1
}

wait_models() {
  write_curl_request models GET /v1/models
  local deadline=$((SECONDS + 2400)) code=000
  while (( SECONDS < deadline )); do
    code="$(curl -sS --max-time 20 -o "$ARTIFACT_ROOT/backend_smoke/raw_responses/models.json" -w '%{http_code}' "http://127.0.0.1:${FRONTEND_PORT}/v1/models" 2> "$ARTIFACT_ROOT/backend_smoke/raw_responses/models.err" || true)"
    echo "$code" > "$ARTIFACT_ROOT/backend_smoke/models.status"
    if [[ "$code" == "200" ]] && grep -q "$SERVED_MODEL_NAME" "$ARTIFACT_ROOT/backend_smoke/raw_responses/models.json"; then
      return 0
    fi
    $DOCKER_CMD exec "$CONTAINER" bash -lc 'for f in /artifacts/logs/*.log; do [ -f "$f" ] && echo "===== $f =====" && tail -n 120 "$f"; done' > "$ARTIFACT_ROOT/logs/wait_models_logs_tail.txt" 2>&1 || true
    sleep 20
  done
  return 1
}

wait_decode_ready() {
  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    $DOCKER_CMD exec "$CONTAINER" bash -lc 'for f in /artifacts/logs/frontend.log /artifacts/logs/decode.log; do [ -f "$f" ] && echo "===== $f =====" && tail -n 800 "$f"; done' > "$ARTIFACT_ROOT/logs/decode_ready_tail.txt" 2>&1 || true
    if [[ "$BACKEND" == "trtllm" ]]; then
      if grep -q "dynamo.tensorrt_llm.generate" "$ARTIFACT_ROOT/logs/decode_ready_tail.txt"; then
        return 0
      fi
    elif [[ "$BACKEND" == "vllm" || "$BACKEND" == "sglang" ]]; then
      # /v1/models may appear after prefill registration. Require the non-prefill
      # decode/backend WorkerSet before sending chat traffic.
      if grep "Adding worker set to model" "$ARTIFACT_ROOT/logs/decode_ready_tail.txt" \
        | grep "namespace.*dynamo" \
        | grep -vq "dynamo:prefill"; then
        sleep 3
        return 0
      fi
    fi
    if [[ -n "${DYN_FILE_KV:-}" ]]; then
      find "$DYN_FILE_KV" -maxdepth 6 -type f -o -type d > "$ARTIFACT_ROOT/logs/trt_discovery_tree_latest.txt" 2>&1 || true
      grep -q "tensorrt_llm.generate" "$ARTIFACT_ROOT/logs/trt_discovery_tree_latest.txt" && return 0
    fi
    sleep 10
  done
  return 1
}

short_chat() {
  local body
  body='{"model":"'"$SERVED_MODEL_NAME"'","messages":[{"role":"user","content":"Return exactly: disagg smoke ok"}],"max_tokens":8,"temperature":0,"chat_template_kwargs":{"enable_thinking":false,"force_nonempty_content":true}}'
  write_curl_request short_chat POST /v1/chat/completions "$body"
  local code
  code="$(curl -sS --max-time 180 -H 'Content-Type: application/json' -o "$ARTIFACT_ROOT/backend_smoke/raw_responses/short_chat.json" -w '%{http_code}' "http://127.0.0.1:${FRONTEND_PORT}/v1/chat/completions" -d "$body" 2> "$ARTIFACT_ROOT/backend_smoke/raw_responses/short_chat.err" || true)"
  echo "$code" > "$ARTIFACT_ROOT/backend_smoke/short_chat.status"
  [[ "$code" == "200" ]] || return 1
  python3 - "$ARTIFACT_ROOT/backend_smoke/raw_responses/short_chat.json" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1]))
content = obj["choices"][0]["message"].get("content") or ""
usage = obj.get("usage") or {}
print(content)
if content.strip() != "disagg smoke ok":
    raise SystemExit(2)
if not all(k in usage for k in ("prompt_tokens", "completion_tokens", "total_tokens")):
    raise SystemExit(3)
PY
}

wait_health || fail "endpoint_unhealthy" "endpoint_smoke" "/health did not return 200"
wait_models || fail "endpoint_registration_failure" "endpoint_smoke" "/v1/models missing $SERVED_MODEL_NAME"
wait_decode_ready || fail "decode_worker_not_ready" "endpoint_smoke" "decode worker readiness evidence missing"
short_chat > "$ARTIFACT_ROOT/backend_smoke/short_chat_content.txt" || fail "endpoint_unhealthy" "endpoint_smoke" "short chat exact check failed"
status_event "PASS" "endpoint_smoke" "health/models/short chat passed"

capture_metrics() {
  local label="$1"
  mkdir -p "$ARTIFACT_ROOT/cache_routing_diagnostic"
  curl -sS --max-time 10 "http://127.0.0.1:${FRONTEND_PORT}/metrics" > "$ARTIFACT_ROOT/cache_routing_diagnostic/${label}_metrics.prom" 2> "$ARTIFACT_ROOT/cache_routing_diagnostic/${label}_metrics.err" || true
  $DOCKER_CMD exec "$CONTAINER" bash -lc 'for f in /artifacts/logs/*.log; do [ -f "$f" ] && echo "===== $f =====" && tail -n 500 "$f"; done' > "$ARTIFACT_ROOT/cache_routing_diagnostic/${label}_logs_tail.txt" 2>&1 || true
}

capture_metrics before_aiperf

status_event "RUNNING" "aiperf" "running $WORKLOAD $POINT_ID"
POINT_ROOT="$ARTIFACT_ROOT/aiperf/mooncake/$WORKLOAD/points/$POINT_ID"
mkdir -p "$POINT_ROOT"
cat > "$POINT_ROOT/inputs.json" <<JSON
{"point_id":"$POINT_ID","backend":"$BACKEND","workload":"$WORKLOAD","request_count":$REQUEST_COUNT,"warmup_request_count":$WARMUP_REQUEST_COUNT,"concurrency":$POINT_CONCURRENCY,"trace_mode":"mooncake-trace","filtered_trace":"$FILTERED_TRACE","server_shape_id":"$SERVER_SHAPE_ID"}
JSON
cat > "$POINT_ROOT/run_point.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
cd "$ARTIFACT_ROOT"
export ARTIFACT_ROOT="$ARTIFACT_ROOT"
export BASE_URL="http://127.0.0.1:${FRONTEND_PORT}"
export SERVED_MODEL_NAME="$SERVED_MODEL_NAME"
export HF_HOME="$HF_CACHE_ROOT"
export TOKENIZER_PATH_IN_CONTAINER="$TOKENIZER_PATH_IN_CONTAINER"
export AIPERF_IMAGE="$AIPERF_IMAGE"
POINT_ID="$POINT_ID" REQUEST_COUNT="$REQUEST_COUNT" WARMUP_REQUEST_COUNT="$WARMUP_REQUEST_COUNT" POINT_CONCURRENCY="$POINT_CONCURRENCY" WARMUP_CONCURRENCY="$WARMUP_CONCURRENCY" bash "$WORKLOAD_SCRIPT"
SH
chmod +x "$POINT_ROOT/run_point.sh"
bash "$POINT_ROOT/run_point.sh" > "$POINT_ROOT/aiperf_stdout.log" 2> "$POINT_ROOT/aiperf_stderr.log" || fail "aiperf_trace_point_failed" "aiperf" "$POINT_ID failed"
test -s "$POINT_ROOT/profile_export_aiperf.json" || fail "aiperf_trace_point_failed" "aiperf" "profile_export_aiperf.json missing"

python3 - "$POINT_ROOT/profile_export_aiperf.json" "$ARTIFACT_ROOT/metrics.jsonl" "$POINT_ID" "$BACKEND" "$WORKLOAD" "$SERVER_SHAPE_ID" <<'PY' || fail "aiperf_request_errors" "aiperf" "$POINT_ID had request errors or parse failure"
import json, sys
profile, metrics, point, backend, workload, shape = sys.argv[1:7]
obj = json.load(open(profile))
errs = obj.get("error_summary")
if isinstance(errs, list):
    error_count = len(errs)
elif isinstance(errs, dict):
    vals = list(errs.values())
    error_count = sum(v for v in vals if isinstance(v, int)) if vals else 0
else:
    error_count = 0
def avg(name):
    v = obj.get(name)
    return v.get("avg") if isinstance(v, dict) else v
req_s = avg("request_throughput")
out_avg = avg("output_sequence_length")
output_tps = (req_s or 0.0) * (out_avg or 0.0)
row = {
    "point_id": point,
    "backend": backend,
    "workload": workload,
    "server_shape_id": shape,
    "profile_export": profile,
    "request_errors": error_count,
    "request_count": avg("request_count"),
    "request_throughput": req_s,
    "request_latency_avg": avg("request_latency"),
    "input_sequence_length_avg": avg("input_sequence_length"),
    "output_sequence_length_avg": out_avg,
    "output_tps": output_tps,
    "tps_gpu": output_tps / 8.0,
    "tps_user": output_tps / 1.0,
}
with open(metrics, "a") as f:
    f.write(json.dumps(row) + "\n")
if error_count:
    raise SystemExit(1)
PY

capture_metrics after_aiperf

python3 - "$ARTIFACT_ROOT/cache_routing_diagnostic" "$ARTIFACT_ROOT/analysis/cache_summary.compact.json" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
metric_names = [
    "dynamo_frontend_cached_tokens_sum",
    "dynamo_component_router_kv_hit_rate_sum",
    "dynamo_component_router_kv_hit_rate_count",
    "dynamo_component_kv_cache_events_applied",
]
def parse(path):
    vals = {}
    if not path.exists():
        return vals
    for line in path.read_text(errors="ignore").splitlines():
        if not line or line.startswith("#"):
            continue
        name = line.split("{", 1)[0].split()[0]
        if name in metric_names:
            try:
                vals[name] = vals.get(name, 0.0) + float(line.split()[-1])
            except Exception:
                pass
    return vals
before = parse(root / "before_aiperf_metrics.prom")
after = parse(root / "after_aiperf_metrics.prom")
deltas = {k: after.get(k, 0.0) - before.get(k, 0.0) for k in metric_names}
count_delta = deltas.get("dynamo_component_router_kv_hit_rate_count", 0.0)
sum_delta = deltas.get("dynamo_component_router_kv_hit_rate_sum", 0.0)
avg = (sum_delta / count_delta) if count_delta else None
log_text = "\n".join(p.read_text(errors="ignore") for p in root.glob("*logs_tail.txt"))
checked = ["cached", "cache hit", "hit_rate", "kv event", "router", "prefix", "reuse"]
log_hits = [p for p in checked if p.lower() in log_text.lower()]
positive_metric = (
    deltas.get("dynamo_frontend_cached_tokens_sum", 0.0) > 0
    or deltas.get("dynamo_component_kv_cache_events_applied", 0.0) > 0
    or (count_delta > 0 and avg is not None and avg > 0)
)
if positive_metric:
    classification = "verified_by_metrics"
elif "dynamo_component_router_kv_hit_rate_sum" in after and "dynamo_component_router_kv_hit_rate_count" not in after:
    classification = "cache_metric_count_missing"
elif log_hits:
    classification = "verified_by_logs"
else:
    classification = "not_verified_no_server_cache_evidence"
obj = {
    "evidence_paths": [str(p) for p in sorted(root.glob("*")) if p.is_file()],
    "checked_patterns": metric_names + checked,
    "metric_before": before,
    "metric_after": after,
    "metric_deltas": deltas,
    "router_kv_hit_rate_avg": avg,
    "router_kv_hit_rate_count_delta": count_delta,
    "log_hits": log_hits,
    "classification": classification,
}
(root / "summary.json").write_text(json.dumps(obj, indent=2) + "\n")
out.write_text(json.dumps(obj, indent=2) + "\n")
PY
CACHE_VERIFICATION="$(python3 -c 'import json; print(json.load(open("'"$ARTIFACT_ROOT"'/cache_routing_diagnostic/summary.json"))["classification"])')"
status_event "PASS" "aiperf" "$POINT_ID profile export OK with zero request errors"

status_event "RUNNING" "cleanup" "cleaning server containers"
cleanup
status_event "PASS" "complete" "$BACKEND $WORKLOAD filtered Mooncake canary complete"
write_run_status "PASS" "" "complete" "$CACHE_VERIFICATION"
finalize_manifest
trap - EXIT
