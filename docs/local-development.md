# Local development

## Prerequisites

Use Docker Desktop, Kind 0.31.0, kubectl compatible with Kubernetes 1.35,
Helm 3.12 or later, Bash, Make, curl, jq 1.6 or later, OpenSSL, and lsof.
The scripts support macOS's `/bin/bash` and GNU Make 3.81.
The offline test runner additionally uses Python 3's standard library.
No Python environment, SDK package, azd extension, container build, or Node.js
installation is needed to run the gateway.
K9s is optional and required only for `make k9s`.

Cloud commands need Azure CLI 2.80 or later, an authenticated enabled
subscription in AzureCloud, and permission to register the service, create a
resource group/Foundry account/project/deployment, and read its API key.
Model quota and regional capacity are checked independently. Missing tools or
permissions are reported; nothing is installed or upgraded automatically.

Pinned Kubernetes and gateway versions live in `versions.env`.
The current stack is Kubernetes 1.35.0, Gateway API 1.6.0 standard CRDs, and
agentgateway 1.5.0. Both the controller and a proxy are installed.

## Command sections and output

`make` defaults to `make help`. Help and progress share named sections and
aligned command rows. Interactive terminals get bold headings and restrained
colors; `NO_COLOR=1`, `TERM=dumb`, and captured output remain plain. There are no
spinners or progress animations that hide errors.

| Section | Commands |
| --- | --- |
| Local environment | `up`, `status`, `k9s`, `dashboard`, `gateway-forward` |
| Foundry model | `foundry-register`, `foundry-regions`, `foundry-models`, `foundry-up`, `foundry-status`, `gateway-configure`, `endpoints` |
| Prompting | `prompt` |
| Diagnostics | `doctor`, `check`, `logs`, `test` |
| Cleanup | `down CONFIRM=1`, `foundry-down CONFIRM=1` |

For troubleshooting, `cluster-up` and `gateway-install` run individual local
setup stages. All names in the table are Make targets.

Prompt progress goes to stderr. Default prompt stdout contains the assistant's
text. `FORMAT=json` stdout contains only the complete JSON response, suitable
for piping into jq. Errors return a nonzero exit code and are not replaced with
an empty or fabricated answer.

## Isolation and reserved ports

The dedicated cluster is `multi-tenant-ai-gateway`, with context
`kind-multi-tenant-ai-gateway`. Kubernetes resources use namespace
`agentgateway-system`. The proxy Gateway is `agentgateway-proxy`.

Every Kubernetes and Helm command selects `.local/kubeconfig` and the explicit
project context. Kind selects Docker Desktop's `desktop-linux` context and the
Docker provider. Ownership records include the actual Kind node ID, image, and
API binding. An unexplained cluster with the same name is not adopted or deleted.
Missing kubeconfig never falls back to your global context.

Run `make k9s` to open K9s with the same local kubeconfig and explicit project
context. It verifies the project cluster before launching and does not merge or
switch your global contexts.

`ports.env` reserves host ports 38470 through 38479:

| Host port | Purpose |
| --- | --- |
| 38470 | Foreground gateway access for curl, clients, and SDKs |
| 38471 | Kind Kubernetes API |
| 38472 | Temporary connection owned by `check`, `prompt`, or gateway configuration |
| 38473 | Foreground access to the built-in gateway dashboard |
| 38474 through 38479 | Reserved for future project use |

All host listeners bind to `127.0.0.1`. Internal Service/container ports do not
reserve host ports. The gateway Service is ClusterIP, not NodePort or LoadBalancer.
No ingress controller, load balancer addon, metrics forward, or browser is
started. The dashboard forward starts only when explicitly requested.

Do not run independent lifecycle/configuration commands concurrently.
`make -j up` still runs its stages in order, but separate shells can contend
for the same resource or temporary port. Occupied ports cause failure; the
scripts never kill another process to reclaim one.

## Gateway dashboard

```bash
make dashboard
```

Open http://127.0.0.1:38473/ui/ in your browser and keep the command running.
Ctrl-C stops forwarding. The command verifies the project kubeconfig and context,
then forwards the proxy deployment's admin port 15000 to the localhost port
defined by `DASHBOARD_PORT` in `ports.env`.

