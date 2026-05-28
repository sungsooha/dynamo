#!/usr/bin/env bash
set -euo pipefail

# One-click bounded QA wrapper for the Nemotron Ultra reasoning API
# compatibility endpoint on the old validated Patch06+humming recipe base. It
# launches a public proxy endpoint in front of the Dynamo frontend and removes
# only containers created by this script.

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUBCOMMAND="${1:-all}"
if [ "$#" -gt 0 ]; then
  shift
fi

: "${MODEL_PATH:?Set MODEL_PATH to the host Ultra model/cache view}"

RUN_TS="${RUN_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
TRACK="${TRACK:-nemotron-ultra-phase0-v3}"
ACTION_ID="${ACTION_ID:-VLLM_OLD_BASE_REASONING_API_QA}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/vllm_old_base_reasoning_api_qa_${RUN_TS}}"
IMAGE="${IMAGE:-nemotron-3-ultra-vllm-reasoning:dev}"
BUILD_IMAGE="${BUILD_IMAGE:-0}"
DOCKER_BIN="${DOCKER_BIN:-}"
if [ -z "${DOCKER_BIN}" ]; then
  if docker ps >/dev/null 2>&1; then
    DOCKER_BIN="docker"
  else
    DOCKER_BIN="sudo docker"
  fi
fi
read -r -a docker_cmd <<<"${DOCKER_BIN}"
DOCKER_BUILD_ARGS="${DOCKER_BUILD_ARGS:-}"
read -r -a docker_build_args <<<"${DOCKER_BUILD_ARGS}"

SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-nemotron-ultra-ea}"
GPU_SET="${GPU_SET:-0,1,2,3}"
GPU_DEVICE_REQUEST="${GPU_DEVICE_REQUEST:-\"device=${GPU_SET}\"}"
PORT="${PORT:-18000}"
INNER_FRONTEND_PORT="${INNER_FRONTEND_PORT:-18001}"
ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-22379}"
ETCD_PEER_PORT="${ETCD_PEER_PORT:-22380}"
ETCD_IMAGE="${ETCD_IMAGE:-gcr.io/etcd-development/etcd:v3.6.7}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-32}"
MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS:-32768}"
BLOCK_SIZE="${BLOCK_SIZE:-64}"
SPEC_METHOD="${SPEC_METHOD:-nemotron_h_mtp}"
SPEC_TOKENS="${SPEC_TOKENS:-1}"
ENFORCE_EAGER="${ENFORCE_EAGER:-0}"
if [ "${ENFORCE_EAGER}" = "1" ]; then
  EVIDENCE_CLASS="${EVIDENCE_CLASS:-debug_eager_only}"
  PROMOTION_ELIGIBLE="${PROMOTION_ELIGIBLE:-false}"
else
  EVIDENCE_CLASS="${EVIDENCE_CLASS:-qa_candidate}"
  PROMOTION_ELIGIBLE="${PROMOTION_ELIGIBLE:-true}"
fi
READY_TIMEOUT_S="${READY_TIMEOUT_S:-1800}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-10}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-ultra-vllm-oldbase-qa-${RUN_TS}}"
SERVER_CONTAINER="${SERVER_CONTAINER:-${CONTAINER_PREFIX}-server}"
ETCD_CONTAINER="${ETCD_CONTAINER:-${CONTAINER_PREFIX}-etcd}"

MODEL_PARENT="$(dirname "${MODEL_PATH}")"
MODEL_VIEW_NAME="$(basename "${MODEL_PATH}")"
if [ "$(basename "${MODEL_PARENT}")" = "patched" ]; then
  HOST_MODEL_MOUNT_ROOT="${HOST_MODEL_MOUNT_ROOT:-$(dirname "${MODEL_PARENT}")}"
  CONTAINER_MODEL_MOUNT_ROOT="${CONTAINER_MODEL_MOUNT_ROOT:-/opt/models}"
  CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-${CONTAINER_MODEL_MOUNT_ROOT}/patched/${MODEL_VIEW_NAME}}"
