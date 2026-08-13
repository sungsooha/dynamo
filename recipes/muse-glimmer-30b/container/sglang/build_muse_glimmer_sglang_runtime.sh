#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Render, build, and optionally push the pinned Muse Glimmer SGLang runtime.

set -euo pipefail

: "${TARGET_IMAGE:?set TARGET_IMAGE (for example nvcr.io/nvstaging/nim/sungsooh:muse-sglang-b200-20260813)}"
: "${PLATFORM:=linux/amd64}"
: "${BUILD_TARGET:=runtime}"
: "${PUSH:=0}"

case "${PLATFORM}" in
  linux/amd64) ;;
  *) echo "Muse B200 runtime requires PLATFORM=linux/amd64, got ${PLATFORM}" >&2; exit 2 ;;
esac

python3 container/render.py \
  --framework sglang \
  --device cuda \
  --cuda-version 13.0 \
  --target "${BUILD_TARGET}" \
  --platform "${PLATFORM}" \
  --output-short-filename

docker build --pull=false --target "${BUILD_TARGET}" --platform "${PLATFORM}" \
  -f container/rendered.Dockerfile \
  -t "${TARGET_IMAGE}" \
  .

if [[ "${PUSH}" == "1" ]]; then
  docker push "${TARGET_IMAGE}"
fi
