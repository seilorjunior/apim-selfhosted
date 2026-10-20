import importlib.util
from concurrent.futures import Future
import io
import os
from pathlib import Path
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import URLError
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


readiness = load_module("readiness", "gateway/readiness.py")
load = load_module("load_test", "scripts/load_test.py")


class GatewayResponse(io.BytesIO):
    def __init__(self, body=b"ready", headers=None, status=200):
        super().__init__(body)
        self.status = status
        self.headers = headers if headers is not None else {
            "X-Gateway-Ready": "configured", "X-Served-By": "gateway"
        }


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {"EXPECTED_GATEWAY_ID": "gateway"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_accepts_loaded_configuration(self):
        with patch.object(readiness, "urlopen", return_value=GatewayResponse()):
            self.assertTrue(readiness.gateway_is_ready())

    def test_empty_200_is_not_ready(self):
        with patch.object(readiness, "urlopen", return_value=GatewayResponse(b"", {})):
            self.assertFalse(readiness.gateway_is_ready())

    def test_wrong_gateway_is_not_ready(self):
        response = GatewayResponse(headers={"X-Gateway-Ready": "configured", "X-Served-By": "other"})
        with patch.object(readiness, "urlopen", return_value=response):
            self.assertFalse(readiness.gateway_is_ready())

    def test_wrong_marker_body_or_status_is_not_ready(self):
        for response in (
            GatewayResponse(b"not ready"), GatewayResponse(status=503),
            GatewayResponse(headers={"X-Gateway-Ready": "wrong", "X-Served-By": "gateway"})
        ):
            with self.subTest(response=response), patch.object(readiness, "urlopen", return_value=response):
                self.assertFalse(readiness.gateway_is_ready())

    def test_network_failure_is_not_ready(self):
        with patch.object(readiness, "urlopen", side_effect=URLError("refused")):
            self.assertFalse(readiness.gateway_is_ready())

    def test_http_probe_observes_503_not_false_positive_200(self):
        server = readiness.ThreadingHTTPServer(("127.0.0.1", 0), readiness.ReadinessHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.object(readiness, "gateway_is_ready", return_value=False):
                with self.assertRaises(URLError) as failure:
                    urlopen(f"http://127.0.0.1:{server.server_port}/ready", timeout=2)
                self.assertEqual(failure.exception.code, 503)
            with patch.object(readiness, "gateway_is_ready", return_value=True):
                with urlopen(f"http://127.0.0.1:{server.server_port}/ready", timeout=2) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), b"ready")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


class LoadTests(unittest.TestCase):
    def test_absolute_schedule_does_not_accumulate_sleep_overhead(self):
        clock = [0.0]

        def sleep(seconds):
            clock[0] += seconds + 0.002

        class ImmediateExecutor:
            def __init__(self, max_workers):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def submit(self, requester, url, gateway_id):
                future = Future()
                future.set_result(requester(url, gateway_id))
                return future

        with patch.object(load.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(load.time, "sleep", side_effect=sleep), \
                patch.object(load, "ThreadPoolExecutor", ImmediateExecutor):
            report = load.run_load(
                "https://example/sample/", "gateway", rate=10, duration=60, concurrency=1,
                requester=lambda *args: {"ok": True, "latencyMs": 1, "failure": None}
            )
        self.assertEqual(report["startedRequests"], 600)
        self.assertEqual(report["droppedRequests"], 0)
        self.assertEqual(sum(report["droppedByReason"].values()), 0)
        self.assertLess(report["elapsedSeconds"], 60)
        self.assertTrue(report["passed"])

    def test_exact_percentiles_and_inclusive_thresholds(self):
        rows = [{"ok": True, "latencyMs": n, "failure": None} for n in range(1, 101)]
        report = load.summarize(rows, 100, 0, 10, 10, 95, 0)
        self.assertEqual(report["p95Ms"], 95)
        self.assertEqual(report["p99Ms"], 99)
        self.assertTrue(report["passed"])
        self.assertFalse(load.summarize(rows, 100, 0, 10, 10, 94.9, 0)["passed"])

    def test_error_rate_and_drops_fail_thresholds(self):
        rows = [{"ok": False, "latencyMs": 10, "failure": "bad header"}]
        self.assertFalse(load.summarize(rows, 1, 0, 1, 1, 100, 0.01)["passed"])
        rows[0]["ok"] = True
        self.assertFalse(load.summarize(rows, 2, 1, 1, 1, 100, 1)["passed"])
        self.assertFalse(load.summarize([], 0, 0, 1, 0, 100, 0)["passed"])

    def test_scheduler_caps_concurrency_and_counts_drops(self):
        lock = threading.Lock()
        active = maximum = 0

        def request(url, gateway):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(maximum, active)
            time.sleep(0.16)
            with lock:
                active -= 1
            return {"ok": True, "latencyMs": 160, "failure": None}

        report = load.run_load("https://example/sample/", "gateway", rate=10,
                               duration=0.5, concurrency=1, requester=request)
        self.assertEqual(maximum, 1)
        self.assertLessEqual(report["maxObservedConcurrency"], 1)
        self.assertGreater(report["droppedRequests"], 0)
        self.assertEqual(report["droppedByReason"]["concurrencyLimit"], report["droppedRequests"])
        self.assertEqual(report["startedRequests"] + report["droppedRequests"], 5)
        self.assertFalse(report["passed"])

    def test_scheduler_drops_expired_slots_instead_of_catching_up(self):
        clock = [0.0]
        launches = []

        def sleep(seconds):
            clock[0] = max(0.24, clock[0] + seconds)

        def request(url, gateway):
            launches.append(clock[0])
            return {"ok": True, "latencyMs": 1, "failure": None}

        def submit(requester, url, gateway):
            future = Future()
            future.set_result(requester(url, gateway))
            return future

        with patch.object(load.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(load.time, "sleep", side_effect=sleep), \
                patch.object(load, "ThreadPoolExecutor") as executor:
            executor.return_value.__enter__.return_value.submit.side_effect = submit
            report = load.run_load("https://example/sample/", "gateway", rate=10,
                                   duration=0.5, concurrency=2, requester=request)
        self.assertEqual(report["startedRequests"], 3)
        self.assertEqual(report["droppedByReason"]["scheduleLate"], 2)
        self.assertEqual(report["droppedRequests"], 2)
        for actual, expected in zip(launches, (0.24, 0.3, 0.4)):
            self.assertAlmostEqual(actual, expected)
        self.assertFalse(report["passed"])

    def test_request_rejects_empty_body(self):
        class Opener:
            def open(self, url, timeout):
                return GatewayResponse(b"", {"X-Served-By": "gateway"})
        with patch.object(load, "build_opener", return_value=Opener()):
            self.assertFalse(load.request_sample("https://example/sample/", "gateway")["ok"])

    def test_requests_reuse_verified_tls_context(self):
        class Opener:
            def open(self, url, timeout):
                return GatewayResponse(b"html", {"X-Served-By": "gateway"})
        with patch.object(load, "build_opener", return_value=Opener()), \
                patch.object(load, "HTTPSHandler", wraps=load.HTTPSHandler) as handler:
            for _ in range(2):
                self.assertTrue(load.request_sample("https://example/sample/", "gateway")["ok"])
        self.assertEqual(handler.call_count, 2)
        self.assertTrue(all(call.kwargs["context"] is load.TLS_CONTEXT for call in handler.call_args_list))
        self.assertTrue(load.TLS_CONTEXT.check_hostname)
        self.assertEqual(load.TLS_CONTEXT.verify_mode, load.ssl.CERT_REQUIRED)
