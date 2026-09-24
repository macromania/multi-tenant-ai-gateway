# Review findings

This file records what each review found and what was done about it. Every milestone of
[the implementation plan](docs/plans/tenancy-comparison-execplan.md) gets a rubber-duck review
(logic, design, and measurement validity) and a security review before its changes are pushed.

Each finding has a status:

- **Fixed**: changed in the commit named in the milestone section.
- **Accepted**: left as is by a decision recorded here, usually because it is an acceptable risk for a
  local proof of concept.
- **Open**: known and not yet addressed; the milestone that will address it is named.

Severity follows the reviewers' own rating. Security findings use CRITICAL, HIGH, MEDIUM, and LOW.
Rubber-duck findings use Blocking and Non-blocking.


## Plan reviews (before implementation)

### Rubber-duck review, first pass (14 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | The plan's own token limits (20,000 per minute) would throttle the latency and stress workloads, so gateway runs would measure fast 429s while direct runs measured real work. | Every workload has a fixed profile with its rate, prompt size, completion tokens, and limit; latency and resource-pressure runs raise the limit and are invalid on any 429. | Fixed in plan |
| 2 | Blocking | k6's Prometheus remote-write percentiles are cumulative for the whole run, so per-window percentiles cannot be derived from them. | Native histograms for time series, and per-request probe records for window statistics. | Fixed in plan |
| 3 | Blocking | Calibration at 500 requests per second did not prove the mock and k6 could sustain the 2,000 requests per second, 1,500 in-flight, and large-body workloads. | `make calibrate` runs every profile directly against the mock with pass or fail gates; probe and attack traffic run in separate k6 Jobs. | Fixed in plan |
| 4 | Blocking | Restore after an interruption or `KEEP=1` had no record of the original state. | Recovery journal written before any change; restore converges from any stage. | Fixed in plan |
| 5 | Blocking | "Affected" at a 1 percent threshold could miss a complete one-second outage, and first-to-last failure time is not downtime. | Separate "any impact" and "material impact", failure episodes, and a healthy-streak recovery time. | Fixed in plan |
| 6 | Blocking | Deleting a pod is a graceful shutdown, not a crash. | The proxy process is killed with SIGKILL from the Kind node. | Fixed in plan |
| 7 | Blocking | The agentgateway chart ships with monitoring and model support switched off. | `monitoring.enabled: true` set explicitly; model-name routing later dropped. | Fixed in plan |
| 8 | Blocking | Existing commands assumed one gateway and one client key. | Every affected function is listed in the migration. | Fixed in plan |
| 9 | Blocking | The first result would make the Git tree dirty for the next run. | Validity uses a fingerprint of implementation inputs only, never `results/`. | Fixed in plan |
| 10 | Blocking | "Latest valid run" from each cluster could compare different workloads. | Comparisons require identical configuration fingerprints. | Fixed in plan |
| 11 | Non-blocking | The rollout object count contradicted the shared limit's source of truth. | One limit annotation per tenant in both designs; records and enforcement objects counted separately. | Fixed in plan |
| 12 | Non-blocking | Onboarding and offboarding ended at different lifecycle stages in the two designs. | The same "usable", "enforced", "revoked", and "cleaned" definitions in both designs. | Fixed in plan |
| 13 | Non-blocking | The OOM check could accept an earlier OOM, and sampled memory is not peak memory. | A new termination inside the run window is required; memory is reported as "maximum sampled". | Fixed in plan |
| 14 | Non-blocking | Prometheus head series include history from earlier runs. | Active gateway series measured separately from total head series. | Fixed in plan |

### Security review of the plan (5 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | HIGH | The proxy admin port (15000) serves an unauthenticated `/debug/trace` that records request headers, including tenant keys and the injected Foundry key, while `make dashboard` forwards it to the host. | Automated configuration reads enter the pod's network namespace from the Kind node instead of forwarding the port. `make dashboard` is kept. | Accepted (local proof of concept) |
| 2 | MEDIUM | Make evaluates `$(...)` in command-line values before the scripts validate them. | Every public variable uses the existing `override VAR := $(value VAR)` convention. | Fixed |
| 3 | MEDIUM | curl reads `~/.curlrc`, so a verbose or trace setting there would print Authorization headers. | Left as is. | Accepted (local proof of concept) |
| 4 | MEDIUM | Prometheus's remote-write receiver has no authentication, so a local process could push fake samples while Prometheus is forwarded. | Left as is; results record every query they use. | Accepted (local proof of concept) |
| 5 | MEDIUM | The mock's key replacement endpoint has no authentication. | Left as is; the mock is test apparatus inside the cluster. | Accepted (local proof of concept) |

### Rubber-duck review, second pass (6 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | `rateLimit.conditional` and HTTPRoute `rules` accept at most 16 entries, so the shared design as chosen cannot hold a 17th tenant. | Sweep shortened to 1, 5, and 10 tenants; the ceiling is reported as a structural finding. | Fixed in plan |
| 2 | Blocking | The leak check would count gateway-generated 401 and 429 responses as leaks, and had no proof that it could detect a leak. | Five verdicts (verified, leak, blocked, unverifiable, failed) and two positive controls. | Fixed in plan |
| 3 | Blocking | Recovery required "no journal exists" while the journal still existed, and rotation had two recovery destinations. | Separate entry and recovery checks; rotation always rolls forward and is verified on every mock replica. | Fixed in plan |
| 4 | Blocking | Dedicated offboarding waited for a GatewayClass that nothing deletes. | The tenant's GatewayClass is deleted explicitly; revocation is reported as a bounded interval. | Fixed in plan |
| 5 | Blocking | Onboarding used the probe runner and authentication before the milestones that introduced them. | tenant-auth moved to Milestone 1 and the probe runner to Milestone 2. | Fixed in plan |
| 6 | Non-blocking | The dedicated wrong-credential test used a missing Secret, not the same wrong key as the shared test. | Two halves in both designs: a reference mistake and a value mistake. | Fixed in plan |