Agentgateway's built-in UI is read-only in Kubernetes mode. It shows the
configuration received by the proxy, including listeners, routes, and policies;
configuration changes still go through Kubernetes resources and Make commands.
The admin endpoint is not exposed by a Service and is separate from the
API-key-protected model route. Do not expose this port publicly.

## Foundry registration and region selection

Start with:

```bash
make up
make foundry-register
make foundry-up
```

`foundry-register` shows the active subscription and asks before registering
`Microsoft.CognitiveServices`. Registration does not create a model deployment.
If it is already registered, the command is a read-only no-op. Registration is
not silently performed by model discovery or local startup.

`foundry-up` guides region selection when no `REGION` is supplied.
`make foundry-regions` lists region names supported by the resource provider.
That list alone does not prove model availability. To investigate a particular
region without creating resources:

```bash
make foundry-models REGION=eastus2
```

Discovery considers generally available GPT text chat models of all sizes,
including full-size models as well as `mini` and `nano` variants. Models must
support chat completions; Responses-only models are not offered by this workflow.
Discovery excludes preview/legacy models, audio/image-specialized and realtime
models, fine-tuning SKUs, provisioned throughput, and third-party marketplace purchases. It checks the
catalog's exact quota identifier rather than guessing it from the model name.
It requires both subscription quota and platform capacity. No capacity/quota
result means no deployable candidate, not success.

Select a candidate from the numbered menu. The suggested capacity is the
published minimum, or the service's published default when no minimum is
advertised. Review the exact subscription, names, region, model/version, SKU,
capacity, public HTTPS exposure, and API-key authentication before confirming.
GlobalStandard can process requests outside the resource's region.

Non-interactive deployment requires every choice and explicit confirmation:

```bash
make foundry-up REGION=<region> MODEL=<model> MODEL_VERSION=<version> \
  SKU=<Standard-or-GlobalStandard> CAPACITY=<units> CONFIRM=1
```

Replace placeholders with a candidate reported by discovery.
The command does not silently choose another model, region, or deployment type
when deployment fails. It does not send an inference request after setup.

## What is provisioned

The command creates one owned resource group, one AIServices Foundry account
with project management and system identity, its first/default project
`gateway-dev`, and one model deployment `gateway-chat`.
Stable generated names and exact Azure resource IDs are recorded in
`.local/foundry.json` before provisioning. Account creation uses Azure CLI's ARM
REST interface to make the public-network and local-auth settings explicit.

The account uses authenticated public HTTPS so a local Kind cluster can reach it.
Account creation applies the requested `SecurityControl=Ignore` exception tag
and sets `disableLocalAuth=false` to keep API-key authentication. The tag is
scoped to this owned Foundry account, not its resource group or subscription.
It is an organization-specific policy exception, not a built-in Azure security
feature, and can exempt the account from policies that honor the tag. The
deployment confirmation explicitly shows this exception.

If Azure Policy blocks public access or key authentication, setup stops.
It does not disable another resource's security policy or grant itself roles.
The gateway does not inherit your host `az login` and does not pretend to have an
Azure managed identity.

The chosen subscription is supplied explicitly to cloud operations. Repeated
setup reuses only the owned compatible resources and the recorded selection.
Changing the current subscription or passing conflicting deployment settings
causes an error rather than provisioning elsewhere.

No storage account, Search service, hosted Foundry agent, or telemetry stack is
created. No unrelated Foundry resource is adopted.

## Configuration and authentication

`.env` is generated after successful provisioning. It holds:

- The selected subscription, resource group, region, resource/project names,
  model name/version/SKU/capacity, and deployment name.
- The Foundry project endpoint and OpenAI-compatible inference base URL.
- The Azure provider key and a separate random local gateway API key.
- The stable local client base URL, `http://127.0.0.1:38470/v1`.

`.env.example` documents the keys without credentials. Do not copy its empty
values over a working `.env`. The parser accepts literal `KEY=value` lines and
comments. Quotes are literal, not shell quoting; `export` lines, malformed
entries, and duplicates are rejected. Shell and Make expressions are never
evaluated.

`.local/` is owner-only, and `.env`/kubeconfig use mode 0600.
Configuration updates are atomic. Symlink destinations and a Git-tracked `.env`
are refused. Unrelated `.env` entries survive setup and cleanup.
Do not source `.env`, run `make` with shell tracing around secrets, or commit
generated state.

