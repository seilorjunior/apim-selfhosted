import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("integration", ROOT / "scripts" / "shared" / "integration_test.py")
integration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integration)
SUBSCRIPTION = "00000000-0000-0000-0000-000000000001"
RUN_ID = "a" * 32


class AzureProcess:
    """External CLI boundary double; no Azure subprocesses are started."""

    def __init__(self):
        self.exists = False
        self.revision = "ca-apim-gateway--initial"
        self.tags = {"shgwIntegrationRun": RUN_ID, "purpose": "disposable-integration"}
        self.calls = []
        self.fail_deploy = False
        self.fail_delete = False
        self.partial_create = False
        self.same_revision = False
        self.bad_rollback = False
        self.empty_key = False
        self.profile = None
        self.bodies = []

    def __call__(self, command, **kwargs):
        self.calls.append(command)
        if command[0] != "az":
            if any("rollback" in str(value).lower() for value in command):
                if not self.bad_rollback:
                    self.revision = "ca-apim-gateway--initial"
            elif "-RotateTokenOnly" in command or "--rotate-token-only" in command:
                if not self.same_revision:
                    self.revision = "ca-apim-gateway--rotated"
            else:
                option = "-ParametersFile" if os.name == "nt" else "--parameters-file"
                self.profile = json.loads(Path(command[command.index(option) + 1]).read_text())
                if self.fail_deploy:
                    raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)
        operation = command[1:3]
        result = {}
        if operation == ["account", "show"]:
            result = {"environmentName": "AzureCloud"}
        elif operation == ["group", "exists"]:
            result = self.exists
        elif operation == ["group", "create"]:
            self.exists = True
            if self.partial_create:
                return subprocess.CompletedProcess(command, 1, "", "partial create")
        elif operation == ["group", "show"]:
            result = {"tags": self.tags}
        elif operation == ["group", "delete"]:
            if self.fail_delete:
                return subprocess.CompletedProcess(command, 1, "", "delete denied")
            self.exists = False
        elif operation == ["containerapp", "show"]:
            app = command[command.index("-n") + 1]
            result = {"properties": {"configuration": {"ingress": {
                "fqdn": f"{app}.example", "traffic": [{"revisionName": self.revision, "weight": 100}],
            }}}}
        elif operation == ["deployment", "group"]:
            result = {"properties": {"outputs": {"apimName": {"value": "disposable-apim"}}}}
        elif command[1] == "rest":
            if "--body" in command:
                path = command[command.index("--body") + 1][1:]
                self.bodies.append(json.loads(Path(path).read_text()))
            if "/listSecrets?" in command[command.index("--url") + 1]:
                result = {"primaryKey": "" if self.empty_key else "private-integration-key"}
        else:
            raise AssertionError(f"Unexpected CLI command: {command}")
        return subprocess.CompletedProcess(command, 0, json.dumps(result), "")


