#!/usr/bin/env python3
"""OpenAI-compatible mock upstream for the tenancy comparison.

Standard library only. Port 8080 serves POST /v1/chat/completions and GET /healthz.
Port 8081 serves GET /metrics, GET /admin/keys (owners only, never keys) and
POST /admin/keys (replace the accepted keys). Every chat response carries
x-mock-key-owner (the tenant whose provider key was received, or "none") and echoes
x-probe-id as x-mock-probe-id so clients can prove which credential served them.
"""

import asyncio
import json
import math
import os
import re
import signal
import time
import uuid

API_PORT = int(os.environ.get("MOCK_API_PORT", "8080"))
ADMIN_PORT = int(os.environ.get("MOCK_ADMIN_PORT", "8081"))
KEY_FILE = os.environ.get("MOCK_KEY_FILE", "/etc/mock/keys")
DEFAULT_LATENCY_MS = int(os.environ.get("MOCK_LATENCY_MS", "100"))
COMPLETION_TOKENS = int(os.environ.get("MOCK_COMPLETION_TOKENS", "100"))
MAX_BODY = int(os.environ.get("MOCK_MAX_BODY_BYTES", str(1024 * 1024)))
MAX_LATENCY_MS = 120000
IDLE_TIMEOUT = 300
CHAT_PATHS = ("/v1/chat/completions", "/mock/v1/chat/completions")
OWNER = re.compile(r"^[a-z0-9-]{1,63}$")
KEY = re.compile(r"^[a-f0-9]{64}$")

keys = {}
requests_total = {}
paths_total = {}
in_flight = 0


class BadRequest(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def parse_keys(text):
    parsed = {}
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2 or not OWNER.match(parts[0]) or not KEY.match(parts[1]):
            raise ValueError(f"line {number} must be '<owner> <64 hex key>'")
        parsed[parts[1]] = parts[0]
    return parsed


def load_key_file():
    global keys
    try:
        with open(KEY_FILE, encoding="utf-8") as handle:
            keys = parse_keys(handle.read())
    except FileNotFoundError:
        keys = {}


def count(code, owner, path):
    requests_total[(code, owner)] = requests_total.get((code, owner), 0) + 1
    paths_total[path] = paths_total.get(path, 0) + 1


async def read_request(reader):
    line = await asyncio.wait_for(reader.readline(), IDLE_TIMEOUT)
    if not line:
        return None
    try:
        method, target, _version = line.decode("latin-1").rstrip("\r\n").split(" ", 2)
    except ValueError as error:
        raise BadRequest(400, "malformed request line") from error
    headers = {}
    while True:
        header = await reader.readline()
        if header in (b"\r\n", b"\n", b""):
            break
        name, _, value = header.decode("latin-1").partition(":")
        headers[name.strip().lower()] = value.strip()
    if "chunked" in headers.get("transfer-encoding", "").lower():
        chunks, total = [], 0
        while True:
            size = int((await reader.readline()).split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while (await reader.readline()) not in (b"\r\n", b"\n", b""):
                    pass
                break
            total += size
            if total > MAX_BODY:
                raise BadRequest(413, "request body too large")
            chunks.append(await reader.readexactly(size))
            await reader.readexactly(2)
        body = b"".join(chunks)
    else:
        length = int(headers.get("content-length", "0") or "0")
        if length > MAX_BODY:
            raise BadRequest(413, "request body too large")
        body = await reader.readexactly(length) if length else b""
    return method, target.split("?", 1)[0], headers, body


async def respond(writer, status, body, headers=None, content_type="application/json"):
    reason = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
              405: "Method Not Allowed", 413: "Payload Too Large"}.get(status, "OK")
    payload = body if isinstance(body, bytes) else body.encode("utf-8")
    lines = [f"HTTP/1.1 {status} {reason}", f"Content-Type: {content_type}",
             f"Content-Length: {len(payload)}", "Connection: keep-alive"]
    for name, value in (headers or {}).items():
        lines.append(f"{name}: {value}")
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + payload)
    await writer.drain()


def error_body(message, code):
    return json.dumps({"error": {"message": message, "type": "invalid_request_error", "code": code}})


def prompt_characters(messages):
    total = 0
    for message in messages if isinstance(messages, list) else []:
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, str):
            total += len(content)
        elif isinstance(content, list):
            total += sum(len(part.get("text", "")) for part in content if isinstance(part, dict))
    return total


def presented_key(headers):
    authorization = headers.get("authorization", "")
    if authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return headers.get("api-key", "").strip()


