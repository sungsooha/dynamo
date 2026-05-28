#!/usr/bin/env python3
"""Nemotron Ultra reasoning API compatibility proxy.

This is a narrow compatibility component for the Ultra recipe. It accepts the
QA-owned OpenAI compatibility fields at the public endpoint, rewrites only
those fields before forwarding to Dynamo, and augments usage accounting when
the backend returns reasoning content.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


LOG = logging.getLogger("ultra_reasoning_proxy")

EFFORT_BUDGETS = {
    "none": 0,
    "low": 32,
    "medium": 128,
    "high": 512,
    "xhigh": 1024,
    "max": 1024,
}


class ReasoningTokenCounter:
    def __init__(self, model_path: str | None):
        self.model_path = model_path
        self._tokenizer = None
        self._lock = threading.Lock()
        self._load_error: str | None = None

    def count(self, text: str | None) -> tuple[int, str]:
        if not text:
            return 0, "empty"
        tokenizer = self._get_tokenizer()
        if tokenizer is not None:
            try:
                return len(tokenizer.encode(text, add_special_tokens=False)), "tokenizer"
            except Exception as exc:  # pragma: no cover - diagnostic fallback
                LOG.warning("tokenizer encode failed, using fallback: %s", exc)
        return max(1, len(text) // 4), f"fallback_char4:{self._load_error or 'no_tokenizer'}"

    def truncate(self, text: str | None, budget: int | None) -> tuple[str, int, str]:
        if not text:
            return "", 0, "empty"
        if budget is None:
            tokens, method = self.count(text)
            return text, tokens, method
        if budget <= 0:
            return "", 0, "budget_zero"
        tokenizer = self._get_tokenizer()
        if tokenizer is not None:
            try:
                token_ids = tokenizer.encode(text, add_special_tokens=False)
                if len(token_ids) <= budget:
                    return text, len(token_ids), "tokenizer"
                return tokenizer.decode(token_ids[:budget], skip_special_tokens=False), budget, "tokenizer_truncated"
            except Exception as exc:  # pragma: no cover - diagnostic fallback
                LOG.warning("tokenizer truncate failed, using fallback: %s", exc)
        max_chars = max(1, budget * 4)
        if len(text) <= max_chars:
            tokens, method = self.count(text)
            return text, min(tokens, budget), method
        return text[:max_chars], budget, f"fallback_char4_truncated:{self._load_error or 'no_tokenizer'}"

    def _get_tokenizer(self):
        if self._tokenizer is not None or self._load_error is not None:
            return self._tokenizer
        with self._lock:
            if self._tokenizer is not None or self._load_error is not None:
                return self._tokenizer
            if not self.model_path:
                self._load_error = "model_path_unset"
                return None
            try:
                from transformers import AutoTokenizer

                self._tokenizer = AutoTokenizer.from_pretrained(
                    self.model_path,
                    trust_remote_code=True,
                    local_files_only=True,
                )
                LOG.info("loaded tokenizer for reasoning token accounting: %s", self.model_path)
            except Exception as exc:  # pragma: no cover - depends on image runtime
                self._load_error = repr(exc)
                LOG.warning("failed to load tokenizer for reasoning accounting: %s", exc)
            return self._tokenizer


def _as_dict(value: Any) -> dict[str, Any]:
    return dict(value) if isinstance(value, dict) else {}


def _apply_no_thinking(payload: dict[str, Any]) -> None:
    kwargs = _as_dict(payload.get("chat_template_kwargs") or payload.get("chat_template_args"))
    kwargs["enable_thinking"] = False
    kwargs["force_nonempty_content"] = True
    payload["chat_template_kwargs"] = kwargs
    payload.pop("chat_template_args", None)


def transform_request(payload: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return upstream payload plus proxy metadata."""
    payload = dict(payload)
    meta: dict[str, Any] = {
        "include_reasoning": payload.pop("include_reasoning", None),
        "thinking_token_budget": payload.pop("thinking_token_budget", None),
        "reasoning_effort": payload.pop("reasoning_effort", None),
        "suppress_reasoning": False,
        "mapped_budget": None,
    }

    if meta["thinking_token_budget"] is not None:
        nvext = _as_dict(payload.get("nvext"))
        nvext.setdefault("max_thinking_tokens", int(meta["thinking_token_budget"]))
        payload["nvext"] = nvext
        meta["mapped_budget"] = nvext.get("max_thinking_tokens")

    effort = meta["reasoning_effort"]
    if isinstance(effort, str):
        normalized = effort.lower()
        meta["reasoning_effort"] = normalized
        if normalized == "none":
            meta["suppress_reasoning"] = True
            _apply_no_thinking(payload)
        elif normalized in EFFORT_BUDGETS:
            nvext = _as_dict(payload.get("nvext"))
            nvext.setdefault("max_thinking_tokens", EFFORT_BUDGETS[normalized])
            payload["nvext"] = nvext
            meta["mapped_budget"] = nvext.get("max_thinking_tokens")
            kwargs = _as_dict(payload.get("chat_template_kwargs") or payload.get("chat_template_args"))
            kwargs["reasoning_effort"] = "high" if normalized in ("xhigh", "max") else normalized
            payload["chat_template_kwargs"] = kwargs
            payload.pop("chat_template_args", None)
        else:
            LOG.warning("unknown reasoning_effort=%r; removing before upstream validation", effort)

    if meta["include_reasoning"] is False:
        meta["suppress_reasoning"] = True
        _apply_no_thinking(payload)

    return payload, meta


