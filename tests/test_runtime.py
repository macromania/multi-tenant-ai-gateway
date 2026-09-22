"""Opt-in checks against this project's existing Kind cluster, without Azure calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("GATEWAY_RUNTIME_TEST") == "1", "opt-in local Kind integration")
class RunningGateway(unittest.TestCase):
    def test_configuration_authentication_and_cleanup(self):
        command = ["kubectl", "--kubeconfig", str(ROOT / ".local/kubeconfig"),
                   "--context", "kind-multi-tenant-ai-gateway", "-n", "agentgateway-system"]
        current = subprocess.check_output(command + ["get", "httproute,agentgatewaybackend,agentgatewaypolicy",
                                                     "-o", "json"], text=True)
        self.assertEqual(json.loads(current)["items"], [],
                         "Integration check requires an unconfigured gateway; it will not replace your connection.")
        with tempfile.TemporaryDirectory(prefix="runtime-", dir=ROOT / ".local") as directory:
            root = Path(directory)
            for name in ("scripts", "deploy"):
                shutil.copytree(ROOT / name, root / name)
            for name in ("Makefile", ".gitignore", "versions.env", "ports.env"):
                shutil.copy2(ROOT / name, root / name)
            state = root / ".local"
            state.mkdir(mode=0o700)
            for name in ("cluster.json", "kubeconfig"):
                shutil.copy2(ROOT / ".local" / name, state / name)
                (state / name).chmod(0o600)
            owner = "a" * 32
            subscription = "11111111-1111-1111-1111-111111111111"
            group = "rg-mtag-aaaaaaaa"
            account = "ai-mtag-aaaaaaaa"
            group_id = f"/subscriptions/{subscription}/resourceGroups/{group}"
            account_id = group_id + "/providers/Microsoft.CognitiveServices/accounts/" + account
            record = {
                "owner": owner, "subscription": subscription, "region": "eastus2",
                "group": group, "account": account, "project": "gateway-dev", "deployment": "gateway-chat",
                "model": "gpt-5-nano", "version": "2025-08-07", "sku": "GlobalStandard", "capacity": 1,
                "groupId": group_id, "accountId": account_id,
                "projectId": account_id + "/projects/gateway-dev",
                "deploymentId": account_id + "/deployments/gateway-chat", "phase": "provisioned",
            }
            record_path = state / "foundry.json"
            record_path.write_text(json.dumps(record))
            record_path.chmod(0o600)
            endpoint = f"https://{account}.services.ai.azure.com/api/projects/gateway-dev"
            values = {
                "AZURE_SUBSCRIPTION_ID": subscription, "AZURE_RESOURCE_GROUP": group,
                "AZURE_LOCATION": "eastus2", "AZURE_FOUNDRY_RESOURCE_NAME": account,
                "AZURE_FOUNDRY_PROJECT_NAME": "gateway-dev", "AZURE_FOUNDRY_PROJECT_ENDPOINT": endpoint,
                "AZURE_MODEL_BASE_URL": endpoint + "/openai/v1", "AZURE_MODEL_DEPLOYMENT": "gateway-chat",
                "AZURE_MODEL_NAME": "gpt-5-nano", "AZURE_MODEL_VERSION": "2025-08-07",
                "AZURE_MODEL_SKU": "GlobalStandard", "AZURE_MODEL_CAPACITY": "1",
                "AZURE_API_KEY": "FICTIONAL_KEY_NOT_A_REAL_AZURE_CREDENTIAL",
                "AGENTGATEWAY_BASE_URL": "http://127.0.0.1:38470/v1", "AGENTGATEWAY_API_KEY": "b" * 64,
            }
            env = root / ".env"
            env.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
            env.chmod(0o600)
            try:
                subprocess.run(["make", "gateway-configure"], cwd=root, check=True, timeout=240)
                subprocess.run(["make", "check"], cwd=root, check=True, timeout=120)
            finally:
                # This state is fictional; the cleanup path makes only project-scoped Kubernetes calls.
                record["phase"] = "cloud-deleted"
                record_path.write_text(json.dumps(record))
                subprocess.run(["/bin/bash", "scripts/foundry.sh", "gateway-restore"],
                               cwd=root, check=True, timeout=120)
        subprocess.run(["make", "check"], cwd=ROOT, check=True, timeout=120)
