#!/usr/bin/env bash
# Build the released-vLLM 0.27.0 + released-ai-dynamo 1.4.0 Inkling runtime.
# Run only on an allocated aarch64 Docker compute node from a clean git checkout.
set -euo pipefail

readonly EXPECTED_VLLM_VERSION="0.27.0"
readonly VLLM_SOURCE_COMMIT="4bdc8a788d2e2ce9165d552b3d4d8b72604626bf"
readonly BASE_REPO="vllm/vllm-openai"
readonly BASE_DIGEST="sha256:7441a0579b7974fe00eec2c41a5710bcd0dc3dafc03edcdc5663158dd68286cf"
readonly BASE_REF="${BASE_REPO}@${BASE_DIGEST}"
readonly AI_DYNAMO_VERSION="1.4.0"
readonly PLATFORM="linux/arm64"
readonly IMAGE_REPO="nvcr.io/nvstaging/nim/sungsooh"
readonly IMAGE_VERSION="inkling-gb300-vllm027-v1"
readonly TARGET_IMAGE="${IMAGE_REPO}:${IMAGE_VERSION}"

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REQUIREMENTS_IN="${SCRIPT_DIR}/requirements-vllm027-dynamo14.in"
readonly LOCK_RENDERER="${SCRIPT_DIR}/render_requirements_lock.py"
readonly RUN_ID="${RUN_ID:-vllm027-$(date -u +%Y%m%dT%H%M%SZ)}"
readonly RUN_ROOT="${CAMPAIGN_RUN_ROOT:-${HOME}/inkling/runs}"
readonly OUT="${RUN_ROOT}/${RUN_ID}"
readonly CTX="/tmp/inkling-vllm027-build.${RUN_ID}.$$"

[[ "$(uname -m)" == "aarch64" ]] || { echo "FATAL: build must run on aarch64"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "FATAL: build checkout is dirty"; exit 1; }
[[ -f "${REQUIREMENTS_IN}" && -f "${LOCK_RENDERER}" ]] || { echo "FATAL: missing tracked build inputs"; exit 1; }
[[ ! -e "${OUT}/build-contract.json" ]] || { echo "FATAL: existing run contract: ${OUT}"; exit 1; }
if docker manifest inspect "${TARGET_IMAGE}" >/dev/null 2>&1; then
  echo "FATAL: immutable image tag already exists: ${TARGET_IMAGE}"
  exit 1
fi

mkdir -p "${OUT}/manifests" "${OUT}/patches" "${CTX}"
exec > >(tee -a "${OUT}/build.log") 2>&1
echo "RUN_ID=${RUN_ID} host=$(hostname) arch=$(uname -m) source=$(git rev-parse HEAD)"
trap 'rc=$?; [[ $rc -ne 0 ]] && echo "FAILED rc=$rc context=${CTX}"; exit $rc' EXIT

echo "pull pinned base ${BASE_REF}"
docker pull --platform "${PLATFORM}" "${BASE_REF}"
docker run --rm --platform "${PLATFORM}" --entrypoint /bin/bash -v "${CTX}:/out" "${BASE_REF}" -lc '
  pip freeze > /out/pre.txt
  pip check > /out/pipcheck-before.txt 2>&1 || true
  grep -Ei "^(vllm|nixl|torch|triton|flashinfer|nvidia-|cuda)==" /out/pre.txt > /out/base-engine-constraints.txt || true
'
cp "${CTX}/pre.txt" "${OUT}/manifests/pre.txt"
cp "${CTX}/pipcheck-before.txt" "${OUT}/manifests/"
cp "${CTX}/base-engine-constraints.txt" "${OUT}/manifests/"
BASE_NIXL="$(awk -F== 'tolower($1)=="nixl" {print $2; exit}' "${OUT}/manifests/pre.txt")"
[[ -n "${BASE_NIXL}" ]] || { echo "FATAL: pinned base is missing nixl transport"; exit 1; }