class Response(io.BytesIO):
    def __init__(self, status, body, headers):
        super().__init__(body)
        self.code = status
        self.headers = headers


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        policy = self.root / "api" / "policies"
        policy.mkdir(parents=True)
        (policy / "sample.xml").write_text("<policies/>")
        self.process = AzureProcess()
        self.requests = []
        self.clock = [0]
        patches = [
            patch.object(integration, "ROOT", self.root),
            patch.object(integration.shutil, "which", side_effect=lambda name: name),
            patch.object(integration.subprocess, "run", side_effect=self.process),
            patch.object(integration, "build_opener", return_value=self),
            patch.object(integration.time, "monotonic", side_effect=lambda: self.clock[0]),
            patch.object(integration.time, "sleep", side_effect=self.sleep),
            patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}),
        ]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)

    def sleep(self, duration):
        self.clock[0] += duration

    def open(self, req, timeout):
        self.requests.append(req)
        headers = {"X-Served-By": "aca-gateway"}
        if req.full_url.endswith("/gateway-health/ready"):
            headers["X-Gateway-Ready"] = "configured"
            return Response(200, b"ready", headers)
        if req.full_url.endswith("/integration-auth/"):
            key = req.get_header("Ocp-apim-subscription-key")
            return Response(200 if key == "private-integration-key" else 401, b"backend", headers)
        if req.method == "POST" or req.full_url.endswith("/integration-route-does-not-exist"):
            return Response(404, b"not found", headers)
        return Response(200, b"backend", headers)

    def invoke(self, *extra):
        arguments = ["--subscription-id", SUBSCRIPTION, "--publisher-email", "test@example.com",
                     "--run-id", RUN_ID, "--allow-provisioning", *extra]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return integration.main(arguments)

    def report(self):
        return json.loads((self.root / "TestResults" / f"integration-{RUN_ID}.json").read_text())

    def test_full_rehearsal_checks_routes_rotation_rollback_and_cleanup(self):
        self.assertEqual(self.invoke(), 0)
        report = self.report()
        self.assertTrue(report["passed"])
        self.assertEqual([step["name"] for step in report["steps"]], [
            "create-disposable-group", "initial-deployment", "authenticated-fixture",
            "initial-route-checks", "rotate-token-and-promote", "post-rotation-route-checks",
            "rollback-to-initial-revision", "post-rollback-route-checks", "cleanup-disposable-group",
        ])
        self.assertTrue(all(step["passed"] for step in report["steps"]))
        self.assertEqual(len(self.requests), 21)
        self.assertFalse(self.process.exists)
        self.assertEqual(self.process.revision, "ca-apim-gateway--initial")
        self.assertNotIn("private-integration-key", json.dumps(report))
        self.assertEqual(self.process.profile["parameters"]["existingApimName"]["value"], "")
        self.assertEqual(self.process.profile["parameters"]["apimResourceGroup"]["value"],
                         f"rg-shgw-it-{RUN_ID}")
        properties = [body["properties"] for body in self.process.bodies]
        self.assertTrue(any(value.get("subscriptionRequired") is True for value in properties))
        self.assertTrue(any(value.get("scope") == "/apis/integration-auth" for value in properties))

    def test_refuses_existing_group_without_deploying_or_deleting(self):
        self.process.exists = True
        self.assertEqual(self.invoke(), 1)
        self.assertTrue(self.process.exists)
        self.assertFalse(any(call[1:3] == ["group", "delete"] for call in self.process.calls))
        self.assertIsNone(self.process.profile)

    def test_deployment_failure_still_deletes_owned_group_and_fails_report(self):
        self.process.fail_deploy = True
        self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)
        self.assertFalse(self.report()["passed"])
        self.assertEqual([step["passed"] for step in self.report()["steps"]], [True, False, True])

    def test_partial_group_creation_is_cleaned_up(self):
        self.process.partial_create = True
        self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)
        self.assertFalse(self.report()["steps"][0]["passed"])

    def test_cleanup_failure_never_reports_success(self):
        self.process.fail_delete = True
        self.assertEqual(self.invoke(), 1)
        self.assertTrue(self.process.exists)
        self.assertFalse(self.report()["passed"])
        self.assertFalse(self.report()["steps"][-1]["passed"])

    def test_cleanup_refuses_unowned_group(self):
        self.process.exists = True
        self.process.tags["shgwIntegrationRun"] = "b" * 32
        self.assertEqual(self.invoke("--cleanup-only"), 1)
        self.assertTrue(self.process.exists)
        self.assertFalse(any(call[1:3] == ["group", "delete"] for call in self.process.calls))

    def test_cleanup_refuses_missing_purpose_tag(self):
        self.process.exists = True
        del self.process.tags["purpose"]
        self.assertEqual(self.invoke("--cleanup-only"), 1)
        self.assertTrue(self.process.exists)

    def test_cleanup_retry_has_its_own_report(self):
        self.process.fail_deploy = True
        self.assertEqual(self.invoke(), 1)
        self.assertEqual(self.invoke("--cleanup-only"), 0)
        self.assertFalse(self.report()["passed"])
        cleanup = self.root / "TestResults" / f"integration-{RUN_ID}-cleanup.json"
        self.assertTrue(json.loads(cleanup.read_text())["passed"])

    def test_rotation_must_change_serving_revision(self):
        self.process.same_revision = True
        self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)

    def test_rollback_must_restore_original_revision(self):
        self.process.bad_rollback = True
        self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)

    def test_wrong_gateway_marker_fails_and_cleans_up(self):
        with patch.object(self, "open", return_value=Response(200, b"ready", {
            "X-Gateway-Ready": "configured", "X-Served-By": "different-gateway",
        })):
            self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)
        self.assertFalse(self.report()["steps"][3]["passed"])

    def test_unauthenticated_success_is_rejected(self):
        original = self.open

        def bypass(req, timeout):
            if req.full_url.endswith("/integration-auth/"):
                return Response(200, b"backend", {"X-Served-By": "aca-gateway"})
            return original(req, timeout)

        with patch.object(self, "open", side_effect=bypass):
            self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)
        self.assertFalse(self.report()["steps"][3]["passed"])

    def test_empty_successful_sample_is_rejected(self):
        original = self.open

        def empty(req, timeout):
            if req.full_url.endswith("/sample/"):
                return Response(200, b"", {"X-Served-By": "aca-gateway"})
            return original(req, timeout)

        with patch.object(self, "open", side_effect=empty):
            self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)

    def test_empty_subscription_key_fails_before_route_checks(self):
        self.process.empty_key = True
        self.assertEqual(self.invoke(), 1)
        self.assertFalse(self.process.exists)
        self.assertEqual(self.requests, [])

    def test_scenario_and_cleanup_failures_are_both_reported(self):
        self.process.fail_deploy = True
        self.process.fail_delete = True
        diagnostics = io.StringIO()
        suite = integration.IntegrationSuite(SUBSCRIPTION, "test@example.com", "eastus2", RUN_ID)
        with contextlib.redirect_stdout(diagnostics), self.assertRaisesRegex(
                RuntimeError, "Live scenario failed:.*Cleanup also failed"):
            suite.run()
        self.assertEqual([step["passed"] for step in suite.steps], [True, False, False])

    def test_requires_acknowledgement_before_any_external_command(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            integration.main(["--subscription-id", SUBSCRIPTION])
        self.assertEqual(self.process.calls, [])

    def test_cleanup_requires_explicit_run_identity(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            integration.main(["--subscription-id", SUBSCRIPTION, "--allow-provisioning", "--cleanup-only"])
        self.assertEqual(self.process.calls, [])

    def test_invalid_run_identity_cannot_target_arbitrary_group(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            self.invoke("--run-id", "../../shared")
        self.assertEqual(self.process.calls, [])


if __name__ == "__main__":
    unittest.main()
