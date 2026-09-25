# Shared versus dedicated agentgateway

This guide explains the two multi-tenancy designs this repository builds, what each experiment does
to them, and how to read the results. The numbers themselves are in
[results/report.md](../results/report.md), which `make results` writes from the run records. This
guide does not choose a design. The report is one input to a later architecture decision, which
[ADR 0001](adr/0001-multi-tenant-gateway-design.md) sets out for reviewers.

Two words have fixed meanings here. **Separation** is what namespaces and separate gateways give
tenants that share one cluster. **Isolation** would mean a dedicated cluster for each tenant, which
this comparison does not test. Neither design isolates tenants.

## The two designs

A tenant is one API key and one token-per-minute limit. Every tenant also has its own provider key
for the mock upstream, so the experiments can detect a request that is served with another tenant's
credential. All tenants in both clusters share one Microsoft Foundry deployment, `gateway-chat`.

| | Shared (`mtag-shared`) | Dedicated (`mtag-dedicated`) |
| --- | --- | --- |
| Gateways | One controller and one proxy in `agentgateway-system` serve every tenant. | Each tenant namespace `tenant-NN` has its own controller (Helm release `agw-tenant-NN`) and its own proxy. |
| How a request finds its tenant | Key authentication reads the tenant from the key's metadata. Policy `tenant-routing` then overwrites `x-tenant` with that tenant, and HTTPRoute `mock-chat` routes on it. | The tenant's own gateway accepts only the tenant's own key. |
| Where a tenant's limit lives | One entry in the shared policy `tenant-limits`. | The tenant's own `tenant-limits` policy, with one entry. |
| Objects changed by onboarding | Per-tenant objects, plus two shared objects rebuilt from every tenant (`tenant-limits`, `mock-chat`). | Per-tenant objects only, plus the cluster-wide GatewayClass `agw-tenant-NN` and two ClusterRoles. |
| Foundry key copies | One. | One per tenant. |
| Most tenants as built | 16, because `rateLimit.conditional` and HTTPRoute `rules` each hold at most 16 entries. | Limited by cluster resources. |

In both designs, the CRDs, the Kind node, the mock upstream, and the Foundry deployment are shared.
Every agentgateway controller, as granted by the v1.5.0 chart, can list and read Secrets in every
namespace. The dedicated design therefore does not separate tenant credentials at the Kubernetes
permission level; the separation scenario records this in both clusters.

To see every object that holds one tenant's settings, and how many tenants share each object, run:

```bash
make tenant-objects CLUSTER=shared TENANT=tenant-01
make tenant-objects CLUSTER=dedicated TENANT=tenant-01
```

## A tenant's lifecycle

`make tenant-add` and `make tenant-remove` work the same way in both designs, and each measures
itself with a probe that sends five requests per second with the tenant's key from inside the
cluster.

1. Onboarding applies every object with the key inactive (`gateway.dev/key-active: "false"`).
2. It waits until the proxy's own configuration, read through the Kind node, enforces the tenant's
   limit ("limit enforced").
3. It activates the key and records the first successful probe ("usable"). In the dedicated
   cluster it then connects the tenant's own copy of the Foundry route and records when that is
   ready.
4. Offboarding deactivates the key first and records the interval between the last successful probe
   and the first of 25 consecutive refusals by authentication ("revoked").
5. It checks that every gateway in the cluster refuses the key, then removes the rest and records
   when every object holding the tenant is gone ("cleaned").

The tenant's state (`onboarding`, `active`, or `offboarding`) is stored on its key ConfigMap, so an
interrupted command resumes or cleans up from where it stopped.

## Workload profiles

The mock counts prompt tokens as characters divided by four and completion tokens as the smaller of
`max_completion_tokens` and 100. Every run records the profile it used.

| Profile | Rate | Request | Mock latency | Limit in force |
| --- | --- | --- | --- | --- |
| probe | 5 per second per tenant | 40-character prompt, 16 completion tokens | 100 ms | default (20,000 tokens per minute) |
| latency | 50 per second | as probe | 100 ms | raised; any 429 makes the run invalid |
| flood | 2,000 per second | as probe | 100 ms | default, so most requests get 429; `RAISE_LIMIT=1` raises it |
| slow | 50 per second | as probe | 30 seconds (about 1,500 in flight) | raised |
| memory | 50 per second | 256 KiB prompt | 30 seconds | raised |
| scale | 1 per second per tenant | as probe | 100 ms | default |

