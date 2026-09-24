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


## Milestone 1: two clusters from the same commands

Reviewed commit `e5fff1d`. Fixes are in the commit "Fix the Milestone 1 review findings".

### Rubber-duck review (8 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | `for ... in $(gateway_namespaces)` discards a failed lookup, so cleanup could report success while Foundry objects remained, and `check` could pass with "0 tenant keys checked". | Every list is captured in a plain, checked assignment before the loop; `tenants_served_by` now fails on an API error instead of treating it as "no tenant". | Fixed |
| 2 | Blocking | Any failed `get secret mock-upstream-keys` was treated as "not found", so a transient API error could overwrite the tenants' provider keys with an empty list. | The empty Secret is created only when a successful `--ignore-not-found` lookup finds nothing. | Fixed |
| 3 | Blocking | The mock kept each request body referenced during its simulated latency and while waiting for the next request on a keep-alive connection. | The body is parsed into a few small values and every reference is dropped before sleeping. Forty 256 KiB requests in flight now add about 2.6 MB instead of about 10 MB. | Fixed |
| 4 | Blocking | Removing the last key from a credential file failed, because `jq -e` treats empty output as an error. | `save_env_file` accepts an empty result; removing the last test key now leaves an empty 0600 file. | Fixed |
| 5 | Non-blocking | `select_cluster` did not clear the cached node ID, so reselecting a cluster in the same process could reach the previous cluster's node. | `select_cluster` clears `NODE_ID`. | Fixed |
| 6 | Non-blocking | `tenant_key` loaded `.env.tenants` lazily inside a command substitution, and `render_namespace` created its file inside one, so those temporary files escaped exit cleanup. | Callers load `.env.tenants` in the parent shell first; `render_namespace` sets a variable instead of printing a path. | Fixed |
| 7 | Non-blocking | `check` never confirmed Prometheus, the operator, kube-state-metrics, or the CRDs. | `shared_components_ready` checks all of them; `status` lists them. | Fixed |
| 8 | Non-blocking | Dashboard CPU and throttling panels used 30-second rate windows, but cAdvisor refreshes container CPU only every 10 to 20 seconds, so panels were intermittently empty. | Container-metric panels use 2-minute windows. | Fixed |

### Security review

No vulnerabilities were found in the commit. The reviewer noted that one of its own failed diagnostic
queries could have written Secret data to a temporary file, and deleted those files without reading
them.


## Milestone 2: prototypes and the load runner

Reviewed commit `05add5d`. Fixes are in the commit "Fix the Milestone 2 review findings".

### Rubber-duck review (9 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | Stopping k6 through its API aborts requests still in flight, so their records disappeared and the summary under-counted them. Pausing first had no effect in a live test. | Streams with records print a `START` line when a request begins; at the end, a start without a finished record becomes a `censored` record. A stopped run with 4-second responses kept 70 finished and 20 censored requests. | Fixed |
| 2 | Blocking | A plan without `mock: true` marked every 200 as verified, and `mock: true` without `expected_owner` marked every real response as a leak. | Every stream is checked against the mock, and the expected owner defaults to the stream's tenant. A control using another tenant's key without either field was classified as a leak on all 36 requests. | Fixed |
| 3 | Blocking | The memory profile (256 KiB prompts, about 1,500 in flight) OOM-killed k6 at its 2 GiB limit. | Large bodies are built per request instead of kept by every VU, and a plan can request more k6 memory (`job_memory`). At 6 GiB the profile completed 3,000 requests with no drops at 1,512 in flight; k6 peaked at 3.7 GiB. | Fixed |
| 4 | Blocking | Probe VUs were sized for normal latency, so a slowdown beyond about 2.8 seconds dropped probe iterations exactly when a victim needed measuring. | Streams with records get enough VUs for every request to reach its timeout. The 4-second stream above dropped none. | Fixed |
| 5 | Blocking | kubelet rotates container logs at 10 MiB and `kubectl logs` reads only the current file, so long recorded runs could lose early records while the summary still looked complete. | Plans are capped at 20,000 recorded requests, and `load_finish` rejects a run unless every counted request has a record and every record a start. | Fixed |
| 6 | Non-blocking | A load started inside a cleanup hook inherited the parent's pending list and registered no cleanup of its own. | `run_hook` clears the pending list, so each context registers its own cleanup. | Fixed |
| 7 | Non-blocking | `mock_push_keys` pushed once to the running replicas, so a replica starting with the previous Secret could keep old keys. | It waits for the rollout, then pushes until the same ready replicas (by pod and restart count) report the expected owners twice in a row. | Fixed |
| 8 | Non-blocking | `grep -q` exits at the first match, and with `pipefail` the producer's SIGPIPE could turn a found probe into a failure. | Logs are captured into a variable before searching. | Fixed |
| 9 | Non-blocking | k6 publishes a verdict counter only when that verdict first occurs, so `increase()` could not show a single leak. | The leak panel is a table of totals per run and stream over the selected time range. | Fixed |

### Security review (1 finding)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | LOW | Load Secrets holding raw tenant keys had no owner or expiry, so a runner killed before its cleanup could leave them in the cluster indefinitely, and cleanup stopped at the first failed deletion. | Jobs are created suspended with a deadline, their key Secret and plan ConfigMap are owned by the Job (Kubernetes deletes them with it, verified in 1 second), and then the Job starts. Cleanup attempts every pending run and reports failures at the end. | Fixed |
