#!/usr/bin/env bash
# Build the SGLang 0.5.16 + PD-transfer correctness backport runtime for Inkling.
# Run only on an allocated aarch64 Docker compute node from a clean git checkout.
set -euo pipefail

readonly EXPECTED_SGLANG_VERSION="0.5.16"
readonly SGLANG_SOURCE_COMMIT="fdebc938f7f4d16fe6b9f55dcd9a767cf0899ea1"
readonly BACKPORT_COMMIT="ac019b014d33cbca63b062f86ac6978e7a7acb3c"
readonly UPSTREAM_FIX_COMMIT="ba97cc6397ac98b0d889609598cc18ad365d462c"
readonly BASE_REPO="lmsysorg/sglang"
readonly BASE_DIGEST="sha256:f082dfc7e734f1956e9a023157c5a82d7c1ebe0cd689dcad7163f4f57ebc2e60"
readonly BASE_REF="${BASE_REPO}@${BASE_DIGEST}"
readonly AI_DYNAMO_VERSION="1.4.0"
readonly PLATFORM="linux/arm64"
readonly IMAGE_REPO="nvcr.io/nvstaging/nim/sungsooh"
readonly IMAGE_VERSION="inkling-gb300-sglang-pd35689-v1"
readonly TARGET_IMAGE="${IMAGE_REPO}:${IMAGE_VERSION}"

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REQUIREMENTS_IN="${SCRIPT_DIR}/requirements-sglang0516-dynamo14.in"
readonly LOCK_RENDERER="${SCRIPT_DIR}/render_requirements_lock.py"
readonly RUNTIME_PATCH="${SCRIPT_DIR}/0001-pd35689-skip-empty-linear-state.runtime.patch"
readonly REGRESSION_TEST="${SCRIPT_DIR}/test_mamba_state_transfer_buffers.py"
readonly RUN_ID="${RUN_ID:-sglang-pd35689-$(date -u +%Y%m%dT%H%M%SZ)}"
readonly RUN_ROOT="${CAMPAIGN_RUN_ROOT:-${HOME}/inkling/runs}"
readonly OUT="${RUN_ROOT}/${RUN_ID}"
readonly CTX="/tmp/inkling-sglang-pd35689-build.${RUN_ID}.$$"

[[ "$(uname -m)" == "aarch64" ]] || { echo "FATAL: build must run on aarch64"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "FATAL: build checkout is dirty"; exit 1; }
[[ -f "${REQUIREMENTS_IN}" && -f "${LOCK_RENDERER}" && -f "${RUNTIME_PATCH}" && -f "${REGRESSION_TEST}" ]] || { echo "FATAL: missing tracked build input"; exit 1; }
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
  grep -Ei "^(sglang|nixl|torch|triton|flashinfer|nvidia-|cuda)==" /out/pre.txt > /out/base-engine-constraints.txt || true
'
cp "${CTX}/pre.txt" "${OUT}/manifests/pre.txt"
cp "${CTX}/pipcheck-before.txt" "${OUT}/"
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
cp "${CTX}/requirements.lock" "${OUT}/requirements-sglang0516-dynamo14.lock"
cp "${REQUIREMENTS_IN}" "${OUT}/requirements-sglang0516-dynamo14.in"
cp "${RUNTIME_PATCH}" "${OUT}/patches/"
cp "${REGRESSION_TEST}" "${OUT}/patches/"