"Raised" means 1,000,000,000 tokens per minute, written into the recovery journal before the change
and restored afterwards.

## How every experiment runs

```bash
make calibrate CLUSTER=both
make scenario CLUSTER=both NAME=separation
make break CLUSTER=both FAILURE=proxy-crash
make scale CLUSTER=both TENANTS=1,5,10 CONFIRM=1
make results
```

`CLUSTER=both` runs the shared cluster and then the dedicated cluster, never both at once, because
the two Kind nodes share Docker Desktop's CPU and memory. An experiment refuses to start while the
other cluster runs a load Job. Every run, including each onboarding and offboarding, samples the
other Kind node's CPU every 5 seconds and records the mean in `run.json` under `contention`.

Every experiment that changes a cluster:

1. Checks that no recovery journal exists, that no tenant is part-way through onboarding or
   offboarding, and that tenant-01, tenant-02, and tenant-03 are healthy (the entry check). Healthy
   means: active, with a ready controller and proxy, a fully accepted limit policy, the expected limit
   enforced by the proxy, and a verified response from the mock with the tenant's own provider key.
2. Writes a recovery journal (`.local/<cluster>/experiment.json`, mode 0600) with every tenant's
   limit, key hash, and state, and what the experiment will change. The experiment refuses to start
   if this snapshot is incomplete.
3. Starts probes for all three tenants and records 30 seconds of baseline.
4. Triggers the change against tenant-01 or the component that serves it, and observes for 120
   seconds.
5. Restores, unless `KEEP=1` is given, and waits until every tenant has 25 consecutive verified
   probes.
6. Runs the same health checks again, with the journal's limits as the expected ones, writes a run
   record under `results/<cluster>/`, and deletes the journal only when the checks passed.

If a run is interrupted, or `KEEP=1` left a failure in place, `make restore CLUSTER=...` converges
the cluster back to the journal's recorded state. It reapplies only tenants that were active; a
tenant that was onboarding or offboarding is left as it is, so a restore never reactivates a key that
offboarding had deactivated. It is safe to repeat.

Every request the probes send gets one verdict:

| Verdict | Meaning |
| --- | --- |
| verified | Served by the mock with the sending tenant's own provider key and its own probe ID. |
| leak | Served with another tenant's provider key, or with another request's probe ID. |
| blocked | Refused by the gateway, for example 401 or 429. |
| unverifiable | A 200 response without the mock's identifying headers. |
| failed | Any other error, including timeouts. |
| censored | Still in flight when the run stopped the load generator; not counted. |

## Calibration

`make calibrate` runs the latency, flood, slow, and memory profiles for 2 minutes each directly
against the mock, without any gateway, alongside the probes. A profile is valid only when the attack
had verified responses for at least 95 percent of its target, with no other outcome and no dropped
iterations; every probe response was verified and the probes delivered their planned rate; the mock
returned no errors; its p99 stayed within 20 percent of its configured latency; its CPU was throttled
in less than 10 percent of the window; and Prometheus had the mock's request, in-flight, and
throttling figures (missing telemetry makes the run invalid rather than counting as zero). This proves that k6 and the mock can deliver each workload, so a gateway
result is not limited by the apparatus.

## Scenarios

**separation** checks, with evidence for each check, that:

- no key and an invalid key get 401;
- each tenant is served with its own provider key;
- a forged `x-tenant` header does not reach another tenant;
- in the dedicated cluster, each tenant's key is refused by every other tenant's gateway;
- tenant-01 spending its budget gets 429 while the other tenants keep getting 200;
- gateway metrics attribute traffic to each tenant;
- no probe leaked.

Two positive controls prove that the leak detector works: one sends another tenant's provider key,
and one makes the mock echo a wrong probe ID. The scenario also records, without changing anything,
whether the controller can list Secrets outside its own namespace.

**latency** raises tenant-01's limit and runs three pairs of 2-minute measurements at 50 requests
per second, each after a 30-second warm-up. Each pair measures the mock directly and through the
gateway, and the order alternates between pairs. It reports the differences in p50, p95, and p99 per
pair, with the median and range across pairs. A difference in percentiles is not a per-request cost.

**rollout** changes every tenant's limit with `make tenant-limit TENANT=all` and measures the time
until the proxy enforces the new limit for every tenant. It also counts the records written (one per
tenant in both designs) and the enforcement objects written (one shared policy, or one policy per
tenant).

**foundry-smoke** sends one real prompt per tenant through Foundry (at most 32 completion tokens
each) and needs `CONFIRM=1`, because it can incur charges.