def _set_usage_reasoning_tokens(usage: dict[str, Any] | None, tokens: int) -> None:
    if not isinstance(usage, dict):
        return
    usage["reasoning_tokens"] = tokens
    output_details = usage.setdefault("output_tokens_details", {})
    if isinstance(output_details, dict):
        output_details["reasoning_tokens"] = tokens


def _mapped_budget(meta: dict[str, Any]) -> int | None:
    raw = meta.get("mapped_budget")
    if raw is None:
        return None
    try:
        return max(0, int(raw))
    except Exception:
        return None


def augment_json_response(
    parsed: dict[str, Any],
    meta: dict[str, Any],
    counter: ReasoningTokenCounter,
) -> dict[str, Any]:
    remaining_budget = _mapped_budget(meta)
    total_tokens = 0
    methods: list[str] = []
    saw_reasoning = False
    for choice in parsed.get("choices") or []:
        msg = choice.get("message") or {}
        reasoning = msg.get("reasoning_content")
        if meta.get("suppress_reasoning"):
            msg["reasoning_content"] = None
        elif isinstance(reasoning, str):
            saw_reasoning = True
            capped, tokens, method = counter.truncate(reasoning, remaining_budget)
            msg["reasoning_content"] = capped
            total_tokens += tokens
            methods.append(method)
            if remaining_budget is not None:
                remaining_budget = max(0, remaining_budget - tokens)
    if saw_reasoning:
        _set_usage_reasoning_tokens(parsed.get("usage"), total_tokens)
    parsed.setdefault("nvext", {})
    if isinstance(parsed["nvext"], dict):
        parsed["nvext"]["reasoning_compat"] = {
            "reasoning_tokens_method": ",".join(methods) if methods else "empty",
            "reasoning_tokens": total_tokens,
            "mapped_budget": meta.get("mapped_budget"),
            "suppress_reasoning": bool(meta.get("suppress_reasoning")),
        }
    return parsed


def augment_sse_response(body: bytes, meta: dict[str, Any], counter: ReasoningTokenCounter) -> bytes:
    text = body.decode("utf-8", errors="replace")
    lines_out: list[str] = []
    total_tokens = 0
    methods: list[str] = []
    remaining_budget = _mapped_budget(meta)

    for line in text.splitlines():
        if not line.startswith("data:"):
            lines_out.append(line)
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            lines_out.append(line)
            continue
        try:
            event = json.loads(data)
        except Exception:
            lines_out.append(line)
            continue
        for choice in event.get("choices") or []:
            delta = choice.get("delta") or {}
            reasoning = delta.get("reasoning_content")
            if meta.get("suppress_reasoning") and "reasoning_content" in delta:
                delta["reasoning_content"] = None
            elif isinstance(reasoning, str):
                capped, tokens, method = counter.truncate(reasoning, remaining_budget)
                delta["reasoning_content"] = capped
                total_tokens += tokens
                methods.append(method)
                if remaining_budget is not None:
                    remaining_budget = max(0, remaining_budget - tokens)
        if isinstance(event.get("usage"), dict) and total_tokens:
            _set_usage_reasoning_tokens(event["usage"], total_tokens)
            event.setdefault("nvext", {})["reasoning_compat"] = {
                "reasoning_tokens_method": ",".join(methods) if methods else "empty",
                "reasoning_tokens": total_tokens,
                "mapped_budget": meta.get("mapped_budget"),
                "suppress_reasoning": bool(meta.get("suppress_reasoning")),
            }
        lines_out.append("data: " + json.dumps(event, separators=(",", ":"), sort_keys=True))

    return ("\n".join(lines_out) + "\n").encode("utf-8")


