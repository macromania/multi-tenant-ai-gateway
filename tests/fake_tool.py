#!/usr/bin/env python3
"""Scoped command doubles. These never execute Docker, Kubernetes, or Azure."""
import json
import os
from pathlib import Path
import signal
import sys
import time

root = Path(os.environ["FIXTURE_ROOT"])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = root / "mock-state.json"
state = json.loads(state_path.read_text())
record_path = root / ".local/foundry.json"
record = json.loads(record_path.read_text()) if record_path.exists() else {}
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps({"tool": tool, "args": args, "pid": os.getpid()}) + "\n")


def save():
    state_path.write_text(json.dumps(state))


def output(value):
    print(json.dumps(value) if not isinstance(value, str) else value)


def option(name, default=None):
    return args[args.index(name) + 1] if name in args else default


def env_values():
    result = {}
    path = root / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                result[key] = value
    return result


def kubeconfig():
    return {
        "contexts": [{"name": "kind-multi-tenant-ai-gateway",
                      "context": {"cluster": "local", "user": "local"}}],
        "clusters": [{"name": "local", "cluster": {
            "server": "https://127.0.0.1:38471"}}],
        "users": [{"name": "local", "user": {}}],
    }


def account():
    tags = {"agentgatewayProjectId": record["owner"]}
    exception = state.get("account_request", {}).get("tags", {}).get("SecurityControl")
    if exception is not None:
        tags["SecurityControl"] = exception
    disabled = bool(os.environ.get("MOCK_LOCAL_AUTH_DISABLED"))
    if os.environ.get("MOCK_LOCAL_AUTH_POLICY") and exception != "Ignore":
        disabled = True
    return {"id": record["accountId"], "name": record["account"], "kind": "AIServices",
            "location": record["region"],
            "tags": tags,
            "properties": {"provisioningState": "Succeeded", "allowProjectManagement": True,
                           "disableLocalAuth": disabled, "publicNetworkAccess": "Enabled"}}


def deployment():
    return {"id": record["deploymentId"], "name": record["deployment"],
            "sku": {"name": record["sku"], "capacity": record["capacity"]},
            "properties": {"provisioningState": "Succeeded", "versionUpgradeOption": "NoAutoUpgrade",
                           "model": {"name": record["model"], "version": record["version"]}}}


def model_catalog():
    models = [("gpt-5-nano", "2025-08-07", "GenerallyAvailable", "true")]
    if os.environ.get("MOCK_LARGE_MODELS"):
        models += [
            ("gpt-5-mini", "2025-08-07", "GenerallyAvailable", "true"),
            ("gpt-5", "2025-08-07", "GenerallyAvailable", "true"),
            ("gpt-5.4", "2026-03-05", "GenerallyAvailable", "true"),
            ("gpt-5.6-sol", "2026-07-09", "GenerallyAvailable", "true"),
            ("gpt-6-astra", "2026-09-03", "GenerallyAvailable", "true"),
            ("gpt-audio", "2025-08-28", "GenerallyAvailable", "true"),
            ("gpt-4o-audio", "test-version", "GenerallyAvailable", "true"),
            ("gpt-4o-realtime", "test-version", "GenerallyAvailable", "true"),
            ("gpt-5-codex", "test-version", "GenerallyAvailable", "false"),
            ("gpt-4.1", "2025-04-14", "Legacy", "true"),
            ("gpt-6-preview", "test-version", "Preview", "true"),
            ("model-router", "2025-11-18", "GenerallyAvailable", "true"),
        ]
    return [{"kind": "AIServices", "model": {
        "format": "OpenAI", "lifecycleStatus": lifecycle,
        "name": name, "version": version, "capabilities": {"chatCompletion": chat},
        "skus": [{"name": "GlobalStandard", "usageName": "OpenAI.GlobalStandard." + name,
                  "capacity": {"minimum": 1, "default": 10, "maximum": 100,
                               "step": 1, "allowedValues": None}}],
    }} for name, version, lifecycle, chat in models]


if tool == "sleep":
    time.sleep(0.01)
elif tool == "lsof":
    sys.exit(0 if os.environ.get("MOCK_BUSY") else 1)