## Failure modes

Each failure is aimed at tenant-01 or the component serving it. Each also has an invocation check
that proves the failure really happened. If that check fails, the run is invalid; it never reports
"no impact".

| Failure | What it does | Invocation check | Restore |
| --- | --- | --- | --- |
| proxy-crash | Kills the proxy serving tenant-01 with SIGKILL. The run first waits until the proxy has run for 10 minutes, so the kubelet's restart back-off does not lengthen the outage. | The killed container exited with code 137, and the same pod restarted it once. | The kubelet restarts the container. |
| bad-tenant-config | Replaces tenant-01's limit condition with the invalid CEL expression `apiKey.tenant ==`. | The applied policy holds the invalid expression. It records the policy status and what the proxy enforces for each tenant. | Re-renders the policy from the stored limits. |
| duplicate-key | Gives tenant-02's key entry tenant-01's key hash. In the dedicated cluster, tenant-01's key is also sent to tenant-02's gateway. | tenant-02's entry holds tenant-01's hash. | Reapplies tenant-02's own hash. |
| flood | tenant-01 sends 2,000 requests per second for 2 minutes. | At least 80 percent of the target was sent and some were refused with 429; with `RAISE_LIMIT=1`, at least 80 percent reached the mock. | The load stops. |
| slow-upstream | tenant-01's requests take 30 seconds at the mock. | The mock held more than 1,000 requests in flight. | The load stops. |
| proxy-memory | tenant-01 sends 256 KiB prompts held for 30 seconds, against the proxy's 512 MiB memory limit. | A new OOM kill inside the run window, or the result "no OOM at these parameters" with the largest sampled memory. | The load stops. |
| controller-outage | Scales the controller serving tenant-01 to zero, then changes tenant-01's and tenant-02's limits. | The controller had zero ready replicas. It records which changes the proxies enforced during the outage. | Scales the controller back and waits for the pending changes. |
| credential-rotation | Rotates tenant-01's mock provider key: the mock stops accepting the old key, then the gateway's copy is updated. | Every mock replica refuses the old key and accepts the new one. | Rolls forward to the new key. |
| wrong-credential | First minute: tenant-02's backend references a Secret named after tenant-01's provider key. Second minute: tenant-02's own Secret holds tenant-01's key. | The wrong reference and the wrong value were applied (the value is compared by hash). | Reapplies tenant-02's backend and key. |
| forged-tenant-header | tenant-01 sends `x-tenant: tenant-02` for the whole run. In the second minute of the shared run, the routing policy is changed to trust a client-supplied header, to simulate a platform mistake. In the dedicated cluster, the forged request is also sent to tenant-02's gateway. | The forged header was sent, and in the shared run the policy trusted it in the second half. | Reapplies the correct routing policy. |

For each tenant, a failure reports, from its probe records:

- **affected**: at least one failed probe, or one more than five times slower than its baseline p95;
- **material impact**: more than 1 percent of probes failed, or the observe-phase p95 was more than
  twice the baseline p95;
- **episodes** and **failed time**: runs of consecutive failed probes, each from the start of its
  first failed probe to the start of the next successful one;
- **failed statuses** and **leaks**;
- **recovery**: the time from the trigger, and from the start of the restore, to the first of 25
  consecutive verified probes.

For the tenant causing a flood, 429 responses are expected and are reported separately. Timing
precision is 200 ms, the interval between probes. Only requests that started before the end of the
run count; a request cut off when the load generator is stopped is censored.

A failure run is invalid, and excluded from comparisons, when any of these holds:

- its invocation check failed;
- a probe or extra stream dropped iterations or delivered less than 99 percent of its planned rate;
- the attack dropped iterations (proxy-memory is allowed to, because the proxy it overloads is
  killed) or sent less than 80 percent of its planned requests;
- any response was unverifiable, or a run with a raised limit saw a 429;
- the mock was CPU-throttled in more than 10 percent of the observe window, its throttling telemetry
  was missing, or a mock or k6 container was killed for memory;
- the tenants did not recover within 5 minutes, or the health checks failed after the restore.

## Scale sweep

