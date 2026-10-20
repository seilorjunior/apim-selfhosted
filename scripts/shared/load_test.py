"""Bounded, paced HTTPS gateway checks using only the Python standard library."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from http.client import HTTPException
import json
import math
from pathlib import Path
import ssl
import time
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, HTTPSHandler, build_opener


TLS_CONTEXT = ssl.create_default_context()


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def request_sample(url, gateway_id):
    started = time.monotonic()
    try:
        with build_opener(NoRedirect, HTTPSHandler(context=TLS_CONTEXT)).open(url, timeout=5) as response:
            valid = (
                response.status == 200
                and response.headers.get("X-Served-By") == gateway_id
                and bool(response.read(1024))
            )
            failure = None if valid else "Invalid status, gateway header, or empty body"
    except (URLError, TimeoutError, OSError, HTTPException) as error:
        valid, failure = False, type(error).__name__
    return {"ok": valid, "latencyMs": (time.monotonic() - started) * 1000, "failure": failure}


def summarize(results, planned, dropped, elapsed, max_inflight, max_p95_ms, max_error_rate):
    failed = sum(not item["ok"] for item in results)
    latencies = sorted(item["latencyMs"] for item in results)
    p95 = latencies[math.ceil(0.95 * len(latencies)) - 1] if latencies else None
    p99 = latencies[math.ceil(0.99 * len(latencies)) - 1] if latencies else None
    error_rate = (failed + dropped) / planned if planned else 1.0
    passed = bool(results) and dropped == 0 and error_rate <= max_error_rate and p95 <= max_p95_ms
    return {
        "plannedRequests": planned,
        "startedRequests": len(results),
        "successfulRequests": len(results) - failed,
        "failedRequests": failed,
        "droppedRequests": dropped,
        "errorRate": error_rate,
        "p95Ms": round(p95, 2) if p95 is not None else None,
        "p99Ms": round(p99, 2) if p99 is not None else None,
        "maxLatencyMs": round(latencies[-1], 2) if latencies else None,
        "elapsedSeconds": round(elapsed, 2),
        "successfulRequestsPerSecond": round((len(results) - failed) / elapsed, 2) if elapsed else 0,
        "maxObservedConcurrency": max_inflight,
        "thresholds": {"maxErrorRate": max_error_rate, "maxP95Ms": max_p95_ms, "maxDroppedRequests": 0},
        "passed": passed,
        "failureExamples": [item["failure"] for item in results if item["failure"]][:5],
    }


def run_load(url, gateway_id, rate=10, duration=60, concurrency=10,
             max_p95_ms=2000, max_error_rate=0.01, requester=request_sample):
    planned = int(rate * duration)
    started = time.monotonic()
    inflight, results = [], []
    dropped = max_inflight = 0
    drop_reasons = {"scheduleLate": 0, "concurrencyLimit": 0, "durationElapsed": 0}
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        for index in range(planned):
            due = started + index / rate
            time.sleep(max(0, due - time.monotonic()))
            completed = [future for future in inflight if future.done()]
            results.extend(future.result() for future in completed)
            inflight = [future for future in inflight if future not in completed]
            # Discard expired slots instead of accumulating catch-up requests.
            now = time.monotonic()
            reason = None
            if now - started >= duration:
                reason = "durationElapsed"
            elif now - due >= 1 / rate:
                reason = "scheduleLate"
            elif len(inflight) >= concurrency:
                reason = "concurrencyLimit"
            if reason:
                dropped += 1
                drop_reasons[reason] += 1
                continue
            inflight.append(executor.submit(requester, url, gateway_id))
            max_inflight = max(max_inflight, len(inflight))
        results.extend(future.result() for future in inflight)
    report = summarize(results, planned, dropped, time.monotonic() - started,
                       max_inflight, max_p95_ms, max_error_rate)
    report.update({"url": url, "requestsPerSecond": rate, "durationSeconds": duration,
                   "maxConcurrency": concurrency, "droppedByReason": drop_reasons})
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--gateway-id", default="aca-gateway")
    parser.add_argument("--rate", type=int, choices=range(1, 11), default=10)
    parser.add_argument("--duration", type=int, choices=range(1, 61), default=60)
    parser.add_argument("--concurrency", type=int, choices=range(1, 11), default=10)
    parser.add_argument("--max-p95-ms", type=float, default=2000)
    parser.add_argument("--max-error-rate", type=float, default=0.01)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    target = urlparse(args.url)
    if target.scheme != "https" or not target.hostname or target.username or target.password or target.query or target.fragment or target.path not in ("", "/"):
        parser.error("URL must be an HTTPS gateway origin without a path, credentials, query, or fragment")
    if args.max_p95_ms <= 0 or not 0 <= args.max_error_rate <= 1:
        parser.error("Latency threshold must be positive and error rate must be between 0 and 1")
    url = args.url.rstrip("/") + "/sample/"
    report = run_load(url, args.gateway_id, args.rate, args.duration, args.concurrency,
                      args.max_p95_ms, args.max_error_rate)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
