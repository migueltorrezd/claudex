#!/usr/bin/env python3
"""Bounded retry shim for claude-code-proxy.

The shim intentionally retries only explicit, configured HTTP statuses. Its
default is one retry for a 401 response. Claude Code already retries transport
and 5xx failures, so retrying those again here would multiply requests across
every subagent.

All connection phases have deadlines, client cancellation closes the upstream
socket, and concurrent connections are capped. Ports and limits are
configurable for deterministic tests:

  CCX_SHIM_LISTEN_PORT             (default 18767)
  CCX_SHIM_UPSTREAM_PORT           (default 18765)
  CCX_SHIM_MAX_RETRIES             (default 1)
  CCX_SHIM_RETRY_STATUSES          (default 401)
  CCX_SHIM_CONNECT_TIMEOUT         (default 5 seconds)
  CCX_SHIM_REQUEST_TIMEOUT         (default 30 seconds)
  CCX_SHIM_RESPONSE_HEADER_TIMEOUT (default 120 seconds)
  CCX_SHIM_STREAM_IDLE_TIMEOUT     (default 120 seconds)
  CCX_SHIM_MAX_CONNECTIONS         (default 8)
  CCX_SHIM_QUEUE_TIMEOUT           (default 10 seconds)
  CCX_SHIM_LOG_PATH                (default: XDG state directory)
"""

import asyncio
import contextlib
import os
import time
from pathlib import Path


def env_int(name, default, minimum=0):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"{name} must be an integer, got {raw!r}") from exc
    if value < minimum:
        raise SystemExit(f"{name} must be at least {minimum}, got {value}")
    return value


def env_float(name, default, minimum=0.001):
    raw = os.environ.get(name, str(default))
    try:
        value = float(raw)
    except ValueError as exc:
        raise SystemExit(f"{name} must be a number, got {raw!r}") from exc
    if value < minimum:
        raise SystemExit(f"{name} must be at least {minimum}, got {value}")
    return value


def env_statuses(name, default):
    raw = os.environ.get(name, default)
    try:
        statuses = {int(part.strip()) for part in raw.split(",") if part.strip()}
    except ValueError as exc:
        raise SystemExit(f"{name} must be a comma-separated list of HTTP statuses") from exc
    if not statuses or any(status < 100 or status > 599 for status in statuses):
        raise SystemExit(f"{name} must contain HTTP statuses from 100 to 599")
    return statuses


LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = env_int("CCX_SHIM_LISTEN_PORT", 18767, 1)
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = env_int("CCX_SHIM_UPSTREAM_PORT", 18765, 1)
MAX_RETRIES = env_int("CCX_SHIM_MAX_RETRIES", 1)
RETRY_STATUSES = env_statuses("CCX_SHIM_RETRY_STATUSES", "401")
CONNECT_TIMEOUT = env_float("CCX_SHIM_CONNECT_TIMEOUT", 5)
REQUEST_TIMEOUT = env_float("CCX_SHIM_REQUEST_TIMEOUT", 30)
RESPONSE_HEADER_TIMEOUT = env_float("CCX_SHIM_RESPONSE_HEADER_TIMEOUT", 120)
STREAM_IDLE_TIMEOUT = env_float("CCX_SHIM_STREAM_IDLE_TIMEOUT", 120)
WRITE_TIMEOUT = env_float("CCX_SHIM_WRITE_TIMEOUT", 5)
MAX_CONNECTIONS = env_int("CCX_SHIM_MAX_CONNECTIONS", 8, 1)
QUEUE_TIMEOUT = env_float("CCX_SHIM_QUEUE_TIMEOUT", 10)
BACKOFF = (0.25, 0.5, 1.0, 2.0)

state_home = Path(
    os.environ.get(
        "XDG_STATE_HOME",
        str(Path.home() / ".local" / "state"),
    )
)
LOG_PATH = Path(
    os.path.expanduser(
        os.environ.get(
            "CCX_SHIM_LOG_PATH",
            str(state_home / "claudex" / "retry-shim.log"),
        )
    )
)