docker run --rm --platform "${PLATFORM}" --entrypoint /bin/bash \
  -v "${CTX}:/out" -v "${REQUIREMENTS_IN}:/inputs/requirements.in:ro" "${BASE_REF}" -lc '
    pip install --dry-run --report /out/resolve-report.json \
      --constraint /out/base-engine-constraints.txt -r /inputs/requirements.in
  '
python3 "${LOCK_RENDERER}" "${CTX}/resolve-report.json" "${CTX}/requirements.lock"
cp "${CTX}/resolve-report.json" "${OUT}/manifests/"
cp "${CTX}/requirements.lock" "${OUT}/requirements-vllm027-dynamo14.lock"
cp "${REQUIREMENTS_IN}" "${OUT}/requirements-vllm027-dynamo14.in"

cat > "${CTX}/Dockerfile" <<EOF
FROM ${BASE_REF}
SHELL ["/bin/bash", "-c"]
COPY requirements.lock /tmp/requirements.lock
COPY pipcheck-before.txt /tmp/pipcheck-before.txt
RUN pip install --require-hashes --no-deps -r /tmp/requirements.lock \\
 && { pip check > /tmp/pipcheck-after.txt 2>&1 || true; } \\
 && { if comm -13 <(sort -u /tmp/pipcheck-before.txt) <(sort -u /tmp/pipcheck-after.txt) | grep -q .; then \\
      echo "FATAL: layer introduced new pip-check failure"; exit 1; fi; } \\
 && python3 -c "import vllm; assert vllm.__version__ == '${EXPECTED_VLLM_VERSION}', vllm.__version__" \\
 && python3 -c "import dynamo.vllm.main, dynamo.vllm.instrumented_scheduler" \\
 && VLLM_TARGET_DEVICE=cpu python3 -m dynamo.vllm --help >/dev/null \\
 && rm -rf /workspace/vllm \\
 && pip freeze > /opt/inkling-vllm027-post-freeze.txt
USER 1000:0
EOF
cp "${CTX}/Dockerfile" "${OUT}/Dockerfile"
cp "${CTX}/pipcheck-before.txt" "${OUT}/pipcheck-before.txt"
cp "${CTX}/requirements.lock" "${OUT}/requirements-vllm027-dynamo14.lock"

docker build --platform "${PLATFORM}" --pull=false -t "${TARGET_IMAGE}" -f "${CTX}/Dockerfile" "${CTX}"
docker run --rm --platform "${PLATFORM}" --entrypoint /bin/cat "${TARGET_IMAGE}" /opt/inkling-vllm027-post-freeze.txt > "${OUT}/manifests/post.txt"
docker run --rm --platform "${PLATFORM}" --entrypoint /bin/cat "${TARGET_IMAGE}" /tmp/pipcheck-after.txt > "${OUT}/pipcheck-after.txt"
diff -u "${OUT}/manifests/pre.txt" "${OUT}/manifests/post.txt" > "${OUT}/manifests/diff.txt" || true
if grep -qiE '^[-+](vllm|nixl|torch|triton|flashinfer|nvidia-|cuda)' "${OUT}/manifests/diff.txt"; then
  echo "FATAL: engine or CUDA-stack package moved"
  exit 1
fi
docker run --rm --platform "${PLATFORM}" --entrypoint /bin/bash "${TARGET_IMAGE}" -lc '
  pip show vllm ai-dynamo ai-dynamo-runtime
  python3 -c "import vllm, dynamo.vllm; print(vllm.__version__)"
' | tee "${OUT}/in-image-provenance.txt"

printf 'patches: []\nreason: released-vllm-base-and-released-ai-dynamo-package; no source overlay\n' > "${OUT}/patches/stack.yaml"
(cd "${OUT}" && sha256sum Dockerfile requirements-vllm027-dynamo14.in requirements-vllm027-dynamo14.lock patches/stack.yaml manifests/pre.txt manifests/post.txt manifests/resolve-report.json) > "${OUT}/patch-manifest.sha256"

