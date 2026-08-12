#!/usr/bin/env python3
"""Test-only TCP proxy keeping Chromium CDP on loopback inside the container."""

import asyncio


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()


async def handle(client_reader, client_writer):
    upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", 9222)
    await asyncio.gather(
        pipe(client_reader, upstream_writer),
        pipe(upstream_reader, client_writer),
        return_exceptions=True,
    )


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", 9223)
    async with server:
        await server.serve_forever()


asyncio.run(main())
