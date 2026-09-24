# Compare one shared agentgateway with one agentgateway per tenant on two local Kind clusters

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds. It follows the OpenAI Cookbook ExecPlan format (the PLANS.md described at https://developers.openai.com/cookbook/articles/codex_exec_plans). No PLANS.md is checked into this repository, so this file must stay fully self-contained.

The repository root is the directory that contains the Makefile. Every command in this plan runs from that directory unless the plan says otherwise.


## Purpose / Big Picture

Today this repository runs one local Kubernetes cluster with one agentgateway that serves one user and forwards prompts to one Microsoft Foundry model. After this work, a developer can build two local clusters from the same commands and compare two ways of serving many tenants.

In the shared cluster, one agentgateway serves every tenant, the way a SaaS API serves all of its customers from one endpoint. The API key in each request tells the gateway which tenant is calling. In the dedicated cluster, every tenant gets its own complete agentgateway, meaning its own controller and its own proxy, inside its own Kubernetes namespace.

The developer can add tenants, send prompts, generate load, break things on purpose, grow each cluster to 20 tenants, and read a committed report that compares both designs on the same measurements. Every result links to the matching time range in Grafana. The report is the input to a later architecture decision. This work does not choose a design, and it must not present either design as the answer.

You can see it working when `make break CLUSTER=both FAILURE=proxy-crash` prints, for each cluster in turn, which tenants saw errors, for how long, what error they saw, and how long recovery took, and when `make results` then writes results/report.md containing that comparison with Grafana links.

Two words have fixed meanings in this plan, in the code, and in every document it produces. "Separation" is what namespaces and separate gateways give tenants that share one cluster. "Isolation" means a dedicated cluster for a single tenant, which is out of scope. Never write that either design isolates tenants.


## Progress

- [x] (2026-09-24 09:43Z) Design decisions agreed with the user in a grilling session and recorded in the Decision Log.
- [x] (2026-09-24 10:05Z) Rubber-duck review of the plan; all 14 findings folded into the milestones, Surprises & Discoveries, and the Decision Log.
- [x] (2026-09-24 10:40Z) Security review of the plan; five findings presented to the user, who accepted them as risks for a local proof of concept (see Decision Log).
- [x] (2026-09-24 10:40Z) Scope update from the user: cross-tenant leakage added (per-tenant mock provider keys, an always-on check, two new failures); shared provider quota exhaustion parked.
- [x] (2026-09-24 12:55Z) Second, focused rubber-duck pass; its six remaining findings and five partial resolutions folded in; scale sweep shortened to 1, 5, and 10 by the user.
- [x] (2026-09-24 12:40Z) Milestone 1: both clusters start from the same commands, with the mock upstream and observability, and the offline fake-tool tests are removed. Also done early: foundry.sh and prompt.sh became cluster-aware (planned for Milestone 3), because `make up` restores the Foundry connection and would otherwise have used the retired single-user key.
- [ ] Milestone 1 reviews: rubber-duck and security review of the Milestone 1 commit, findings recorded in FINDINGS.md.
- [ ] Milestone 2: prototypes prove or replace each gateway feature the designs depend on.
- [ ] Milestone 3: shared-cluster tenants, the Foundry route in the shared cluster, and retirement of the old cluster.
- [ ] Milestone 4: dedicated-cluster tenants and the Foundry route in each tenant gateway.
- [ ] Milestone 5: prompts, load, calibration, and the separation, latency, rollout, and Foundry smoke scenarios.
- [ ] Milestone 6: the ten deliberate failure modes with automatic restore.
- [ ] Milestone 7: the scale sweep and onboarding measurements.
- [ ] Milestone 8: the results report, Grafana links, documentation, and final cleanup.


## Surprises & Discoveries

These facts were found while designing the plan, before any implementation. Each one shapes a decision below. Keep adding entries as implementation discovers more.

- Observation: the Foundry deployment is small and shared by everything. It allows 100 requests and 10,000 tokens per minute in total.
  Evidence: `az cognitiveservices account deployment show ... --deployment-name gateway-chat` returned rateLimits `request` count 100 and `token` count 10000, renewalPeriod 60, SKU GlobalStandard, capacity 10. With the current `max_completion_tokens: 1024`, about ten requests can use up the whole minute's token budget.

- Observation: agentgateway local rate limits are counted separately by each proxy process, and token limits apply only to later requests.
  Evidence: `kubectl explain agentgatewaypolicy.spec.traffic.rateLimit.local` says local limits are "handled on a per-proxy basis, without coordination between instances of the proxy" and that token counts "are not known until the request completes", so "token-based rate limits will apply to future requests only". Consequences: running two proxy replicas doubles every tenant's effective limit, and token limits do not cap concurrency, so a tenant can hold many slow requests open while under its token limit.

- Observation: one policy can hold a separate limit for each tenant.
  Evidence: `rateLimit.conditional` is a list of `{condition: <CEL expression>, policy: {...}}` entries, and "the first matching policy will be executed". CEL (Common Expression Language) is the small expression language agentgateway uses in policies.

- Observation: an API key can carry metadata that other policies read.
  Evidence: `kubectl explain agentgatewaypolicy.spec.traffic.apiKeyAuthentication.configMapSelector` says each ConfigMap entry is JSON with `keyHash` (in `sha256:<hex>` form) and optional `metadata`, "which may be used by other policies", for example `apiKey.group == 'sales'`. It also says "If the same key is defined in multiple ConfigMaps, the behavior is undefined". The duplicate-key failure mode tests exactly that sentence.

- Observation: metrics can get extra labels from CEL expressions.
  Evidence: `kubectl explain agentgatewaypolicy.spec.frontend.metrics --recursive` shows `attributes.add[]` with `name` and `expression`. Whether the expression can read `apiKey` metadata is unproven and is prototype P1.

- Observation: agentgateway policies can only point at objects in their own namespace, and key selectors only match labels.
  Evidence: `spec.targetRefs` has `group`, `kind`, `name`, `port`, and `sectionName`, but no namespace. `configMapSelector` has only `matchLabels`.

- Observation: the agentgateway Helm chart supports several controllers in one cluster.
  Evidence: `helm show values oci://cr.agentgateway.dev/charts/agentgateway --version v1.5.0` documents `gatewayClassName` ("Name of the primary GatewayClass the controller creates and manages"), `controllerName` ("Change this together with gatewayClassName when running multiple agentgateway controllers"), `discoveryNamespaceSelectors`, and `rbac.gatewayNamespaces` ("The namespaces must already exist ... Restricting this list means only Gateways in these namespaces can be used"). Rendering the chart twice with `helm template` for releases in namespaces tenant-01 and tenant-02 produced cluster-scoped objects named per release (ClusterRole agentgateway-tenant-01, agentgateway-tenant-01-deployer, ClusterRoleBinding agentgateway-role-tenant-01) and no name collisions. The controller chart does not contain the CRDs; they come from the separate agentgateway-crds chart and are shared by every controller in the cluster.

- Observation: a per-tenant controller can read every Secret in the cluster, including other tenants' credentials.
  Evidence: the rendered ClusterRole agentgateway-tenant-01 grants `get`, `list`, and `watch` on `secrets` cluster-wide, commented "Used for reference configs in policies/TLS/API keys". `rbac.gatewayNamespaces` restricts only namespaced writes. This means the dedicated design does not separate tenant credentials at the Kubernetes permission level. The separation scenario records it with `kubectl auth can-i` rather than changing any RBAC, because RBAC changes are out of scope.

- Observation: the chart already integrates with the Prometheus Operator and Grafana.
  Evidence: chart values include a controller ServiceMonitor, a proxy PodMonitor that scrapes proxy pods on port 15020 and selects them by `gatewayClassNames` (default `[agentgateway]`), and a Grafana dashboard ConfigMap labelled `grafana_dashboard: "1"` for the Grafana sidecar.

- Observation: machine limits. Docker Desktop has 10 CPUs and 23.4 GiB of memory, shared with the user's other projects. The existing Kind node uses about 1.7 GiB with only agentgateway installed. Host ports 38400 to 38699 were free except 38471 (the existing cluster's API port).
  Evidence: `docker info` reported CPUs=10 and Mem=25162678272 bytes, `docker stats` reported 1.677GiB for multi-tenant-ai-gateway-control-plane, and `lsof -iTCP -sTCP:LISTEN` found only 38471 in that range.

- Observation: `kubectl port-forward` tunnels traffic through the Kubernetes API server, so it cannot carry load tests without measuring the tunnel instead of the gateway. All load and latency measurements therefore run inside the clusters.

- Observation: agentgateway v1.5.0 is the latest stable release (2026-08-27). v1.6.0-alpha.2 is a prerelease. Version upgrades are out of scope, so both clusters stay on v1.5.0.

- Observation: two chart features this plan needs are off by default.
  Evidence: `helm show values oci://cr.agentgateway.dev/charts/agentgateway --version v1.5.0` shows `monitoring.enabled: false` ("Create monitoring resources (ServiceMonitors and Grafana dashboard ConfigMap). Requires the Prometheus Operator CRDs") and `agentgatewayModels.enabled: false` ("Enable AgentgatewayModel support in the agentgateway controller"). The reviewer rendered the existing values and got no ServiceMonitor or PodMonitor until monitoring was enabled.

- Observation: the proxy's admin endpoint listens only on the pod's loopback address, and the Kind node can reach it without any host port-forward.
  Evidence: the proxy container declares only port 15020 (metrics). Inside its network namespace, /proc/net/tcp lists a listener at 0100007F:3A98, which is 127.0.0.1:15000. From the node, `docker exec <node> crictl inspect <container>` gives the process ID (`.info.pid`), and `docker exec <node> nsenter -t <pid> -n curl -s http://127.0.0.1:15000/config_dump` returned HTTP 200. The kindest/node image contains crictl 1.33.0, nsenter, and curl. Other pods cannot reach this endpoint because it is bound to loopback.

- Observation: deleting a pod is not a crash. Kubernetes sends SIGTERM and waits for graceful shutdown, and agentgateway v1.5.0 handles SIGTERM by draining connections. A crash must be SIGKILL of the proxy process.

- Observation: k6 v2.3.0 (2026-09-21) is the latest stable release. Its Prometheus remote-write output keeps one aggregate per time series for the whole run, so the exported percentile values are cumulative, not per push interval. A window's p95 cannot be recovered by subtracting cumulative values.
  Evidence: grafana/k6 v2.3.0 internal/output/prometheusrw/remotewrite/remotewrite.go (the per-series sink is retained and samples are added to it) and config.go (K6_PROMETHEUS_RW_TREND_STATS, K6_PROMETHEUS_RW_PUSH_INTERVAL, K6_PROMETHEUS_RW_STALE_MARKERS, and the native-histogram setting K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM). k6 also timestamps HTTP metrics when a request completes or times out, not when it starts, so a failure can appear seconds after it began.

- Observation (Milestone 1): Helm on this machine is 4.1.4. In Helm 4, `--wait` takes a strategy (watcher, hookOnly, or legacy) and defaults to hookOnly when omitted; a bare `--wait` means watcher, which is what the scripts use.
  Evidence: `helm upgrade --help` shows `--wait WaitStrategy[=watcher] ... (default hookOnly)`.

- Observation (Milestone 1): with zero tenant keys, the Strict tenant-auth policy is Accepted and every request gets 401, so a cluster is safe before any tenant exists.
  Evidence: `make check CLUSTER=shared` printed "agentgateway-system rejects requests without a key" with no tenant ConfigMaps.

- Observation (Milestone 1): the mock sustains 500 requests per second from one k6 Job with a p99 of 103.7 ms at its default 100 ms latency, with no failures and no dropped iterations.
  Evidence: `K6_SUMMARY {"reqs":30001,"rate":499.2,"failed":0,"dur":{"p(50)":101.1,"p(95)":102.3,"p(99)":103.7,"max":148.3},"dropped":0}`.

- Observation (Milestone 1): a failing command substitution inside an argument, such as `kube -n "$(tenant_scope_namespace)" logs`, does not stop a Bash script under `set -e`; the command ran against the default namespace. Assigning to a plain variable first (`namespace=$(...)`) does stop it.
  Evidence: `make logs CLUSTER=dedicated` without TENANT printed `deployments.apps "agentgateway-proxy" not found in namespace "default"` before the fix and "TENANT must look like tenant-01" after it.

- Observation (Milestone 1): footprint right after start in the shared cluster: Grafana 435 MiB, Prometheus 95 MiB, the agentgateway controller 39 MiB, the proxy 7 MiB, each mock replica 17 MiB, kube-state-metrics 24 MiB, the operator 22 MiB (working-set memory from cAdvisor).

- Observation: the first plan's workloads would have been throttled by the plan's own token limits.
  Evidence: at 50 requests per second with 100 completion tokens each, one tenant uses 300,000 completion tokens per minute before prompt tokens, against a 20,000 token-per-minute default limit. One 256 KiB ASCII prompt alone is about 65,536 prompt tokens under the mock's four-characters-per-token rule. Every workload now states its token use and the limit it runs under (see "Workload profiles" in Milestone 5).

- Observation: a backend's credential reference cannot cross namespaces, and a PreRouting policy can influence routing.
  Evidence: `kubectl explain agentgatewaybackend.spec.policies.auth.secretRef` lists only `group`, `key`, `kind`, and `name`, with no namespace, so a tenant's backend in the dedicated cluster can use only Secrets in its own namespace. `kubectl explain agentgatewaypolicy.spec.traffic.phase` says "PreRouting is typically used only when a policy needs to influence the routing decision" and that PreRouting policies must target a Gateway or Listener. `spec.traffic.transformation.request` supports `add`, `set`, `remove`, `body`, and `metadata`. Whether a PreRouting transformation runs after API key authentication, so that it can read `apiKey.tenant`, is unproven and is prototype P2.

