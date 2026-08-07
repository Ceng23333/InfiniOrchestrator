#!/usr/bin/env python3
"""Async client for cancel/disconnect/timeout fault injection against OpenAI-compatible API."""

from __future__ import annotations

import argparse
import asyncio
import json
import socket
import sys
import urllib.error
import urllib.request

def _build_payload(model: str, prompt: str, max_tokens: int, stream: bool) -> bytes:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": stream,
    }
    return json.dumps(body).encode("utf-8")


def _post(url: str, data: bytes, timeout: float | None) -> urllib.request.Request:
    req = urllib.request.Request(
        f"{url.rstrip('/')}/v1/chat/completions",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    return req, timeout


async def cmd_happy(args: argparse.Namespace) -> int:
    data = _build_payload(args.model, args.prompt, args.max_tokens, stream=False)
    req, timeout = _post(args.base_url, data, args.timeout_sec)

    def _do() -> str:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")

    body = await asyncio.to_thread(_do)
    if '"object"' not in body:
        print(f"unexpected body: {body[:200]}", file=sys.stderr)
        return 1
    print("happy: OK")
    return 0


async def cmd_cancel_stream(args: argparse.Namespace) -> int:
    data = _build_payload(args.model, args.prompt, args.max_tokens, stream=True)
    url = f"{args.base_url.rstrip('/')}/v1/chat/completions"

    async def _stream_and_cancel() -> None:
        loop = asyncio.get_running_loop()

        def _open():
            req = urllib.request.Request(
                url,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            return urllib.request.urlopen(req, timeout=args.timeout_sec)

        resp = await loop.run_in_executor(None, _open)
        try:
            if args.delay_ms > 0:
                await asyncio.sleep(args.delay_ms / 1000.0)
            else:
                # Cancel before reading any byte.
                await asyncio.sleep(0.01)
        finally:
            resp.close()

    task = asyncio.create_task(_stream_and_cancel())
    await asyncio.sleep(args.delay_ms / 1000.0 if args.delay_ms > 0 else 0.05)
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    except Exception as exc:
        print(f"cancel-stream: client action done ({exc})", file=sys.stderr)
    print("cancel-stream: OK")
    return 0


async def cmd_cancel_after_chunk(args: argparse.Namespace) -> int:
    """Open stream, read through prefill into decode, cancel after N SSE data chunks."""
    data = _build_payload(args.model, args.prompt, args.max_tokens, stream=True)
    url = f"{args.base_url.rstrip('/')}/v1/chat/completions"

    def _stream_until_chunks() -> int:
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        resp = urllib.request.urlopen(req, timeout=args.timeout_sec)
        chunks_seen = 0
        try:
            while chunks_seen < args.chunks_before_cancel:
                line = resp.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").strip()
                if text.startswith("data:") and text != "data: [DONE]":
                    chunks_seen += 1
        finally:
            resp.close()
        return chunks_seen

    seen = await asyncio.to_thread(_stream_until_chunks)
    print(f"cancel-after-chunk: OK (chunks_seen={seen})")
    return 0


async def cmd_cancel_burst(args: argparse.Namespace) -> int:
    """Fire parallel cancel-after-chunk requests to widen the cancel/forward race."""
    async def _one(i: int) -> None:
        sub = argparse.Namespace(**vars(args))
        sub.prompt = f"{args.prompt} (burst {i})"
        await cmd_cancel_after_chunk(sub)

    tasks = [asyncio.create_task(_one(i)) for i in range(args.parallel)]
    await asyncio.gather(*tasks, return_exceptions=True)
    print(f"cancel-burst: OK (parallel={args.parallel})")
    return 0


async def cmd_disconnect_stream(args: argparse.Namespace) -> int:
    host_port = args.base_url.replace("http://", "").replace("https://", "")
    if "/" in host_port:
        host_port = host_port.split("/", 1)[0]
    host, port_str = host_port.rsplit(":", 1)
    port = int(port_str)

    payload = (
        f"POST /v1/chat/completions HTTP/1.1\r\n"
        f"Host: {host_port}\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(_build_payload(args.model, args.prompt, args.max_tokens, True))}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode("utf-8") + _build_payload(args.model, args.prompt, args.max_tokens, True)

    def _connect_and_drop() -> None:
        sock = socket.create_connection((host, port), timeout=args.timeout_sec)
        try:
            sock.sendall(payload)
            if args.delay_ms > 0:
                import time

                time.sleep(args.delay_ms / 1000.0)
        finally:
            sock.close()

    await asyncio.to_thread(_connect_and_drop)
    print("disconnect-stream: OK")
    return 0


async def cmd_short_timeout(args: argparse.Namespace) -> int:
    data = _build_payload(args.model, args.prompt, args.max_tokens, stream=False)
    req, _ = _post(args.base_url, data, None)
    timeout = max(0.01, args.client_timeout_sec)

    def _do() -> None:
        try:
            urllib.request.urlopen(req, timeout=timeout)
        except (urllib.error.URLError, TimeoutError, socket.timeout):
            pass

    await asyncio.to_thread(_do)
    print("short-timeout: OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Unexpected-behavior sim client")
    parser.add_argument("--base-url", default="http://127.0.0.1:8102")
    parser.add_argument("--model", default="9g_8b_thinking")
    parser.add_argument("--prompt", default="Write a long story about robots.")
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--timeout-sec", type=float, default=120.0)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_happy = sub.add_parser("happy")
    p_happy.set_defaults(func=cmd_happy)

    p_cancel = sub.add_parser("cancel-stream")
    p_cancel.add_argument("--delay-ms", type=int, default=200)
    p_cancel.set_defaults(func=cmd_cancel_stream)

    p_after = sub.add_parser("cancel-after-chunk")
    p_after.add_argument(
        "--chunks-before-cancel", type=int, default=2,
        help="Close connection after this many SSE data chunks (decode phase)",
    )
    p_after.set_defaults(func=cmd_cancel_after_chunk)

    p_burst = sub.add_parser("cancel-burst")
    p_burst.add_argument("--parallel", type=int, default=8)
    p_burst.add_argument("--chunks-before-cancel", type=int, default=2)
    p_burst.set_defaults(func=cmd_cancel_burst)

    p_disc = sub.add_parser("disconnect-stream")
    p_disc.add_argument("--delay-ms", type=int, default=100)
    p_disc.set_defaults(func=cmd_disconnect_stream)

    p_to = sub.add_parser("short-timeout")
    p_to.add_argument("--client-timeout-sec", type=float, default=0.05)
    p_to.set_defaults(func=cmd_short_timeout)

    args = parser.parse_args()
    return asyncio.run(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
