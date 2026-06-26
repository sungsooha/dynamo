# DeepSeek-V4 Flash MTP BF16 Projection Overlay

This directory contains the one-file DeepSeek-V4 Flash MTP overlay used by the
Dynamo vLLM runtime build.

```text
target=vllm/models/deepseek_v4/nvidia/mtp.py
sha256=1b599ddfe6f578c1e98551ceceead599e3cae24534427a84462143c6eac86f30
required_for=DeepSeek-V4-Flash MTP1
not_required_for=DeepSeek-V4-Pro MTP
```

The patch is scoped by `config.hidden_size == 4096`, so it only changes the
Flash MTP projection path. Pro uses the 7168-wide MTP path and is left
untouched.

Enable it at build time with:

```bash
--build-arg DSV4_FLASH_MTP_BF16_PATCH=true
```
