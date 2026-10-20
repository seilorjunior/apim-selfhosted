"""Opt-in, disposable Azure integration rehearsal. Never targets an existing group."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import build_opener, HTTPSHandler, HTTPRedirectHandler, Request
import uuid


ROOT = Path(__file__).resolve().parents[2]
ARM = "https://management.azure.com"
VERSION = "2024-05-01"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(url, key=None, method="GET"):
    headers = {"Ocp-Apim-Subscription-Key": key} if key else {}
    opener = build_opener(HTTPSHandler(context=ssl.create_default_context()), NoRedirect())
    try:
        response = opener.open(Request(url, headers=headers, method=method), timeout=15)
    except HTTPError as error:
        response = error
    with response:
        return response.code, response.headers, response.read()


class IntegrationSuite:
    def __init__(self, subscription, publisher_email, location, run_id):
        self.subscription = str(uuid.UUID(subscription))
        if not re.fullmatch(r"[0-9a-f]{32}", run_id):
            raise ValueError("Run ID must contain exactly 32 lowercase hexadecimal characters.")
        if not re.fullmatch(r"[a-z0-9]+", location):
            raise ValueError("Location must be an Azure region name.")
        self.run_id = run_id
        self.group = f"rg-shgw-it-{run_id}"
        self.location = location
        self.publisher_email = publisher_email
        self.created = False
        self.steps = []
        self.gateway_url = None
        self.key = None

    def az(self, *arguments):
        executable = shutil.which("az")
        if not executable:
            raise RuntimeError("Azure CLI is required.")
        result = subprocess.run(
            [executable, *arguments, "--subscription", self.subscription,
             "--only-show-errors", "-o", "json"],
            capture_output=True, text=True, timeout=7200, check=False,
        )
        if result.returncode:
            # REST responses can contain keys; do not copy command output into reports.
            raise RuntimeError(f"Azure CLI {arguments[0]} {arguments[1]} failed (exit {result.returncode}). "
                               "Inspect the resource group's deployment operations in Azure.")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def rest(self, method, path, body=None):
        arguments = ["rest", "--method", method, "--url", f"{ARM}{path}?api-version={VERSION}"]
        if body is None:
            return self.az(*arguments)
        with tempfile.TemporaryDirectory(prefix="shgw-it-") as directory:
            payload = Path(directory) / "request.json"
            payload.write_text(json.dumps(body), encoding="utf-8")
            payload.chmod(0o600)
            return self.az(*arguments, "--body", f"@{payload}")

    def command(self, name, *arguments):
        if os.name == "nt":
            executable = shutil.which("pwsh")
            scripts = {"deploy": "deploy.ps1", "rollback": "Rollback-Gateway.ps1"}
            command = [executable, "-NoProfile", "-File",
                       str(ROOT / "scripts" / "psw" / scripts[name])]
            command.extend(arguments)
        else:
            executable = shutil.which("bash")
            scripts = {"deploy": "deploy.sh", "rollback": "rollback-gateway.sh"}
            command = [executable, str(ROOT / "scripts" / "bash" / scripts[name])]
            command.extend(arguments)
        if not executable:
            raise RuntimeError("PowerShell 7 is required on Windows; Bash is required on POSIX hosts.")
        subprocess.run(command, cwd=ROOT, check=True, timeout=7200)

    def deploy(self, rotate=False):
        if os.name == "nt":
            arguments = ["-SubscriptionId", self.subscription, "-ResourceGroup", self.group,
                         "-Location", self.location, "-Environment", "dev", "-TimeoutSeconds", "1200"]
            arguments += ["-RotateTokenOnly"] if rotate else ["-PublisherEmail", self.publisher_email]
        else:
            arguments = ["--subscription-id", self.subscription, "--resource-group", self.group,
                         "--location", self.location, "--environment", "dev", "--timeout-seconds", "1200"]
            arguments += ["--rotate-token-only"] if rotate else ["--publisher-email", self.publisher_email]
        if rotate:
            self.command("deploy", *arguments)
        else:
            # Never inherit an existing-APIM or subnet override from a user's dev profile.
            parameters = {
                "environmentName": {"value": "dev"}, "apimSku": {"value": "Developer"},
                "existingApimName": {"value": ""}, "apimResourceGroup": {"value": self.group},
                "gatewayName": {"value": "aca-gateway"}, "gatewayAppName": {"value": "ca-apim-gateway"},
                "backendAppName": {"value": "ca-backend"},
            }
            with tempfile.TemporaryDirectory(prefix="shgw-it-") as directory:
                path = Path(directory) / "integration.parameters.json"
                path.write_text(json.dumps({"parameters": parameters}), encoding="utf-8")
                option = "-ParametersFile" if os.name == "nt" else "--parameters-file"
                self.command("deploy", *arguments, option, str(path))

    def state(self):
        return self.az("containerapp", "show", "-g", self.group, "-n", "ca-apim-gateway")

    @staticmethod
    def serving(state):
        traffic = state["properties"]["configuration"]["ingress"]["traffic"]
        serving = [entry for entry in traffic if entry["weight"] > 0]
        if len(serving) != 1 or serving[0]["weight"] != 100 or not serving[0].get("revisionName"):
            raise RuntimeError("Expected one explicit gateway revision receiving 100% traffic.")
        return serving[0]["revisionName"]

    def verify(self, path, status, key=None, method="GET", marker=False):
        deadline = time.monotonic() + 300
        last = "No response"
        while True:
            try:
                actual, headers, body = request(self.gateway_url + path, key, method)
                valid = actual == status
                if marker:
                    valid = valid and headers.get("X-Served-By") == "aca-gateway" and bool(body.strip())
                if path == "/gateway-health/ready":
                    valid = valid and headers.get("X-Gateway-Ready") == "configured" and body == b"ready"
                if valid:
                    return
                last = f"HTTP {actual}; expected {status} and required markers"
            except (URLError, TimeoutError) as error:
                last = type(error).__name__
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Live check {method} {path} failed: {last}.")
            time.sleep(5)

    def verify_routes(self):
        self.verify("/gateway-health/ready", 200, marker=True)
        self.verify("/sample/", 200, marker=True)
        self.verify("/integration-auth/", 200, key=self.key, marker=True)
        self.verify("/integration-auth/", 401)
        self.verify("/integration-auth/", 401, key="deliberately-invalid-integration-key")
        self.verify("/integration-route-does-not-exist", 404)
        self.verify("/sample/", 404, method="POST")

    def fixture(self, apim):
        service = (f"/subscriptions/{self.subscription}/resourceGroups/{self.group}"
                   f"/providers/Microsoft.ApiManagement/service/{apim}")
        api = service + "/apis/integration-auth"
        backend = self.az("containerapp", "show", "-g", self.group, "-n", "ca-backend")
        backend_url = "https://" + backend["properties"]["configuration"]["ingress"]["fqdn"]
        self.rest("put", api, {"properties": {
            "displayName": "Disposable authenticated integration fixture",
            "path": "integration-auth", "protocols": ["https"],
            "serviceUrl": backend_url, "subscriptionRequired": True,
        }})
        self.rest("put", api + "/operations/get", {"properties": {
            "displayName": "Get backend", "method": "GET", "urlTemplate": "/",
            "responses": [{"statusCode": 200}],
        }})
        self.rest("put", api + "/policies/policy", {"properties": {
            "format": "rawxml", "value": (ROOT / "api" / "policies" / "sample.xml").read_text(),
        }})
        self.rest("put", service + "/gateways/aca-gateway/apis/integration-auth", {"properties": {}})
        subscription = service + "/subscriptions/integration-client"
        self.rest("put", subscription, {"properties": {
            "displayName": "Disposable integration client",
            "scope": "/apis/integration-auth", "state": "active", "allowTracing": False,
        }})
        self.key = self.rest("post", subscription + "/listSecrets")["primaryKey"]
        if not isinstance(self.key, str) or not self.key.strip():
            raise RuntimeError("APIM returned an empty integration subscription key.")
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::add-mask::{self.key}", flush=True)

    def cleanup(self):
        if not self.az("group", "exists", "-n", self.group):
            return
        group = self.az("group", "show", "-n", self.group)
        tags = group.get("tags") or {}
        if tags.get("shgwIntegrationRun") != self.run_id or tags.get("purpose") != "disposable-integration":
            raise RuntimeError(f"Cleanup refused: ownership tags do not match on {self.group}.")
        self.az("group", "delete", "-n", self.group, "--yes")
        if self.az("group", "exists", "-n", self.group):
            raise RuntimeError(f"Cleanup incomplete: {self.group} still exists.")

    def step(self, name, action):
        start = time.monotonic()
        print(f"Integration: {name}", flush=True)
        result = {"name": name, "passed": False}
        self.steps.append(result)
        try:
            value = action()
            result["passed"] = True
            return value
        finally:
            result["durationSeconds"] = round(time.monotonic() - start, 2)

    def run(self):
        if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", self.publisher_email):
            raise ValueError("A valid publisher email is required.")
        print(f"Integration run ID: {self.run_id}; disposable group: {self.group}", flush=True)
        if self.az("account", "show")["environmentName"] != "AzureCloud":
            raise RuntimeError("Only Azure public cloud is supported.")
        if self.az("group", "exists", "-n", self.group):
            raise RuntimeError("Refusing to use an existing resource group, even with matching tags.")
        try:
            self.created = True
            self.step("create-disposable-group", lambda: self.az(
                "group", "create", "-n", self.group, "-l", self.location, "--tags",
                f"shgwIntegrationRun={self.run_id}", "purpose=disposable-integration"))
            self.step("initial-deployment", self.deploy)
            state = self.state()
            initial = self.serving(state)
            self.gateway_url = "https://" + state["properties"]["configuration"]["ingress"]["fqdn"]
            outputs = self.az("deployment", "group", "show", "-g", self.group, "-n", "shgw-infra")
            apim = outputs["properties"]["outputs"]["apimName"]["value"]
            self.step("authenticated-fixture", lambda: self.fixture(apim))
            self.step("initial-route-checks", self.verify_routes)
            self.step("rotate-token-and-promote", lambda: self.deploy(rotate=True))
            if self.serving(self.state()) == initial:
                raise RuntimeError("Rotation did not promote a new revision.")
            self.step("post-rotation-route-checks", self.verify_routes)
            arguments = (["-SubscriptionId", self.subscription, "-ResourceGroup", self.group,
                          "-RevisionName", initial, "-Confirm:$false"] if os.name == "nt" else
                         ["--subscription-id", self.subscription, "--resource-group", self.group,
                          "--revision-name", initial, "--yes"])
            self.step("rollback-to-initial-revision", lambda: self.command("rollback", *arguments))
            if self.serving(self.state()) != initial:
                raise RuntimeError("Rollback did not restore the initial revision to 100%.")
            self.step("post-rollback-route-checks", self.verify_routes)
        finally:
            if self.created:
                failure = sys.exc_info()[1]
                try:
                    self.step("cleanup-disposable-group", self.cleanup)
                except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                    if failure is not None:
                        raise RuntimeError(f"Live scenario failed: {failure}. Cleanup also failed: {error}") from error
                    raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subscription-id", required=True)
    parser.add_argument("--publisher-email", default="")
    parser.add_argument("--location", default="eastus2")
    parser.add_argument("--run-id", default=uuid.uuid4().hex)
    parser.add_argument("--allow-provisioning", action="store_true",
                        help="Acknowledge Azure charges and deletion of this run's disposable group.")
    parser.add_argument("--cleanup-only", action="store_true")
    arguments = sys.argv[1:] if argv is None else argv
    args = parser.parse_args(arguments)
    if not args.allow_provisioning:
        parser.error("--allow-provisioning is required; live tests incur Azure charges.")
    if args.cleanup_only and not any(value == "--run-id" or value.startswith("--run-id=")
                                     for value in arguments):
        parser.error("--cleanup-only requires an explicit --run-id.")
    try:
        suite = IntegrationSuite(args.subscription_id, args.publisher_email, args.location, args.run_id)
    except ValueError as error:
        parser.error(str(error))
    report = {"runId": suite.run_id, "resourceGroup": suite.group, "passed": False,
              "startedAt": datetime.now(timezone.utc).isoformat(), "steps": suite.steps}
    try:
        if args.cleanup_only:
            suite.step("cleanup-disposable-group", suite.cleanup)
        else:
            suite.run()
        report["passed"] = True
        return 0
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"Integration failed: {error}", file=sys.stderr)
        return 1
    finally:
        directory = ROOT / "TestResults"
        directory.mkdir(exist_ok=True)
        suffix = "-cleanup" if args.cleanup_only else ""
        path = directory / f"integration-{suite.run_id}{suffix}.json"
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"Integration report: {path}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