cat > "${CTX}/Dockerfile" <<EOF
FROM ${BASE_REF}
SHELL ["/bin/bash", "-c"]
COPY requirements.lock /tmp/requirements.lock
COPY pipcheck-before.txt /tmp/pipcheck-before.txt
COPY 0001-pd35689-skip-empty-linear-state.runtime.patch /tmp/pd35689.patch
COPY test_mamba_state_transfer_buffers.py /tmp/test_mamba_state_transfer_buffers.py
RUN pip install --require-hashes --no-deps -r /tmp/requirements.lock \\
 && { pip check > /tmp/pipcheck-after.txt 2>&1 || true; } \\
 && { if comm -13 <(sort -u /tmp/pipcheck-before.txt) <(sort -u /tmp/pipcheck-after.txt) | grep -q .; then \\
      echo "FATAL: layer introduced new pip-check failure"; exit 1; fi; } \\
 && patch --batch --forward --dry-run -p2 -d /sgl-workspace/sglang/python < /tmp/pd35689.patch \\
 && patch --batch --forward -p2 -d /sgl-workspace/sglang/python < /tmp/pd35689.patch \\
 && python3 -c "import sglang; assert sglang.__version__ == '${EXPECTED_SGLANG_VERSION}', sglang.__version__" \\
 && python3 /tmp/test_mamba_state_transfer_buffers.py \\
 && python3 -c "import dynamo.sglang; print('dynamo.sglang import PASS')" \\
 && pip freeze > /opt/inkling-sglang-pd35689-post-freeze.txt
USER 1000:0
EOF
cp "${CTX}/Dockerfile" "${OUT}/Dockerfile"
cp "${CTX}/pipcheck-before.txt" "${OUT}/pipcheck-before.txt"
cp "${CTX}/requirements.lock" "${OUT}/requirements-sglang0516-dynamo14.lock"
cp "${RUNTIME_PATCH}" "${CTX}/0001-pd35689-skip-empty-linear-state.runtime.patch"
cp "${REGRESSION_TEST}" "${CTX}/test_mamba_state_transfer_buffers.py"

docker build --platform "${PLATFORM}" --pull=false -t "${TARGET_IMAGE}" -f "${CTX}/Dockerfile" "${CTX}"
docker run --rm --platform "${PLATFORM}" --entrypoint /bin/cat "${TARGET_IMAGE}" /opt/inkling-sglang-pd35689-post-freeze.txt > "${OUT}/manifests/post.txt"
docker run --rm --platform "${PLATFORM}" --entrypoint /bin/cat "${TARGET_IMAGE}" /tmp/pipcheck-after.txt > "${OUT}/pipcheck-after.txt"
diff -u "${OUT}/manifests/pre.txt" "${OUT}/manifests/post.txt" > "${OUT}/manifests/diff.txt" || true
if grep -qiE '^[-+](sglang|nixl|torch|triton|flashinfer|nvidia-|cuda)' "${OUT}/manifests/diff.txt"; then
  echo "FATAL: engine or CUDA-stack package moved"
  exit 1
fi
docker run --rm --platform "${PLATFORM}" --entrypoint /bin/bash "${TARGET_IMAGE}" -lc '
  pip show sglang ai-dynamo
  python3 -c "import sglang, dynamo.sglang; print(\"sglang\", sglang.__version__)"
' | tee "${OUT}/in-image-provenance.txt"

cat > "${OUT}/patches/stack.yaml" <<EOF
patch_mode: baked
base_ref: ${SGLANG_SOURCE_COMMIT}
patches:
  - order: 010
    name: pd35689-skip-empty-linear-state
    provenance: merged-upstream-backport
    upstream_commit: ${UPSTREAM_FIX_COMMIT}
    backport_commit: ${BACKPORT_COMMIT}
    apply_target: python/sglang/srt/mem_cache/memory_pool.py
    rationale: skip zero-byte ShortConv temporal state buffers before P/D RDMA registration
EOF
(cd "${OUT}" && sha256sum Dockerfile requirements-sglang0516-dynamo14.in requirements-sglang0516-dynamo14.lock patches/stack.yaml patches/0001-pd35689-skip-empty-linear-state.runtime.patch patches/test_mamba_state_transfer_buffers.py manifests/pre.txt manifests/post.txt manifests/resolve-report.json) > "${OUT}/patch-manifest.sha256"

docker push "${TARGET_IMAGE}"
IMAGE_DIGEST="$(docker manifest inspect -v "${TARGET_IMAGE}" | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(d.get("Descriptor",{}).get("digest") or d.get("descriptor",{}).get("digest", ""))')"
[[ -n "${IMAGE_DIGEST}" ]] || { echo "FATAL: registry digest unavailable"; exit 1; }
printf '%s@%s\n' "${IMAGE_REPO}" "${IMAGE_DIGEST}" | tee "${OUT}/image-digest.txt"