elif tool == "docker":
    if "info" in args:
        if os.environ.get("MOCK_DOCKER_DOWN"):
            sys.exit(1)
        output("Docker Desktop")
    elif "inspect" in args:
        image = next(line.split("=", 1)[1] for line in (root / "versions.env").read_text().splitlines()
                     if line.startswith("KIND_IMAGE="))
        output([{"Id": "foreign" if os.environ.get("MOCK_FOREIGN_NODE") else "test-node",
                 "Config": {"Image": image, "Labels": {"io.x-k8s.kind.cluster": "multi-tenant-ai-gateway"}},
                 "HostConfig": {"PortBindings": {"6443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "38471"}]}}}])
elif tool == "kind":
    if args == ["version"]:
        output("kind v0.31.0 go1.25 darwin/arm64")
    elif args[:2] == ["get", "clusters"]:
        output("unrelated-cluster" + ("\nmulti-tenant-ai-gateway" if state.get("cluster") else ""))
    elif args[:2] == ["create", "cluster"]:
        state["cluster"] = True
        save()
        path = Path(option("--kubeconfig"))
        path.write_text(json.dumps(kubeconfig()))
        path.chmod(0o600)
    elif args[:2] == ["export", "kubeconfig"]:
        path = Path(option("--kubeconfig"))
        path.write_text(json.dumps(kubeconfig()))
        path.chmod(0o600)
    elif args[:2] == ["delete", "cluster"]:
        state["cluster"] = False
        save()
elif tool == "k9s":
    output("k9s ready")
    sys.exit(int(os.environ.get("MOCK_K9S_EXIT", "0")))
elif tool == "helm":
    if os.environ.get("MOCK_HELM_FAIL"):
        print("simulated chart install error", file=sys.stderr)
        sys.exit(1)
    output("chart ready")
elif tool == "kubectl":
    if os.environ.get("MOCK_KUBE_DOWN"):
        print("simulated API unavailable", file=sys.stderr)
        sys.exit(1)
    if "config" in args:
        config = kubeconfig()
        if os.environ.get("MOCK_WRONG_CONTEXT"):
            config["clusters"][0]["cluster"]["server"] = "https://unrelated.example"
        output(config)
    elif "port-forward" in args:
        port = args[-1].split(":")[0]
        print(f"Forwarding from 127.0.0.1:{port} -> 80", flush=True)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while True:
            time.sleep(1)
    elif "create" in args and "configmap" in args:
        output({"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"name": "local-client-keys", "namespace": "agentgateway-system"}})
    elif "apply" in args:
        file = option("-f")
        text = sys.stdin.read() if file == "-" else Path(file).read_text()
        if "local-client-auth" in text:
            state["auth"] = True
        if "foundry-chat" in text:
            state["route"] = True
        if "Secret" in text and text.startswith("{"):
            value = json.loads(text)
            if value.get("kind") == "Secret":
                state["provider_key_present"] = bool(value["stringData"]["Authorization"])
        save()
        output("applied")
    elif "delete" in args:
        if "foundry-chat" in args:
            state["route"] = False
        if "local-client-auth" in args:
            state["auth"] = False
        save()
        output("deleted")
    elif "get" in args:
        resource = args[args.index("get") + 1]
        if resource.startswith("service/"):
            output("ClusterIP")
        elif resource == "agentgatewaypolicy" and "--ignore-not-found" in args:
            output("agentgatewaypolicy/local-client-auth" if state.get("auth") else "")
        else:
            conditions = [{"type": name, "status": "True", "observedGeneration": 1}
                          for name in ("Accepted", "ResolvedRefs", "Programmed")]
            if resource.startswith("agentgatewaypolicy/"):
                status = {"ancestors": [{"ancestorRef": {"name": "agentgateway-proxy"},
                                         "conditions": conditions}]}
            elif resource.startswith("httproute/"):
                status = {"parents": [{"parentRef": {"name": "agentgateway-proxy"}, "conditions": conditions}]}
            else:
                status = {"conditions": conditions}
            output({"metadata": {"generation": 1}, "status": status})
    else:
        output("ready")
elif tool == "curl":
    url = args[-1]
    if "github.com" in url:
        output("apiVersion: v1\nkind: List\nitems: []")
    else:
        response = {"object": "chat.completion", "model": "test-model",
                    "choices": [{"message": {"role": "assistant", "content": "Hello from the mocked model."}}],
                    "usage": {"total_tokens": 9}}
        status = 200
        header = option("--header", "")
        if header.startswith("@"):
            actual_header = Path(header[1:]).read_text().strip()
        else:
            actual_header = ""
        expected = "Authorization: Bearer " + env_values().get("AGENTGATEWAY_API_KEY", "")
        if state.get("auth") and actual_header != expected:
            status = 401
        elif "__gateway_unmatched__" in url:
            status = 404
        elif option("--data-binary"):
            payload = json.loads(Path(option("--data-binary")[1:]).read_text())
            (root / "request.json").write_text(json.dumps(payload))
            if os.environ.get("MOCK_HOLD_CURL"):
                while True:
                    time.sleep(1)
        else:
            status = 404
        status = int(os.environ.get("MOCK_HTTP_STATUS", status))
        if os.environ.get("MOCK_CONTENT_FILTER"):
            response["choices"][0]["finish_reason"] = "content_filter"
        content = "not JSON" if os.environ.get("MOCK_BAD_JSON") else json.dumps(response)
        Path(option("--output")).write_text(content)
        sys.stdout.write(str(status))
elif tool == "az":
    if args[0] == "version":
        output({"azure-cli": "2.83.0"})
    elif args[:2] == ["cloud", "show"]:
        output("AzureCloud")
    elif args[:2] == ["account", "show"]:
        output({"id": os.environ.get("MOCK_SUBSCRIPTION", "11111111-1111-1111-1111-111111111111"),
                "name": "test-subscription", "state": "Enabled"})
    elif args[:2] == ["account", "list-locations"]:
        if "--subscription" in args:
            print("account list-locations does not accept --subscription", file=sys.stderr)
            sys.exit(2)
        output([{"name": "eastus2", "displayName": "East US 2"},
                {"name": "swedencentral", "displayName": "Sweden Central"}])
    elif args[:2] == ["provider", "show"]:
        registered = state.get("registered", not os.environ.get("MOCK_UNREGISTERED"))
        if option("--query"):
            output("Registered" if registered else "NotRegistered")
        else:
            output({"resourceTypes": [{"resourceType": "accounts", "locations": ["East US 2", "Sweden Central"]}]})
    elif args[:2] == ["provider", "register"]:
        state["registered"] = True
        save()
    elif args[:3] == ["cognitiveservices", "model", "list"]:
        output(model_catalog())
    elif args[:3] == ["cognitiveservices", "usage", "list"]:
        output([{"name": {"value": entry["model"]["skus"][0]["usageName"]}, "currentValue": 0,
                 "limit": 0 if os.environ.get("MOCK_NO_QUOTA") else 100} for entry in model_catalog()])
    elif args[:2] == ["group", "exists"]:
        output("true" if state.get("group") else "false")
    elif args[:2] == ["group", "create"]:
        state["group"] = True
        save()
        output({"id": record["groupId"]})
    elif args[:2] == ["group", "show"]:
        output({"id": record["groupId"], "tags": {"agentgatewayProjectId": record["owner"]}})
    elif args[:2] == ["group", "delete"]:
        state["group"] = False
        state["account"] = False
        state["project"] = False
        state["deployment"] = False
        save()
    elif args[:2] == ["resource", "list"]:
        resources = [{"id": record["accountId"]}] if state.get("account") else []
        if os.environ.get("MOCK_FOREIGN_RESOURCE"):
            resources.append({"id": record["groupId"] + "/providers/Microsoft.Storage/storageAccounts/foreign"})
        output(resources)
    elif args[0] == "rest":
        url = option("--url")
        if "/locations?" in url:
            output([{"name": "eastus2", "displayName": "East US 2"},
                    {"name": "swedencentral", "displayName": "Sweden Central"}])
        elif "modelCapacities?" in url:
            output({"value": [{"location": "eastus2", "properties": {
                "skuName": "GlobalStandard", "availableCapacity": 0 if os.environ.get("MOCK_NO_CAPACITY") else 100}}]})
        elif option("--method") == "put":
            item = "project" if "/projects/" in url else "deployment" if "/deployments/" in url else "account"
            if item == "account":
                state["account_request"] = json.loads(Path(option("--body")[1:]).read_text())
            state[item] = True
            save()
            output({"properties": {"provisioningState": "Succeeded"}})
        else:
            output("Succeeded")
    elif args[:3] == ["cognitiveservices", "account", "list"]:
        output([account()] if state.get("account") else [])
    elif args[:3] == ["cognitiveservices", "account", "show"]:
        output(account())
    elif args[:4] == ["cognitiveservices", "account", "keys", "list"]:
        output("TEST_AZURE_CREDENTIAL_NEVER_PRINT_12345")
    elif args[:4] == ["cognitiveservices", "account", "project", "list"]:
        output([{"name": record["account"] + "/" + record["project"], "id": record["projectId"]}]
               if state.get("project") else [])
    elif args[:4] == ["cognitiveservices", "account", "project", "show"]:
        output({"properties": {"endpoints": {"AI Foundry API":
            f"https://{record['account']}.services.ai.azure.com/api/projects/{record['project']}"}}})
    elif args[:4] == ["cognitiveservices", "account", "deployment", "list"]:
        output([deployment()] if state.get("deployment") else [])
    elif args[:4] == ["cognitiveservices", "account", "deployment", "show"]:
        output(deployment())
    else:
        print("Unhandled mock Azure call: " + " ".join(args), file=sys.stderr)
        sys.exit(2)
else:
    print("Unhandled fake tool " + tool, file=sys.stderr)
    sys.exit(2)
