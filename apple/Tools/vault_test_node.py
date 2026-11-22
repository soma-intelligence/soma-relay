#!/usr/bin/env python3
"""Local relay node for the backup UI tests (apple/UITests/BackupUITests.swift).

Runs `cargo run -p relay-node` on 127.0.0.1:<node-port> with a scratch data directory, and a
small control server on 127.0.0.1:<ctl-port> so the UI tests can stop and restart the node:

    GET /start          start the node (fresh data directory)
    GET /start?keep=1   start it again on the same data directory
    GET /stop           stop it
    GET /status         "up" or "down"

The fake passkey of the UI tests always gives the same vault id, and the first mailbox that
writes a vault id owns it, so every test starts the node fresh.

Usage (from the repository root):

    python3 apple/Tools/vault_test_node.py --node-port 8131 --ctl-port 8132 &
    cd apple && TEST_RUNNER_RELAY_NODE_URL=http://127.0.0.1:8131 \\
        TEST_RUNNER_RELAY_NODE_CTL=http://127.0.0.1:8132 \\
        xcodebuild test ... -only-testing:SomaRelayUITests/BackupUITests
"""

import argparse
import http.server
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class Node:
    def __init__(self, port, data_root):
        self.port = port
        self.data_dir = os.path.join(data_root, "node")
        self.proc = None
        self.lock = threading.Lock()

    def up(self):
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.3):
                return True
        except OSError:
            return False

    def start(self, fresh):
        with self.lock:
            self._stop()
            if fresh:
                shutil.rmtree(self.data_dir, ignore_errors=True)
            os.makedirs(self.data_dir, exist_ok=True)
            cmd = [
                "cargo", "run", "-q", "-p", "relay-node", "--",
                "--listen", f"127.0.0.1:{self.port}",
                "--data-dir", self.data_dir,
                "--web-dir", os.path.join(self.data_dir, "web"),
                "--rate-per-sec", "0",
            ]
            self.proc = subprocess.Popen(cmd, cwd=REPO, stdout=sys.stderr, stderr=sys.stderr)
            deadline = time.time() + 120
            while time.time() < deadline:
                if self.proc.poll() is not None:
                    return False
                if self.up():
                    return True
                time.sleep(0.1)
            return False

    def _stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None
        deadline = time.time() + 10
        while self.up() and time.time() < deadline:
            time.sleep(0.1)

    def stop(self):
        with self.lock:
            self._stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node-port", type=int, default=8131)
    parser.add_argument("--ctl-port", type=int, default=8132)
    parser.add_argument("--data-root", default=None)
    args = parser.parse_args()

    data_root = args.data_root or tempfile.mkdtemp(prefix="relay-vault-test-")
    node = Node(args.node_port, data_root)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path == "/start":
                ok = node.start(fresh=query.get("keep") != ["1"])
                self.reply(200 if ok else 500, "up" if ok else "failed")
            elif url.path == "/stop":
                node.stop()
                self.reply(200, "down")
            elif url.path == "/status":
                self.reply(200, "up" if node.up() else "down")
            else:
                self.reply(404, "not found")

        def reply(self, code, text):
            body = text.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *a):
            sys.stderr.write("ctl: " + (fmt % a) + "\n")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.ctl_port), Handler)

    def shutdown(*_):
        node.stop()
        shutil.rmtree(data_root, ignore_errors=True) if args.data_root is None else None
        os._exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    sys.stderr.write(f"control on 127.0.0.1:{args.ctl_port}, node on 127.0.0.1:{args.node_port}, data {data_root}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
