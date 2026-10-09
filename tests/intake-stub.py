#!/usr/bin/env python3
"""A local HTTPS stand-in for the backend's ops-alert intake, for
tests/test-notify-backoffice.sh.

Every request is saved as <dir>/req.<n>.json (method, path, headers) plus
<dir>/req.<n>.body, the body exactly as it arrived. The answer comes from
<dir>/respond if it exists: its first line is "<status> [delay in seconds]",
the rest is the body. Without it the answer is 202 with an alert id, as the
intake gives for an alert it opened or updated.

Usage: intake-stub.py <dir> <port> <certfile> <keyfile>
"""
import http.server
import json
import os
import ssl
import sys
import threading
import time

state_dir, port, certfile, keyfile = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
lock = threading.Lock()
count = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self):
        global count
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with lock:
            count += 1
            n = count
        with open(os.path.join(state_dir, "req.%d.body" % n), "wb") as f:
            f.write(body)
        with open(os.path.join(state_dir, "req.%d.json" % n), "w") as f:
            json.dump({"method": self.command, "path": self.path,
                       "headers": {k.lower(): v for k, v in self.headers.items()}}, f)

        status, delay, payload = 202, 0.0, b'{"id":"65f1c0de2a9b4e0012345678"}'
        respond = os.path.join(state_dir, "respond")
        if os.path.exists(respond):
            with open(respond, "rb") as f:
                first, _, payload = f.read().partition(b"\n")
            fields = first.split()
            status = int(fields[0])
            delay = float(fields[1]) if len(fields) > 1 else 0.0
        time.sleep(delay)
        try:
            self.send_response(status)
            self.send_header("Content-Length", str(len(payload)))
            if 300 <= status < 400:
                self.send_header("Location", "/moved")
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the client gave up first, as the timeout test makes it

    do_POST = do_GET = answer

    def log_message(self, *args):
        pass


httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile, keyfile)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
