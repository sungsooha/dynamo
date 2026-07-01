# DSV4 Per-Rank NIC Overlay for vLLM nightly-4559c43a

This directory contains a retargeted full-file vLLM NIXL `base_worker.py`
overlay for the pinned vLLM nightly base.

```text
target=vllm/distributed/kv_transfer/kv_connector/v1/nixl/base_worker.py
base_vllm_commit=4559c43a9526597c00cbcc4f59979496500268d1
base_sha256=d459c858e5bd4cfcb73be441cfefa6529d1c14def8a64314eb9dce8fde629878
patched_sha256=2a5080698a240db2fc51ac37821eeae7dc18fbd9fcbfec40c4ba779041fa5b5b
```

The overlay keeps the validated DSV4 nscale behavior from
`work-tracker/nim/dsv4_dynamo/scripts/nscale/per_rank_nic_config.md`:

```bash
UCX_NET_DEVICES=mlx5_0:1
UCX_NET_DEVICES_BY_RANK=mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1
```

At worker startup, each TP rank rewrites `UCX_NET_DEVICES` to its corresponding
entry before NIXL creates the backend. Validation should look for:

```text
DSV4 per-rank NIC override: tp_rank=... UCX_NET_DEVICES=...
```

Enable it at build time with:

```bash
--build-arg DSV4_PER_RANK_NIC_PATCH=true
```
