<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Ultra vLLM AGG1 K8s Templates

These manifests port the local synthetic AGG1 champions into K8s
`DynamoGraphDeployment` form. They are aggregate vLLM candidates, not P/D
evidence:

- one Dynamo frontend/router
- one aggregate TP4 `VllmWorker`
- no prefill/decode split
- no NIXL/UCX/RDMA transfer args
- no `rdma/ib` resource request

Both templates use the accepted Patch06+humming image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521@sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

## Templates

| Manifest | Workload | Serve shape |
|---|---|---|
| `deploy-chat-c40.yaml` | Moontrace chat candidate | `max_model_len=262144`, `max_num_seqs=40`, `max_num_batched_tokens=32768`, `block_size=32`; full 256K Moontrace chat c40 PASS |
| `deploy-swe-c27.yaml` | Moontrace SWE candidate | `max_model_len=262144`, `max_num_seqs=32`, `max_num_batched_tokens=49152`, `block_size=64`; partial profile only, not a final SWE row |

## Local Direct-Docker Reference

The local aggregate server command that corresponds to these K8s aggregate
templates is documented in `../aiperf/local-synthetic-champions.md`. It starts
the recipe image with Docker and calls:

```text
/workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_aggregate.sh
```

For the `deploy-swe-c27.yaml` shape, use the same AGG1 TP4 layout:

```text
WORKER_CVD=0,1,2,3
TP=4
MAX_MODEL_LEN=262144
MAX_NUM_SEQS=32
MAX_BATCHED_TOKENS=49152
VLLM_BLOCK_SIZE=64
P/D transfer: none
```

The local synthetic SWE frontier later moved to `MAX_BATCHED_TOKENS=65536`.
Keep that distinction explicit: `deploy-swe-c27.yaml` is the K8s Moontrace
SWE c27 template that was already exercised; `local-synthetic-champions.md`
contains the local Docker command pattern and both local synthetic row notes.

The worker uses `runAsUser: 0` and mounts an `emptyDir` tmpfs at the exact
FlashInfer cubin path:

```text
/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer
```

This is intentional. The first AGG1 K8s attempt failed before endpoint because
the image default user `dynamo` could not create that path under the root-owned
site-packages directory. The disaggregated DGD already used the same root user
and exact tmpfs path, which is why the permission failure showed up in AGG1
first.

## Guardrails

Before live apply, run server-side dry-run and grep the rendered manifest:

```bash
NAMESPACE=<your-namespace>
kubectl -n "${NAMESPACE}" apply --dry-run=server \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/agg1/deploy-chat-c40.yaml \
  -o yaml >/tmp/ultra-agg1-chat-c40.dryrun.yaml

kubectl -n "${NAMESPACE}" apply --dry-run=server \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/agg1/deploy-swe-c27.yaml \
  -o yaml >/tmp/ultra-agg1-swe-c27.dryrun.yaml
```

The rendered worker command must include the candidate-specific
`--max-num-seqs`, `--max-num-batched-tokens`, and `--block-size` values above.
It must not contain `--kv-transfer-config`, `NixlConnector`, `kv_role`,
`--disaggregation-mode`, or `rdma/ib`.

Run the matching AIPerf jobs from `../aiperf/` only after KAI metadata,
prestart GPU guard, readiness, `/health`, `/v1/models`, and exact short chat
pass.