_connection_semaphore = None


class ClientDisconnected(Exception):
    """The downstream client disappeared while a request was in flight."""


def log(message):
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as log_file:
            log_file.write(f"{timestamp} {message}\n")
    except OSError:
        pass


def parse_head(head):
    lines = head.split(b"\r\n")
    headers = {}
    for line in lines[1:]:
        if b":" in line:
            key, value = line.split(b":", 1)
            headers[key.strip().lower()] = value.strip()
    return lines[0], headers


async def read_body(reader, headers):
    content_length = headers.get(b"content-length")
    if content_length:
        length = int(content_length)
        if length < 0:
            raise ValueError("negative content-length")
        return await reader.readexactly(length)

    if headers.get(b"transfer-encoding", b"").lower() == b"chunked":
        body = bytearray()
        while True:
            size_line = await reader.readuntil(b"\r\n")
            size_token = size_line.split(b";", 1)[0].strip()
            size = int(size_token, 16)
            body.extend(size_line)
            if size == 0:
                while True:
                    trailer_line = await reader.readuntil(b"\r\n")
                    body.extend(trailer_line)
                    if trailer_line == b"\r\n":
                        return bytes(body)
            chunk = await reader.readexactly(size + 2)
            if not chunk.endswith(b"\r\n"):
                raise ValueError("invalid chunk framing")
            body.extend(chunk)

    return b""


def rebuild_request(first_line, headers, body):
    forwarded_headers = dict(headers)
    forwarded_headers[b"connection"] = b"close"
    output = [first_line]
    for key, value in forwarded_headers.items():
        output.append(key + b": " + value)
    return b"\r\n".join(output) + b"\r\n\r\n" + body


async def close_writer(writer):
    if writer is None:
        return
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()


async def cancel_task(task):
    if task is None or task.done():
        return
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await task


async def wait_with_disconnect(awaitable, disconnect_task, timeout):
    operation_task = asyncio.create_task(awaitable)
    done, _ = await asyncio.wait(
        {operation_task, disconnect_task},
        timeout=timeout,
        return_when=asyncio.FIRST_COMPLETED,
    )
    if disconnect_task in done:
        await cancel_task(operation_task)
        raise ClientDisconnected
    if operation_task not in done:
        await cancel_task(operation_task)
        raise asyncio.TimeoutError
    return operation_task.result()


