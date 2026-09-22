import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
AZURE_KEY = "TEST_AZURE_CREDENTIAL_NEVER_PRINT_12345"


class Workflows(unittest.TestCase):
    def setUp(self):
        (ROOT / ".local").mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix="test-", dir=ROOT / ".local")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("scripts", "deploy"):
            shutil.copytree(ROOT / name, self.root / name)
        for name in ("Makefile", ".gitignore", "ports.env", "versions.env"):
            shutil.copy2(ROOT / name, self.root / name)
        self.state = self.root / ".local"
        self.state.mkdir(mode=0o700)
        self.mock = self.root / "mock-state.json"
        self.mock.write_text(json.dumps({"cluster": False}))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        script = self.bin / "fake_tool.py"
        shutil.copy2(ROOT / "tests/fake_tool.py", script)
        script.chmod(0o755)
        for name in ("docker", "kind", "kubectl", "helm", "curl", "lsof", "az", "sleep"):
            (self.bin / name).symlink_to(script)
        self.env = {**os.environ, "PATH": str(self.bin) + ":" + os.environ["PATH"],
                    "FIXTURE_ROOT": str(self.root), "NO_COLOR": "1"}
        for key in ("PROMPT", "PROMPT_FILE", "FORMAT", "REGION", "MODEL", "MODEL_VERSION", "SKU", "CAPACITY", "CONFIRM"):
            self.env.pop(key, None)
        subprocess.run(["git", "-c", "user.name=macromania",
                        "-c", "user.email=2471683+macromania@users.noreply.github.com",
                        "init", "-q", str(self.root)], check=True)

    def run_make(self, *args, success=True, env=None):
        result = subprocess.run(["make", *args], cwd=self.root, env={**self.env, **(env or {})},
                                text=True, capture_output=True, timeout=60)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if (self.root / "calls.jsonl").exists():
            for call in self.calls():
                if call["tool"] == "kubectl" and "port-forward" in call["args"]:
                    with self.assertRaises(ProcessLookupError, msg="Leaked port-forward process"):
                        os.kill(call["pid"], 0)
        return result

    def up(self):
        self.run_make("up")

    def foundry_up(self):
        return self.run_make("foundry-up", "REGION=eastus2", "MODEL=gpt-5-nano",
                             "MODEL_VERSION=2025-08-07", "SKU=GlobalStandard", "CAPACITY=1", "CONFIRM=1")

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_help_sections_and_plain_capture(self):
        result = self.run_make("help")
        for heading in ("LOCAL ENVIRONMENT", "FOUNDRY MODEL", "PROMPTING", "DIAGNOSTICS", "CLEANUP"):
            self.assertIn(heading, result.stdout)
        self.assertNotIn("\x1b", result.stdout + result.stderr)
        self.assertFalse((self.state / "cluster.json").exists())

    def test_local_up_repeatable_and_explicit_contexts(self):
        self.up()
        first = json.loads((self.state / "cluster.json").read_text())
        self.up()
        self.assertEqual(first, json.loads((self.state / "cluster.json").read_text()))
        for call in self.calls():
            if call["tool"] == "kubectl":
                self.assertIn("--kubeconfig", call["args"])
                self.assertIn("kind-multi-tenant-ai-gateway", call["args"])
            if call["tool"] == "helm":
                self.assertIn("--kube-context", call["args"])
            self.assertNotEqual(call["tool"], "az")
        self.assertFalse(list(self.state.glob("tmp.*")))

    def test_parallel_make_still_orders_work(self):
        self.run_make("-j4", "up")
        calls = self.calls()
        create = next(i for i, call in enumerate(calls) if call["tool"] == "kind" and call["args"][:2] == ["create", "cluster"])
        install = next(i for i, call in enumerate(calls) if call["tool"] == "helm")
        self.assertLess(create, install)

    def test_docker_unavailable_stops_creation(self):
        self.run_make("up", success=False, env={"MOCK_DOCKER_DOWN": "1"})
        self.assertFalse(any(call["tool"] == "kind" and call["args"][:1] == ["create"] for call in self.calls()))

    def test_unowned_cluster_is_not_adopted(self):
        self.mock.write_text('{"cluster":true}')
        self.run_make("up", success=False)
        self.assertFalse((self.state / "cluster.json").exists())

    def test_foreign_node_blocks_status_and_deletion(self):
        self.up()
        for args in (("status",), ("down", "CONFIRM=1")):
            self.run_make(*args, success=False, env={"MOCK_FOREIGN_NODE": "1"})
        self.assertTrue(json.loads(self.mock.read_text())["cluster"])

    def test_missing_kubeconfig_does_not_fall_back(self):
        self.up()
        (self.state / "kubeconfig").unlink()
        self.run_make("status", success=False)
        self.run_make("cluster-up")
        self.assertTrue((self.state / "kubeconfig").exists())

    def test_wrong_kubeconfig_blocks_access(self):
        self.up()
        result = self.run_make("logs", success=False, env={"MOCK_WRONG_CONTEXT": "1"})
        self.assertIn("Never falling back", result.stderr)

    def test_chart_failure_is_not_success(self):
        self.run_make("up", success=False, env={"MOCK_HELM_FAIL": "1"})

    def test_occupied_port_is_not_reused(self):
        self.up()
        self.run_make("check", success=False, env={"MOCK_BUSY": "1"})

    def test_cleanup_requires_confirmation_and_is_repeatable(self):
        self.up()
        self.run_make("down", success=False)
        self.run_make("down", "CONFIRM=1")
        self.run_make("down", "CONFIRM=1")
        self.assertFalse(json.loads(self.mock.read_text())["cluster"])

    def test_registration_requires_confirmation(self):
        self.run_make("foundry-register", success=False, env={"MOCK_UNREGISTERED": "1"})
        self.assertFalse(any(call["args"][:2] == ["provider", "register"] for call in self.calls()))
        self.run_make("foundry-register", "CONFIRM=1", env={"MOCK_UNREGISTERED": "1"})
        self.assertTrue(json.loads(self.mock.read_text())["registered"])

    def test_region_selection_is_required_noninteractively(self):
        result = self.run_make("foundry-models", success=False)
        self.assertIn("Choose a region", result.stderr)
        self.run_make("foundry-regions")
        self.assertFalse((self.state / "foundry.json").exists())

    def test_quota_and_capacity_both_gate_selection(self):
        self.run_make("foundry-models", "REGION=eastus2", success=False, env={"MOCK_NO_QUOTA": "1"})
        self.run_make("foundry-models", "REGION=eastus2", success=False, env={"MOCK_NO_CAPACITY": "1"})
        self.assertFalse((self.state / "foundry.json").exists())

    def test_cloud_setup_secret_handling_and_scoping(self):
        self.up()
        result = self.foundry_up()
        contents = (self.root / ".env").read_text()
        self.assertIn(AZURE_KEY, contents)
        self.assertEqual((self.root / ".env").stat().st_mode & 0o777, 0o600)
        self.assertNotIn(AZURE_KEY, result.stdout + result.stderr)
        self.assertNotIn(AZURE_KEY, (self.root / "calls.jsonl").read_text())
        self.assertEqual(json.loads((self.state / "foundry.json").read_text())["phase"], "configured")
        for call in self.calls():
            if call["tool"] == "az" and call["args"][0] != "version" and call["args"][:2] not in (
                    ["account", "show"], ["cloud", "show"]):
                self.assertIn("--subscription", call["args"])
        self.assertFalse(list(self.state.glob("tmp.*")))

    def test_prompt_is_literal_and_json_stdout_is_clean(self):
        self.up()
        self.foundry_up()
        text = 'quote " \n dollar $HOME $(shell touch injected) `touch injected` \\\\ end'
        result = self.run_make("prompt", "PROMPT=" + text, "FORMAT=json")
        self.assertEqual(json.loads(result.stdout)["object"], "chat.completion")
        self.assertEqual(json.loads((self.root / "request.json").read_text())["messages"][0]["content"], text)
        self.assertFalse((self.root / "injected").exists())
        self.assertNotIn(AZURE_KEY, result.stdout + result.stderr)
        curl_calls = [call["args"] for call in self.calls() if call["tool"] == "curl"]
        self.assertTrue(any(args[-1] == "http://127.0.0.1:38472/v1/chat/completions" for args in curl_calls))
        self.assertFalse(list(self.state.glob("tmp.*")))

    def test_prompt_file_and_failure_exit(self):
        self.up()
        self.foundry_up()
        (self.root / "prompt.txt").write_text("A multiline\nprompt.")
        self.run_make("prompt", "PROMPT_FILE=prompt.txt")
        self.run_make("prompt", "PROMPT=Hello", success=False, env={"MOCK_HTTP_STATUS": "429"})
        self.run_make("prompt", "PROMPT=Hello", success=False, env={"MOCK_BAD_JSON": "1"})
        result = self.run_make("prompt", "PROMPT=Hello", success=False, env={"MOCK_CONTENT_FILTER": "1"})
        self.assertIn("content filter", result.stderr)
        self.assertFalse(list(self.state.glob("tmp.*")))

    def test_interrupt_cleans_forward_and_request_files(self):
        self.up()
        self.foundry_up()
        process = subprocess.Popen(["make", "prompt", "PROMPT=Hello"], cwd=self.root,
                                   env={**self.env, "MOCK_HOLD_CURL": "1"}, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 20
            while not (self.root / "request.json").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue((self.root / "request.json").exists(), "curl never received the request")
            os.killpg(process.pid, signal.SIGINT)
            process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(list(self.state.glob("tmp.*")))
            for call in self.calls():
                if call["tool"] == "kubectl" and "port-forward" in call["args"]:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(call["pid"], 0)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=10)

    def test_tracked_env_is_not_overwritten(self):
        self.up()
        path = self.root / ".env"
        path.write_text("CUSTOM_NOTE=preserve\n")
        path.chmod(0o600)
        subprocess.run(["git", "add", "-f", ".env"], cwd=self.root, check=True)
        result = self.run_make("foundry-up", "REGION=eastus2", "MODEL=gpt-5-nano",
                               "MODEL_VERSION=2025-08-07", "SKU=GlobalStandard", "CAPACITY=1",
                               "CONFIRM=1", success=False)
        self.assertIn("tracked by Git", result.stderr)
        self.assertEqual(path.read_text(), "CUSTOM_NOTE=preserve\n")

    def test_resume_rejects_changed_capacity(self):
        self.up()
        self.foundry_up()
        result = self.run_make("foundry-up", "CAPACITY=2", "CONFIRM=1", success=False)
        self.assertIn("CAPACITY differs", result.stderr)

    def test_env_is_data_and_unknown_fields_survive(self):
        self.up()
        path = self.root / ".env"
        path.write_text("CUSTOM_NOTE=$(touch injected)\n")
        path.chmod(0o600)
        self.foundry_up()
        self.assertIn("CUSTOM_NOTE=$(touch injected)", path.read_text())
        self.assertFalse((self.root / "injected").exists())

    def test_duplicate_env_and_symlink_refused(self):
        self.up()
        self.foundry_up()
        path = self.root / ".env"
        with path.open("a") as file:
            file.write("AZURE_API_KEY=duplicate\n")
        self.run_make("gateway-configure", success=False)
        path.unlink()
        path.symlink_to(self.root / ".env.example")
        self.run_make("gateway-configure", success=False)

    def test_subscription_change_blocks_cloud_operations(self):
        self.up()
        self.foundry_up()
        self.run_make("foundry-status", success=False,
                      env={"MOCK_SUBSCRIPTION": "22222222-2222-2222-2222-222222222222"})

    def test_cloud_down_clears_auth_and_new_setup_changes_names(self):
        self.up()
        self.foundry_up()
        first = json.loads((self.state / "foundry.json").read_text())
        self.run_make("foundry-down", "CONFIRM=1")
        self.run_make("check")
        self.run_make("up")
        self.assertNotIn(AZURE_KEY, (self.root / ".env").read_text())
        self.foundry_up()
        second = json.loads((self.state / "foundry.json").read_text())
        self.assertNotEqual(first["account"], second["account"])

    def test_partial_local_cleanup_preserves_key_until_recovery(self):
        self.up()
        self.foundry_up()
        self.run_make("foundry-down", "CONFIRM=1", success=False, env={"MOCK_KUBE_DOWN": "1"})
        self.assertEqual(json.loads((self.state / "foundry.json").read_text())["phase"], "cloud-deleted")
        self.assertIn(AZURE_KEY, (self.root / ".env").read_text())
        self.run_make("up")
        self.run_make("check")
        self.assertEqual(json.loads((self.state / "foundry.json").read_text())["phase"], "deleted")

    def test_foreign_cloud_resource_prevents_deletion(self):
        self.up()
        self.foundry_up()
        self.run_make("foundry-down", "CONFIRM=1", success=False, env={"MOCK_FOREIGN_RESOURCE": "1"})
        self.assertTrue(json.loads(self.mock.read_text())["group"])