class SSEStreamAugmenter:
    """Incrementally apply reasoning compatibility edits to SSE data lines."""

    def __init__(self, meta: dict[str, Any], counter: ReasoningTokenCounter):
        self.meta = meta
        self.counter = counter
        self.total_tokens = 0
        self.methods: list[str] = []
        self.remaining_budget = _mapped_budget(meta)

    def process_line(self, raw_line: bytes) -> bytes:
        text = raw_line.decode("utf-8", errors="replace")
        if not text.startswith("data:"):
            return raw_line
        data = text[5:].strip()
        if data == "[DONE]":
            return raw_line
        try:
            event = json.loads(data)
        except Exception:
            return raw_line

        for choice in event.get("choices") or []:
            delta = choice.get("delta") or {}
            reasoning = delta.get("reasoning_content")
            if self.meta.get("suppress_reasoning") and "reasoning_content" in delta:
                delta["reasoning_content"] = None
            elif isinstance(reasoning, str):
                capped, tokens, method = self.counter.truncate(reasoning, self.remaining_budget)
                delta["reasoning_content"] = capped
                self.total_tokens += tokens
                self.methods.append(method)
                if self.remaining_budget is not None:
                    self.remaining_budget = max(0, self.remaining_budget - tokens)

        if isinstance(event.get("usage"), dict) and self.total_tokens:
            _set_usage_reasoning_tokens(event["usage"], self.total_tokens)
            event.setdefault("nvext", {})["reasoning_compat"] = {
                "reasoning_tokens_method": ",".join(dict.fromkeys(self.methods)) if self.methods else "empty",
                "reasoning_tokens": self.total_tokens,
                "mapped_budget": self.meta.get("mapped_budget"),
                "suppress_reasoning": bool(self.meta.get("suppress_reasoning")),
            }

        return ("data: " + json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream: str
    counter: ReasoningTokenCounter

    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.info("%s - " + fmt, self.address_string(), *args)

    def do_GET(self) -> None:  # noqa: N802
        self._proxy(method="GET")

    def do_POST(self) -> None:  # noqa: N802
        self._proxy(method="POST")

    def _proxy(self, method: str) -> None:
        body = b""
        meta: dict[str, Any] = {}
        path = self.path
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in {"host", "content-length"}
        }
        if method == "POST":
            length = int(self.headers.get("content-length", "0") or "0")
            body = self.rfile.read(length)
            if urllib.parse.urlparse(path).path == "/v1/chat/completions":
                try:
                    payload = json.loads(body.decode("utf-8"))
                    payload, meta = transform_request(payload)
                    body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
                    headers["content-type"] = "application/json"
                    LOG.info(
                        "reasoning compat transform include_reasoning=%r reasoning_effort=%r mapped_budget=%r suppress=%s",
                        meta.get("include_reasoning"),
                        meta.get("reasoning_effort"),
                        meta.get("mapped_budget"),
                        meta.get("suppress_reasoning"),
                    )
                except Exception as exc:
                    self.send_error(400, f"reasoning compatibility transform failed: {exc}")
                    return

        url = self.upstream + path
        req = urllib.request.Request(
            url,
            data=body if method == "POST" else None,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                status = resp.status
                resp_headers = dict(resp.headers.items())
                content_type = resp_headers.get("content-type", "")
                if "text/event-stream" in content_type:
                    self._stream_sse_response(resp, status, resp_headers, meta, content_type)
                    return
                resp_body = resp.read()
        except urllib.error.HTTPError as exc:
            resp_body = exc.read()
            status = exc.code
            resp_headers = dict(exc.headers.items())
        except Exception as exc:
            self.send_error(502, f"upstream request failed: {exc}")
            return

        content_type = resp_headers.get("content-type", "")
        if meta and status < 400:
            if "text/event-stream" in content_type:
                resp_body = augment_sse_response(resp_body, meta, self.counter)
            elif "application/json" in content_type or resp_body.lstrip().startswith(b"{"):
                try:
                    parsed = json.loads(resp_body.decode("utf-8"))
                    resp_body = json.dumps(
                        augment_json_response(parsed, meta, self.counter),
                        separators=(",", ":"),
                        sort_keys=True,
                    ).encode("utf-8")
                    content_type = "application/json"
                except Exception as exc:
                    LOG.warning("failed to augment JSON response: %s", exc)

        self.send_response(status)
        for key, value in resp_headers.items():
            if key.lower() in {"content-length", "connection", "transfer-encoding"}:
                continue
            if key.lower() == "content-type" and content_type:
                value = content_type
            self.send_header(key, value)
        self.send_header("content-length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)

    def _stream_sse_response(
        self,
        resp: Any,
        status: int,
        resp_headers: dict[str, str],
        meta: dict[str, Any],
        content_type: str,
    ) -> None:
        self.send_response(status)
        for key, value in resp_headers.items():
            lower = key.lower()
            if lower in {"content-length", "connection", "transfer-encoding"}:
                continue
            if lower == "content-type" and content_type:
                value = content_type
            self.send_header(key, value)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        augmenter = SSEStreamAugmenter(meta, self.counter) if meta and status < 400 else None
        try:
            while True:
                line = resp.readline()
                if not line:
                    break
                out = augmenter.process_line(line) if augmenter is not None else line
                if out:
                    self._write_chunk(out)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            LOG.info("client disconnected during SSE proxy stream")

    def _write_chunk(self, data: bytes) -> None:
        self.wfile.write(f"{len(data):x}\r\n".encode("ascii"))
        self.wfile.write(data)
        self.wfile.write(b"\r\n")
        self.wfile.flush()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=18000)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--model-path", default=os.environ.get("MODEL_PATH"))
    args = parser.parse_args()

    logging.basicConfig(
        level=os.environ.get("ULTRA_REASONING_PROXY_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    handler = ProxyHandler
    handler.upstream = args.upstream.rstrip("/")
    handler.counter = ReasoningTokenCounter(args.model_path)
    server = ThreadingHTTPServer((args.listen_host, args.listen_port), handler)
    LOG.info(
        "Ultra reasoning compatibility proxy listening on %s:%s upstream=%s",
        args.listen_host,
        args.listen_port,
        handler.upstream,
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