- Observation: the shared design as chosen holds at most 16 tenants.
  Evidence: in the agentgateway-crds v1.5.0 chart, `AgentgatewayPolicy.spec.traffic.rateLimit.conditional` has `maxItems: 16` (and `spec.targetRefs` also has `maxItems: 16`). The second reviewer read `HTTPRoute.spec.rules.maxItems = 16` from the installed Gateway API 1.6.0 schema. One conditional entry and one route rule per tenant means tenant-17 fails admission.

- Observation: in agentgateway v1.5.0, gateway-level API key authentication runs before gateway transformations and route selection, authentication removes the consumed client credential before the request goes upstream, `transformation.request.set` overwrites a header, and `add` appends a value instead of filling a missing one. OpenAI-compatible request and response processing keeps custom headers such as x-probe-id and x-mock-key-owner.
  Evidence: second rubber-duck review of the v1.5.0 source, including crates/agentgateway/src/http/transformation_cel.rs lines 348 to 354 for `add`. P2 still confirms each point live.


## Decision Log

- Decision (Milestone 1): pinned K6_IMAGE=grafana/k6:2.3.0@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34, PYTHON_IMAGE=python:3.13-slim@sha256:8d9d0b8bcf6506481eae4907c18f5e3e7902e629f5f6d684f9e7c32e85e3ddf0 (both multi-architecture index digests), and KUBE_PROMETHEUS_STACK_VERSION=91.5.1 (Prometheus v3.14.0, operator v0.94.1).
  Rationale: latest stable releases on 2026-09-24, resolved with `docker buildx imagetools inspect` and `helm show chart`.
  Date/Author: 2026-09-24, Copilot.

- Decision (Milestone 1): Grafana's container memory limit is 1 GiB, not 512 MiB.
  Rationale: the Grafana pod used 435 MiB right after start in the shared cluster, too close to a 512 MiB limit.
  Date/Author: 2026-09-24, Copilot.

- Decision (Milestone 1): foundry.sh and prompt.sh became cluster-aware in Milestone 1 instead of Milestone 3. `gateway-configure` accepts CLUSTER=both and applies the Foundry objects to every gateway namespace of the selected cluster after checking for 401 without a key and with an invalid key. `foundry-up` no longer changes any cluster.
  Rationale: `make up` restores the Foundry connection, and the old code would have applied the retired single-user authentication objects.
  Date/Author: 2026-09-24, Copilot.

- Decision: build two Kind clusters named mtag-shared and mtag-dedicated. In mtag-shared, one agentgateway (one controller and one proxy) serves all tenants. In mtag-dedicated, each tenant namespace holds a full agentgateway installation (its own controller from its own Helm release and its own proxy).
  Rationale: the user wants grounded data on the two design ideas, "one gateway for everyone" and "a gateway per tenant", and chose a cluster per design so the designs never compete for one cluster's resources or share configuration. Variants such as a shared controller with per-tenant proxies were considered and dropped to keep the comparison simple.
  Date/Author: 2026-09-24, user and Copilot.

- Decision: use plain names everywhere (shared, dedicated, tenant-01) and never codes such as D1 or D2.
  Rationale: the user found variant codes confusing.
  Date/Author: 2026-09-24, user.

- Decision: a tenant is a client identity with exactly one API key and one token-per-minute limit that applies to the whole tenant. There are no users inside a tenant, no per-user limits, and no request-count limits.
  Rationale: the user asked to keep the spike as simple as possible. The future product lets tenant admins define policies for their users; that is recorded only as a structural finding for later.
  Date/Author: 2026-09-24, user.

- Decision: all tenants in both clusters share the existing Foundry deployment gateway-chat. It is not renamed or duplicated.
  Rationale: the spike compares gateway designs. Keeping the upstream identical means every difference in results comes from the gateway design. Azure deployment names cannot be changed in place, and the name has no design meaning.
  Date/Author: 2026-09-24, user.

- Decision: in the shared cluster, tenants are entries inside the gateway namespace agentgateway-system. Each tenant has a key ConfigMap. All tenants call one URL. One shared policy holds every tenant's limit as a conditional entry.
  Rationale: this is how a shared SaaS API works and is the simplest shared model to explain. It also makes the shared-object blast radius visible.
  Date/Author: 2026-09-24, user.

- Decision: no RBAC changes and no tenant-admin functionality. All commands run as the cluster owner. Structural facts that matter for future tenant-admin delegation (which objects hold a tenant's settings, and how many tenants share each object) are exposed by `make tenant-objects` and written up in the docs.
  Rationale: the user gave tenant admins as future context, not a requirement for this spike.
  Date/Author: 2026-09-24, user.

- Decision: measure eight criteria in both clusters: tenant separation, noisy neighbour, footprint, onboarding and offboarding, blast radius, per-tenant observability, configuration rollout, and gateway latency overhead.
  Rationale: the user selected all of them. "Configuration rollout" means applying one change to every tenant; version upgrades were removed from scope.
  Date/Author: 2026-09-24, user.

- Decision: trigger eight failure modes on purpose in both clusters: proxy crash, bad configuration for one tenant, the same API key defined for two tenants, one tenant flooding, slow upstream for one tenant, proxy memory exhaustion, controller outage, and upstream credential rotation. Shared CRD or version upgrades, upstream quota exhaustion, and GatewayClass conflicts are out of scope. (Later extended to ten by the cross-tenant leakage decision below.)
  Rationale: the user wants the designs' failure modes exposed deliberately, and removed upgrades from scope.
  Date/Author: 2026-09-24, user.

- Decision: load tests call an in-cluster mock of the OpenAI chat completions API. Real Foundry is used only for the separation checks and a small smoke test per tenant.
  Rationale: at 100 requests and 10,000 tokens per minute, Foundry would return 429 errors to every tenant in both designs, which measures the quota rather than the gateway, and Foundry latency noise would hide the gateway's own overhead.
  Date/Author: 2026-09-24, user.

- Decision: non-streaming responses only.
  Rationale: none of the eight failure modes needs streaming, and the user asked for simplicity. Streaming is a follow-up.
  Date/Author: 2026-09-24, user.

- Decision: generate load with k6 running as a Kubernetes Job inside each cluster, using k6's constant-arrival-rate executor and writing its metrics into that cluster's Prometheus.
  Rationale: k6 is a pinned public image with no build step. An open-loop load generator (one that keeps sending at the requested rate even when responses slow down) keeps overload visible instead of hiding it.
  Date/Author: 2026-09-24, user.

- Decision: a working set of three tenants (tenant-01 causes the problem, tenant-02 is the victim, tenant-03 is a bystander) and a scale sweep of 1, 5, 10, and 20 tenants. (Later changed to 1, 5, and 10; see the 16-entry limit decision below.)
  Rationale: three roles are the minimum for a noisy-neighbour test; 20 tenants is the largest step that plausibly fits on the machine.
  Date/Author: 2026-09-24, user.

- Decision: every controller and proxy pod in both clusters uses the same resources: requests 100m CPU and 128 MiB, limits 1 CPU and 512 MiB. Results always show the total reserved capacity next to each measurement.
  Rationale: this is how each design would be operated by default, and it is simple. The shared proxy serves all tenants within one pod's budget, which is a real property of the design.
  Date/Author: 2026-09-24, user.

- Decision: each cluster runs its own observability stack (kube-prometheus-stack trimmed to Prometheus, the Prometheus Operator, Grafana, and kube-state-metrics) with identical dashboards. Metrics and access logs only; no tracing.
  Rationale: the user wants observability to be first-class inside each cluster, and self-contained clusters keep the designs independent.
  Date/Author: 2026-09-24, user.

- Decision: one set of Make targets. `CLUSTER=shared|dedicated` is required on every command that touches a cluster and is never defaulted. Experiments and `make results` also accept `CLUSTER=both`, which runs the clusters one after the other, never in parallel.
  Rationale: the repository already refuses to guess a Kubernetes context, and one command set makes it obvious both designs are driven identically.
  Date/Author: 2026-09-24, user.

- Decision: every experiment follows the same sequence: check that all tenants are healthy before starting, start steady load for every tenant, trigger the failure, observe for 2 minutes, restore automatically even after an error or Ctrl-C, verify recovery, write a run record, and print a summary. `KEEP=1` skips the restore; `make restore` repairs the cluster afterwards.
  Rationale: automatic restore keeps each experiment starting from a known state so results are not silently contaminated.
  Date/Author: 2026-09-24, user.

- Decision: commit results under results/ with provenance (Git commit, clean or dirty tree, start and end times, versions, parameters). `make results` writes results/report.md, marks runs as stale when relevant files changed after the run's commit, and labels runs from uncommitted code. Each run includes time-bounded Grafana links; no PNG rendering.
  Rationale: the data is only grounded if every number in the report can be traced to a run and a commit. Grafana links work while a cluster exists; the committed JSON is the durable evidence.
  Date/Author: 2026-09-24, user.

- Decision: host ports. The shared cluster uses 38480 to 38489 and the dedicated cluster uses 38490 to 38499, with identical offsets: +0 gateway access for clients, +1 Kubernetes API, +2 temporary request port used by commands, +3 agentgateway admin UI, +4 Grafana, +5 Prometheus, +6 to +9 reserved. The old block 38470 to 38479 stays reserved for this project after the old cluster is retired.
  Rationale: the user runs many projects at once and never uses default ports; separate blocks let both clusters be forwarded at the same time.
  Date/Author: 2026-09-24, user.

- Decision: retire the existing cluster multi-tenant-ai-gateway once the shared cluster serves a real Foundry prompt. The Foundry account, project, and deployment stay.
  Rationale: one tenant in the shared cluster reproduces the old single-user setup, so keeping both would duplicate it.
  Date/Author: 2026-09-24, user.

- Decision: tenant API keys live in .env.tenants at the repository root, which is Git-ignored, never in .env. .env keeps only the Azure settings.
  Rationale: requested by the user. `git check-ignore -v .env.tenants` already reports `.gitignore:3:.env.*`.
  Date/Author: 2026-09-24, user.

- Decision: remove the offline test suite (tests/, `make test`, the fake tools). Each command and experiment validates itself live, and every live check must prove that the mechanism under test actually ran (for example, that the proxy pod's UID changed after a crash), not only that a command exited with status 0.
  Rationale: the user wants a proof of concept validated by live runs.
  Date/Author: 2026-09-24, user.

- Decision (proposed by Copilot, accepted by the user): the request's `model` field chooses the upstream. `gateway-chat` goes to Foundry and `mock-chat` goes to the mock. If prototype P2 shows agentgateway v1.5.0 cannot route on the model name, the mock is reached on the path prefix /mock/v1 instead, and this entry must be updated.
  Rationale: OpenAI-compatible clients already select models this way, so the client contract stays natural.
  Date/Author: 2026-09-24, Copilot.

- Decision (proposed by Copilot, accepted by the user): gateway latency overhead is measured by running k6 against the mock directly and through the gateway at the same rate; the difference is the gateway's cost.
  Rationale: this removes the mock's own latency from the result.
  Date/Author: 2026-09-24, Copilot.

- Decision (proposed by Copilot, accepted by the user): both clusters use a single Kind node.
  Rationale: all nodes would run on one laptop anyway, so extra nodes add no real separation. That the dedicated proxies still share one node's CPU is itself a finding.
  Date/Author: 2026-09-24, Copilot.

- Decision (made by Copilot while planning): the credential-rotation failure rotates the mock upstream's API key, not the real Azure key.
  Rationale: rotating the Azure key is a real cloud change that could break the project's only Foundry access and costs money to test under traffic. The mock accepts a configured key exactly as Foundry does, so the rotation mechanics (one Secret in the shared cluster, one Secret per tenant in the dedicated cluster) are identical. The docs must state that Azure also offers two keys for zero-downtime rotation, which this failure mode deliberately does not use.
  Date/Author: 2026-09-24, Copilot.

- Decision (made by Copilot while planning): in both designs, the tenant limit policy uses the conditional form with a CEL condition per tenant, even though a dedicated gateway has only one tenant.
  Rationale: the "bad configuration for one tenant" failure then injects the identical mistake into the identical kind of entry in both designs, so the only difference is whether the object is shared.
  Date/Author: 2026-09-24, Copilot.

- Decision (made by Copilot while planning): enforcement is checked by reading the proxy's effective configuration from its admin endpoint (port 15000, the same one the read-only dashboard uses), not only from Kubernetes status. (Later refined: automated reads go through the Kind node with nsenter, not a host port-forward.)
  Rationale: a policy can be accepted by Kubernetes yet absent from the proxy, or rejected while the proxy keeps an older copy. The bad-configuration, controller-outage, and rollout experiments must know what the proxy actually enforces.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): every workload has a fixed profile with its rate, prompt size, completion tokens, mock latency, and the tenant limit it runs under. Experiments that measure latency or resource pressure (latency, slow-upstream, proxy-memory) temporarily raise the causing tenant's limit, record the change in the recovery journal, restore it afterwards, and are invalid if any unexpected 429 appears. The flood keeps the default limit, because its purpose is to measure a tenant that the gateway is rejecting; `RAISE_LIMIT=1` repeats it with accepted traffic.
  Rationale: otherwise the gateway runs would measure fast 429 responses while the direct runs measure real work, and the comparison would be meaningless.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): impact, outage, and recovery come from per-probe records, not from Prometheus. The probe load writes one JSON line per request (tenant, start time, duration, status). Prometheus and Grafana remain the visual and time-series view. k6 pushes latency as native histograms so Grafana can show latency per time window, and every request carries a `phase` tag (baseline, observe, recover) so the end-of-run summary gives correct percentiles per phase.
  Rationale: k6's remote-write percentiles are cumulative for the whole run, and k6 timestamps requests at completion. Probe records with start times give exact failure episodes at a known precision.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): probe load and attack load run in separate k6 Jobs with separate CPU and memory. A run is invalid if any probe iteration was dropped, if the probes achieved less than 99 percent of their offered rate, or if the mock's CPU was throttled for more than 10 percent of the window. `make calibrate` proves, per cluster, that the mock and k6 sustain every workload profile without the gateway in the path.
  Rationale: if the load generator or the mock saturates, victim requests are delayed or never sent, and a design can falsely appear to protect its tenants.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): the other cluster is not paused during experiments. Each run records the other Kind node's CPU use from `docker stats`, refuses to start while the other cluster has a load Job running, and is marked "confounded" if the other node averaged more than 0.5 CPU.
  Rationale: pausing a Kind node container risks breaking that cluster, and recording the confound is simpler and honest.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): the proxy-crash failure kills the proxy process with SIGKILL from the Kind node (`crictl inspect` for the process ID, then `kill -KILL <pid>` inside the node), so the kubelet restarts the container in place.
  Rationale: pod deletion is a graceful shutdown, which is not the failure the user selected.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): before an experiment changes anything, it writes a recovery journal at .local/<cluster>/experiment.json (mode 0600) holding the original state it will change and the current stage. Restore converges the cluster to the journal's recorded state from any stage, is safe to repeat, and deletes the journal only after recovery passes. `make restore` reads the journal. Experiment cleanup runs as a hook inside the existing exit trap in scripts/common.sh.
  Rationale: rebuilding from the cluster's current records cannot undo a change to those same records, and a credential rotation interrupted halfway must still end consistent.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): each tenant's limit is recorded as the annotation gateway.dev/tokens-per-minute on its key ConfigMap in both designs, and the limit policy is always rendered from those annotations. A rollout therefore writes N records in both designs, then one shared policy or N tenant policies.
  Rationale: this keeps one source of truth, keeps both designs symmetric, and makes the rollout count honest.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): run validity is defined over the implementation inputs only (Makefile, scripts/, deploy/, versions.env, ports.env), including untracked files there, and never over results/. Each run records the commit and a content fingerprint of those inputs. Each run also records a configuration fingerprint (workload profile, tenant count, limits, mock replicas and latency, versions, windows), and the report compares only runs whose configuration fingerprints match. `CLUSTER=both` gives both runs one comparison ID.
  Rationale: the first result would otherwise make the tree dirty for the second cluster's run, and "latest valid run" from each cluster could compare different workloads.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): the latency scenario repeats three direct-and-gateway pairs with a 30-second warm-up, alternating which goes first, and reports the median and range of the percentile differences. The report calls these "differences in percentiles", not "per-request gateway cost".
  Rationale: a single fixed-order pair has no estimate of normal run-to-run variation.
  Date/Author: 2026-09-24, Copilot.