def latency_ms(headers):
    value = headers.get("x-mock-latency-ms")
    if value is None:
        return DEFAULT_LATENCY_MS
    if not value.isdigit() or int(value) > MAX_LATENCY_MS:
        raise BadRequest(400, "x-mock-latency-ms must be an integer from 0 to 120000")
    return int(value)


async def chat(writer, headers, body, path):
    global in_flight
    owner = keys.get(presented_key(headers), "none")
    echo = {"x-mock-key-owner": owner}
    probe = headers.get("x-probe-id")
    if probe is not None:
        echo["x-mock-probe-id"] = probe + "-corrupt" if headers.get("x-mock-corrupt-id") == "1" else probe
    if owner == "none":
        count(401, owner, path)
        await respond(writer, 401, error_body("Invalid API key", "invalid_api_key"), echo)
        return
    try:
        request = json.loads(body)
        if not isinstance(request, dict):
            raise ValueError
    except ValueError:
        count(400, owner, path)
        await respond(writer, 400, error_body("Request body must be a JSON object", "invalid_json"), echo)
        return
    wait = latency_ms(headers)
    prompt_tokens = max(1, math.ceil(prompt_characters(request.get("messages")) / 4))
    limit = request.get("max_completion_tokens") or request.get("max_tokens") or COMPLETION_TOKENS
    completion_tokens = max(1, min(int(limit), COMPLETION_TOKENS))
    model = request.get("model") if isinstance(request.get("model"), str) else "mock-chat"
    del request, body
    in_flight += 1
    try:
        await asyncio.sleep(wait / 1000)
        response = {
            "id": "chatcmpl-mock-" + uuid.uuid4().hex,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "This is a mock answer."}}],
            "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens,
                      "total_tokens": prompt_tokens + completion_tokens},
        }
        count(200, owner, path)
        await respond(writer, 200, json.dumps(response), echo)
    finally:
        in_flight -= 1


async def api(reader, writer):
    try:
        while True:
            try:
                request = await read_request(reader)
            except BadRequest as error:
                await respond(writer, error.status, error_body(error.message, "bad_request"))
                break
            if request is None:
                break
            method, path, headers, body = request
            if path == "/healthz" and method == "GET":
                await respond(writer, 200, "ok", content_type="text/plain")
            elif path in CHAT_PATHS and method == "POST":
                try:
                    await chat(writer, headers, body, path)
                except BadRequest as error:
                    await respond(writer, error.status, error_body(error.message, "bad_request"))
            elif path in CHAT_PATHS:
                await respond(writer, 405, error_body("Use POST", "method_not_allowed"))
            else:
                await respond(writer, 404, error_body("Not found", "not_found"))
            if headers.get("connection", "").lower() == "close":
                break
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError):
        pass
    finally:
        writer.close()


def metrics():
    lines = ["# TYPE mock_requests_total counter"]
    for (code, owner), value in sorted(requests_total.items()):
        lines.append(f'mock_requests_total{{code="{code}",owner="{owner}"}} {value}')
    lines.append("# TYPE mock_path_requests_total counter")
    for path, value in sorted(paths_total.items()):
        lines.append(f'mock_path_requests_total{{path="{path}"}} {value}')
    lines += ["# TYPE mock_in_flight gauge", f"mock_in_flight {in_flight}",
              "# TYPE mock_keys gauge", f"mock_keys {len(keys)}"]
    return "\n".join(lines) + "\n"


async def admin(reader, writer):
    global keys
    try:
        request = await read_request(reader)
        if request is None:
            return
        method, path, _headers, body = request
        if path == "/metrics" and method == "GET":
            await respond(writer, 200, metrics(), content_type="text/plain; version=0.0.4")
        elif path == "/admin/keys" and method == "GET":
            await respond(writer, 200, json.dumps({"owners": sorted(set(keys.values()))}))
        elif path == "/admin/keys" and method == "POST":
            try:
                keys = parse_keys(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError) as error:
                await respond(writer, 400, error_body(str(error), "invalid_keys"))
                return
            await respond(writer, 200, json.dumps({"owners": sorted(set(keys.values()))}))
        else:
            await respond(writer, 404, error_body("Not found", "not_found"))
    except (BadRequest, asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError):
        pass
    finally:
        writer.close()


async def main():
    load_key_file()
    api_server = await asyncio.start_server(api, "0.0.0.0", API_PORT, backlog=4096)
    admin_server = await asyncio.start_server(admin, "0.0.0.0", ADMIN_PORT)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, stop.set)
    print(f"mock listening on {API_PORT} (api) and {ADMIN_PORT} (metrics, admin); {len(keys)} keys", flush=True)
    async with api_server, admin_server:
        await stop.wait()


if __name__ == "__main__":
    asyncio.run(main())