docker push "${TARGET_IMAGE}"
IMAGE_DIGEST="$(docker manifest inspect -v "${TARGET_IMAGE}" | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(d.get("Descriptor",{}).get("digest") or d.get("descriptor",{}).get("digest", ""))')"
[[ -n "${IMAGE_DIGEST}" ]] || { echo "FATAL: registry digest unavailable"; exit 1; }
printf '%s@%s\n' "${IMAGE_REPO}" "${IMAGE_DIGEST}" | tee "${OUT}/image-digest.txt"

RUN_COMMIT="$(git rev-parse HEAD)"
export OUT RUN_ID RUN_COMMIT IMAGE_DIGEST BASE_NIXL
python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
out = Path(os.environ["OUT"])
sha = lambda path: hashlib.sha256((out / path).read_bytes()).hexdigest()
contract = {
  "lane": "vllm", "build_mode": "mode-2-base-plus-pip", "patch_mode": "baked", "plan_rev": 29,
  "source": {"repo": "https://github.com/sungsooha/dynamo", "commit": os.environ["RUN_COMMIT"], "branch": "inkling-vllm027-release", "build_pattern_reference": "ai-dynamo/dynamo PR 10234"},
  "base": {"tag": "vllm/vllm-openai:v0.27.0", "digest": "sha256:7441a0579b7974fe00eec2c41a5710bcd0dc3dafc03edcdc5663158dd68286cf", "ref": "vllm/vllm-openai@sha256:7441a0579b7974fe00eec2c41a5710bcd0dc3dafc03edcdc5663158dd68286cf", "vllm_source_commit": "4bdc8a788d2e2ce9165d552b3d4d8b72604626bf"},
  "platform": "linux/arm64", "target_arch": "aarch64",
  "dependency_pin_override": {
    "declared": "ai-dynamo[vllm]==1.4.0 requires vllm[flashinfer,otel,runai]==0.26.0",
    "used": "ai-dynamo==1.4.0 plus the vllm-extra companion requirements excluding its vllm line, resolved under base engine/CUDA constraints; NIXL is intentionally unpinned and retained from the base",
    "abi_evidence": "33/33 direct modules and 54/54 named imports present at vLLM 0.26.0 and 0.27.0; used changes are backward-compatible optional additions; Dynamo later v0.27.1 bump required only a contract test",
    "verdict": "SOURCE_COMPATIBLE", "runtime_verified": False
  },
  "base_preserved_transport": {"nixl": os.environ["BASE_NIXL"], "reason": "base-constrained; do not override the digest-pinned transport ABI"},
  "lock": {"file": "requirements-vllm027-dynamo14.lock", "sha256": sha("requirements-vllm027-dynamo14.lock")},
  "resolver_report": {"file": "manifests/resolve-report.json", "sha256": sha("manifests/resolve-report.json")},
  "patch_stack": [], "patch_manifest": {"file": "patch-manifest.sha256", "sha256": sha("patch-manifest.sha256")},
  "run_id": os.environ["RUN_ID"], "run_dir": str(out),
  "output": {"image_repo": "nvcr.io/nvstaging/nim/sungsooh", "image_version": "inkling-gb300-vllm027-v1", "image_ref": "nvcr.io/nvstaging/nim/sungsooh:inkling-gb300-vllm027-v1", "image_digest": os.environ["IMAGE_DIGEST"], "image_digest_ref": "nvcr.io/nvstaging/nim/sungsooh@" + os.environ["IMAGE_DIGEST"], "published": True, "serve_verified": False},
  "smoke": {"required": True, "status": "NOT_RUN", "upgrade_condition": "digest-pinned GB300 Service-DNS models 200 plus nonempty chat 200 with hashed artifacts"},
  "artifact_sha256": {name: sha(name) for name in ["Dockerfile", "requirements-vllm027-dynamo14.in", "requirements-vllm027-dynamo14.lock", "patches/stack.yaml", "patch-manifest.sha256", "in-image-provenance.txt"]}
}
(out / "build-contract.json").write_text(json.dumps(contract, indent=2) + "\n")
PY
echo "BUILT ${IMAGE_REPO}@${IMAGE_DIGEST}; serve_verified=false pending smoke"
rm -rf "${CTX}"
trap - EXIT