- Decision (rubber-duck review): onboarding records two times, when the tenant can first make a successful call and when the proxy enforces its limit, and is complete only when both are true. Offboarding records when access is revoked and when every tenant object is gone. Both designs use the same four definitions.
  Rationale: the first plan ended onboarding and offboarding at different lifecycle stages in the two designs.
  Date/Author: 2026-09-24, Copilot.

- Decision: add cross-tenant leakage. Each tenant gets its own mock provider key; Foundry stays one shared key. The mock reports which tenant's key it received, and every mock request in every scenario and failure checks that the key belongs to the sending tenant and that the response echoes the request's own probe ID. Two failures are added: wrong-credential (one tenant's backend entry points at another tenant's key) and forged-tenant-header (a client sends another tenant's name in the routing header). This amends the earlier decision that tenants share one upstream: they share the Foundry deployment and the mock service, but not the mock credential.
  Rationale: with one shared provider key, a request cannot reach "the wrong tenant's key", so leakage could not be observed. Credential leakage is likely the largest security difference between the designs.
  Date/Author: 2026-09-24, user.

- Decision: the upstream is chosen by path, not by the request's model name. POST /v1/chat/completions goes to Foundry, as today. POST /mock/v1/chat/completions goes to the requesting tenant's mock backend. In the shared cluster, a PreRouting policy overwrites the header x-tenant with the authenticated `apiKey.tenant`, and the mock route has one rule per tenant that matches that header and sends the request to that tenant's backend and key. This supersedes the earlier model-name decision.
  Rationale: per-tenant backends need a routing decision based on the tenant, and AgentgatewayModel matching supports only the model name. Path routes are the mechanism this repository already uses and has proven. Prototype P2 verifies the header approach; its fallback is a per-tenant path prefix guarded by an authorization rule.
  Date/Author: 2026-09-24, Copilot.

- Decision: the credential-rotation failure rotates tenant-01's own mock provider key. The mock stops accepting the old key first, then the gateway's copy is updated. The structural difference for the shared Foundry key (one Secret in the shared cluster, one per tenant in the dedicated cluster) is reported by `make tenant-objects` and the report, without rotating the real Azure key.
  Rationale: with per-tenant mock keys, a one-tenant rotation shows whether a credential change for one tenant disturbs the others (a configuration push to a shared proxy, or to one tenant's own proxy). Rotating the Azure key would break the project's only Foundry access.
  Date/Author: 2026-09-24, Copilot.

- Decision: shared provider quota exhaustion is parked. It is not built in this plan.
  Rationale: requested by the user. Facts kept for later: gateway-chat allows 10,000 tokens per minute in total, the plan's default tenant limit of 20,000 already overcommits it six times with three tenants, per-tenant gateways sit in front of the same quota, and local rate limits in separate proxies cannot cap the total across tenants without a global rate-limit service.
  Date/Author: 2026-09-24, user.

- Decision: the security review's five findings are accepted as risks for a local proof of concept and are not fixed: (1) `make dashboard` forwards the proxy admin port, whose unauthenticated /debug/trace can record live request headers, including tenant keys and the injected Foundry key, while the forward runs; (2) Make evaluates `$(...)` in command-line values; (3) curl reads the user's ~/.curlrc, so a verbose or trace setting there would print Authorization headers; (4) Prometheus's remote-write receiver has no authentication, so a local process could push fake samples while Prometheus is forwarded; (5) the mock's key admin endpoint has no authentication. `make dashboard`, `make prometheus`, and anonymous Grafana Viewer access stay. The Makefile still applies its existing `override VAR := $(value VAR)` and `export VAR` convention to every new variable, because that is how this repository passes values literally. Automated configuration read-back goes through the Kind node rather than a host port-forward, because the proxy-crash failure already needs that path.
  Rationale: the user judged none of these to be high risks for a local proof of concept. docs/tenancy-comparison.md records all five as known limitations.
  Date/Author: 2026-09-24, user.

- Decision: the plan claims digest pinning only for images it names itself (the Kind node, k6, and Python). Charts are pinned by version. Milestone 1 records the images each chart deploys, with their tags and resolved digests, in docs/local-development.md.
  Rationale: pinning a chart version does not pin the images that chart deploys. The security reviewer corrected the first plan's wording.
  Date/Author: 2026-09-24, Copilot.

- Decision: keep the shared design as chosen (one conditional limit policy and one mock route for all tenants) and sweep 1, 5, and 10 tenants in both clusters. The shared design's 16-tenant ceiling is reported as a structural finding, not tested.
  Rationale: the user chose to keep the design and shorten the sweep after the second review found that `rateLimit.conditional` and HTTPRoute `rules` each accept at most 16 entries.
  Date/Author: 2026-09-24, user.

- Decision (second rubber-duck review): every mock-bound request gets one verdict (verified, leak, blocked, unverifiable, or failed). Unverifiable responses invalidate a run's leakage check instead of passing it, and the separation scenario includes two positive controls that must be detected as leaks (a wrong key owner and a wrong echoed probe ID, the latter produced by the mock's x-mock-corrupt-id header).
  Rationale: gateway-generated 401 and 429 responses carry no mock headers and are not leaks, while a detector that has never been shown to fire proves nothing.
  Date/Author: 2026-09-24, Copilot.

- Decision (second rubber-duck review): experiment windows come from the recorded times of real mutations, and probe records are classified afterwards. The k6 script has no phase schedule.
  Rationale: Helm installs, restores, and rotations take variable time, so fixed offsets would put probes in the wrong window.
  Date/Author: 2026-09-24, Copilot.

- Decision (second rubber-duck review): the entry check (no journal exists) is separate from the recovery checks. The journal survives KEEP=1 and failed recovery. Credential rotation always rolls forward to the new key and verifies each mock replica individually.
  Rationale: recovery could otherwise never pass its own check, and an interrupted rotation needs one unambiguous destination.
  Date/Author: 2026-09-24, Copilot.

- Decision (second rubber-duck review): wrong-credential runs a reference mistake and a value mistake in both designs, and the dedicated result for the reference mistake is reported only as protection against cross-namespace references.
  Rationale: in the dedicated cluster a reference to another tenant's Secret name resolves locally to a missing Secret, which is not the same test as the shared cluster's existing wrong key. A wrong key value can happen in both designs.
  Date/Author: 2026-09-24, Copilot.

- Decision (second rubber-duck review): offboarding requires a healthy baseline, reports revocation as a bounded interval, and in the dedicated cluster deletes the tenant's GatewayClass explicitly. tenant-auth moves to Milestone 1, and the minimal probe runner is promoted at the end of Milestone 2, because Milestones 1 and 3 need them.
  Rationale: the controller-created GatewayClass is owned by neither Helm nor the namespace, and the first rewrite used both mechanisms before the milestone that introduced them.
  Date/Author: 2026-09-24, Copilot.


## Outcomes & Retrospective

Nothing has been implemented yet. At each milestone, record what now works, what remains, and what was learned.


## Context and Orientation

This section describes the repository as it is before this plan starts, for a reader who has never seen it.

The repository is a set of Bash scripts driven by a Makefile. It creates a local Kubernetes cluster with Kind, installs agentgateway into it, and connects agentgateway to a model deployed in Microsoft Foundry on Azure. There is no application code and no container build.

Kind ("Kubernetes in Docker") runs a whole Kubernetes cluster inside one Docker container, called the node. This project always uses Docker Desktop's desktop-linux Docker context. A namespace is a named partition inside one Kubernetes cluster; objects in different namespaces can share names. A CRD (custom resource definition) teaches Kubernetes a new object type; CRDs are cluster-wide, so every namespace shares one version of each. Helm installs a packaged set of Kubernetes objects called a chart; one installation is a release.

agentgateway is an open-source gateway for AI traffic. It has two parts. The controller is a Deployment that watches Kubernetes objects and turns them into configuration. The proxy is a separate Deployment that receives client requests and forwards them upstream; the controller pushes configuration to it over a gRPC channel called xDS. If the controller stops, the proxy keeps serving with its last configuration. agentgateway uses the standard Kubernetes Gateway API objects: a GatewayClass names which controller owns a kind of gateway; a Gateway asks that controller to create a proxy with listeners; an HTTPRoute sends matching requests to a backend. It adds its own objects: AgentgatewayParameters (proxy Deployment settings such as resources), AgentgatewayBackend (an upstream, such as the Foundry model), AgentgatewayPolicy (authentication, rate limits, telemetry, and more, attached to a Gateway or route through `targetRefs`), and AgentgatewayModel (a model entry that can match the request's model name).

A tenant, in this plan, is a client identity: one API key, one token-per-minute limit, and a name such as tenant-01. The upstream is where the gateway sends a request: the real Foundry deployment gateway-chat, or the mock added by this plan.

The files and what they do today:

Makefile maps every target to a script. Variables are passed through with `override VAR := $(value VAR)` followed by `export VAR`, which macOS's GNU Make 3.81 needs so values reach the scripts literally, without Make expanding `$` signs in prompts.

scripts/common.sh is sourced by every script. It sets `set -euo pipefail` and `umask 077`, and hardcodes CLUSTER=multi-tenant-ai-gateway, CONTEXT=kind-multi-tenant-ai-gateway, NAMESPACE=agentgateway-system, GATEWAY=agentgateway-proxy, and KUBECONFIG_FILE=.local/kubeconfig. It sources versions.env and ports.env. It provides output helpers (`section`, `info`, `ok`, `warn`, `die`, `row`) that write to standard error, with bold and colour only when standard error is a terminal, `NO_COLOR` is unset, and `TERM` is not dumb. It provides temporary files inside .local that a cleanup trap deletes on exit, and that trap also stops any port-forward child. `load_env` and `config` parse .env through scripts/env.jq, which accepts only literal KEY=value lines and never evaluates shell. `save_env` refuses a symlinked or Git-tracked .env, refuses to write unless .gitignore excludes it, merges new entries, and writes atomically at mode 0600. `docker_local` and `kind_local` pin Docker Desktop. `kube` and `helm_local` always pass the project kubeconfig and context. `cluster_exists`, `verify_cluster`, and `verify_context` confirm the Kind node's container ID, image, and API port against .local/cluster.json and check the kubeconfig's shape, so the scripts never act on a cluster they did not create. `port_free` fails if a port is taken and never kills anything. `start_forward` runs `kubectl port-forward` to the gateway Service on a given local port. `gateway_header` writes the Authorization header to a private temporary file so the key never appears in a process argument. `http_call` runs curl once with no retries. `wait_condition` waits for a Kubernetes condition. `confirm_action` asks for confirmation unless CONFIRM=1.

scripts/dev.sh implements help, doctor, up (create the cluster, install Gateway API CRDs from the pinned GitHub release, install the agentgateway-crds and agentgateway Helm releases from oci://cr.agentgateway.dev/charts, apply deploy/agentgateway/gateway.yaml, restore the Foundry connection, check the gateway), status, k9s, logs, dashboard, gateway-forward, and down.

scripts/foundry.sh handles Azure: registering Microsoft.CognitiveServices, discovering regions and models, provisioning one owned resource group, Foundry account, project, and model deployment, recording everything in .local/foundry.json with a phase (planned, provisioned, configured, cloud-deleted, deleted), writing .env, and configuring the gateway. Its `gateway_configure` function writes the hash of the single local client key into ConfigMap local-client-keys, applies deploy/agentgateway/auth.yaml (a Strict API key policy), checks that missing and invalid keys get HTTP 401, and only then applies the Azure key Secret foundry-provider and deploy/agentgateway/foundry.yaml.tmpl (AgentgatewayBackend foundry-model and HTTPRoute foundry-chat for POST /v1/chat/completions). `validate_connection` checks that .env matches the record, including AGENTGATEWAY_BASE_URL and AGENTGATEWAY_API_KEY. `cleanup_connection`, `gateway_restore`, `cloud_down`, and `foundry_up` complete the lifecycle.

scripts/prompt.sh sends one prompt through a temporary port-forward on REQUEST_PORT and validates that the answer is a real chat completion. scripts/env.jq parses .env; scripts/models.jq filters the model catalogue.

deploy/kind.yaml.tmpl is the Kind configuration (API server on 127.0.0.1 at KUBERNETES_PORT, one control-plane node). deploy/agentgateway/values.yaml holds controller Helm values (one replica, TLS for xDS, experimental Gateway API features off, `rbac.gatewayNamespaces: [agentgateway-system]`, and resources). deploy/agentgateway/gateway.yaml holds AgentgatewayParameters local-dev (ClusterIP Service, one replica, the resource settings) and Gateway agentgateway-proxy with one HTTP listener on port 80 that accepts routes from its own namespace.

versions.env pins Kind 0.31.0, the kindest/node v1.35.0 image by digest, Gateway API 1.6.0, and agentgateway v1.5.0. ports.env reserves 38470 to 38479. .env.example documents .env's keys without values. .gitignore excludes .local/, .env, .env.* (except .env.example), .DS_Store, and __pycache__/.

tests/ holds an offline suite with fake kubectl, kind, helm, and az tools (tests/fake_tool.py, tests/test_workflows.py, tests/dev-test.sh) and an opt-in live check (tests/test_runtime.py). This plan removes the whole directory.

README.md and docs/local-development.md describe the single-user environment.

The live state before this plan: the Kind cluster multi-tenant-ai-gateway is running (context kind-multi-tenant-ai-gateway, API on 127.0.0.1:38471) with the Foundry route configured. .local/foundry.json has phase configured for resource group rg-mtag-<owner prefix>, account ai-mtag-<owner prefix>, project gateway-dev, deployment gateway-chat (gpt-5.1, version 2025-11-13, GlobalStandard, capacity 10, the recorded region). .env holds the Azure settings, the Azure key, and the old single-user gateway key.


## Plan of Work

The work is eight milestones. Each ends with something a person can run and observe.

The overall shape of the finished repository is as follows. scripts/common.sh gains a `select_cluster` function that turns CLUSTER=shared or CLUSTER=dedicated into the Kind cluster name, context, per-cluster state directory, kubeconfig path, and port numbers. Because `CLUSTER` becomes the user-facing variable, the internal Kind name variable is renamed `KIND_CLUSTER` throughout. Per-cluster state lives in .local/shared/ and .local/dedicated/ (kubeconfig, cluster.json, kind.yaml, grafana-admin, and the recovery journal experiment.json while an experiment is active). .local/foundry.json stays at the top of .local because both clusters use the one Foundry deployment. New scripts are scripts/tenants.sh (tenant commands), scripts/load.sh (k6 Jobs and probe records), scripts/experiments.sh (calibration, scenarios, failures, restore, and scale), and scripts/results.sh (the report). scripts/dev.sh keeps cluster lifecycle and observability access. scripts/foundry.sh and scripts/prompt.sh become cluster-aware. New manifests live under deploy/mock/, deploy/observability/, and deploy/k6/, and deploy/agentgateway/ gains templates for the shared and per-tenant gateways. results/ holds committed run records and results/report.md.

Two helpers used throughout are defined here once. The node helper runs a command inside a cluster's Kind node container with `docker --context desktop-linux exec <node container ID>`, where the ID comes from the verified .local/<cluster>/cluster.json, never from a name lookup alone. It is used to find a proxy's process ID (`crictl ps` then `crictl inspect`, reading `.info.pid`), to read a proxy's effective configuration (`nsenter -t <pid> -n curl -s http://127.0.0.1:15000/config_dump`), and to kill a proxy process for the crash failure. The probe records are one JSON line per probe request, written by k6 to its log between the lines K6_PROBES_BEGIN and K6_PROBES_END, in the form {"tenant":"tenant-02","gateway":"agentgateway-proxy.tenant-02","sent_tenant_header":null,"start_ms":...,"duration_ms":...,"status":200,"probe_id":"...","echoed_probe_id":"...","key_owner":"tenant-02","verdict":"verified"}. Probe records never contain keys. Each mock-bound request gets one verdict: verified (a 200 whose key owner is the sending tenant and whose echoed probe ID matches), leak (any response carrying mock headers whose key owner is another tenant or whose echoed probe ID differs), blocked (an answer produced by the gateway itself, such as 401 or 429, which carries no mock headers), unverifiable (a 200 without the mock headers, which makes that run's leakage check invalid rather than passing it), or failed (connection errors, timeouts, and other errors). Experiments record the real time of every mutation (trigger start and end, restore start and end) in run.json, and probe records are assigned to the baseline, observe, and recover windows afterwards by their start times, so windows follow variable-length operations such as Helm installs or restores. Impact, outage, recovery, onboarding, offboarding, and leakage are all computed from probe records with jq. Per-window latency for streams that do not write records comes from Prometheus native histograms over the same real windows.

Kubernetes objects are generated with jq as JSON and applied with `kubectl apply --server-side`, as the repository already does for Secrets and ConfigMaps. sed substitution is used only for fixed templates whose substituted values have already passed a strict pattern check (tenant names must match `^tenant-[0-9]{2}$`). Server-side apply matters for Secrets because client-side apply would store the Secret's contents in a last-applied annotation.

Every new public Make variable (CLUSTER, TENANT, TOKENS_PER_MINUTE, UPSTREAM, RATE, DURATION, LATENCY_MS, PROMPT_BYTES, NAME, FAILURE, TENANTS, KEEP, RAISE_LIMIT) is added to the Makefile with the existing `override VAR := $(value VAR)` line and the matching `export` line, so values reach the scripts literally. Every script validates each value against a fixed pattern or list before use.

Every human-facing command keeps the repository's output style: named sections, aligned rows, bold headings and restrained colour only on terminals, plain text when NO_COLOR is set or output is captured, progress on standard error, machine-readable data (such as FORMAT=json) on standard output, full Helm and kubectl errors shown rather than hidden, and non-zero exit codes on failure.


### Milestone 1: two clusters from the same commands, with the mock upstream and observability

At the end of this milestone, `make up CLUSTER=shared` and `make up CLUSTER=dedicated` each create a Kind cluster with Gateway API, the agentgateway CRDs, the mock upstream, Prometheus, and Grafana. The shared cluster also has its one agentgateway controller and proxy. The dedicated cluster has no controller yet, because each tenant brings its own. The old offline tests are gone.

First, protect the old cluster's state, because the new scripts will not know its name. Move .local/kubeconfig, .local/cluster.json, and .local/kind.yaml into a new directory .local/legacy/ with `mv`. Do not touch the running old cluster. Add a temporary target `make legacy-down CONFIRM=1` to scripts/dev.sh that reads .local/legacy/cluster.json, confirms with `docker --context desktop-linux inspect multi-tenant-ai-gateway-control-plane` that the node's container ID and image match the record, refuses otherwise, runs `kind delete cluster --name multi-tenant-ai-gateway` with the legacy kubeconfig and Docker Desktop pinned, removes .local/legacy/, and removes AGENTGATEWAY_BASE_URL and AGENTGATEWAY_API_KEY from .env. Milestone 3 runs it; Milestone 8 deletes the target.

Delete tests/ and the `test` target from the Makefile, and remove `make test` from the help menu and docs.

Rewrite ports.env as the two blocks from the Decision Log, with names SHARED_GATEWAY_PORT=38480, SHARED_KUBERNETES_PORT=38481, SHARED_REQUEST_PORT=38482, SHARED_DASHBOARD_PORT=38483, SHARED_GRAFANA_PORT=38484, SHARED_PROMETHEUS_PORT=38485, and the same six names with the DEDICATED_ prefix at 38490 to 38495, plus comments reserving +6 to +9 of each block and 38470 to 38479.

In scripts/common.sh, add `select_cluster`. It reads CLUSTER from the environment, accepts only `shared` or `dedicated`, and otherwise stops with "Set CLUSTER=shared or CLUSTER=dedicated. No cluster is ever chosen for you." It sets KIND_CLUSTER=mtag-$CLUSTER, CONTEXT=kind-mtag-$CLUSTER, CLUSTER_STATE=.local/$CLUSTER, KUBECONFIG_FILE=$CLUSTER_STATE/kubeconfig, and GATEWAY_PORT, KUBERNETES_PORT, REQUEST_PORT, DASHBOARD_PORT, GRAFANA_PORT, and PROMETHEUS_PORT from the matching ports.env names. Scripts that accept CLUSTER=both call `for_each_cluster`, which runs shared then dedicated, each in a subshell so no variable leaks between clusters. Update `verify_cluster`, `verify_context`, `cluster_up`, and `down` to use these variables and the per-cluster cluster.json. Generalise `load_env` and `save_env` into `load_env_file <path>` and `save_env_file <path> <additions-json>` with the same checks, keeping `load_env` and `save_env` as wrappers for .env. Change `start_forward` to take a namespace and Service name, because the dedicated cluster has one gateway Service per tenant namespace. Add an `ON_EXIT_HOOKS` list to the existing `cleanup` trap: registered functions run first, in reverse order, and their failures are reported without stopping the rest of the cleanup, which then stops port-forwards and deletes temporary files as today. Experiments and load Jobs register their restore and deletion steps there, so one trap handles exit, Ctrl-C, and termination. Add the node helper functions `node_exec`, `proxy_pid <namespace>`, and `proxy_config <namespace>`.

Add to versions.env: KUBE_PROMETHEUS_STACK_VERSION (the latest stable kube-prometheus-stack chart version, pulled from oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack), K6_IMAGE (grafana/k6:2.3.0, the latest stable release on 2026-09-21, pinned by digest), and PYTHON_IMAGE (python:3.13-slim pinned by digest). Resolve each digest with `docker --context desktop-linux buildx imagetools inspect <image:tag>` and record the exact values in this plan's Decision Log. Use OCI chart references so no global `helm repo add` state is created. After both clusters are up, list every image the charts deployed with `kubectl get pods -A -o jsonpath` and record the tags and resolved digests in docs/local-development.md.

Create deploy/mock/server.py, a single-file Python standard library server built on `asyncio` so thousands of slow requests can wait at once without threads. It listens on port 8080 for API traffic and port 8081 for metrics and administration. Its accepted keys are a map from key to owner, loaded at start from /etc/mock/keys (one "owner key" pair per line, where the owner is a tenant name, mounted from Secret mock-upstream-keys) and replaceable at runtime by POST /admin/keys on port 8081, whose body is the new list in the same format. POST /v1/chat/completions requires `Authorization: Bearer <key>` or `api-key: <key>` with a known key; otherwise it returns HTTP 401 with an OpenAI-style error body. A valid request gets a chat.completion object whose `model` echoes the request, with one assistant message, `usage` set to prompt_tokens = ceiling(total characters of all message contents / 4), completion_tokens = the smaller of the request's `max_completion_tokens` (or `max_tokens`) and MOCK_COMPLETION_TOKENS (default 100), and their sum as total_tokens. Every response, including errors, carries the header x-mock-key-owner with the owner of the key it received (or `none`) and echoes the request header x-probe-id as x-mock-probe-id, so a client can prove which provider credential served it and that the response belongs to its own request. A request carrying x-mock-corrupt-id: 1 gets a deliberately wrong echoed ID; it exists only for the leak detector's positive control. The server waits MOCK_LATENCY_MS milliseconds (default 100) before answering, unless the request carries `x-mock-latency-ms` with an integer from 0 to 120000, which overrides it for that request. It reads the request body in chunks and keeps only a running character count, so large prompts do not accumulate in memory. GET /healthz returns 200. GET /metrics on port 8081 exposes mock_requests_total by status code and key owner, and mock_in_flight, as Prometheus text. It uses HTTP/1.1 keep-alive.

Create deploy/mock/mock.yaml: namespace mock-upstream; a Deployment `mock` with two replicas (Milestone 5's calibration may raise this; record any change here), image PYTHON_IMAGE, command `python /app/server.py`, the script mounted from a ConfigMap generated from deploy/mock/server.py, the Secret mock-upstream-keys mounted at /etc/mock, requests 500m CPU and 128 MiB, limits 2 CPU and 1 GiB, running as user 65534 with a read-only root filesystem, no privilege escalation, and no service account token; a Service `mock` for port 8080 (ClusterIP); and a PodMonitor for port 8081 at a 5-second interval. `make up` creates Secret mock-upstream-keys empty if it does not exist. The function `mock_push_keys` rebuilds that Secret from the cluster's tenant keys in .env.tenants, then sends the same list to each mock pod's POST /admin/keys through `kubectl exec` running Python's urllib against 127.0.0.1:8081, passing the list on standard input, and verifies each pod's key count. It is called whenever a tenant's mock key changes, so a restarted pod and a running pod always agree.

Create deploy/observability/values.yaml for kube-prometheus-stack, installed as release `monitoring` in namespace monitoring. Turn off Alertmanager, node-exporter, the default alerting rules, and the scrape jobs for etcd, the scheduler, the controller manager, and kube-proxy, which Kind does not expose. Keep the kubelet scrape at a 5-second interval, because its cAdvisor metrics give per-container CPU, CPU throttling, and memory, and keep kube-state-metrics, which gives pod counts, restarts, OOM kills, and resource requests. Configure Prometheus with 15 days of retention, a 5 GiB persistent volume on Kind's default local-path storage, `enableRemoteWriteReceiver: true` so k6 can push results, native histogram ingestion enabled (the `native-histograms` feature flag, or its successor setting in the pinned Prometheus version; prototype P4 confirms which), and `serviceMonitorSelectorNilUsesHelmValues: false` and `podMonitorSelectorNilUsesHelmValues: false` so it scrapes every ServiceMonitor and PodMonitor in the cluster. Configure Grafana with the dashboard sidecar watching all namespaces for the label grafana_dashboard=1, anonymous access with the Viewer role (so time-bounded links open without a login), and an admin password read from Secret grafana-admin, which `make up` creates from a random value saved to .local/<cluster>/grafana-admin at mode 0600. Every Service stays ClusterIP.

Create deploy/observability/dashboards/tenants.json, a Grafana dashboard with the fixed UID mtag-tenants and a `tenant` variable (multi-select, including All) taken from the `tenant` label. Panels: requests per second by tenant and status code; tokens per minute by tenant from the gateway's token metric; 429 responses per second by tenant; gateway latency p50, p95, and p99 by tenant; client latency by tenant from k6's native histograms; probe error rate and leak count by tenant; CPU, CPU throttling, and memory of every gateway pod (controllers and proxies); gateway pod count, restarts, and OOM kills; mock in-flight requests and requests by key owner; and Prometheus head series. The exact gateway metric names are recorded by prototype P1 and then written into this dashboard. `make up` applies it as ConfigMap mtag-dashboard-tenants in monitoring with label grafana_dashboard=1. `make up` also extracts the agentgateway chart's own dashboard once, with `helm template` using `monitoring.enabled=true` and `--show-only` for the dashboard template, and applies it the same way. Every agentgateway release in either cluster sets `monitoring.enabled: true` (without it the chart creates no ServiceMonitor or PodMonitor), sets the monitor interval to 5 seconds, and disables the chart's dashboard ConfigMap, so both clusters hold exactly one copy of each dashboard and the dedicated cluster does not load one copy per tenant.

Create namespace loadgen for k6 Jobs in `make up`, and ConfigMap k6-scripts from deploy/k6/ (the probe script is written at the end of Milestone 2 and extended in Milestone 5, before first use).

The `up` sequence in scripts/dev.sh becomes: `select_cluster`; `doctor`; create or verify the Kind cluster; install the Gateway API standard CRDs; install kube-prometheus-stack; install agentgateway-crds as Helm release agentgateway-crds in agentgateway-system; in the shared cluster only, install the agentgateway controller release, apply the shared Gateway (below), and apply AgentgatewayPolicy tenant-auth (Strict API key authentication in the PreRouting phase on Gateway agentgateway-proxy, selecting ConfigMaps labelled gateway.dev/component=tenant-key, so that with no tenants every request gets 401); install the mock; apply dashboards; create loadgen; restore Foundry objects and tenants if they exist (Milestones 3 and 4); and run `check`. Installing observability before any agentgateway release means the Prometheus Operator's ServiceMonitor and PodMonitor types exist when the agentgateway chart renders its monitors.

For the shared cluster, keep deploy/agentgateway/values.yaml for the one controller, adding the monitoring settings above, and keep deploy/agentgateway/gateway.yaml for AgentgatewayParameters and the Gateway agentgateway-proxy in agentgateway-system.

Every function in scripts/dev.sh that assumed one gateway changes as follows. `gateway_ready` in the shared cluster waits for the controller, the proxy, GatewayClass agentgateway, and the Gateway; in the dedicated cluster it waits for the CRDs, the mock, and monitoring, then for each tenant namespace's controller, proxy, GatewayClass, and Gateway. `check_gateway` defines healthy with zero tenants as: in the shared cluster, the Gateway is Programmed, tenant-auth is Accepted, and a request with no key gets 401; in the dedicated cluster, the shared components are ready and there is nothing else to check. For each tenant, it adds: no key gets 401, and the tenant's key on an unmatched path gets 404. No model request is made. `status` shows both clusters' state when CLUSTER=both, or one cluster's workloads, tenants, and routing otherwise. `gateway-forward`, `dashboard`, and `logs` take TENANT in the dedicated cluster (to pick the tenant's proxy) and ignore it in the shared cluster. `doctor` reports Docker Desktop's total memory and the memory used by running Kind nodes, and warns, without stopping, when less than 6 GiB remains. Add `make grafana CLUSTER=...` (port-forward Grafana to GRAFANA_PORT on 127.0.0.1 until Ctrl-C, printing the URL) and `make prometheus CLUSTER=...` (the same for Prometheus on PROMETHEUS_PORT). `down` deletes only the selected mtag- cluster after identity checks, and prints that .env, that cluster's .env.tenants entries, and Azure resources are kept.

Acceptance for Milestone 1: after `make up CLUSTER=shared` and `make up CLUSTER=dedicated`, `kind get clusters` lists mtag-shared and mtag-dedicated (and still multi-tenant-ai-gateway). In each cluster, `make status` shows the mock, Prometheus, and Grafana running; the shared cluster also shows agentgateway and agentgateway-proxy running and a request with no key gets 401; the dedicated cluster shows no agentgateway controller. `make grafana CLUSTER=shared` serves http://127.0.0.1:38484 and the mtag-tenants dashboard is listed. Prometheus's target page (through `make prometheus`) shows the kubelet, kube-state-metrics, the mock, and, in the shared cluster, the agentgateway controller and proxy as healthy. `make up` run a second time changes nothing and succeeds.


### Milestone 2: prototypes for the features the designs depend on

This milestone is prototyping. Its purpose is to prove, in the real clusters, each agentgateway and tooling behaviour the later milestones rely on, and to record the exact working configuration in Surprises & Discoveries. Prototype objects are applied by hand with `kubectl --kubeconfig .local/<cluster>/kubeconfig --context kind-mtag-<cluster>` into a namespace named proto (or agentgateway-system where the Gateway must be), and deleted afterwards. Nothing in this milestone is a Make target. A prototype is promoted when its acceptance holds; if it fails, the fallback named here becomes the design, and the Decision Log records why.

P1, tenant identity and telemetry from key metadata. In the shared cluster, create two key ConfigMaps with metadata {"tenant":"proto-a"} and {"tenant":"proto-b"} and a Strict API key policy on the Gateway. Add a conditional token limit policy with `apiKey.tenant == "proto-a"` at 200 tokens per minute and `apiKey.tenant == "proto-b"` at 100000, and a frontend policy adding a metrics attribute `tenant` with expression `apiKey.tenant` and the same attribute to access logs. Route a temporary path to the mock. Accept when: proto-a gets 429 after its budget is spent while proto-b continues to get 200 at the same time; the proxy's metrics on port 15020 show request and token metrics with tenant="proto-a" and tenant="proto-b"; access logs show the tenant; and the proxy's effective configuration read through the node helper shows both limits. Record the metric names for the dashboard, and the largest `tokens` value the CRD accepts. Also check whether the CEL expression can reference a missing metadata field without failing the request. Fallback if metrics cannot read `apiKey`: the P2 routing header x-tenant, which is always overwritten from the authenticated key, becomes the metrics attribute's source.

P2, per-tenant upstream selection in the shared cluster. Create two per-tenant mock backends: AgentgatewayBackend mock-proto-a and mock-proto-b, each an AI backend with an OpenAI-compatible provider pointed at http://mock.mock-upstream.svc:8080 and its own key from Secret mock-provider-proto-a or mock-provider-proto-b. Apply a PreRouting traffic policy on the Gateway whose request transformation sets (overwrites) the header x-tenant to `apiKey.tenant`, and HTTPRoute mock-chat for POST /mock/v1/chat/completions with one rule per tenant matching header x-tenant exactly and sending to that tenant's backend. Accept when: proto-a's requests arrive at the mock with proto-a's mock key (x-mock-key-owner is proto-a) and proto-b's with proto-b's; a proto-a request that sends `x-tenant: proto-b` still reaches proto-a's backend; the mock receives x-mock-latency-ms and x-probe-id and returns x-mock-key-owner and x-mock-probe-id to the client; the tenant's gateway API key is not forwarded to the mock; the path the AI backend sends upstream is recorded (the mock serves /v1/chat/completions; add a URL rewrite only if needed); token usage from the mock counts against the P1 limits; and the Foundry route for POST /v1/chat/completions still works alongside it (a fictional Foundry host is enough to see the routing decision). Also record what the gateway does when a backend's secretRef names a Secret that does not exist: whether it fails the request or sends it without credentials. Fallback if the PreRouting transformation cannot read `apiKey.tenant` or runs before authentication: per-tenant path prefixes /t/<tenant>/mock/v1/chat/completions with one route rule per tenant, and a PostRouting authorization policy allowing a request only when `request.path.startsWith("/t/" + apiKey.tenant + "/")`. The forged-tenant-header failure then forges the path instead of the header.

P3, two full agentgateway installations in one cluster. In the dedicated cluster, create namespaces proto-a and proto-b and install the agentgateway chart twice (releases agw-proto-a and agw-proto-b) with gatewayClassName agw-proto-a and agw-proto-b, controllerName agentgateway.dev/proto-a and agentgateway.dev/proto-b, `rbac.gatewayNamespaces` set to the release's own namespace, `discoveryNamespaceSelectors` matching only that namespace's `kubernetes.io/metadata.name` label, `monitoring.enabled: true` with the proxy PodMonitor selecting the release's own GatewayClass, and the chart dashboard off. Apply a Gateway in each namespace with its own GatewayClass. Accept when each controller creates and programs only its own Gateway (check each Gateway's status and each controller's logs), both proxies run, Prometheus shows both controllers and both proxies as healthy targets, and uninstalling one release leaves the other's traffic unaffected. Record the exact values paths (find the PodMonitor settings with `helm show values ... | grep -n -i podmonitor`). Also record `kubectl auth can-i list secrets --as=system:serviceaccount:proto-a:<controller service account> -n proto-b`, which is expected to print yes. Fallback: if `discoveryNamespaceSelectors` breaks the controller, leave it unset and record that each controller watches all namespaces.

P4, k6 metrics and probe records. Run a k6 Job in loadgen with `--out experimental-prometheus-rw`, K6_PROMETHEUS_RW_SERVER_URL set to the in-cluster Prometheus Service's /api/v1/write, K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true, K6_PROMETHEUS_RW_PUSH_INTERVAL=1s, and K6_PROMETHEUS_RW_STALE_MARKERS=true, tagging every request with cluster, tenant, run_id, and stream. The script sends to the mock directly for 60 seconds at 50 milliseconds latency, then 60 seconds at 500 milliseconds (set with x-mock-latency-ms from the elapsed time), writes probe records, and logs the switch time. Accept when: Grafana's latency panel, built on `histogram_quantile` over the native histogram, shows the step at the right minute; `histogram_quantile(0.95, ...)` over each real one-minute window gives about 50 and 500 milliseconds; and the probe records, split at the logged switch time, give the same two values. Fallback if Prometheus will not ingest native histograms: dashboards show gateway-side latency from the proxy's own histograms, and client latency comes only from probe records.

P5, proxy configuration read-back through the node. Use `proxy_config` to fetch /config_dump from a proxy and find the JSON paths that show each API key entry's metadata, the effective rate limits, and the routes. Accept when a script prints "tenant proto-a limit 200 tokens per minute" from it with jq, and the output contains no raw key or credential. Record the paths.

P6, a real proxy crash. Use the node helper to find a proxy's process ID and run `kill -KILL <pid>` inside the node. Accept when the proxy container restarts in place: the pod UID is unchanged, restartCount increased by exactly one, and lastState.terminated shows exit code 137 with a finishedAt time after the kill. Record how long the kubelet took to restart it.

At the end of this milestone, promote P4 into a minimal load runner, because Milestone 3's onboarding measurement needs it before Milestone 5 exists. deploy/k6/chat.js starts with probe streams only. scripts/load.sh provides `load_start <run-id> <role> <plan-json>`, which creates the Secret, ConfigMap, and Job and returns at once; `load_first_record <run-id> <role>`, which waits until the Job's log contains its first probe record; and `load_finish <run-id> <role>`, which stops the Job if it is still running, extracts the summary and probe records, and deletes the Job, ConfigMap, and Secret. `load_finish` is registered in ON_EXIT_HOOKS. Milestone 5 extends both files with attack streams, profiles, and calibration.

Delete every proto object and the proto namespaces afterwards. Acceptance for Milestone 2: each of P1 to P6 is recorded in Surprises & Discoveries as either promoted, with the exact configuration, or replaced by its fallback, with the evidence and a Decision Log entry.


### Milestone 3: tenants in the shared cluster, Foundry in the shared cluster, and retiring the old cluster

At the end of this milestone, `make tenant-add CLUSTER=shared TENANT=tenant-01` gives tenant-01 a working key, a token limit, its own mock provider key and backend, and telemetry in the shared gateway, and a real Foundry prompt succeeds through it. The old cluster is then retired.

Create scripts/tenants.sh with these commands.

`tenant-add` requires CLUSTER and TENANT (matching `^tenant-[0-9]{2}$`) and optional TOKENS_PER_MINUTE (a positive integer, default 20000, at most the CRD's maximum recorded in P1). It reads .env.tenants with `load_env_file`. If SHARED_TENANT_01_API_KEY (the gateway key) or SHARED_TENANT_01_MOCK_KEY (the tenant's mock provider key) is missing, it creates it with `openssl rand -hex 32` and saves it with `save_env_file`, which applies the same symlink, Git-tracking, ignore, and mode 0600 checks as .env. The variable names follow <CLUSTER in capitals>_<TENANT with the dash replaced by an underscore, in capitals>_API_KEY and _MOCK_KEY. Keys are never printed, never passed as command arguments, and never written to results. It then registers the tenant's mock key at the mock with `mock_push_keys`. This is provider-side setup, like a tenant bringing its own provider key, so it happens before the onboarding timer starts.

Onboarding is then measured. A probe Job for this tenant starts first (`load_start`, 5 requests per second to the tenant's gateway URL for the mock) and keeps running until onboarding completes or 5 minutes pass. Only after `load_first_record` returns does the command apply the tenant's objects, and the recorded time of the first apply is the onboarding start. In the shared cluster it applies, in agentgateway-system: ConfigMap tenant-01-key with labels gateway.dev/component=tenant-key and gateway.dev/tenant=tenant-01, annotation gateway.dev/tokens-per-minute=<limit>, and one data entry `tenant-01` holding {"keyHash":"sha256:<hex>","metadata":{"tenant":"tenant-01"}}; Secret mock-provider-tenant-01 with the tenant's mock key; and AgentgatewayBackend mock-tenant-01 using it. It then calls `render_shared`, which reads every tenant-key ConfigMap in agentgateway-system, sorts them by tenant, and applies AgentgatewayPolicy tenant-limits (one conditional entry per tenant, `apiKey.tenant == "tenant-01"` with a local limit of that many tokens per minute, taken from the annotation) and HTTPRoute mock-chat (one rule per tenant, as proven in P2). When no tenants remain, it deletes both. The cluster itself is the record of which tenants exist and what their limits are; there is no separate local list. Onboarding records two times from the probe records and the proxy read-back: usable (the first successful probe) and enforced (`proxy_config` shows the tenant's limit). It is complete when both are true. It also counts the objects created and the shared objects changed, writes results/<cluster>/<timestamp>-onboarding-<tenant>/run.json, and prints the result.

`make up CLUSTER=shared` now also applies, once, AgentgatewayPolicy tenant-routing (the PreRouting transformation whose `set` overwrites x-tenant with `apiKey.tenant`, from P2) and AgentgatewayPolicy tenant-telemetry (the frontend metrics and access log attributes from P1). tenant-auth already exists from Milestone 1.

`tenant-limit` changes one tenant's limit, or every tenant's when TENANT=all: it updates the annotations, then runs `render_shared` once. `tenant-remove CONFIRM=1` measures offboarding the same way: a probe Job runs with the tenant's key and must show at least 10 consecutive successful probes before anything is changed. The command then deletes the tenant's ConfigMap, Secret, and backend and reruns `render_shared`. Offboarding records revoked as an interval, from the last successful probe to the first probe after the first deletion that begins 25 consecutive failures, and reports that interval rather than a single moment. It also records cleaned (every object that held the tenant's settings is gone and the rendered policy and route no longer mention the tenant). It then removes the tenant's keys from .env.tenants and the mock. `tenants` lists each tenant with its limit and state. `tenant-objects TENANT=...` lists every Kubernetes object that holds any of that tenant's settings, and for each one, how many tenants share it. In the shared cluster this shows tenant-01-key, mock-provider-tenant-01, and mock-tenant-01 used by 1 tenant, and tenant-limits, mock-chat, tenant-auth, tenant-routing, tenant-telemetry, the Gateway, the proxy Deployment, the controller, and foundry-provider shared by N tenants. `gateway-config TENANT=...` prints what the proxy actually enforces for that tenant, using `proxy_config` and the P5 paths.

Change scripts/foundry.sh so the Foundry connection no longer involves a single-user key. `persist_config` stops writing AGENTGATEWAY_BASE_URL and AGENTGATEWAY_API_KEY, and `validate_connection` stops checking them. `foundry_up` stops after provisioning and saving .env, and prints the next step `make gateway-configure CLUSTER=shared` (or dedicated), instead of configuring and checking the old single gateway. `gateway_configure` requires CLUSTER: it confirms tenant-auth is Accepted and that a request with no key gets 401 through a port-forward, and only then applies Secret foundry-provider and the Foundry backend and route (unchanged from today apart from their namespace) into agentgateway-system (shared) or into every tenant namespace (dedicated, Milestone 4). `endpoints` requires CLUSTER and shows the Foundry URLs plus, for each tenant, how to reach its gateway (`make gateway-forward CLUSTER=... [TENANT=...]` and the local URL), never a key. `make up` calls `gateway_configure` when .local/foundry.json has phase configured. `cleanup_connection` removes the Foundry objects from every mtag- cluster that exists. `gateway_restore` keeps its phase handling for the selected cluster. Update .env.example to match.

Change scripts/prompt.sh to require CLUSTER and TENANT, accept UPSTREAM=foundry (default) or UPSTREAM=mock, read the tenant's key from .env.tenants, use /v1/chat/completions with model gateway-chat for Foundry or /mock/v1/chat/completions with model mock-chat for the mock, port-forward to the right gateway Service, and keep every existing safety and validation behaviour. For the mock it also prints the x-mock-key-owner it received. The Foundry cost warning stays for UPSTREAM=foundry.

Then retire the old cluster: run `make tenant-add CLUSTER=shared TENANT=tenant-01`, `make gateway-configure CLUSTER=shared`, and `make prompt CLUSTER=shared TENANT=tenant-01 PROMPT="Say hello in one sentence."`. When that prints a real model answer, run `make legacy-down CONFIRM=1`.

Acceptance for Milestone 3: with tenant-01, tenant-02, and tenant-03 added, each tenant's key gets 200 from the mock through one gateway URL, with x-mock-key-owner equal to that tenant; a request with no key or a wrong key gets 401; after tenant-01 spends its budget it gets 429 while tenant-02 still gets 200; the mtag-tenants dashboard shows the three tenants separately; `make tenant-objects CLUSTER=shared TENANT=tenant-02` lists the shared objects; the Foundry prompt succeeds; and after `make legacy-down CONFIRM=1`, `kind get clusters` no longer lists multi-tenant-ai-gateway and port 38471 is free.


### Milestone 4: tenants in the dedicated cluster

At the end of this milestone, `make tenant-add CLUSTER=dedicated TENANT=tenant-01` creates namespace tenant-01 with its own agentgateway controller and proxy, its own key, limit, mock provider key, and telemetry, and its own copy of the Foundry key, and the tenant can call the mock and Foundry through its own gateway.

In scripts/tenants.sh, the dedicated branch of `tenant-add` creates the keys and registers the mock key exactly as in the shared cluster, and starts the onboarding probe the same way. It then creates namespace tenant-01 with label gateway.dev/tenant=tenant-01; installs Helm release agw-tenant-01 of the agentgateway chart at AGENTGATEWAY_VERSION into it with the new file deploy/agentgateway/tenant-values.yaml (the same controller settings, resources, and monitoring settings as the shared controller, the chart dashboard off) plus the per-tenant values proven in P3 (GatewayClass agw-tenant-01, controller name agentgateway.dev/tenant-01, `rbac.gatewayNamespaces` of tenant-01, discovery limited to tenant-01, PodMonitor for agw-tenant-01); applies AgentgatewayParameters tenant-proxy and Gateway agentgateway-proxy (from the new template deploy/agentgateway/tenant-gateway.yaml.tmpl, with the same resource settings as the shared proxy); and applies, all in tenant-01 and targeting that tenant's Gateway: ConfigMap tenant-key (same content and annotation as in the shared cluster), policies tenant-auth, tenant-limits (rendered from the annotation, in the conditional form with the single entry for this tenant), and tenant-telemetry, Secret mock-provider with the tenant's mock key, AgentgatewayBackend mock, and HTTPRoute mock-chat with a single rule. The dedicated gateway needs no tenant-routing policy, because it serves one tenant. If Foundry is configured, it also applies Secret foundry-provider and the Foundry backend and route. Onboarding is recorded with the same two times as in the shared cluster.

`tenant-limit` updates the annotation, then renders only that tenant's tenant-limits policy (for TENANT=all, every tenant's in turn). `tenant-remove CONFIRM=1` runs the offboarding probe with the same healthy baseline, then deletes the tenant's Gateway and waits for its proxy to go, uninstalls the Helm release, deletes GatewayClass agw-tenant-NN after confirming its controllerName is agentgateway.dev/tenant-NN (the controller creates this class, so neither Helm nor namespace deletion removes it), and deletes the namespace. It records revoked as the same bounded interval as in the shared cluster, and cleaned when the namespace, the GatewayClass, and the tenant's cluster roles are gone. `tenant-objects` shows that every namespaced object is used by one tenant, and also lists what the tenant still shares: the CRDs, the tenant controller's ClusterRoles (with the note that they can read Secrets in every namespace), the node, the mock service, and the Foundry deployment, whose key now exists as N copies. `make up CLUSTER=dedicated` restores the Foundry objects in every existing tenant namespace.

Acceptance for Milestone 4: with tenant-01 to tenant-03 added, `kubectl get gatewayclass` lists agw-tenant-01, agw-tenant-02, and agw-tenant-03, each accepted by its own controller; each tenant's key works only against its own gateway (tenant-01's key against tenant-02's gateway gets 401); each tenant's mock traffic carries its own x-mock-key-owner; limits and 429s behave as in the shared cluster; the dashboard shows the three tenants; `make prompt CLUSTER=dedicated TENANT=tenant-02` returns a real model answer; and removing tenant-03 leaves tenant-01 and tenant-02 serving without a single failed probe during the removal.


### Milestone 5: prompts, load, calibration, and the non-failure scenarios

At the end of this milestone, `make load` drives any mix of tenants from inside the cluster, `make calibrate` proves the load generator and the mock are not the bottleneck, and `make scenario` runs the separation, latency, rollout, and Foundry smoke scenarios in either or both clusters, writing run records.

Workload profiles. The mock counts prompt tokens as characters divided by four, rounded up, and completion tokens as the smaller of the request's max_completion_tokens and 100. Every experiment uses one of these profiles, and its run record stores the profile, the rate, and the limit in force.

    probe       5 requests/s per tenant, 40-character prompt (10 tokens), max_completion_tokens 16,
                100 ms mock latency: about 26 tokens per request and 7,800 tokens per minute,
                under the default 20,000 limit. Timing precision is 200 ms.
    latency     50 requests/s, the probe request, 100 ms mock latency. The tenant's limit is
                raised for the run; any 429 makes the run invalid.
    flood       2,000 requests/s, the probe request, the default limit, so most requests get 429
                by design. RAISE_LIMIT=1 repeats it with a raised limit, so the flood is accepted.
    slow        50 requests/s, the probe request, 30,000 ms mock latency (about 1,500 requests in
                flight), raised limit.
    memory      50 requests/s, 256 KiB prompt (about 65,536 tokens), max_completion_tokens 16,
                30,000 ms mock latency, raised limit.
    scale       1 request/s per tenant, the probe request, default limit.

"Raised limit" means the CRD's maximum recorded in P1 (or 1,000,000,000 tokens per minute if there is no lower maximum), written into the recovery journal before the change and restored afterwards.

Create deploy/k6/chat.js. It reads a plan from /etc/k6/plan.json: a list of streams, each with tenant, url, profile values (rate, prompt_bytes, max_completion_tokens, latency_ms), start_delay, duration, and whether it writes per-request records. For each stream it defines a k6 scenario with the constant-arrival-rate executor, preallocated virtual users sized from rate times expected latency, and a maximum large enough to keep sending during slowdowns. Each stream reads its tenant's key from /etc/k6/keys/<tenant> at start. Every request carries a new x-probe-id and, when set, x-mock-latency-ms, and is tagged with cluster, tenant, run_id, and stream. For mock-bound requests it assigns the verdict defined in the Plan of Work introduction and counts leak and unverifiable verdicts in the `leaks` and `unverifiable` counters. Probe streams, latency streams, and onboarding streams write per-request records; attack streams do not. A stream can also send a fixed x-tenant value, which is recorded as sent_tenant_header. `handleSummary` prints the JSON summary, including dropped_iterations per stream, between K6_SUMMARY_BEGIN and K6_SUMMARY_END. Direct-to-mock streams (latency and calibration only) send the tenant's mock key straight to the mock Service.

Create scripts/load.sh with `run_load <run-id> <role> <plan-json>`, where role is probe or attack. It creates, in loadgen, a Secret load-<run-id>-<role>-keys holding only the involved tenants' keys (built in a private temporary file and applied with server-side apply, never through command arguments), a ConfigMap load-<run-id>-<role>-plan, and a Job load-<run-id>-<role> using K6_IMAGE with the k6-scripts ConfigMap and the P4 remote-write settings. Probe Jobs request 1 CPU and 512 MiB with limits of 2 CPU and 1 GiB; attack Jobs request 2 CPU and 1 GiB with limits of 4 CPU and 2 GiB. So probes and attacks never compete inside one k6 process. `run_load <run-id> <role> <plan-json>` is `load_start`, a wait for completion, and `load_finish`. Everything carries label gateway.dev/run=<run-id>, and deletion is registered in ON_EXIT_HOOKS. It extracts the summary and probe records from the Job log. `make load CLUSTER=... TENANT=... PROFILE=... [DURATION=...] [RATE=...] [UPSTREAM=mock]` runs one attack stream plus probes for every tenant and prints the summary. Gateway URLs inside the cluster are http://agentgateway-proxy.agentgateway-system.svc/... for every tenant in the shared cluster and http://agentgateway-proxy.tenant-NN.svc/... in the dedicated cluster.

Create scripts/experiments.sh with a common runner used by every calibration, scenario, failure, and scale step. Before starting, it refuses to run while the other mtag- cluster has an active load Job. It records the Git commit, the input fingerprint (a SHA-256 over the path and content hash of every tracked or untracked, non-ignored file under Makefile, scripts/, deploy/, versions.env, and ports.env), whether those inputs match the commit (`git status --porcelain` on those paths is empty), the configuration fingerprint (a SHA-256 of the canonical JSON of profile, rates, tenant count, limits, mock replicas and latency, windows, and versions), the comparison ID when run with CLUSTER=both, the start time, and versions. results/ is never part of either fingerprint. During the run it samples the other Kind node's CPU with `docker stats --no-stream` every 5 seconds. It writes results/<cluster>/<UTC time as YYYYMMDDTHHMMSSZ>-<kind>-<name>/ containing run.json, k6-summary.json for each Job, probes.jsonl, prometheus.json (every Prometheus query used, with its expression, time range, and answer), events.json (Kubernetes events inside the run window), and summary.txt (exactly what was printed). run.json also holds `grafana` links: http://127.0.0.1:<GRAFANA_PORT>/d/mtag-tenants?from=<start ms>&to=<end ms>&var-tenant=All and the same range for the agentgateway dashboard. Prometheus is queried through a short-lived port-forward on PROMETHEUS_PORT.

Every run is checked for validity, and the reasons are written to run.json. A run is invalid when any probe iteration was dropped, when the probes achieved less than 99 percent of their offered rate, when the mock's CPU was throttled in more than 10 percent of the observe window (from cAdvisor's throttled periods), when a k6 or mock container was OOM-killed, when a raised-limit profile saw any 429, when an attack stream dropped iterations or achieved less than 80 percent of its target rate (unless the failure defines a different check), when any response was unverifiable, or when the failure's invocation check did not pass. A run is marked confounded when the other Kind node averaged more than 0.5 CPU.

`make calibrate CLUSTER=...|both` runs the flood, slow, memory, and latency profiles for 2 minutes each directly against the mock, with probe streams for three tenants alongside, and records the achieved rates, dropped iterations, mock errors, mock CPU and throttling, k6 CPU, and mock in-flight requests. A profile passes only when every stream achieved at least 95 percent of its target rate with no dropped iterations, the mock returned no errors, the mock's p99 was within 20 percent of its configured latency, and the mock was throttled in less than 10 percent of the window. If any profile fails, raise the mock's replicas or the k6 Job's resources, record the change in the Decision Log, and rerun. Every experiment records which calibration run matches its configuration, and the report shows it.

`make scenario NAME=separation` checks, in the selected cluster or both: no key gets 401; an invalid key gets 401; each tenant's key gets 200 from the mock with its own key owner; in the dedicated cluster, each tenant's key gets 401 from every other tenant's gateway; tenant-01 spending its budget gets 429 while tenant-02 and tenant-03 keep 200; the gateway's metrics attribute every request to the right tenant; zero leak and zero unverifiable verdicts across all probes; two positive controls prove the detector works, one sending tenant-02's mock key directly to the mock from a tenant-01 stream (which must be classified as a leak) and one sending the header x-mock-corrupt-id, which makes the mock echo a wrong probe ID (which must also be classified as a leak); and it records, without changing anything, `kubectl auth can-i list secrets` for the controller service account or accounts against another tenant's namespace (dedicated) or against agentgateway-system (shared). Each check is pass or fail with its evidence.

`make scenario NAME=latency` raises tenant-01's limit, then runs three pairs of 2-minute measurements with the latency profile, each preceded by a 30-second warm-up, alternating which of direct-to-mock and through-the-gateway goes first. The percentiles come from per-request records of the measured 2 minutes only, excluding the warm-up. It reports, per pair and as the median and range across pairs, the differences in p50, p95, and p99, and restores the limit.

`make scenario NAME=rollout` sets every tenant's limit to a new value with `tenant-limit TENANT=all`, measures the time until `proxy_config` shows the new limit for every tenant, counts the records written (N in both designs) and the enforcement objects written (1 in the shared cluster, N in the dedicated cluster), and restores the original limits from the journal.

`make scenario NAME=foundry-smoke CONFIRM=1` sends one real prompt per tenant through Foundry with max_completion_tokens 32 and reports each status. It refuses without CONFIRM=1 and repeats the cost warning.

Acceptance for Milestone 5: `make calibrate CLUSTER=both` produces valid runs for every profile; `make scenario CLUSTER=both NAME=separation` prints a pass or fail table for each cluster with zero leaks and writes two run directories sharing one comparison ID; `make scenario CLUSTER=both NAME=latency` reports percentile differences with their range for each cluster; and each run.json opens its Grafana links on the right time range.


### Milestone 6: the ten failure modes

At the end of this milestone, `make break CLUSTER=shared|dedicated|both FAILURE=<name>` runs each failure with the common runner.

Every run follows the same steps. The entry check confirms that no recovery journal exists, and then runs the recovery checks: all three working-set tenants exist, every gateway pod is ready, every policy is Accepted, and each tenant gets a verified 200 from the mock. The runner writes the recovery journal .local/<cluster>/experiment.json (mode 0600) with the run ID, the failure, the stage, and the original state of everything the failure will change, for example every tenant's limit annotation, tenant-02's key hash, controller replica counts, or tenant-01's old and new mock keys. It registers restore in ON_EXIT_HOOKS. It starts probe streams for all three tenants and runs 30 seconds of baseline, then triggers the failure against tenant-01 or the component that serves it and updates the journal stage. It observes for 2 minutes, then restores unless KEEP=1. Probes keep running through restore and recovery. Recovery is verified with the recovery checks (never the entry check, because the journal still exists), within 5 minutes. The runner writes the run record in every case, and deletes the journal only when restore ran and recovery passed. With KEEP=1, or when recovery fails, the journal stays and the summary says to run `make restore`. `make restore CLUSTER=...` reads the journal, if one exists, and converges the cluster to the journal's original state from whatever stage it reached. It then removes anything labelled gateway.dev/run, reruns `render_shared` in the shared cluster or re-renders every tenant's policies in the dedicated cluster, reruns `mock_push_keys`, scales controllers back to one, runs the recovery checks, and deletes the journal only when they pass. Every restore step is safe to repeat.

For each tenant, the summary reports, from probe records: any impact (at least one failed probe, or one slower than five times its baseline p95); material impact (more than 1 percent failed, or an observe-phase p95 more than twice its baseline p95); failure episodes (runs of consecutive failed probes, each lasting from the start of its first failed probe to the start of the next successful one); total failed time; the status codes seen; leaks; and recovery time (from the trigger, and separately from the start of restore, to the first of 25 consecutive successful probes). Timing precision is stated as 200 ms. For the tenant causing the failure, expected 429s are reported separately from errors. Each failure also has an invocation check that proves the failure really happened; if it fails, the run is invalid and says so, rather than reporting "no impact".

proxy-crash kills the proxy process serving tenant-01 (the one shared proxy, or tenant-01's own) with SIGKILL through the node helper, as proven in P6. Invocation check: that container's restartCount rose by exactly one and lastState.terminated shows exit code 137 with a finishedAt inside the run window.

bad-tenant-config replaces tenant-01's conditional entry with an invalid CEL expression (for example `apiKey.tenant ==`) in the policy that holds it (the shared tenant-limits, or tenant-01's own). It records the policy's status, `proxy_config` for every tenant's limit, and traffic. Invocation check: the applied object contains the invalid expression. The restore re-renders the correct policy from the annotations.

duplicate-key changes tenant-02's key entry so it carries tenant-01's key hash, keeping tenant-02's metadata. In the dedicated cluster, the probes also send tenant-01's key to tenant-02's gateway during the window. It records which tenant label tenant-01's traffic gets, which limit applies to it, which mock key owner serves it (a leak if tenant-01's traffic reaches tenant-02's provider key), and whether tenant-02's real key still works. Invocation check: both entries hold the same hash. The restore reapplies tenant-02's correct hash from .env.tenants.

flood runs the flood profile for tenant-01 (RATE overrides the rate; RAISE_LIMIT=1 raises the limit so the flood is accepted). Invocation check: with the default limit, tenant-01 received 429 responses and its achieved rate reached at least 80 percent of the target; with RAISE_LIMIT=1, the mock received at least 80 percent of the target rate. It records the CPU and throttling of every gateway pod and of the node.

slow-upstream runs the slow profile for tenant-01. Invocation check: mock_in_flight rose above 1,000.

proxy-memory runs the memory profile for tenant-01 (prompt size and latency configurable). Before triggering, the runner records the proxy container's restartCount and last termination. Invocation check: a new OOMKilled termination with a finishedAt inside the run window. If none happens, the run is marked "no OOM at these parameters" with the maximum sampled working-set memory and the scrape interval, rather than claiming the proxy is safe. An OOM of a k6 or mock container makes the run invalid.

controller-outage scales the controller serving tenant-01 to zero, confirms traffic keeps flowing, then changes tenant-01's limit and, in the dedicated cluster, also tenant-02's. It records, from `proxy_config`, which changes took effect during the outage. Invocation check: the controller Deployment has zero ready replicas. The restore scales it back, confirms the pending change applies, and restores the original limits from the journal.

credential-rotation rotates tenant-01's mock provider key. Stage 1 creates the new key and saves it to .env.tenants, with the old key kept in the journal. Stage 2 makes the mock accept only the new key for tenant-01, through `mock_push_keys`, which updates the Secret and every mock pod. Stage 3 updates tenant-01's gateway copy (Secret mock-provider-tenant-01 in the shared cluster, or mock-provider in tenant-01). The journal stage is updated after each stage. It records how long tenant-01's requests failed with 401 from the mock, and whether tenant-02 and tenant-03 saw any impact while the configuration change reached their proxy (the shared proxy, or none). Invocation check: on every mock replica, the old key gets 401. Rotation always rolls forward: the journal records the direction as forward, and its restore converges the mock Secret, every mock pod, and the gateway copy to the new key in .env.tenants, from any stage, instead of returning to the original state as other failures do. Both the invocation check and the recovery check test every mock replica individually: for each mock pod, `kubectl exec` sends a request to that pod's own 127.0.0.1:8080, with the key passed on standard input, and confirms the new key is accepted and the old key gets 401.

wrong-credential has two halves of one minute each, and both designs run both. The first half is a reference mistake: tenant-02's mock backend is edited to reference a Secret named mock-provider-tenant-01. In the shared cluster that Secret exists and holds tenant-01's key, so a leak is expected. In the dedicated cluster the name resolves only inside tenant-02's namespace, where no such Secret exists, so the result shows what the gateway does with a missing reference (P2 recorded whether it fails the request or sends it without credentials). The report states this narrowly, as protection against cross-namespace reference mistakes. The second half is a value mistake: the reference is restored, and tenant-02's own provider Secret is overwritten with tenant-01's mock key, which a leak check must detect in both designs, because a namespace does not protect against a wrong value. It records the backend's status, the key owner seen on tenant-02's traffic, and leaks per half. Invocation check: the applied backend references mock-provider-tenant-01 in the first half, and tenant-02's Secret holds tenant-01's key hash in the second (compared by hash, never printed). The restore reapplies the correct reference and tenant-02's key from .env.tenants.

forged-tenant-header makes tenant-01's probes send `x-tenant: tenant-02` for the whole run. The observe window has two halves. In the first minute the configuration is correct, and no leak is expected. In the second minute, in the shared cluster only, the tenant-routing policy's `set` value is changed to a CEL expression that keeps a client-supplied x-tenant when present and uses `apiKey.tenant` only when it is missing (not the transformation's `add`, which appends a second value rather than filling a gap). This simulates a platform configuration mistake, and tenant-01 is then expected to reach tenant-02's backend and key. In the dedicated cluster, the header means nothing to tenant-01's gateway, and the probes also send tenant-01's key with the forged header to tenant-02's gateway, which should answer 401. It records leaks per half. Invocation check: the probe records show the forged header was sent, and in the shared cluster the applied policy in the second half no longer overwrites it. The restore reapplies the correct tenant-routing policy. If P2 fell back to path prefixes, the forged value is the path and the simulated mistake removes the authorization rule.

Acceptance for Milestone 6: each of the ten failures runs to completion in both clusters with a valid invocation check (or an honest "not reproduced" result for proxy-memory), the clusters pass recovery afterwards with no journal left behind, and the summaries show which tenants were affected and whether anything leaked in each design.


### Milestone 7: scale sweep and onboarding

At the end of this milestone, `make scale CLUSTER=shared|dedicated|both TENANTS=1,5,10` measures footprint and onboarding at each step and then returns to the three-tenant working set. With a single number, for example TENANTS=3, it only converges to that many tenants and records the footprint.

For each step, the runner adds or removes tenants in order (tenant-01 upward) through the same functions as `tenant-add` and `tenant-remove`, so every onboarding and offboarding is recorded. It waits 60 seconds idle and samples, then runs the scale profile for every tenant for 2 minutes and samples again. Each sample records, from Prometheus: the summed and per-pod CPU and memory (cAdvisor working-set memory, stated as "maximum sampled" with its 5-second scrape interval) of gateway pods only (controllers and proxies; the monitoring, mock, and loadgen namespaces are excluded); the gateway pod count; the reserved requests and limits from kube-state-metrics; the number of active gateway time series (series from gateway pods present at the sample time); and, separately, Prometheus's total head series as a storage-history figure that includes earlier runs. It also records the Kind node container's memory from Docker. The sweep stops early, records why, and still returns to three tenants when a pod stays Pending for 2 minutes, the node reports memory pressure, or Docker Desktop has less than 2 GiB free. Footprint is compared between clusters only at the same tenant count. The shared design cannot go beyond 16 tenants as designed, because one conditional rate-limit policy and one HTTPRoute each hold at most 16 entries; the report states this as a structural finding, and the sweep does not test it.

Acceptance for Milestone 7: `make scale CLUSTER=both TENANTS=1,5,10` completes or stops with a recorded reason, writes one run per step per cluster, and leaves each cluster at tenant-01 to tenant-03 passing the pre-check.


### Milestone 8: report, documentation, and cleanup

At the end of this milestone, `make results` writes results/report.md, and the documentation describes the two-cluster comparison.

Create scripts/results.sh. It reads every results/*/*/run.json with jq and writes results/report.md. The report opens with the vocabulary (separation and isolation), what the designs are, and what the data cannot prove: one laptop, one Kind node per cluster, a mock upstream, local rate limits, one proxy replica, 200 ms probe precision, and the security limitations accepted for this proof of concept. It has one section per criterion and one per failure mode. Each section compares runs from the two clusters side by side only when their configuration fingerprints are identical; a shared comparison ID groups runs made together but never replaces that requirement. It shows the key numbers, the total reserved capacity, the matching calibration, links to the run directories, and the Grafana links, noting that those links work only while the cluster and its Prometheus data exist. Only valid runs whose inputs matched their commit and whose input fingerprint equals the current one are used in comparisons. Stale, uncommitted, invalid, and confounded runs are listed with their reasons but not compared. Any leak is shown at the top of the report. The report ends with the structural findings for future tenant-admin delegation (which objects hold a tenant's settings in each design and how many tenants share them), the controller Secret-read finding, the count of Foundry key copies in each design, the 16-tenant limit of the shared design as built, and the parked quota question with its facts.

Rewrite README.md as a short quick start for both clusters. Update docs/local-development.md for the new prerequisites (k6, Python, and kube-prometheus-stack run inside the clusters; nothing new is installed on the host), ports, state layout, .env.tenants, the chart image inventory, and the removal of the offline tests. Create docs/tenancy-comparison.md explaining both designs, the objects each creates (with `make tenant-objects` output), every workload profile, scenario, and failure mode (what it does, how it is triggered and restored, what is measured, and its invocation check), how to read results and validity, the accepted security limitations, and the known limits of the measurements. Remove the legacy-down target.

Acceptance for Milestone 8: `make help` shows the sections below, with plain output under NO_COLOR=1; `make results` writes a report whose comparisons use only valid, committed, current runs; and following README.md from a machine with only Docker Desktop and the listed tools builds both clusters.


## Concrete Steps

Run everything from the repository root. The expected output below is illustrative; the numbers will differ.

The complete build and a first comparison:

    make doctor
    make up CLUSTER=shared
    make up CLUSTER=dedicated
    make scale CLUSTER=both TENANTS=3
    make gateway-configure CLUSTER=shared
    make gateway-configure CLUSTER=dedicated
    make prompt CLUSTER=shared TENANT=tenant-01 PROMPT="Say hello in one sentence."
    make calibrate CLUSTER=both
    make scenario CLUSTER=both NAME=separation
    make break CLUSTER=both FAILURE=proxy-crash
    make results

Expected shape of a failure summary:

    === PROXY CRASH | SHARED ================================

      Target                          agentgateway-proxy (serves 3 tenants)
      Invocation check                [OK] restartCount +1, exit 137
      Validity                        [OK] probes 100% delivered, mock not throttled
      tenant-01                       affected, 1 episode, 6.8s failed, 503 x 34
      tenant-02                       affected, 1 episode, 6.8s failed, 503 x 34
      tenant-03                       affected, 1 episode, 6.8s failed, 503 x 34
      Leaks                           0
      Recovery                        [OK] 25 healthy probes 9.2s after the kill
      Run                             results/shared/20260925T101500Z-failure-proxy-crash/
      Grafana                         http://127.0.0.1:38484/d/mtag-tenants?from=...&to=...

    === PROXY CRASH | DEDICATED =============================

      Target                          tenant-01 proxy (serves 1 tenant)
      ...

The help menu sections, in order: CLUSTERS (up, status, down), TENANTS (tenant-add, tenant-limit, tenant-remove, tenants, tenant-objects, gateway-config), TRAFFIC (prompt, load), EXPERIMENTS (calibrate, scenario, break, restore, scale), OBSERVABILITY (grafana, prometheus, dashboard, logs, k9s, gateway-forward), RESULTS (results), FOUNDRY MODEL (foundry-register, foundry-regions, foundry-models, foundry-up, foundry-status, gateway-configure, endpoints), DIAGNOSTICS (doctor, check), CLEANUP (down CONFIRM=1, tenant-remove CONFIRM=1, foundry-down CONFIRM=1), then a GETTING STARTED information block and a DOCUMENTATION block that names docs/tenancy-comparison.md and docs/local-development.md as plain paths.

Update this section with real transcripts as milestones complete.


## Validation and Acceptance

There is no offline test suite. Validation is live, milestone by milestone, using the acceptance statements above. The whole plan is accepted when all of the following are true and recorded here with evidence.

Both clusters exist, built only through Make targets, and `make status CLUSTER=both` shows them healthy with three tenants each. `make calibrate CLUSTER=both` is valid for every profile. `make scenario CLUSTER=both NAME=separation` passes every check with zero leaks, and records the controller Secret-read observation. `make scenario CLUSTER=both NAME=latency` reports percentile differences with their range in each cluster. Each of the ten failures has a valid run in each cluster. `make scale CLUSTER=both TENANTS=1,5,10` has completed or stopped with a recorded reason in each cluster. `make results` produces results/report.md with every criterion and failure compared across the two clusters from valid, committed, current runs, each with Grafana links. A Foundry prompt succeeds in each cluster.

Each live check must prove the mechanism ran, not only that a command succeeded: the proxy container restarted with exit code 137, the invalid expression is in the applied object, the two key entries share a hash, 429s appeared during the flood, in-flight requests rose during the slow-upstream test, a new OOM termination appeared (or the run says it did not), the controller had zero ready replicas, the old mock key was rejected, the backend referenced the wrong Secret, and the probes sent the forged header.

Before any run that will be used in the report, commit the implementation, so that run.json records inputs that match the commit. Results can be committed afterwards without affecting any run's validity.


## Idempotence and Recovery

`make up` can be repeated; it verifies an existing cluster's identity and reapplies configuration without creating duplicates. It never adopts a cluster it did not create. `tenant-add` for an existing tenant reuses the stored keys and reapplies the tenant's objects. `render_shared` rebuilds the shared policy and route from the tenant ConfigMaps every time, so they cannot drift from them. Every experiment writes a recovery journal before changing anything and restores automatically unless KEEP=1; `make restore` converges a cluster from any stage and can be run again if it is interrupted. A new experiment refuses to start while a journal exists. `make down CLUSTER=... CONFIRM=1` deletes only that cluster; `make up` then rebuilds it, and tenants must be added again (their keys are reused from .env.tenants). `make foundry-down CONFIRM=1` still deletes only the recorded, project-owned Azure resources and now removes the Foundry objects from every mtag- cluster. Load Jobs and their Secrets and ConfigMaps carry gateway.dev/run and are removed by the exit trap or by `make restore`.

Deleting the old cluster in Milestone 3 cannot be undone, but nothing in it is needed afterwards: the Foundry resources, .local/foundry.json, and the Azure settings in .env are kept.


## Artifacts and Notes

Evidence from planning, kept for the implementer:

    $ git check-ignore -v .env.tenants
    .gitignore:3:.env.*    .env.tenants

    rendered ClusterRole agentgateway-tenant-01 (agentgateway chart v1.5.0):
      resources: [secrets]    verbs: [get, list, watch]    (cluster-wide)

    Foundry deployment gateway-chat rateLimits:
      request 100 per 60s, token 10000 per 60s

    proxy admin listener inside the pod's network namespace (/proc/net/tcp):
      0100007F:3A98    (127.0.0.1:15000)
    $ docker exec <node> nsenter -t <proxy pid> -n curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:15000/config_dump
    200

    agentgateway chart v1.5.0 defaults:
      monitoring.enabled: false
      agentgatewayModels.enabled: false

Add the most important transcripts from each milestone here.


## Interfaces and Dependencies

Host tools, unchanged except that Python is no longer needed on the host: Docker Desktop, Kind 0.31.0, kubectl compatible with Kubernetes 1.35, Helm 3.12 or later, Bash (macOS /bin/bash), GNU Make 3.81 or later, curl, jq 1.6 or later, OpenSSL, lsof, and Azure CLI 2.80 or later for Foundry commands. K9s is optional.

Pinned in versions.env: KIND_VERSION, KIND_IMAGE, GATEWAY_API_VERSION, AGENTGATEWAY_VERSION=v1.5.0, KUBE_PROMETHEUS_STACK_VERSION, K6_IMAGE (grafana/k6 2.3.0 by digest), and PYTHON_IMAGE (by digest).

In scripts/common.sh, these functions must exist at the end of Milestone 1:

    select_cluster                       # validates CLUSTER, sets KIND_CLUSTER, CONTEXT, CLUSTER_STATE, KUBECONFIG_FILE, *_PORT
    for_each_cluster <function> [args]   # runs the function for shared then dedicated when CLUSTER=both, in subshells
    load_env_file <path>                 # sets ENV_JSON from a literal KEY=value file after private_file checks
    save_env_file <path> <additions>     # atomic, 0600, refuses symlinks, tracked files, and unignored files
    tenant_key_name <tenant> <API|MOCK>  # prints e.g. SHARED_TENANT_01_API_KEY for the selected cluster
    validate_tenant <tenant>             # enforces ^tenant-[0-9]{2}$
    start_forward <port> <namespace> <service>
    on_exit <function>                   # registers a hook that the cleanup trap runs first, in reverse order
    node_exec <command...>               # docker exec into the verified Kind node container
    proxy_pid <namespace>                # process ID of the proxy container in that namespace, via crictl
    proxy_config <namespace>             # /config_dump from that proxy via nsenter, JSON on stdout
    prom_query <expr> <start> <end> <step>  # Prometheus range query through a port-forward, JSON on stdout

In scripts/tenants.sh: `tenant_add`, `tenant_limit`, `tenant_remove`, `tenants_list`, `tenant_objects`, `gateway_config`, `render_shared`, `render_tenant <tenant>`, `mock_push_keys`, and `measure_onboarding <tenant>`.

In scripts/load.sh: `load_start <run-id> <probe|attack> <plan-json-file>`, `load_first_record <run-id> <role>`, `load_finish <run-id> <role>` (prints the paths of the summary and the per-request records), and `run_load`, which runs all three in order.

In scripts/experiments.sh: `run_experiment <kind> <name>` with per-failure functions `trigger_<name>`, `check_<name>` (the invocation check), and `restore_<name>`; `precheck`, `journal_write`, `journal_stage`, `restore_from_journal`, `verify_recovery`, `impact_from_probes`, `check_validity`, `write_run_record`, `calibrate`, and `scale_sweep <list>`.

In scripts/results.sh: `build_report`, writing results/report.md.

Kubernetes objects by design. Shared cluster, namespace agentgateway-system: Helm release agentgateway, AgentgatewayParameters local-dev, Gateway agentgateway-proxy, policies tenant-auth, tenant-routing, tenant-limits, and tenant-telemetry, HTTPRoute mock-chat with one rule per tenant, and per tenant ConfigMap tenant-NN-key, Secret mock-provider-tenant-NN, and AgentgatewayBackend mock-tenant-NN; plus Secret foundry-provider, AgentgatewayBackend foundry-model, and HTTPRoute foundry-chat. Dedicated cluster: Helm release agentgateway-crds in agentgateway-system, and per tenant namespace tenant-NN: Helm release agw-tenant-NN, GatewayClass agw-tenant-NN (cluster-wide, created by that controller), AgentgatewayParameters tenant-proxy, Gateway agentgateway-proxy, ConfigMap tenant-key, policies tenant-auth, tenant-limits, and tenant-telemetry, Secret mock-provider, AgentgatewayBackend mock, HTTPRoute mock-chat, Secret foundry-provider, AgentgatewayBackend foundry-model, and HTTPRoute foundry-chat. Both clusters: namespaces mock-upstream (with Secret mock-upstream-keys), monitoring, and loadgen.

Labels: gateway.dev/component=tenant-key on key ConfigMaps, gateway.dev/tenant=<tenant> on every tenant-owned object, and gateway.dev/run=<run-id> on every experiment object. Annotation: gateway.dev/tokens-per-minute on key ConfigMaps is the single source of each tenant's limit.

Security properties that must hold: tenant gateway keys and mock provider keys are 64 hexadecimal characters from OpenSSL, stored only in .env.tenants (mode 0600, Git-ignored, never tracked, never a symlink), in the cluster Secrets that need them, and in short-lived load Secrets; the cluster stores only hashes of gateway keys; no key is ever a process argument, printed, or written under results/. Secrets are applied server-side so no last-applied annotation holds their contents. Every Service is ClusterIP, every host listener binds 127.0.0.1, and only the Make targets open port-forwards. Images named by this plan are pinned by digest and charts by version; chart-deployed images are inventoried, not claimed as pinned. Prompts sent to Foundry leave the machine, so only non-sensitive test prompts are used. No experiment touches Azure. The five security review findings recorded in the Decision Log are accepted limitations of this proof of concept, and docs/tenancy-comparison.md lists them.


Revision note (2026-09-24 09:43Z): first version, written after the grilling session. It records every decision the user made and the facts gathered while planning.

Revision note (2026-09-24 10:40Z): second version. It folds in the rubber-duck review (workload profiles and limits, per-probe impact records, calibration and validity rules, separate probe and attack Jobs, SIGKILL crashes, recovery journals, chart monitoring flags, the lifecycle migration of existing functions, fingerprints and comparison IDs, repeated latency pairs, symmetric limit records, and consistent onboarding and offboarding times). It adds cross-tenant leakage (per-tenant mock provider keys, an always-on check, and the wrong-credential and forged-tenant-header failures), which changes upstream selection from model names to paths with tenant-based routing in the shared cluster. It parks shared provider quota exhaustion, and records the security review's findings as risks the user accepted for a local proof of concept.

Revision note (2026-09-24 12:55Z): third version, after a focused second rubber-duck pass. It adds the leak verdicts and positive controls, classifies probes by real mutation times instead of a phase schedule, adds calibration and attack-delivery gates, requires identical configuration fingerprints for every comparison, separates entry checks from recovery checks and keeps the journal under KEEP=1, makes credential rotation roll forward with per-replica verification, splits wrong-credential into reference and value mistakes, bounds revocation and deletes the dedicated GatewayClass explicitly, moves tenant-auth and the minimal probe runner earlier, specifies the conditional expression for the forged-header mistake, and shortens the sweep to 1, 5, and 10 tenants after the 16-entry limit was found.
