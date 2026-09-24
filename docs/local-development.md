# Local development

## Prerequisites

Use Docker Desktop, Kind 0.31.0, kubectl compatible with Kubernetes 1.35, Helm 3.12 or later
(Helm 4 works), Bash, Make, curl, jq 1.6 or later, OpenSSL, and lsof. The scripts run with macOS's
`/bin/bash` 3.2 and GNU Make 3.81. K9s is optional and required only for `make k9s`.

Nothing else is installed on the host. The mock upstream (Python), the load generator (k6), and the
observability stack (Prometheus and Grafana) all run inside the clusters from pinned images and
charts.

Cloud commands need Azure CLI 2.80 or later, an authenticated enabled subscription in AzureCloud,
and permission to register the service, create a resource group, Foundry account, project, and
deployment, and read its API key. Missing tools or permissions are reported; nothing is installed or
upgraded automatically.

Pinned versions live in `versions.env`: Kind and its node image, Gateway API 1.6.0 standard CRDs,
agentgateway v1.5.0, kube-prometheus-stack 91.5.1, and digest-pinned k6 and Python images.

### Image inventory

Images this project names itself are pinned by digest in `versions.env` (the Kind node, k6, and
Python). Charts are pinned by version, which does not pin the images a chart deploys. These are the
images the pinned charts deployed, with the digests recorded on 2026-09-24:

| Image | Digest |
| --- | --- |
| cr.agentgateway.dev/agentgateway:v1.5.0 | sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896 |
| cr.agentgateway.dev/controller:v1.5.0 | sha256:319489cb86b7f901a52a3fc532ad07f136c92756f88cf02a4040909e20001120 |
| docker.io/grafana/grafana:13.2.2-distroless | sha256:69a5d2d957ca0bba434c160dcd4f2d07de9d6c756a0ba10ae7f52b72ced1e4cc |
| quay.io/kiwigrid/k8s-sidecar:2.11.2 | sha256:2912be006f62f9ea080194cf6d3afcd90daead8d101d0ba686a137a849f6a4f6 |
| quay.io/prometheus/prometheus:v3.14.0-distroless | sha256:50c707e96da5ade383cb1707790576480485e93de06aa60ad8802cb5f744bd0a |
| quay.io/prometheus-operator/prometheus-operator:v0.94.1 | sha256:7c88d4e7bae63bd8d0f8da986054337c23b4472fa8d3c6817f5bc4b8407a2d6a |
| quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1 | sha256:06b52bd4dbe3ed6dd5905aadaf8b9987d9da4c31d37bb86deaadae68cee2d26b |
| registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0 | sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b |

## The two clusters

| Cluster | Kind name | What runs in it |
| --- | --- | --- |
| Shared | `mtag-shared` | One agentgateway controller and one proxy in `agentgateway-system` serve every tenant. |
| Dedicated | `mtag-dedicated` | Each tenant namespace gets its own agentgateway controller and proxy. |

Both clusters also run the agentgateway CRDs (one version per cluster), the mock upstream in
`mock-upstream`, Prometheus, Grafana, and kube-state-metrics in `monitoring`, and the `loadgen`
namespace for k6 Jobs.

Every command that touches a cluster needs `CLUSTER=shared` or `CLUSTER=dedicated`. `make status`,
`make check`, `make gateway-configure`, and `make endpoints` also accept `CLUSTER=both`, which runs
the shared cluster, then the dedicated cluster, never in parallel. Commands that act on one tenant's
gateway in the dedicated cluster (`logs`, `dashboard`, `gateway-forward`) also need `TENANT`.

## Command sections and output

`make` defaults to `make help`. Help and progress share named sections and aligned command rows.
Interactive terminals get bold headings and restrained colors; `NO_COLOR=1`, `TERM=dumb`, and
captured output remain plain. Progress goes to stderr, errors return a nonzero exit code, and full
Helm and kubectl output is shown rather than hidden.

