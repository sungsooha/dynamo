#!/usr/bin/env bash
set -euo pipefail

# Build the TensorRT-LLM wheel lineage used by the TRT-LLM derived image.
#
# This is intentionally separate from Dockerfile so the expensive source build
# can be cached and inspected. Run on a B200/SM100-capable build host with Docker
# access. For H200, override CUDA_ARCHS to the appropriate Hopper target before
# using the result.

TRTLLM_GIT_URL="${TRTLLM_GIT_URL:-https://github.com/NVIDIA/TensorRT-LLM.git}"
TRTLLM_BASE_SHA="${TRTLLM_BASE_SHA:-501a58034eef4ff1ae144891963f790390875863}"
TRTLLM_PR_REF="${TRTLLM_PR_REF:-pull/14060/head}"
TRTLLM_PR_EXPECTED_SHA="${TRTLLM_PR_EXPECTED_SHA:-9c9cde29249b0e9103d129aca9094217b466b922}"
CUDA_ARCHS="${CUDA_ARCHS:-100-real}"
BUILD_JOBS="${BUILD_JOBS:-64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${WORK_ROOT:-${SCRIPT_DIR}/.trtllm-build}"
SRC_ROOT="${SRC_ROOT:-${WORK_ROOT}/TensorRT-LLM-pr14060}"
RELEASE_IMAGE_TAG="${RELEASE_IMAGE_TAG:-nemotron-ultra/trtllm-base501a580-pr14060-9c9cde-sm100:20260520}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/wheels}"
DOCKER="${DOCKER:-docker}"

mkdir -p "${WORK_ROOT}" "${OUT_DIR}"

if [[ ! -d "${SRC_ROOT}/.git" ]]; then
  git clone "${TRTLLM_GIT_URL}" "${SRC_ROOT}"
else
  git -C "${SRC_ROOT}" fetch origin
fi

git -C "${SRC_ROOT}" fetch origin "${TRTLLM_PR_REF}:refs/heads/nemotron-ultra-pr14060"
actual_pr_sha="$(git -C "${SRC_ROOT}" rev-parse nemotron-ultra-pr14060)"
if [[ "${actual_pr_sha}" != "${TRTLLM_PR_EXPECTED_SHA}" ]]; then
  echo "PR SHA mismatch: expected ${TRTLLM_PR_EXPECTED_SHA}, got ${actual_pr_sha}" >&2
  exit 1
fi

git -C "${SRC_ROOT}" checkout -B nemotron-ultra-base501a580-pr14060 "${TRTLLM_BASE_SHA}"
git -C "${SRC_ROOT}" reset --hard "${TRTLLM_BASE_SHA}"
git -C "${SRC_ROOT}" clean -xffd
git -C "${SRC_ROOT}" merge --no-ff --no-edit nemotron-ultra-pr14060
git -C "${SRC_ROOT}" submodule update --init --recursive

cat > "${OUT_DIR}/trtllm_source_lineage.txt" <<EOF
git_url=${TRTLLM_GIT_URL}
base_sha=${TRTLLM_BASE_SHA}
pr_ref=${TRTLLM_PR_REF}
pr_sha=${actual_pr_sha}
merged_head=$(git -C "${SRC_ROOT}" rev-parse HEAD)
cuda_archs=${CUDA_ARCHS}
release_image_tag=${RELEASE_IMAGE_TAG}
EOF

(
  cd "${SRC_ROOT}"
  make -C docker release_build \
    "CUDA_ARCHS=${CUDA_ARCHS}" \
    "BUILD_WHEEL_OPTS=-j ${BUILD_JOBS}" \
    "IMAGE_WITH_TAG=${RELEASE_IMAGE_TAG}" \
    "DOCKER_BUILD_OPTS=--pull --load"
)

cid="$(${DOCKER} create "${RELEASE_IMAGE_TAG}")"
trap '${DOCKER} rm -f "${cid}" >/dev/null 2>&1 || true' EXIT
rm -rf "${OUT_DIR}/app_tensorrt_llm"
${DOCKER} cp "${cid}:/app/tensorrt_llm/." "${OUT_DIR}/app_tensorrt_llm"
find "${OUT_DIR}/app_tensorrt_llm" -maxdepth 1 -name 'tensorrt_llm*.whl' -type f -print > "${OUT_DIR}/wheel_paths.txt"
if [[ ! -s "${OUT_DIR}/wheel_paths.txt" ]]; then
  echo "No TensorRT-LLM wheel found in release image ${RELEASE_IMAGE_TAG}" >&2
  exit 1
fi
while IFS= read -r wheel; do
  sha256sum "${wheel}"
done < "${OUT_DIR}/wheel_paths.txt" > "${OUT_DIR}/wheel_sha256.txt"

cat "${OUT_DIR}/wheel_sha256.txt"