RUN_COMMIT="$(git rev-parse HEAD)"
export OUT RUN_ID RUN_COMMIT IMAGE_DIGEST BASE_NIXL
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

out = Path(os.environ["OUT"])
sha = lambda path: hashlib.sha256((out / path).read_bytes()).hexdigest()
contract = {
  "lane": "sglang-disagg", "build_mode": "mode-2-base-plus-pip", "patch_mode": "baked", "plan_rev": 29,
  "source": {"repo": "https://github.com/sungsooha/dynamo", "commit": os.environ["RUN_COMMIT"], "branch": "inkling-sglang35689-disagg", "build_pattern_reference": "ai-dynamo/dynamo PR 10234"},
  "base": {"tag": "lmsysorg/sglang:v0.5.16-cu130-runtime", "digest": "sha256:f082dfc7e734f1956e9a023157c5a82d7c1ebe0cd689dcad7163f4f57ebc2e60", "ref": "lmsysorg/sglang@sha256:f082dfc7e734f1956e9a023157c5a82d7c1ebe0cd689dcad7163f4f57ebc2e60", "sglang_source_commit": "fdebc938f7f4d16fe6b9f55dcd9a767cf0899ea1"},
  "platform": "linux/arm64", "target_arch": "aarch64",
  "dependency_pin_override": {"declared": "ai-dynamo[sglang]==1.4.0 requires sglang[diffusion]==0.5.16", "used": "ai-dynamo==1.4.0 plus SGLang-extra companions excluding the engine line; digest-pinned base retains sglang 0.5.16", "verdict": "PIN_SATISFIED_NO_OVERRIDE", "runtime_verified": False},
  "base_preserved_transport": {"nixl": os.environ["BASE_NIXL"], "reason": "base-provided transport retained; SGLang extra NIXL companion omitted"},
  "patch_stack": [{"order": 10, "name": "pd35689-skip-empty-linear-state", "upstream_commit": "ba97cc6397ac98b0d889609598cc18ad365d462c", "backport_commit": "ac019b014d33cbca63b062f86ac6978e7a7acb3c", "patch_file": "patches/0001-pd35689-skip-empty-linear-state.runtime.patch", "patch_sha256": sha("patches/0001-pd35689-skip-empty-linear-state.runtime.patch"), "scope": "P/D temporal-state RDMA registration only; AGG unchanged"}],
  "lock": {"file": "requirements-sglang0516-dynamo14.lock", "sha256": sha("requirements-sglang0516-dynamo14.lock")},
  "resolver_report": {"file": "manifests/resolve-report.json", "sha256": sha("manifests/resolve-report.json")},
  "patch_manifest": {"file": "patch-manifest.sha256", "sha256": sha("patch-manifest.sha256")},
  "run_id": os.environ["RUN_ID"], "run_dir": str(out),
  "output": {"image_repo": "nvcr.io/nvstaging/nim/sungsooh", "image_version": "inkling-gb300-sglang-pd35689-v1", "image_ref": "nvcr.io/nvstaging/nim/sungsooh:inkling-gb300-sglang-pd35689-v1", "image_digest": os.environ["IMAGE_DIGEST"], "image_digest_ref": "nvcr.io/nvstaging/nim/sungsooh@" + os.environ["IMAGE_DIGEST"], "published": True, "serve_verified": False},
  "smoke": {"required": True, "status": "NOT_RUN", "upgrade_condition": "digest-pinned GB300 P/D transfer functional probe plus Service-DNS models 200 and nonempty chat 200 with hashed artifacts"},
  "artifact_sha256": {name: sha(name) for name in ["Dockerfile", "requirements-sglang0516-dynamo14.in", "requirements-sglang0516-dynamo14.lock", "patches/stack.yaml", "patches/0001-pd35689-skip-empty-linear-state.runtime.patch", "patch-manifest.sha256", "in-image-provenance.txt"]}
}
(out / "build-contract.json").write_text(json.dumps(contract, indent=2) + "\n")
PY
echo "BUILT ${IMAGE_REPO}@${IMAGE_DIGEST}; serve_verified=false pending P/D and service smoke"
rm -rf "${CTX}"
trap - EXIT