| Section | Commands |
| --- | --- |
| Clusters | `up`, `status`, `down CONFIRM=1` |
| Observability | `grafana`, `prometheus`, `dashboard`, `logs`, `gateway-forward`, `k9s` |
| Foundry model | `foundry-register`, `foundry-regions`, `foundry-models`, `foundry-up`, `foundry-status`, `gateway-configure`, `endpoints` |
| Diagnostics | `doctor`, `check` |
| Cleanup | `down CONFIRM=1`, `legacy-down CONFIRM=1`, `foundry-down CONFIRM=1` |

For troubleshooting, `cluster-up` and `gateway-install` run individual setup stages.

Every value passed on the Make command line is taken literally (`override VAR := $(value VAR)`), so
Make never evaluates `$(...)` inside a value. The scripts then validate each value against a fixed
list or pattern.

## Isolation of the tooling and reserved ports

Every Kubernetes and Helm command selects `.local/<cluster>/kubeconfig` and the explicit context
`kind-mtag-<cluster>`. Kind selects Docker Desktop's `desktop-linux` context. Ownership records
(`.local/<cluster>/cluster.json`) hold the Kind node's container ID, image, and API port; an
unexplained cluster with the same name is never adopted or deleted. A missing kubeconfig never
falls back to your global context.

`ports.env` reserves two blocks with the same offsets. All host listeners bind to `127.0.0.1`.

| Offset | Purpose | Shared | Dedicated |
| --- | --- | --- | --- |
| +0 | Gateway access for clients (`gateway-forward`) | 38480 | 38490 |
| +1 | Kind Kubernetes API | 38481 | 38491 |
| +2 | Temporary request port used by commands | 38482 | 38492 |
| +3 | agentgateway admin UI (`dashboard`) | 38483 | 38493 |
| +4 | Grafana (`grafana`) | 38484 | 38494 |
| +5 | Prometheus (`prometheus`) | 38485 | 38495 |
| +6 to +9 | Reserved | | |

Ports 38470 to 38479 stay reserved for this project; the retired single-user cluster used them.
Every Service is ClusterIP. No ingress controller, load balancer, or NodePort is created.
Occupied ports cause failure; the scripts never kill another process to reclaim one.

Do not run independent lifecycle or configuration commands for the same cluster concurrently.

## Observability

```bash
make grafana CLUSTER=shared
make prometheus CLUSTER=shared
```

Grafana opens at `http://127.0.0.1:38484/d/mtag-tenants` (shared) or `38494` (dedicated). Viewing
needs no login; the admin password is in `.local/<cluster>/grafana-admin`. Two dashboards load in
each cluster: "Tenancy comparison", generated from `deploy/observability/dashboards/tenants.jq`, and
the agentgateway chart's own dashboard. Prometheus keeps 15 days of data on a 5 GiB volume inside
the cluster, scrapes the kubelet (with cAdvisor) and the gateway pods every 5 seconds, and accepts
remote writes from k6.

The admin UI (`make dashboard`) forwards the proxy's admin port. That port also serves an
unauthenticated debug trace that can record request headers, including tenant keys and the Foundry
key, while the forward runs. Do not leave it running unattended. Automated configuration reads do
not use a forward; they enter the proxy pod's network namespace from the Kind node.

## The mock upstream

`deploy/mock/server.py` is a standard-library Python server that imitates the OpenAI chat
completions API. It runs as two replicas in `mock-upstream`, answers after `x-mock-latency-ms`
milliseconds (default 100), counts prompt tokens as characters divided by four, and reports the
owner of the provider key it received in `x-mock-key-owner`. It echoes `x-probe-id` as
`x-mock-probe-id`. Its accepted keys come from Secret `mock-upstream-keys` and can be replaced at
runtime through its metrics and admin port 8081, which has no authentication and is not exposed
outside the cluster.

## Load generation

`scripts/load.sh` runs k6 as a Kubernetes Job in the `loadgen` namespace from the pinned k6 image and
`deploy/k6/chat.js`. A plan lists streams (tenant, key, URL, rate, duration, and optional mock latency,
prompt size, or forged tenant header). Each stream is an open-loop constant-arrival-rate scenario, so
the offered load stays constant when the system under test slows down. Keys are copied from
`.env.tenants` into a short-lived Secret and deleted with the Job.

