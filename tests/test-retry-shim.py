#!/usr/bin/env python3
"""Deterministic integration tests for the bounded retry shim.

These tests use only local asyncio sockets. They make no model request and read
no credentials.
"""

import asyncio
import importlib.util
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SHIM_PATH = REPO_ROOT / "scripts" / "ccx-retry-shim.py"
SPEC = importlib.util.spec_from_file_location("ccx_retry_shim", SHIM_PATH)
SHIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHIM)

REQUEST = (
    b"POST /v1/messages HTTP/1.1\r\n"
    b"host: 127.0.0.1\r\n"
    b"content-length: 0\r\n"
    b"\r\n"
)


async def close_server(server):
    server.close()
    await server.wait_closed()


async def close_writer(writer):
    writer.close()
    try:
        await writer.wait_closed()
    except (ConnectionError, OSError):
        pass


class RetryShimTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.originals = {
            "MAX_RETRIES": SHIM.MAX_RETRIES,
            "RETRY_STATUSES": SHIM.RETRY_STATUSES,
            "CONNECT_TIMEOUT": SHIM.CONNECT_TIMEOUT,
            "REQUEST_TIMEOUT": SHIM.REQUEST_TIMEOUT,
            "RESPONSE_HEADER_TIMEOUT": SHIM.RESPONSE_HEADER_TIMEOUT,
            "STREAM_IDLE_TIMEOUT": SHIM.STREAM_IDLE_TIMEOUT,
            "WRITE_TIMEOUT": SHIM.WRITE_TIMEOUT,
            "MAX_CONNECTIONS": SHIM.MAX_CONNECTIONS,
            "QUEUE_TIMEOUT": SHIM.QUEUE_TIMEOUT,
            "LOG_PATH": SHIM.LOG_PATH,
            "UPSTREAM_PORT": SHIM.UPSTREAM_PORT,
        }
        SHIM.MAX_RETRIES = 1
        SHIM.RETRY_STATUSES = {401}
        SHIM.CONNECT_TIMEOUT = 0.1
        SHIM.REQUEST_TIMEOUT = 0.2
        SHIM.RESPONSE_HEADER_TIMEOUT = 0.1
        SHIM.STREAM_IDLE_TIMEOUT = 0.1
        SHIM.WRITE_TIMEOUT = 0.1
        SHIM.MAX_CONNECTIONS = 8
        SHIM.QUEUE_TIMEOUT = 0.1
        SHIM.LOG_PATH = Path(self.temp_dir.name) / "nested" / "retry-shim.log"
        SHIM._connection_semaphore = None
        self.servers = []

    async def asyncTearDown(self):
        for server in reversed(self.servers):
            await close_server(server)
        for name, value in self.originals.items():
            setattr(SHIM, name, value)
        SHIM._connection_semaphore = None
        self.temp_dir.cleanup()

    async def start_server(self, handler):
        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        self.servers.append(server)
        return server

    async def start_upstream(self, handler):
        server = await self.start_server(handler)
        SHIM.UPSTREAM_PORT = server.sockets[0].getsockname()[1]
        return server

    async def start_shim(self, guarded=False):
        handler = SHIM.guarded_handle if guarded else SHIM.handle
        return await self.start_server(handler)

    async def request(self, shim_server, close_after_write=False):
        port = shim_server.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(REQUEST)
        await writer.drain()
        if close_after_write:
            await close_writer(writer)
            return b""
        response = await asyncio.wait_for(reader.read(), timeout=1)
        await close_writer(writer)
        return response

    async def test_one_401_retry_recovers_once(self):
        request_count = 0

        async def upstream(reader, writer):
            nonlocal request_count
            await reader.readuntil(b"\r\n\r\n")
            request_count += 1
            if request_count == 1:
                response = (
                    b"HTTP/1.1 401 Unauthorized\r\n"
                    b"content-length: 0\r\n"
                    b"connection: close\r\n\r\n"
                )
            else:
                response = (
                    b"HTTP/1.1 200 OK\r\n"
                    b"content-length: 2\r\n"
                    b"connection: close\r\n\r\nOK"
                )
            writer.write(response)
            await writer.drain()
            await close_writer(writer)

        await self.start_upstream(upstream)
        shim_server = await self.start_shim()
        response = await self.request(shim_server)

        self.assertIn(b"HTTP/1.1 200 OK", response)
        self.assertTrue(response.endswith(b"OK"))
        self.assertEqual(request_count, 2)

    async def test_retry_count_is_bounded(self):
        request_count = 0

        async def upstream(reader, writer):
            nonlocal request_count
            await reader.readuntil(b"\r\n\r\n")
            request_count += 1
            writer.write(
                b"HTTP/1.1 401 Unauthorized\r\n"
                b"content-length: 0\r\n"
                b"connection: close\r\n\r\n"
            )
            await writer.drain()
            await close_writer(writer)

        await self.start_upstream(upstream)
        shim_server = await self.start_shim()
        response = await self.request(shim_server)

        self.assertIn(b"HTTP/1.1 401 Unauthorized", response)
        self.assertEqual(request_count, 2)

    async def test_503_is_not_retried_by_default(self):
        request_count = 0

        async def upstream(reader, writer):
            nonlocal request_count
            await reader.readuntil(b"\r\n\r\n")
            request_count += 1
            writer.write(
                b"HTTP/1.1 503 Service Unavailable\r\n"
                b"content-length: 0\r\n"
                b"connection: close\r\n\r\n"
            )
            await writer.drain()
            await close_writer(writer)

        await self.start_upstream(upstream)
        shim_server = await self.start_shim()
        response = await self.request(shim_server)

        self.assertIn(b"HTTP/1.1 503 Service Unavailable", response)
        self.assertEqual(request_count, 1)

    async def test_connect_failure_is_not_retried(self):
        async def unused_handler(reader, writer):
            await close_writer(writer)

        unused_server = await self.start_server(unused_handler)
        SHIM.UPSTREAM_PORT = unused_server.sockets[0].getsockname()[1]
        await close_server(unused_server)
        self.servers.remove(unused_server)
        shim_server = await self.start_shim()

        started = time.monotonic()
        response = await self.request(shim_server)
        elapsed = time.monotonic() - started

        self.assertIn(b"HTTP/1.1 502 Bad Gateway", response)
        self.assertLess(elapsed, 0.2)

    async def test_stalled_response_header_returns_504(self):
        async def upstream(reader, writer):
            await reader.readuntil(b"\r\n\r\n")
            await asyncio.sleep(0.5)
            await close_writer(writer)

        SHIM.MAX_RETRIES = 0
        SHIM.RESPONSE_HEADER_TIMEOUT = 0.05
        await self.start_upstream(upstream)
        shim_server = await self.start_shim()

        started = time.monotonic()
        response = await self.request(shim_server)
        elapsed = time.monotonic() - started

        self.assertIn(b"HTTP/1.1 504 Gateway Timeout", response)
        self.assertLess(elapsed, 0.4)

    async def test_stalled_stream_is_closed_after_idle_timeout(self):
        async def upstream(reader, writer):
            await reader.readuntil(b"\r\n\r\n")
            writer.write(
                b"HTTP/1.1 200 OK\r\n"
                b"connection: close\r\n\r\n"
                b"first-event"
            )
            await writer.drain()
            await asyncio.sleep(0.5)
            await close_writer(writer)

        SHIM.STREAM_IDLE_TIMEOUT = 0.05
        await self.start_upstream(upstream)
        shim_server = await self.start_shim()

        started = time.monotonic()
        response = await self.request(shim_server)
        elapsed = time.monotonic() - started

        self.assertIn(b"HTTP/1.1 200 OK", response)
        self.assertIn(b"first-event", response)
        self.assertLess(elapsed, 0.4)

    async def test_client_disconnect_closes_stalled_upstream(self):
        upstream_accepted = asyncio.Event()
        upstream_closed = asyncio.Event()

        async def upstream(reader, writer):
            await reader.readuntil(b"\r\n\r\n")
            upstream_accepted.set()
            await reader.read()
            upstream_closed.set()
            await close_writer(writer)

        await self.start_upstream(upstream)
        shim_server = await self.start_shim()
        port = shim_server.sockets[0].getsockname()[1]
        _, client_writer = await asyncio.open_connection("127.0.0.1", port)
        client_writer.write(REQUEST)
        await client_writer.drain()
        await asyncio.wait_for(upstream_accepted.wait(), timeout=0.5)
        await close_writer(client_writer)

        await asyncio.wait_for(upstream_closed.wait(), timeout=0.5)

    async def test_connection_cap_rejects_queue_instead_of_spinning(self):
        upstream_accepted = asyncio.Event()
        release_upstream = asyncio.Event()

        async def upstream(reader, writer):
            await reader.readuntil(b"\r\n\r\n")
            upstream_accepted.set()
            await release_upstream.wait()
            writer.write(
                b"HTTP/1.1 200 OK\r\n"
                b"content-length: 0\r\n"
                b"connection: close\r\n\r\n"
            )
            await writer.drain()
            await close_writer(writer)

        SHIM.MAX_CONNECTIONS = 1
        SHIM.QUEUE_TIMEOUT = 0.05
        SHIM._connection_semaphore = None
        await self.start_upstream(upstream)
        shim_server = await self.start_shim(guarded=True)
        port = shim_server.sockets[0].getsockname()[1]

        first_reader, first_writer = await asyncio.open_connection("127.0.0.1", port)
        first_writer.write(REQUEST)
        await first_writer.drain()
        await asyncio.wait_for(upstream_accepted.wait(), timeout=0.5)

        second_reader, second_writer = await asyncio.open_connection("127.0.0.1", port)
        second_writer.write(REQUEST)
        await second_writer.drain()
        second_response = await asyncio.wait_for(second_reader.read(), timeout=0.5)

        self.assertIn(b"HTTP/1.1 503 Service Unavailable", second_response)

        release_upstream.set()
        await asyncio.wait_for(first_reader.read(), timeout=0.5)
        await close_writer(first_writer)
        await close_writer(second_writer)

    def test_log_creates_portable_state_directory(self):
        SHIM.log("test message")
        self.assertTrue(SHIM.LOG_PATH.is_file())
        self.assertIn("test message", SHIM.LOG_PATH.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
