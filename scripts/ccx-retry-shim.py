#!/usr/bin/env python3
"""Transparent retry shim for claude-code-proxy.

Sits between Claude Code and claude-code-proxy (raine/claude-code-proxy).
The proxy intermittently returns 401 during token-refresh races under
parallel load; Claude Code treats 401 as terminal and kills the subagent.
This shim retries retryable statuses with backoff before the client ever
sees them, converting fatal auth flaps into ~seconds of added latency.

Stdlib only. Ports configurable for testing:
  CCX_SHIM_LISTEN_PORT   (default 18766)
  CCX_SHIM_UPSTREAM_PORT (default 18765)
"""
import asyncio
import os
import time

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("CCX_SHIM_LISTEN_PORT", "18767"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.environ.get("CCX_SHIM_UPSTREAM_PORT", "18765"))
RETRY_STATUSES = {401, 502, 503, 529}
BACKOFF = (0.25, 0.5, 1.0, 2.0, 4.0)
LOG_PATH = os.path.expanduser("~/Library/Logs/claude-code-proxy/retry-shim.log")


def log(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(LOG_PATH, "a") as fh:
            fh.write("%s %s\n" % (ts, msg))
    except OSError:
        pass


def parse_head(head):
    lines = head.split(b"\r\n")
    headers = {}
    for line in lines[1:]:
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.strip().lower()] = v.strip()
    return lines[0], headers


async def read_body(reader, headers):
    cl = headers.get(b"content-length")
    if cl:
        return await reader.readexactly(int(cl))
    if headers.get(b"transfer-encoding", b"").lower() == b"chunked":
        # Preserve raw chunked framing so it can be re-sent verbatim.
        body = b""
        while True:
            size_line = await reader.readuntil(b"\r\n")
            size = int(size_line.strip(), 16)
            chunk = await reader.readexactly(size + 2)
            body += size_line + chunk
            if size == 0:
                return body
    return b""


def rebuild_request(first_line, headers, body):
    headers = dict(headers)
    headers[b"connection"] = b"close"
    out = [first_line]
    for k, v in headers.items():
        out.append(k + b": " + v)
    return b"\r\n".join(out) + b"\r\n\r\n" + body


async def handle(client_reader, client_writer):
    try:
        head = await client_reader.readuntil(b"\r\n\r\n")
        first_line, headers = parse_head(head)
        body = await read_body(client_reader, headers)
        request = rebuild_request(first_line, headers, body)
        path = first_line.split(b" ")[1] if b" " in first_line else b"?"

        for attempt in range(len(BACKOFF) + 1):
            try:
                up_reader, up_writer = await asyncio.wait_for(
                    asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT), timeout=5
                )
            except (OSError, asyncio.TimeoutError):
                if attempt < len(BACKOFF):
                    log("retry connect attempt=%d path=%s" % (attempt + 1, path.decode()))
                    await asyncio.sleep(BACKOFF[attempt])
                    continue
                client_writer.write(
                    b"HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                )
                await client_writer.drain()
                return

            try:
                up_writer.write(request)
                await up_writer.drain()
                resp_head = await up_reader.readuntil(b"\r\n\r\n")
                status = int(resp_head.split(b" ", 2)[1])
            except (asyncio.IncompleteReadError, ConnectionResetError, OSError, ValueError, IndexError):
                up_writer.close()
                if attempt < len(BACKOFF):
                    log("retry broken-upstream attempt=%d path=%s" % (attempt + 1, path.decode()))
                    await asyncio.sleep(BACKOFF[attempt])
                    continue
                client_writer.write(
                    b"HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                )
                await client_writer.drain()
                return

            if status in RETRY_STATUSES and attempt < len(BACKOFF):
                up_writer.close()
                log("retry status=%d attempt=%d path=%s" % (status, attempt + 1, path.decode()))
                await asyncio.sleep(BACKOFF[attempt])
                continue

            if attempt > 0:
                log("recovered status=%d after=%d path=%s" % (status, attempt, path.decode()))
            client_writer.write(resp_head)
            while True:
                chunk = await up_reader.read(65536)
                if not chunk:
                    break
                client_writer.write(chunk)
                await client_writer.drain()
            up_writer.close()
            return
    except (asyncio.IncompleteReadError, ConnectionResetError, asyncio.LimitOverrunError, ValueError, OSError):
        pass
    finally:
        try:
            client_writer.close()
        except Exception:
            pass


async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    log("listening on %s:%d upstream %s:%d" % (LISTEN_HOST, LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT))
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