else
  HOST_MODEL_MOUNT_ROOT="${HOST_MODEL_MOUNT_ROOT:-${MODEL_PATH}}"
  CONTAINER_MODEL_MOUNT_ROOT="${CONTAINER_MODEL_MOUNT_ROOT:-/model}"
  CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-/model}"
fi

mkdir -p "${ARTIFACT_ROOT}"/{cleanup,commands,logs,preflight,raw_requests,raw_responses,smoke,status,summary}
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
row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "status": status, "stage": stage, "message": message}
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
row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "failure_class": failure_class, "stage": stage, "message": message}
with open(path, "a") as f:
    f.write(json.dumps(row, sort_keys=True) + "\n")
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
row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "id": command_id, "script": script, "argv": argv}
with open(path, "a") as f:
    f.write(json.dumps(row, sort_keys=True) + "\n")
PY
}

write_run_config() {
  python3 - "$ARTIFACT_ROOT/run_config.json" <<PY
import json, time
payload = {
  "track": "${TRACK}",
  "action_id": "${ACTION_ID}",
  "artifact_root": "${ARTIFACT_ROOT}",
  "image": "${IMAGE}",
  "docker_build_args": ${DOCKER_BUILD_ARGS@Q},
  "model": "${SERVED_MODEL_NAME}",
  "host_model_path": "${MODEL_PATH}",
  "host_model_mount_root": "${HOST_MODEL_MOUNT_ROOT}",
  "container_model_path": "${CONTAINER_MODEL_PATH}",
  "public_endpoint": "http://127.0.0.1:${PORT}",
  "inner_frontend_endpoint": "http://127.0.0.1:${INNER_FRONTEND_PORT}",
  "gpu_set": "${GPU_SET}",
  "max_model_len": int("${MAX_MODEL_LEN}"),
  "max_num_seqs": int("${MAX_NUM_SEQS}"),
  "max_num_batched_tokens": int("${MAX_BATCHED_TOKENS}"),
  "block_size": int("${BLOCK_SIZE}"),
  "spec_method": "${SPEC_METHOD}",
  "spec_tokens": int("${SPEC_TOKENS}"),
  "enforce_eager": "${ENFORCE_EAGER}" == "1",
  "evidence_class": "${EVIDENCE_CLASS}",
  "promotion_eligible": "${PROMOTION_ELIGIBLE}" == "true",
  "reasoning_api_component": "06_dynamo_reasoning_api_compat_proxy",
  "recipe_base": "patch06-humming-20260521",
  "dashboard_row_ready": "no",
  "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
open("${ARTIFACT_ROOT}/run_config.json", "w").write(json.dumps(payload, indent=2, sort_keys=True) + "\\n")
PY
  printf '{"quality_requested": false, "reason": "reasoning API QA matrix only"}\n' >"${ARTIFACT_ROOT}/quality_not_requested.json"
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
  "public_endpoint": "http://127.0.0.1:${PORT}",
  "server_container": "${SERVER_CONTAINER}",
  "etcd_container": "${ETCD_CONTAINER}",
  "evidence_class": "${EVIDENCE_CLASS}",
  "promotion_eligible": "${PROMOTION_ELIGIBLE}" == "true",
  "dashboard_row_ready": "no",
  "updated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
open(path, "w").write(json.dumps(payload, indent=2, sort_keys=True) + "\\n")
PY
}

finalize_artifacts() {
  python3 - "$ARTIFACT_ROOT" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
cmds = root / "generated_commands.jsonl"
rows = [json.loads(line) for line in cmds.read_text().splitlines() if line.strip()]
(root / "generated_commands.json").write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
manifest = []
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    rel = path.relative_to(root)
    manifest.append(f"{rel}\t{path.stat().st_size}\t{hashlib.sha256(path.read_bytes()).hexdigest()}")
(root / "manifest.tsv").write_text("\n".join(manifest) + "\n")
PY
}

capture_logs() {
  "${docker_cmd[@]}" logs "${SERVER_CONTAINER}" >"${ARTIFACT_ROOT}/logs/server_container.log" 2>&1 || true
  "${docker_cmd[@]}" logs "${ETCD_CONTAINER}" >"${ARTIFACT_ROOT}/logs/etcd_container.log" 2>&1 || true
  "${docker_cmd[@]}" cp "${SERVER_CONTAINER}:/artifacts/server" "${ARTIFACT_ROOT}/logs/server_artifacts" >/dev/null 2>&1 || true
}

preflight() {
  status_event RUNNING preflight "starting QA preflight"
  write_run_config
  hostname >"${ARTIFACT_ROOT}/preflight/hostname.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${ARTIFACT_ROOT}/preflight/date_utc.txt"
  "${docker_cmd[@]}" --version >"${ARTIFACT_ROOT}/preflight/docker_version.txt"
  "${docker_cmd[@]}" ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' >"${ARTIFACT_ROOT}/preflight/docker_ps_before.tsv"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L >"${ARTIFACT_ROOT}/preflight/nvidia_smi_L.txt" 2>&1 || true
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv \
      >"${ARTIFACT_ROOT}/preflight/gpu_before.csv" 2>&1 || true
  fi
  for file in config.json tokenizer_config.json tokenizer.json ultra_v3_reasoning_parser.py; do
    if [ ! -r "${MODEL_PATH}/${file}" ]; then
      record_failure "preflight/model_path_missing" preflight "missing ${MODEL_PATH}/${file}"
      return 1
    fi
  done
  find "${MODEL_PATH}" -maxdepth 1 -type f -o -type l | sort >"${ARTIFACT_ROOT}/preflight/model_files.txt"
  if [ "${BUILD_IMAGE}" = "1" ]; then
    build_cmd=("${docker_cmd[@]}" build "${docker_build_args[@]}" -t "${IMAGE}" -f "${RECIPE_DIR}/Dockerfile" "${RECIPE_DIR}")
    record_command docker_build "${build_cmd[@]}"
    "${build_cmd[@]}" >"${ARTIFACT_ROOT}/logs/docker_build.log" 2>&1 || {
      record_failure image_build_failure preflight "docker build failed"
      return 1
    }
  fi
  inspect_cmd=("${docker_cmd[@]}" image inspect "${IMAGE}")
  record_command image_inspect "${inspect_cmd[@]}"
  "${inspect_cmd[@]}" >"${ARTIFACT_ROOT}/preflight/image_inspect.json" 2>"${ARTIFACT_ROOT}/preflight/image_inspect.err" || {
    record_failure image_inspect_failed preflight "docker image inspect failed"
    return 1
  }
  status_event PASS preflight "preflight passed"
}

launch() {
  preflight || return 1
  status_event RUNNING launch "starting public reasoning endpoint"
  "${docker_cmd[@]}" rm -f "${SERVER_CONTAINER}" "${ETCD_CONTAINER}" >/dev/null 2>&1 || true
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
  "${etcd_cmd[@]}" >"${ARTIFACT_ROOT}/status/etcd_container_id.txt"
  sleep 2

  host_uid="$(id -u)"
  host_gid="$(id -g)"
  host_user="$(id -un)"
  server_cmd=(
    "${docker_cmd[@]}" run -d --name "${SERVER_CONTAINER}"
    --network host --ipc host --user "${host_uid}:${host_gid}"
    --gpus "${GPU_DEVICE_REQUEST}"
    --tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
    --tmpfs /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
    --ulimit memlock=-1 --ulimit stack=67108864
    -v "${HOST_MODEL_MOUNT_ROOT}:${CONTAINER_MODEL_MOUNT_ROOT}:ro"
    -v "${ARTIFACT_ROOT}:/artifacts"
    -e HOME=/tmp -e USER="${host_user}" -e LOGNAME="${host_user}"
    -e MODEL_PATH="${CONTAINER_MODEL_PATH}"
    -e SERVED_MODEL_NAME="${SERVED_MODEL_NAME}"
    -e LOG_DIR=/artifacts/server
    -e FRONTEND_PORT="${PORT}"
    -e INNER_FRONTEND_PORT="${INNER_FRONTEND_PORT}"
    -e ENABLE_REASONING_API_PROXY=1
    -e ETCD_ENDPOINTS="http://127.0.0.1:${ETCD_CLIENT_PORT}"
    -e MAX_MODEL_LEN="${MAX_MODEL_LEN}"
    -e MAX_NUM_SEQS="${MAX_NUM_SEQS}"
    -e MAX_BATCHED_TOKENS="${MAX_BATCHED_TOKENS}"
    -e BLOCK_SIZE="${BLOCK_SIZE}"
    -e AGG_WORKERS=1
    -e SPEC_METHOD="${SPEC_METHOD}"
    -e SPEC_TOKENS="${SPEC_TOKENS}"
    -e SPEC_CLI_STYLE=legacy
    -e ENFORCE_EAGER="${ENFORCE_EAGER}"
    -e WORKER0_CVD=0,1,2,3
    -e VLLM_SSM_CONV_STATE_LAYOUT=DS
    "${IMAGE}"
    bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_aggregate.sh
  )
  record_command docker_run_server "${server_cmd[@]}"
  "${server_cmd[@]}" >"${ARTIFACT_ROOT}/status/server_container_id.txt"
  sleep 3
  "${docker_cmd[@]}" exec "${SERVER_CONTAINER}" nvidia-smi -L \
    >"${ARTIFACT_ROOT}/smoke/inside_container_nvidia_smi.txt" 2>&1 || true
  wait_for_endpoint || return 1
  cat >"${ARTIFACT_ROOT}/qa_env.sh" <<EOF
export BASE_URL=http://127.0.0.1:${PORT}
export ARTIFACT_ROOT=${ARTIFACT_ROOT}
export SERVER_CONTAINER=${SERVER_CONTAINER}
export ETCD_CONTAINER=${ETCD_CONTAINER}
export IMAGE=${IMAGE}
EOF
  status_event PASS launch "public endpoint ready"
  write_run_status RUNNING none
}

wait_for_endpoint() {
  status_event RUNNING endpoint "waiting for /health and /v1/models"
  local deadline=$((SECONDS + READY_TIMEOUT_S))
  until curl -fsS "http://127.0.0.1:${PORT}/health" >"${ARTIFACT_ROOT}/smoke/health.json" 2>"${ARTIFACT_ROOT}/smoke/health.err"; do
    if [ "${SECONDS}" -gt "${deadline}" ]; then
      record_failure health_timeout endpoint "health timeout"
      capture_logs
      return 1
    fi
    sleep "${POLL_INTERVAL_S}"
  done
  deadline=$((SECONDS + READY_TIMEOUT_S))
  until curl -fsS "http://127.0.0.1:${PORT}/v1/models" >"${ARTIFACT_ROOT}/smoke/models.json" 2>"${ARTIFACT_ROOT}/smoke/models.err" && grep -q "${SERVED_MODEL_NAME}" "${ARTIFACT_ROOT}/smoke/models.json"; do
    if [ "${SECONDS}" -gt "${deadline}" ]; then
      record_failure model_context_mismatch endpoint "model did not register"
      capture_logs
      return 1
    fi
    sleep "${POLL_INTERVAL_S}"
  done
  python3 - "$ARTIFACT_ROOT/smoke/models.json" "$MAX_MODEL_LEN" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
expected = int(sys.argv[2])
models = payload.get("data") or []
ctx = models[0].get("context_window") if models else None
if ctx is not None and int(ctx) != expected:
    raise SystemExit(f"context_window={ctx} expected={expected}")
PY
  exact_short_chat
}

exact_short_chat() {
  python3 - "$ARTIFACT_ROOT" "http://127.0.0.1:${PORT}" "${SERVED_MODEL_NAME}" <<'PY'
import json, pathlib, sys, time, urllib.error, urllib.request
root = pathlib.Path(sys.argv[1])
base = sys.argv[2]
model = sys.argv[3]
payload = {
    "model": model,
    "messages": [{"role": "user", "content": "Reply with exactly: recipe qa ok"}],
    "temperature": 0,
    "max_tokens": 32,
    "chat_template_kwargs": {"enable_thinking": False, "force_nonempty_content": True},
}
(root / "smoke" / "exact_chat_request.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
attempts = root / "smoke" / "exact_chat_attempts.jsonl"
for attempt in range(1, 37):
    status = None
    body = ""
    try:
        req = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(payload).encode(), headers={"content-type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=120) as resp:
            status = resp.status
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        status = exc.code
        body = exc.read().decode("utf-8", "replace")
    except Exception as exc:
        body = repr(exc)
    attempts.open("a").write(json.dumps({"attempt": attempt, "status": status, "body": body[:2000]}) + "\n")
    if status == 200:
        parsed = json.loads(body)
        content = ((parsed.get("choices") or [{}])[0].get("message") or {}).get("content", "").strip()
        if content == "recipe qa ok":
            (root / "smoke" / "exact_chat_response.json").write_text(json.dumps(parsed, indent=2, sort_keys=True) + "\n")
            raise SystemExit(0)
    time.sleep(5)
raise SystemExit(2)
PY
}

matrix() {
  status_event RUNNING qa_matrix "running reasoning API matrix"
  cat >"${ARTIFACT_ROOT}/commands/run_reasoning_api_matrix.py" <<'PY'
#!/usr/bin/env python3
import json, pathlib, sys, time, urllib.error, urllib.request

root = pathlib.Path(sys.argv[1])
base_url = sys.argv[2].rstrip("/")
model = sys.argv[3]
raw_req = root / "raw_requests"
raw_resp = root / "raw_responses"
summary_dir = root / "summary"
raw_req.mkdir(parents=True, exist_ok=True)
raw_resp.mkdir(parents=True, exist_ok=True)
summary_dir.mkdir(parents=True, exist_ok=True)

def reasoning_usage(row):
    usage = row.get("usage") or {}
    return usage.get("reasoning_tokens") or ((usage.get("output_tokens_details") or {}).get("reasoning_tokens"))

def post_case(name, payload, stream=False, timeout=600):
    payload = dict(payload)
    if stream:
        payload["stream"] = True
        payload.setdefault("stream_options", {"include_usage": True})
    safe = name.replace("/", "_")
    (raw_req / f"{safe}.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    row = {"name": name, "stream": stream, "status": None, "ok": False, "error": None, "content_chars": 0, "reasoning_chars": 0, "has_reasoning_content": False, "usage": None, "raw_response_path": str(raw_resp / f"{safe}.body")}
    req = urllib.request.Request(base_url + "/v1/chat/completions", data=json.dumps(payload).encode(), headers={"content-type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
            row["status"] = resp.status
            row["ok"] = 200 <= resp.status < 300
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        row["status"] = exc.code
        row["error"] = body[:1000]
    except Exception as exc:
        body = repr(exc)
        row["error"] = body
    (raw_resp / f"{safe}.body").write_text(body)
    if row["status"] and row["status"] < 400 and not stream:
        parsed = json.loads(body)
        (raw_resp / f"{safe}.json").write_text(json.dumps(parsed, indent=2, sort_keys=True) + "\n")
        msg = ((parsed.get("choices") or [{}])[0].get("message") or {})
        reasoning = msg.get("reasoning_content") or ""
        row["content_chars"] = len(msg.get("content") or "")
        row["reasoning_chars"] = len(reasoning)
        row["has_reasoning_content"] = bool(reasoning)
        row["usage"] = parsed.get("usage")
    elif row["status"] and row["status"] < 400 and stream:
        reasoning_parts, content_parts, usage = [], [], None
        done = False
        for line in body.splitlines():
            line = line.strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                done = True
                continue
            try:
                event = json.loads(data)
            except Exception:
                continue
            if event.get("usage"):
                usage = event["usage"]
            for choice in event.get("choices") or []:
                delta = choice.get("delta") or {}
                if delta.get("reasoning_content"):
                    reasoning_parts.append(delta["reasoning_content"])
                if delta.get("content"):
                    content_parts.append(delta["content"])
        row["content_chars"] = len("".join(content_parts))
        row["reasoning_chars"] = len("".join(reasoning_parts))
        row["has_reasoning_content"] = bool(reasoning_parts)
        row["usage"] = usage
        row["stream_done"] = done
    row["reasoning_usage"] = reasoning_usage(row)
    return row

simple = {"model": model, "messages": [{"role": "user", "content": "What is 2+2?"}], "temperature": 0, "max_tokens": 1024}
explain = {"model": model, "messages": [{"role": "user", "content": "Explain the Pythagorean theorem step by step with intermediate reasoning."}], "temperature": 0, "max_tokens": 2048}
multi = {"model": model, "messages": [{"role": "user", "content": "Solve this carefully: A train travels 135 miles in 3 hours, then 90 miles in 2 hours. Compare both speeds and explain the calculation."}], "temperature": 0, "max_tokens": 2048}
cases = [
    ("baseline_simple_nonstream", simple, False),
    ("baseline_simple_stream", simple, True),
    ("include_reasoning_true_nonstream", {**simple, "include_reasoning": True}, False),
    ("include_reasoning_true_stream", {**simple, "include_reasoning": True}, True),
    ("include_reasoning_false_nonstream", {**simple, "include_reasoning": False}, False),
    ("include_reasoning_false_stream", {**simple, "include_reasoning": False}, True),
    ("thinking_budget_10_nonstream", {**explain, "thinking_token_budget": 10}, False),
    ("thinking_budget_10_stream", {**explain, "thinking_token_budget": 10}, True),
    ("thinking_budget_100_nonstream", {**explain, "thinking_token_budget": 100}, False),
    ("reasoning_effort_none_nonstream", {**simple, "reasoning_effort": "none"}, False),
    ("reasoning_effort_none_stream", {**simple, "reasoning_effort": "none"}, True),
    ("reasoning_effort_low_nonstream", {**multi, "reasoning_effort": "low"}, False),
    ("reasoning_effort_high_nonstream", {**multi, "reasoning_effort": "high"}, False),
    ("usage_reasoning_tokens_nonstream", {**explain, "include_reasoning": True}, False),
    ("control_enable_thinking_false_nonstream", {**simple, "chat_template_kwargs": {"enable_thinking": False, "force_nonempty_content": True}}, False),
]
rows = []
for name, payload, stream in cases:
    row = post_case(name, payload, stream=stream)
    rows.append(row)
    print(json.dumps(row, sort_keys=True), flush=True)
    time.sleep(0.5)
by = {row["name"]: row for row in rows}
tickets = {}
tickets["6230473"] = {
    "status": "PASS" if all(by[n]["status"] == 200 for n in [
        "include_reasoning_true_nonstream", "include_reasoning_true_stream",
        "include_reasoning_false_nonstream", "include_reasoning_false_stream",
        "thinking_budget_10_nonstream", "thinking_budget_10_stream", "thinking_budget_100_nonstream",
    ]) and by["thinking_budget_10_nonstream"]["reasoning_chars"] <= by["thinking_budget_100_nonstream"]["reasoning_chars"] else "FAIL",
}
usage_row = by["usage_reasoning_tokens_nonstream"]
tickets["6230496"] = {
    "status": "PASS" if usage_row["has_reasoning_content"] and (usage_row.get("reasoning_usage") or 0) > 0 else "FAIL",
}
low, high = by["reasoning_effort_low_nonstream"], by["reasoning_effort_high_nonstream"]
none_ok = by["reasoning_effort_none_nonstream"]["status"] == 200 and not by["reasoning_effort_none_nonstream"]["has_reasoning_content"]
tickets["6230578"] = {
    "status": "PASS" if none_ok and low["status"] == 200 and high["status"] == 200 and (high.get("reasoning_usage") or high["reasoning_chars"]) >= (low.get("reasoning_usage") or low["reasoning_chars"]) else "FAIL",
}
control_ok = by["control_enable_thinking_false_nonstream"]["status"] == 200 and not by["control_enable_thinking_false_nonstream"]["has_reasoning_content"]
summary = {"rows": rows, "tickets": tickets, "control_enable_thinking_false": "PASS" if control_ok else "FAIL", "overall_status": "PASS" if all(v["status"] == "PASS" for v in tickets.values()) and control_ok else "PASS_PARTIAL"}
(summary_dir / "reasoning_api_matrix.json").write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
(summary_dir / "qa_ticket_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
with (summary_dir / "reasoning_api_matrix.tsv").open("w") as f:
    f.write("name\tstream\tstatus\tok\treasoning_chars\treasoning_usage\tcontent_chars\terror\traw_response_path\n")
    for row in rows:
        f.write(f"{row['name']}\t{row['stream']}\t{row['status']}\t{row['ok']}\t{row['reasoning_chars']}\t{row.get('reasoning_usage')}\t{row['content_chars']}\t{json.dumps(row.get('error'))}\t{row['raw_response_path']}\n")
print(json.dumps(summary, indent=2, sort_keys=True))
raise SystemExit(0 if summary["overall_status"] == "PASS" else 3)
PY
  record_command qa_matrix python3 "${ARTIFACT_ROOT}/commands/run_reasoning_api_matrix.py" "${ARTIFACT_ROOT}" "http://127.0.0.1:${PORT}" "${SERVED_MODEL_NAME}"
  python3 "${ARTIFACT_ROOT}/commands/run_reasoning_api_matrix.py" "${ARTIFACT_ROOT}" "http://127.0.0.1:${PORT}" "${SERVED_MODEL_NAME}" \
    >"${ARTIFACT_ROOT}/summary/reasoning_api_matrix.stdout" 2>&1 || {
      record_failure qa_api_matrix_failure qa_matrix "QA matrix did not fully pass"
      return 1
    }
  cat "${ARTIFACT_ROOT}/summary/reasoning_api_matrix.tsv"
  status_event PASS qa_matrix "QA matrix passed"
}

cleanup() {
  status_event RUNNING cleanup "stopping recipe QA containers"
  capture_logs
  "${docker_cmd[@]}" rm -f "${SERVER_CONTAINER}" "${ETCD_CONTAINER}" >"${ARTIFACT_ROOT}/cleanup/docker_rm.log" 2>&1 || true
  "${docker_cmd[@]}" ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' >"${ARTIFACT_ROOT}/cleanup/docker_ps_after.tsv" 2>&1 || true
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv \
      >"${ARTIFACT_ROOT}/cleanup/gpu_after_cleanup.csv" 2>&1 || true
  fi
  python3 - "$ARTIFACT_ROOT/cleanup_status.json" "$ARTIFACT_ROOT/cleanup/docker_ps_after.tsv" "$ARTIFACT_ROOT/cleanup/gpu_after_cleanup.csv" "$CONTAINER_PREFIX" <<'PY'
import json, pathlib, sys, time
out, docker_path, gpu_path = map(pathlib.Path, sys.argv[1:4])
container_prefix = sys.argv[4]
docker_text = docker_path.read_text(errors="ignore") if docker_path.exists() else ""
payload = {
    "updated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "packet_containers_removed": container_prefix not in docker_text,
    "docker_ps_after_path": str(docker_path),
    "gpu_after_cleanup_path": str(gpu_path),
}
out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
  status_event PASS cleanup "cleanup completed"
  finalize_artifacts
}

case "${SUBCOMMAND}" in
  launch)
    launch
    finalize_artifacts
    ;;
  matrix)
    matrix
    if [ "${ENFORCE_EAGER}" = "1" ]; then
      write_run_status PASS_DIAGNOSTIC none
    else
      write_run_status PASS none
    fi
    finalize_artifacts
    ;;
  cleanup)
    cleanup
    ;;
  all)
    rc=0
    launch || rc=$?
    if [ "${rc}" = "0" ]; then
      matrix || rc=$?
    fi
    if [ "${rc}" = "0" ]; then
      if [ "${ENFORCE_EAGER}" = "1" ]; then
        write_run_status PASS_DIAGNOSTIC none
      else
        write_run_status PASS none
      fi
    else
      write_run_status PASS_PARTIAL qa_api_matrix_failure
    fi
    cleanup
    exit "${rc}"
    ;;
  *)
    echo "usage: $0 {launch|matrix|cleanup|all}" >&2
    exit 2
    ;;
esac
