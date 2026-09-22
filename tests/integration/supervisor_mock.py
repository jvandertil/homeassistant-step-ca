"""Minimal Supervisor API used only by the container integration test."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


OPTIONS_FILE = os.environ["OPTIONS_FILE"]


def response(handler, payload):
    body = json.dumps(payload).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class SupervisorHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            response(self, {"result": "ok"})
            return

        with open(OPTIONS_FILE, encoding="utf-8") as options_file:
            options = json.load(options_file)

        if self.path == "/addons/self/options/config":
            response(self, {"result": "ok", "data": options})
            return

        if self.path == "/addons/self/info":
            response(
                self,
                {
                    "result": "ok",
                    "data": {
                        "name": "step-ca-client",
                        "slug": "step-ca-client",
                        "version": "integration-test",
                        "arch": ["amd64", "aarch64"],
                        "options": options,
                    },
                },
            )
            return

        response(self, {"result": "ok", "data": {}})

    def log_message(self, *_):
        """Do not log API requests, which include no useful test output."""


ThreadingHTTPServer(("", 80), SupervisorHandler).serve_forever()
