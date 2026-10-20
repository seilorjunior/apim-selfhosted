"""Execute native Bash commands against isolated Azure, HTTP and Bicep doubles."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = ROOT / "scripts" / "bash"

MOCK_TOOL = r'''
import json, os, pathlib, stat, sys

name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
directory = pathlib.Path(os.environ["MOCK_DIR"])
state_path = directory / "state.json"
state = json.loads(state_path.read_text())

def save():
    state_path.write_text(json.dumps(state))

def option(flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default

def emit(value):
    print(json.dumps(value) if isinstance(value, (dict, list)) else value)

with (directory / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name] + args) + "\n")

if name == "az":
    command = " ".join(args)
    if args[:2] == ["account", "show"]:
        emit({"id": "test", "environmentName": "AzureCloud"})
    elif args[:2] == ["provider", "show"]:
        emit(state.get("provider", "Registered"))
    elif args[:2] == ["group", "exists"]:
        emit("true")
    elif args[:2] == ["resource", "list"]:
        emit("" if state.get("bootstrap") else "/existing")
    elif args[:2] == ["resource", "show"]:
        if "Microsoft.ApiManagement" in command:
            emit({"sku": {"name": state.get("sku", "Developer")}})
        else:
            traffic = [{"revisionName": state["traffic"], "weight": 100}]
            if state.get("split"):
                traffic = [{"revisionName": "app--stable", "weight": 50},
                           {"revisionName": "app--other", "weight": 50}]
            emit({"tags": {"shgwPreviousRevision": "app--previous"},
                  "properties": {"latestReadyRevisionName": state["traffic"],
                    "configuration": {"activeRevisionsMode": "Multiple",
                      "ingress": {"fqdn": "public.example", "traffic": traffic}}}})
    elif args[:3] == ["deployment", "group", "show"]:
        emit(state["outputs"])
    elif args[:3] == ["deployment", "group", "create"]:
        path = pathlib.Path(option("--parameters")[1:])
        parameters = json.loads(path.read_text())["parameters"]
        state.setdefault("parameterFiles", []).append(str(path))
        state.setdefault("privateModes", []).append(stat.S_IMODE(path.parent.stat().st_mode))
        if option("-n") == "shgw-infra":
            save()
            emit(state["outputs"])
        else:
            state["candidate"] = "app--" + parameters["revisionSuffix"]["value"]
            state["gatewayParameters"] = parameters
            save()
            if state.get("deployFailure"):
                sys.exit("Candidate ARM deployment failed")
            emit({"gatewayFqdn": {"value": "public.example"},
                  "revisionName": {"value": state["candidate"]}})
    elif args[:3] in (["deployment", "group", "validate"], ["deployment", "group", "what-if"]):
        pass
    elif args[:4] == ["containerapp", "ingress", "traffic", "set"]:
        target = option("--revision-weight").split("=")[0]
        if target == "app--stable" and state.get("restoreFailure"):
            sys.exit("Traffic restoration rejected")
        state["traffic"] = target
        state.setdefault("trafficChanges", []).append(target)
        save()
    elif args[0] == "rest" and "generateToken" in command:
        emit(state.get("token", "test-token"))
    elif args[0] == "rest" and "/revisions?" in command:
        emit({"value": [
            {"name": "app--stable", "properties": {"active": True}},
            {"name": "app--previous", "properties": {"active": False}},
            {"name": state.get("candidate", "app--unused"), "properties": {"active": True}},
            {"name": "app--older", "properties": {"active": True}}]})
    elif args[0] == "rest" and option("--method") == "get":
        emit({"healthState": "Healthy",
              "provisioningState": "Failed" if state.get("revisionFailure") else "Provisioned",
              "fqdn": "candidate.example"})
    elif args[0] == "rest" and option("--method") == "post":
        state.setdefault("actions", []).append(option("--url"))
        save()
    elif args[:2] == ["tag", "update"]:
        state["tag"] = option("--tags")
        save()
    else:
        sys.exit("Unexpected mocked Azure command: " + command)
elif name == "bicep":
    pathlib.Path(option("--outfile")).write_text("{}")
elif name == "curl":
    url = args[-1]
    bad = state.get("badReadiness") and url.endswith("/gateway-health/ready")
    bad = bad or (state.get("postPromotionFailure") and "public.example" in url
                  and state["traffic"] == state.get("candidate"))
    headers = "HTTP/1.1 200 OK\r\n"
    if not bad:
        headers += "X-Served-By: aca-gateway\r\nX-Gateway-Ready: configured\r\n"
    pathlib.Path(option("--dump-header")).write_bytes((headers + "\r\n").encode())
    pathlib.Path(option("--output")).write_bytes(
        b"" if bad else b"ready" if url.endswith("/gateway-health/ready") else b"backend")
    print("200", end="")
elif name == "sleep":
    # A failed retry must terminate immediately in tests rather than wait 30 seconds.
    sys.exit(9 if state.get("badReadiness") or state.get("postPromotionFailure") else 0)
elif name == "python3":
    if args and args[0].endswith("load_test.py"):
        output = pathlib.Path(option("--output"))
        report = json.dumps({"passed": not state.get("loadFailure")})
        if directory in output.parents:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(report)
        print(report)
        sys.exit(1 if state.get("loadFailure") else 0)
    os.execv(sys.executable, [sys.executable] + args)
else:
    sys.exit("Unexpected tool: " + name)
'''


@unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("jq"),
                     "Native Bash tests require a POSIX host, bash and jq")
class BashTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shgw-bash-tests-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.tmp = self.directory / "private"
        self.tmp.mkdir()
        for name in ("az", "bicep", "curl", "sleep", "python3"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + MOCK_TOOL)
            path.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        MOCK_DIR=str(self.directory), TMPDIR=str(self.tmp),
                        GITHUB_ACTIONS="false")
        self.state_path = self.directory / "state.json"
        self.state = {
            "traffic": "app--stable",
            "outputs": {
                "apimName": {"value": "test-apim"}, "gatewayName": {"value": "aca-gateway"},
                "gatewayId": {"value": "/gateway"}, "environmentId": {"value": "/environment"},
                "gatewaySettings": {"value": {
                    "appName": "app", "location": "eastus2", "imageTag": "2.9.2",
                    "minReplicas": 1, "maxReplicas": 3, "concurrentRequests": 50,
                    "cpu": "1.0", "memory": "2Gi", "tags": {"environment": "dev"}
                }}
            }
        }
        self.save()

    def save(self, **updates):
        self.state.update(updates)
        self.state_path.write_text(json.dumps(self.state))

    def run_script(self, name, *args, success=True):
        result = subprocess.run(["bash", str(BASH / name), *args], env=self.env,
                                cwd=self.directory, capture_output=True, text=True, timeout=30)
        self.state = json.loads(self.state_path.read_text())
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.tmp.iterdir()), [], "Private deployment files were not cleaned up")
        return result

    def deploy(self, *args, success=True):
        return self.run_script("deploy.sh", "--subscription-id", "test", "--resource-group",
                               "test", "--publisher-email", "test@example.com", *args, success=success)

    def calls(self):
        path = self.directory / "calls.jsonl"
        return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []

    def test_help_and_unknown_or_missing_options(self):
        self.run_script("deploy.sh", "--help")
        self.run_script("deploy.sh", "--unknown", success=False)
        self.run_script("deploy.sh", "--publisher-email", success=False)
        self.assertEqual(self.calls(), [])

    def test_validate_only_never_mutates_or_generates_tokens(self):
        self.deploy("--validate-only")
        calls = self.calls()
        self.assertTrue(any(row[1:4] == ["deployment", "group", "validate"] for row in calls))
        self.assertFalse(any("create" in row or "post" in row for row in calls))

    def test_full_deploy_pins_stable_checks_candidate_then_promotes(self):
        result = self.deploy()
        candidate = self.state["candidate"]
        self.assertEqual(self.state["trafficChanges"], [candidate])
        parameters = self.state["gatewayParameters"]
        self.assertEqual(parameters["previousRevision"]["value"], "app--stable")
        self.assertEqual(parameters["gatewayToken"]["value"], "GatewayKey test-token")
        self.assertEqual(self.state["privateModes"], [0o700, 0o700])
        calls = self.calls()
        promotion = next(i for i, row in enumerate(calls) if row[1:5] == ["containerapp", "ingress", "traffic", "set"])
        candidate_checks = [i for i, row in enumerate(calls) if row[0] == "curl" and "candidate.example" in row[-1]]
        self.assertEqual(len(candidate_checks), 2)
        self.assertLess(max(candidate_checks), promotion)
        self.assertNotIn("test-token", result.stdout + result.stderr)
        actions = self.state["actions"]
        self.assertTrue(any("/app--older/deactivate?" in url for url in actions))
        self.assertFalse(any("/app--stable/deactivate?" in url for url in actions))

    def test_rotation_does_not_redeploy_infrastructure_and_uses_new_suffix(self):
        self.deploy("--rotate-token-only")
        first = self.state["candidate"]
        self.deploy("--rotate-token-only")
        self.assertNotEqual(first, self.state["candidate"])
        self.assertFalse(any(row[1:4] == ["deployment", "group", "create"] and "shgw-infra" in row for row in self.calls()))

    def test_token_prefix_is_added_once_and_empty_token_rejected(self):
        self.save(token="GatewayKey test-token")
        self.deploy("--rotate-token-only")
        self.assertEqual(self.state["gatewayParameters"]["gatewayToken"]["value"], "GatewayKey test-token")
        self.save(token="")
        self.deploy("--rotate-token-only", success=False)

    def test_unregistered_provider_stops_before_deployment(self):
        self.save(provider="NotRegistered")
        self.deploy(success=False)
        self.assertFalse(any("create" in row for row in self.calls()))

    def test_invalid_resource_and_environment_inputs_fail(self):
        for args in (("--token-days", "31"), ("--environment", "bad"),
                     ("--validate-only", "--rotate-token-only")):
            with self.subTest(args=args):
                self.deploy(*args, success=False)
        self.assertEqual(self.calls(), [])

    def test_ambiguous_traffic_is_rejected(self):
        self.save(split=True)
        self.deploy("--rotate-token-only", success=False)
        self.assertNotIn("trafficChanges", self.state)

    def test_failed_revision_restores_and_deactivates_candidate(self):
        self.save(revisionFailure=True)
        self.deploy("--rotate-token-only", success=False)
        self.assertEqual(self.state["trafficChanges"], ["app--stable"])
        self.assertTrue(any(f'/{self.state["candidate"]}/deactivate?' in url for url in self.state["actions"]))

    def test_partial_arm_failure_still_cleans_up_exact_candidate(self):
        self.save(deployFailure=True)
        self.deploy("--rotate-token-only", success=False)
        self.assertEqual(self.state["trafficChanges"], ["app--stable"])
        self.assertTrue(any(f'/{self.state["candidate"]}/deactivate?' in url for url in self.state["actions"]))

    def test_empty_200_readiness_never_promotes(self):
        self.save(badReadiness=True)
        self.deploy("--rotate-token-only", success=False)
        self.assertEqual(self.state["trafficChanges"], ["app--stable"])

    def test_load_gate_failure_prevents_promotion(self):
        self.save(loadFailure=True)
        self.deploy("--rotate-token-only", "--run-load-test", success=False)
        self.assertEqual(self.state["trafficChanges"], ["app--stable"])

    def test_successful_load_gate_runs_before_promotion(self):
        self.deploy("--rotate-token-only", "--run-load-test")
        self.assertEqual(self.state["traffic"], self.state["candidate"])
        calls = self.calls()
        load_index = next(i for i, row in enumerate(calls)
                          if row[0] == "python3" and row[1].endswith("load_test.py"))
        promotion_index = next(i for i, row in enumerate(calls)
                               if row[1:5] == ["containerapp", "ingress", "traffic", "set"])
        self.assertLess(load_index, promotion_index)

    def test_bootstrap_success_has_no_previous_revision(self):
        self.save(bootstrap=True)
        self.deploy("--rotate-token-only")
        self.assertEqual(self.state["gatewayParameters"]["previousRevision"]["value"], "")
        self.assertEqual(self.state["traffic"], self.state["candidate"])

    def test_existing_apim_checks_actual_sku(self):
        self.save(sku="Standard")
        result = self.deploy("--existing-apim-name", "existing", success=False)
        self.assertIn("classic Developer or Premium", result.stderr)
        self.assertFalse(any("create" in row for row in self.calls()))

    def test_post_promotion_failure_restores_and_verifies_public_api(self):
        self.save(postPromotionFailure=True)
        self.deploy("--rotate-token-only", success=False)
        self.assertEqual(self.state["trafficChanges"], [self.state["candidate"], "app--stable"])
        self.assertEqual(self.state["traffic"], "app--stable")

    def test_restoration_failure_is_reported_and_does_not_deactivate_candidate(self):
        self.save(revisionFailure=True, restoreFailure=True)
        result = self.deploy("--rotate-token-only", success=False)
        self.assertIn("Restoration/cleanup also failed", result.stderr)
        self.assertNotIn("actions", self.state)

    def test_bootstrap_reports_no_rollback_target(self):
        self.save(bootstrap=True, revisionFailure=True)
        result = self.deploy("--rotate-token-only", success=False)
        self.assertIn("no previous revision", result.stderr)
        self.assertNotIn("trafficChanges", self.state)

    def rollback(self, *args, success=True):
        return self.run_script("rollback-gateway.sh", "--subscription-id", "test",
                               "--resource-group", "test", "--app-name", "app", *args, success=success)

    def test_manual_rollback_what_if_never_mutates(self):
        self.rollback("--what-if")
        self.assertNotIn("trafficChanges", self.state)
        self.assertNotIn("actions", self.state)

    def test_manual_rollback_rejects_foreign_missing_and_current_revisions(self):
        for name in ("other--previous", "app--missing", "app--stable"):
            with self.subTest(name=name):
                self.rollback("--revision-name", name, "--yes", success=False)
        self.assertNotIn("trafficChanges", self.state)

    def test_manual_rollback_requires_confirmation_and_activates_target(self):
        self.rollback(success=False)
        self.rollback("--yes")
        self.assertEqual(self.state["traffic"], "app--previous")
        self.assertEqual(self.state["tag"], "shgwPreviousRevision=app--stable")
        self.assertTrue(any("/app--previous/activate?" in url for url in self.state["actions"]))

    def test_failed_manual_rollback_restores_current(self):
        self.save(revisionFailure=True)
        self.rollback("--yes", success=False)
        self.assertEqual(self.state["traffic"], "app--stable")

    def test_restart_preview_and_explicit_confirmation(self):
        args = ("--subscription-id", "test", "--resource-group", "test", "--app-name",
                "app", "--gateway-url", "https://public.example")
        self.run_script("test-restart.sh", *args, "--what-if")
        self.assertNotIn("actions", self.state)
        self.run_script("test-restart.sh", *args, success=False)
        self.run_script("test-restart.sh", *args, "--yes")
        self.assertTrue(any("/app--stable/restart?" in url for url in self.state["actions"]))

    def test_load_caps_origin_validation_and_exit_status(self):
        output = str(self.directory / "report.json")
        self.run_script("test-load.sh", "--gateway-url", "http://public.example", success=False)
        self.run_script("test-load.sh", "--gateway-url", "https://public.example/sample/", success=False)
        self.run_script("test-load.sh", "--gateway-url", "https://public.example", "--requests-per-second", "11", success=False)
        self.run_script("test-load.sh", "--gateway-url", "https://public.example", "--output-path", output)
        self.assertTrue(json.loads(Path(output).read_text())["passed"])
        self.save(loadFailure=True)
        self.run_script("test-load.sh", "--gateway-url", "https://public.example", "--output-path", output, success=False)


if __name__ == "__main__":
    unittest.main()