`make scale TENANTS=1,5,10` adds or removes tenants in order through the normal `tenant-add` and
`tenant-remove` commands, so every onboarding and offboarding is measured. At each step it waits 60
seconds idle and samples, then sends 1 request per second per tenant for 2 minutes and samples again.
Each sample covers only the gateway pods (controllers and proxies): their CPU and maximum sampled
memory, pod count, reserved requests and limits, and active gateway time series, plus the Kind node's
memory. The load window is taken from the requests themselves. A step is valid only when every tenant
had verified responses for 99 percent of its requests with no drops, and every figure covers exactly
the expected gateway pods (2 in the shared cluster, 2 per tenant in the dedicated cluster).

The sweep stops early, and records why, when a pod stays Pending for 2 minutes, the node reports
memory pressure, or the Docker Desktop VM has less than 2 GiB available; it checks before each
tenant is added, before each measurement, and during it. It returns to the three-tenant working set
and checks its health, also after an error or Ctrl-C. With a single number, for example `TENANTS=3`,
it converges to that many tenants and records the footprint.

The sweep manages only tenant-01 to tenant-16 and refuses to start if another tenant exists. Removing
a tenant deletes its keys, and a tenant added again gets new ones, so a command that would remove
tenants that existed before it started needs `CONFIRM=1`. A sweep that starts from the working set
removes tenant-02 and tenant-03 at the 1-tenant step, so it needs `CONFIRM=1`.

## Reading the results

`make results` reads every run record and writes `results/report.md`. It compares runs only when
all of the following are true:

- the run used committed code (`inputs_committed`), and no input changed during the run;
- the input fingerprint equals the current implementation's, so the result is not stale;
- the run passed its own validity checks (for a failure, including its invocation check and the
  health check after the restore; for an onboarding or offboarding, a clean finish);
- the run recorded the other cluster's load, and that node averaged at most 0.5 CPU (not confounded);
- the shared and dedicated runs have the same configuration fingerprint, which covers the workload,
  the windows, the tenants and their limits, and the mock replicas. When several pairs exist, the
  latest matching pair is used.

Every other run is listed at the end of the report with the reason it was excluded, and so is every
usable run that no section shows (for example one superseded by a later run). Any leak appears
at the top. Each result links to its run directory and to the matching time range in Grafana
(`make grafana CLUSTER=...`); those links work only while that cluster and its Prometheus data exist.

A run directory holds `run.json` (the record, with provenance, validity, and Grafana links),
`summary.txt` (what the command printed), the k6 summaries, the per-request probe records, every
Prometheus query and its answer, and the Kubernetes events from the run window.

## What the measurements cannot show

- Both clusters run on one laptop, each on a single Kind node that shares Docker Desktop's CPU and
  memory. Absolute numbers do not transfer to production hardware; compare the two designs with
  each other.
- The upstream is a mock for every load test. Foundry is used only for smoke checks.
- Token limits are local to each proxy, and every proxy has one replica.
- Probe timing precision is 200 ms, and memory figures are the maximum of 5-second samples.
- Other software on the host competes for the same CPUs. On the measuring machine, it raised the
  load average to about 10 on 10 CPUs and made the calibration fail. Each run records the host's load average (`contention.host_load`) as evidence;
  it is not a gate, because the run's own load raises it too. The campaign waited up to 15 minutes
  before each step for the host to settle, a best-effort wait: some runs still averaged a load of
  11 to 16 on 10 CPUs. A valid run proves the apparatus delivered its workload, not that host load
  left its timings unbiased, so the report shows the host load beside every timing.
- Most lifecycle and footprint figures come from a single run each.
- Shared provider quota exhaustion is not tested. Both designs sit in front of one deployment with
  10,000 tokens per minute, and local limits in separate proxies cannot cap their total.
- Version and CRD upgrades are out of scope.

## Security limitations accepted for this proof of concept

These were found in the security review of the plan and accepted as local risks:

1. `make dashboard` forwards the proxy's admin port, whose unauthenticated `/debug/trace` can
   record live request headers, including tenant keys and the Foundry key, while the forward runs.
2. Make evaluates `$(...)` in command-line values. This repository takes every value literally
   with `override VAR := $(value VAR)`, and the scripts validate each value.
3. curl reads the user's `~/.curlrc`, so a verbose or trace setting there would print
   Authorization headers.
4. Prometheus's remote-write receiver has no authentication, so a local process could push fake
   samples while Prometheus is forwarded.
5. The mock's key administration endpoint has no authentication. It is reachable only inside the
   cluster.

Grafana allows anonymous Viewer access on `127.0.0.1`. The k6 control API used to stop load early
is unauthenticated inside the cluster. See [FINDINGS.md](../FINDINGS.md) for every review finding
and what was done about it.
