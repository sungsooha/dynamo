<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Ultra vLLM AGG2 K8s Templates

These manifests describe aggregate two-worker Dynamo/vLLM candidates:

- one Dynamo frontend/router
- two aggregate TP4 `VllmWorker` replicas
- no prefill/decode split
- no NIXL/UCX/RDMA transfer args
- no `rdma/ib` resource request

The template uses the proxy-enabled validated tailfix image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-reasoning-api-validated-tailfix-20260528T070932Z@sha256:bfa2d02fd0dd1daab3fd41e4f2acfd8b131c44b49f0a4282937b5716e04fc265
```

The public Kubernetes service remains on port `8000`. The frontend pod runs
the reasoning API compatibility proxy on `8000` and the inner Dynamo frontend
on `8001`; the two aggregate TP4 workers keep the recipe serve args below.

The AGG2 chat template was server-side dry-run validated and endpoint-smoked in
K8s, but its benchmark was intentionally stopped before AIPerf because another
same-model DGD was live in the same Kubernetes namespace. Dynamo `/health`
reported three generate backends: the two AGG2 workers plus the live AGG1 SWE
worker. Source review indicates request routing is scoped more narrowly than
the `/health` all-endpoints listing, but benchmark runs should still isolate
same-model DGDs operationally.

## Templates

| Manifest | Workload | Serve shape | K8s status |
|---|---|---|---|
| `deploy-chat-c64.yaml` | Chat | `2x TP4`, `max_model_len=262144`, per-worker `max_num_seqs=32`, `max_num_batched_tokens=32768`, `block_size=64` | endpoint PASS, AIPerf blocked pending namespace isolation |

For concurrent same-model benchmarks, run AGG2 in a dedicated namespace with
the same required PVCs/secrets and `kai.scheduler/enabled=true`. Do not run
AGG1 and AGG2 same-model benchmark lanes in one namespace unless the discovery
isolation contract has been explicitly accepted for that run.

The worker uses `runAsUser: 0` and mounts an `emptyDir` tmpfs at:

```text
/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer
```

This preserves the FlashInfer cubin writable-path fix proven during the AGG1
K8s retry.

## Dry Run

```bash
NAMESPACE=<your-namespace>
kubectl -n "${NAMESPACE}" apply --dry-run=server \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/agg2/deploy-chat-c64.yaml \
  -o yaml >/tmp/ultra-agg2-chat-c64.dryrun.yaml
```

The rendered worker command must contain `--max-num-seqs 32`,
`--max-num-batched-tokens 32768`, and `--block-size 64`, and must not contain
`--kv-transfer-config`, `NixlConnector`, `kv_role`, `--disaggregation-mode`, or
`rdma/ib`.

The rendered frontend command should expose the proxy on public port `8000`
and forward to the inner Dynamo frontend on `8001`.