Every request goes to the mock, directly or through a gateway, and gets one verdict: verified (served
with the sending tenant's provider key and its own probe ID), leak (another tenant's key or a wrong
probe ID), blocked (refused by the gateway, such as 401 or 429), unverifiable (a 200 without the
mock's headers), or failed. Streams with records print a `START {json}` line when a request begins
and a `PROBE {json}` line when it ends; a request cut off when a run is stopped early is kept as
censored. Every Job prints a `K6_SUMMARY {json}` line with per-stream counts, dropped iterations,
latency percentiles, and verdicts. A run whose saved records do not cover every request k6 counted
is rejected, because kubelet rotates container logs at 10 MiB; plans are capped at 20,000 recorded
requests. Streams with records get enough VUs for every request to reach its timeout. The key
Secret and plan ConfigMap are owned by the Job, so Kubernetes deletes them with it. k6 also pushes its metrics, with
latency as native histograms, to the cluster's Prometheus, where the "Tenants: what the clients saw"
panels read them.

## Foundry registration and deployment

```bash
make foundry-register
make foundry-regions
make foundry-models REGION=eastus2
make foundry-up
```

`foundry-register` shows the active subscription and asks before registering
`Microsoft.CognitiveServices`. `foundry-up` guides region and model selection, checks quota and
capacity, and asks you to confirm the deployment. It creates one owned resource group, one
AIServices account with system identity, the default project `gateway-dev`, and one model deployment
`gateway-chat`, which every tenant in both clusters shares. It saves protected configuration to
`.env` and does not change any cluster.

Non-interactive deployment requires every choice and explicit confirmation:

```bash
make foundry-up REGION=<region> MODEL=<model> MODEL_VERSION=<version> \
  SKU=<Standard-or-GlobalStandard> CAPACITY=<units> CONFIRM=1
```

The account uses authenticated public HTTPS, API-key authentication, and the requested
`SecurityControl=Ignore` exception tag on the account only. If Azure Policy blocks public access or
key authentication, setup stops.

```bash
make gateway-configure CLUSTER=both
```

`gateway-configure` checks that each gateway rejects requests with no key and with an invalid key,
then applies Secret `foundry-provider`, AgentgatewayBackend `foundry-model`, and HTTPRoute
`foundry-chat` (POST `/v1/chat/completions`). In the dedicated cluster it does this in every tenant
namespace. `make up` reapplies it when the Foundry record is configured.

## Configuration and credentials

`.env` holds the Azure selection, the Foundry endpoints, and the Azure key. `.env.tenants` holds the
tenant keys. Both are Git-ignored literal `KEY=value` files with mode 0600; quotes are literal,
`export` lines, malformed entries, and duplicates are rejected, and shell expressions are never
evaluated. Symlinks and Git-tracked copies are refused. Do not source either file, run `make` with
shell tracing around secrets, or commit generated state.

Tenant keys never appear in a process argument. The clusters store only SHA-256 hashes of tenant
gateway keys. Secrets are applied with server-side apply so no last-applied annotation holds their
contents.

This is not protection from a malicious local administrator, cluster administrator, or another
process running as your operating-system account. Use non-sensitive test prompts; prompts sent to
Foundry leave the machine.

## Recovery and cleanup

Use `make status`, `make check`, and `make logs` to inspect failure. `make up` can be repeated; it
verifies the existing cluster's identity and reapplies configuration.

```bash
make down CLUSTER=shared CONFIRM=1
make legacy-down CONFIRM=1
make foundry-down CONFIRM=1
```

`down` deletes one project cluster and its `.local/<cluster>/` state. `.env`, `.env.tenants`, and
Azure resources remain. `legacy-down` deletes the retired single-user cluster
`multi-tenant-ai-gateway` after verifying its recorded identity, and removes its single-user key from
`.env`. `foundry-down` deletes only the recorded, project-owned Azure resources after verifying their
IDs and tags, then removes the Foundry objects from every project cluster.

## Verification

There is no offline test suite. Each command verifies its own outcome live: `make up` ends with
`make check`, `gateway-configure` checks for 401 responses before applying the paid route, and later
milestones add experiments whose checks prove that the mechanism under test actually ran.
