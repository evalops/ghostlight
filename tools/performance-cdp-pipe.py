#!/usr/bin/env python3
"""Benchmark-only bridge from Chromium's trusted CDP pipe to a TCP socket."""

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time


def log(message):
    print(f"[ghostlight-cdp-pipe] {message}", flush=True)


def http_response(path):
    if path == "/json/version":
        body = {
            "Browser": "ghostlight-performance-chromium-pipe",
            "Protocol-Version": "1.3",
            "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/browser/pipe",
        }
    elif path == "/json/list":
        body = []
    else:
        body = {"error": "not found"}
    encoded = json.dumps(body, separators=(",", ":")).encode()
    status = b"200 OK" if path in ("/json/version", "/json/list") else b"404 Not Found"
    return (
        b"HTTP/1.1 " + status + b"\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(encoded)).encode() + b"\r\n"
        b"Connection: close\r\n\r\n" + encoded
    )


class PipeBridge:
    def __init__(self, command, bind_address, port):
        self.command = command
        self.bind_address = bind_address
        self.port = port
        self.process = None
        self.browser_write = None
        self.browser_read = None
        self.server = None
        self.stopping = threading.Event()

    def start_browser(self):
        browser_read, browser_write = os.pipe()
        browser_output_read, browser_output_write = os.pipe()
        child_read = os.dup(browser_read)
        child_write = os.dup(browser_output_write)
        parent_write = os.dup(browser_write)
        parent_read = os.dup(browser_output_read)
        for fd in (browser_read, browser_write, browser_output_read, browser_output_write):
            os.close(fd)
        os.dup2(child_read, 3, inheritable=True)
        os.dup2(child_write, 4, inheritable=True)
        os.close(child_read)
        os.close(child_write)
        self.browser_write = parent_write
        self.browser_read = parent_read
        self.process = subprocess.Popen(
            self.command,
            close_fds=True,
            pass_fds=(3, 4),
        )
        os.close(3)
        os.close(4)
        log(f"chromium pid={self.process.pid} cdp=pipe")

    def forward_client(self, client, initial):
        try:
            if initial:
                os.write(self.browser_write, initial)
            while not self.stopping.is_set():
                data = client.recv(65536)
                if not data:
                    return
                os.write(self.browser_write, data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def forward_browser(self, client):
        try:
            while not self.stopping.is_set():
                data = os.read(self.browser_read, 65536)
                if not data:
                    return
                client.sendall(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def serve_client(self, client):
        with client:
            client.settimeout(10)
            try:
                initial = client.recv(65536)
            except (socket.timeout, ConnectionResetError, OSError):
                return
            if initial.startswith(b"GET "):
                request_line = initial.split(b"\r\n", 1)[0].decode("ascii", "replace")
                path = request_line.split(" ", 2)[1] if len(request_line.split(" ", 2)) > 1 else ""
                try:
                    client.sendall(http_response(path))
                except OSError:
                    pass
                return
            client.settimeout(None)
            browser_to_client = threading.Thread(target=self.forward_browser, args=(client,), daemon=True)
            browser_to_client.start()
            self.forward_client(client, initial)
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def serve(self):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((self.bind_address, self.port))
        self.server.listen(4)
        self.server.settimeout(1)
        log(f"listening on {self.bind_address}:{self.port}")
        while not self.stopping.is_set():
            if self.process.poll() is not None:
                raise RuntimeError(f"chromium exited with status {self.process.returncode}")
            try:
                client, address = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stopping.is_set():
                    return
                raise
            log(f"client {address[0]}:{address[1]}")
            self.serve_client(client)

    def stop(self, *_args):
        if self.stopping.is_set():
            return
        self.stopping.set()
        if self.server:
            try:
                self.server.close()
            except OSError:
                pass
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        for fd in (self.browser_write, self.browser_read):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bind",
        default="127.0.0.1",
        help="listen address (default: 127.0.0.1; the CDP socket is unauthenticated,"
        " so a wider bind such as 0.0.0.0 must be requested explicitly)",
    )
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("a Chromium command is required")
    if "--remote-debugging-pipe" not in command:
        command.append("--remote-debugging-pipe")
    bridge = PipeBridge(command, args.bind, args.port)
    signal.signal(signal.SIGTERM, bridge.stop)
    signal.signal(signal.SIGINT, bridge.stop)
    try:
        bridge.start_browser()
        bridge.serve()
    finally:
        bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