The Azure key is sent to the gateway in a Kubernetes Secret without a
credential-bearing command-line argument or client-side last-applied annotation.
Only a SHA-256 hash of the local client key is stored in its ConfigMap.
A Strict PreRouting policy checks local client authentication before routing.
Setup checks actual 401 responses for missing/invalid credentials and accepts a
valid key before applying the paid route.

The HTTPRoute accepts POST `/v1/chat/completions` and points to an
`AgentgatewayBackend` resource describing Foundry. That object is configuration,
not a local backend workload. Agentgateway injects the Azure credential; clients
use the separate local key.

This is not protection from a malicious local administrator, cluster
administrator, or another user with access to the same operating-system account.
It is not tenant isolation or a hard spending limit. Use non-sensitive test
prompts; prompts and responses leave the machine for Azure inference.

## Prompt requests

```bash
make prompt PROMPT="Say hello in one sentence."
make prompt PROMPT_FILE=prompt.txt
make prompt PROMPT_FILE=prompt.txt FORMAT=json | jq '.choices[0].message'
```

Use a prompt file to keep text out of shell history. Prompts are limited to
32 KiB. The command JSON-encodes the text with jq, sets `stream: false`, and uses
`max_completion_tokens: 1024`. It does not set optional temperature or other
model-specific parameters.

The logical request is:

```http
POST /v1/chat/completions
Authorization: Bearer <local gateway key>
Content-Type: application/json

{"model":"gateway-chat","messages":[{"role":"user","content":"Hello"}],"stream":false,"max_completion_tokens":1024}
```

Curl reads the header from a short-lived private file and sends the JSON through
the project-owned loopback forward. It does not follow redirects, use an ambient
HTTP proxy for localhost, or automatically retry billable POST requests.
Request and header files and the exact forwarding child process are cleaned up
on success, failure, and interrupts.

The response must be a real chat-completion JSON object with an assistant
message or an explicit refusal. HTTP errors, malformed bodies, and empty
responses are errors. A reasoning model can exhaust the completion allowance
before producing visible text; this is reported rather than treated as success.

`make gateway-forward` is for a persistent foreground client connection on
38470. The one-shot `make prompt` uses 38472 independently, so it does not need a
second terminal.

## Recovery and cleanup

Use `make status`, `make logs`, and `make foundry-status` to inspect failure.
No partial deployment is silently deleted. `.local/foundry.json` records the
selection and provisioning phase so that rerunning setup can resume.

`make gateway-configure` reapplies an existing valid connection without creating
Azure resources. `make up` restores that saved connection after local cluster
recreation without making Azure calls or generating text.

```bash
make down CONFIRM=1
make up
```

Local teardown preserves `.env` and cloud ownership records. Changing the Kind
image or API binding requires explicit local recreation; existing incompatible
nodes are not silently reused.

```bash
make foundry-down CONFIRM=1
```

Cloud cleanup verifies the exact recorded subscription, resource IDs, ownership
tags, and child resources. Unexpected resources/models/projects prevent
automatic deletion. It does not purge soft-deleted accounts or unregister the
service.

After cloud deletion, cleanup removes the local route, provider connection,
provider Secret, and client authentication objects, then removes only managed
connection settings from `.env`. If local Kubernetes is unavailable, credentials
and pending-cleanup state are retained. A later `make up` finishes that cleanup
before checking the now-unconfigured gateway. Fresh cloud setup after deletion
uses newly confirmed names rather than trying to reuse soft-deleted names.

## Verification

```bash
make test
```

The offline suite runs actual Make entry points in disposable, isolated
workspaces with tool doubles. It checks context/subscription selection,
confirmation, ownership, literal prompt handling, credential transport,
response validation, failure behavior, repeated setup, cleanup, and child
process termination. It never contacts Azure or a real Kubernetes cluster.

For a dedicated, running gateway that has no provider routes or policies:

```bash
GATEWAY_RUNTIME_TEST=1 PYTHONPATH=tests python3 -m unittest -v test_runtime
```

This opt-in local integration check applies a temporary fictional provider
configuration and verifies real gateway authentication and resource acceptance.
It does not send an inference request. It removes that configuration afterward
and refuses to replace an existing connection.

Actual Azure provisioning and end-to-end hosted inference require the user's
subscription registration, selected region/model, permissions, quota, and
deployment confirmation. Offline checks and local routing/authentication checks
do not prove that a particular Azure deployment will succeed.
