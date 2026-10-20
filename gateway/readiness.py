"""Translate a configuration-dependent gateway response into an HTTP readiness probe."""

import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import URLError
from urllib.request import urlopen


def gateway_is_ready():
    try:
        with urlopen("http://127.0.0.1:8080/gateway-health/ready", timeout=2) as response:
            return (
                response.status == 200
                and response.headers.get("X-Gateway-Ready") == "configured"
                and response.headers.get("X-Served-By") == os.environ["EXPECTED_GATEWAY_ID"]
                and response.read(64) == b"ready"
            )
    except (URLError, TimeoutError, OSError) as error:
        logging.warning("Gateway readiness request failed: %s", type(error).__name__)
        return False


class ReadinessHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/ready":
            self.send_error(404)
            return
        ready = gateway_is_ready()
        body = b"ready" if ready else b"configuration unavailable"
        self.send_response(200 if ready else 503)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        if len(args) < 2 or str(args[1]) != "200":
            logging.warning(format, *args)


if __name__ == "__main__":
    if not os.environ.get("EXPECTED_GATEWAY_ID"):
        raise RuntimeError("EXPECTED_GATEWAY_ID is required")
    logging.basicConfig(level=logging.WARNING)
    ThreadingHTTPServer(("0.0.0.0", 18081), ReadinessHandler).serve_forever()