async def send_response(writer, status, reason):
    payload = (
        f"HTTP/1.1 {status} {reason}\r\n"
        "content-length: 0\r\n"
        "connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    writer.write(payload)
    with contextlib.suppress(
        asyncio.TimeoutError,
        ConnectionError,
        OSError,
    ):
        await asyncio.wait_for(writer.drain(), timeout=WRITE_TIMEOUT)


def retry_delay(attempt):
    return BACKOFF[min(attempt, len(BACKOFF) - 1)]


async def handle(client_reader, client_writer):
    disconnect_task = None
    upstream_writer = None
    path = "?"
    try:
        try:
            head = await asyncio.wait_for(
                client_reader.readuntil(b"\r\n\r\n"),
                timeout=REQUEST_TIMEOUT,
            )
            first_line, headers = parse_head(head)
            body = await asyncio.wait_for(
                read_body(client_reader, headers),
                timeout=REQUEST_TIMEOUT,
            )
            request = rebuild_request(first_line, headers, body)
            path_bytes = first_line.split(b" ")[1] if b" " in first_line else b"?"
            path = path_bytes.decode("utf-8", errors="replace")
        except asyncio.TimeoutError:
            log("client request timeout")
            await send_response(client_writer, 408, "Request Timeout")
            return
        except (
            asyncio.IncompleteReadError,
            asyncio.LimitOverrunError,
            IndexError,
            OSError,
            ValueError,
        ):
            await send_response(client_writer, 400, "Bad Request")
            return

        # HTTP pipelining is intentionally unsupported. After one complete
        # request, additional bytes or EOF mean the client has gone away.
        disconnect_task = asyncio.create_task(client_reader.read(1))

        for attempt in range(MAX_RETRIES + 1):
            response_started = False
            upstream_writer = None
            try:
                upstream_reader, upstream_writer = await wait_with_disconnect(
                    asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT),
                    disconnect_task,
                    CONNECT_TIMEOUT,
                )
            except ClientDisconnected:
                log(f"client disconnected before upstream connect path={path}")
                return
            except (asyncio.TimeoutError, OSError):
                log(f"upstream connect failed path={path}")
                await send_response(client_writer, 502, "Bad Gateway")
                return

            try:
                upstream_writer.write(request)
                await wait_with_disconnect(
                    upstream_writer.drain(),
                    disconnect_task,
                    WRITE_TIMEOUT,
                )
                response_head = await wait_with_disconnect(
                    upstream_reader.readuntil(b"\r\n\r\n"),
                    disconnect_task,
                    RESPONSE_HEADER_TIMEOUT,
                )
                status = int(response_head.split(b" ", 2)[1])

                if status in RETRY_STATUSES and attempt < MAX_RETRIES:
                    log(f"retry status={status} attempt={attempt + 1} path={path}")
                    await close_writer(upstream_writer)
                    upstream_writer = None
                    await wait_with_disconnect(
                        asyncio.sleep(retry_delay(attempt)),
                        disconnect_task,
                        retry_delay(attempt) + 1,
                    )
                    continue

                if attempt > 0:
                    log(f"recovered status={status} after={attempt} path={path}")

                client_writer.write(response_head)
                await wait_with_disconnect(
                    client_writer.drain(),
                    disconnect_task,
                    WRITE_TIMEOUT,
                )
                response_started = True

                while True:
                    chunk = await wait_with_disconnect(
                        upstream_reader.read(65536),
                        disconnect_task,
                        STREAM_IDLE_TIMEOUT,
                    )
                    if not chunk:
                        return
                    client_writer.write(chunk)
                    await wait_with_disconnect(
                        client_writer.drain(),
                        disconnect_task,
                        WRITE_TIMEOUT,
                    )
            except ClientDisconnected:
                log(f"client disconnected path={path}")
                return
            except asyncio.TimeoutError:
                phase = "stream idle" if response_started else "response header"
                log(f"{phase} timeout path={path}")
                if not response_started:
                    await send_response(client_writer, 504, "Gateway Timeout")
                return
            except (
                asyncio.IncompleteReadError,
                ConnectionError,
                OSError,
                ValueError,
                IndexError,
            ):
                log(f"broken upstream path={path}")
                if not response_started:
                    await send_response(client_writer, 502, "Bad Gateway")
                return
            finally:
                await close_writer(upstream_writer)
                upstream_writer = None
    finally:
        await cancel_task(disconnect_task)
        await close_writer(upstream_writer)
        await close_writer(client_writer)


async def guarded_handle(client_reader, client_writer):
    global _connection_semaphore
    if _connection_semaphore is None:
        _connection_semaphore = asyncio.Semaphore(MAX_CONNECTIONS)

    try:
        await asyncio.wait_for(
            _connection_semaphore.acquire(),
            timeout=QUEUE_TIMEOUT,
        )
    except asyncio.TimeoutError:
        log("connection queue timeout")
        await send_response(client_writer, 503, "Service Unavailable")
        await close_writer(client_writer)
        return

    try:
        await handle(client_reader, client_writer)
    finally:
        _connection_semaphore.release()


async def main():
    server = await asyncio.start_server(
        guarded_handle,
        LISTEN_HOST,
        LISTEN_PORT,
    )
    log(
        "listening "
        f"on {LISTEN_HOST}:{LISTEN_PORT} "
        f"upstream {UPSTREAM_HOST}:{UPSTREAM_PORT} "
        f"max_connections={MAX_CONNECTIONS} "
        f"max_retries={MAX_RETRIES} "
        f"retry_statuses={sorted(RETRY_STATUSES)}"
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
