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


## Milestone 3: tenants in the shared cluster

Reviewed commit `f489419`. Milestone 4 had already changed the same script when the reviews
arrived, so the fixes are in the Milestone 4 commit, "Add a complete agentgateway per tenant in the
dedicated cluster".

### Rubber-duck review (9 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | The key ConfigMap made a tenant's key valid before its limit and route were installed, so for a moment (or indefinitely after a failure) the key worked without a limit. | Keys take part in authentication only while `gateway.dev/key-active` is `"true"`. Onboarding applies everything with the key inactive, waits until the proxy shows the limit, then activates the key. | Fixed |
| 2 | Blocking | Revocation counted every non-verified response, including leaks, 404s, 429s, and censored requests, and could pair a late success with an early failure run, producing an inverted interval. | Revocation requires 25 consecutive 401 responses after the last success; a success after them, an inverted interval, or any leak fails the command. | Fixed |
| 3 | Blocking | An interrupted add or remove left objects or keys that `tenant-remove` then refused to clean because the key ConfigMap was gone. | `tenant-remove` recognizes leftovers (objects, namespace, GatewayClass, cluster roles, keys) and removes them as an unmeasured cleanup; `tenant-add` refuses to start over leftovers and prints how to recover. | Fixed |
| 4 | Blocking | A failed read could look like "cleaned", because an empty result from a failed command substitution passed the check. | Each read is captured and checked; only successful reads showing absence count. | Fixed |
| 5 | Blocking | Rerunning `tenant-add` for an existing tenant reset its limit to the default. | The stored limit is kept unless `TOKENS_PER_MINUTE` is given. | Fixed |
| 6 | Non-blocking | Enforcement was first checked only after the apply step and its status waits returned. | A background watcher polls the proxy's configuration from the start, in both designs. | Fixed |
| 7 | Non-blocking | Provenance was captured when the run record was written, not when the run started. | Captured at the start and compared at the end; a change marks the run as not using committed inputs. | Fixed |
| 8 | Non-blocking | Run records had no configuration fingerprint, and offboarding omitted the tenant count and limit. | Every record has a `config` object and `config_fingerprint`. | Fixed |
| 9 | Non-blocking | Stored limit annotations were checked only for digits, bypassing the 1,000,000,000 ceiling. | `render_shared` applies the same bounds and names the offending ConfigMap. | Fixed |

### Security review (1 finding)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | MEDIUM | Offboarding treated cross-tenant access (HTTP 200 marked `leak`) as revocation, so with a duplicate key hash a removed tenant's key could keep working as another tenant while the command reported success. | Removal refuses to start if the key's hash is stored for another tenant, requires authentication refusals (401) as revocation evidence, and fails on any leak. | Fixed |


## Milestone 4: a complete agentgateway per tenant

Reviewed commit `788419a`. Fixes are in the commit "Fix the Milestone 4 review findings".

### Rubber-duck review (9 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | Retrying an interrupted add reapplied the tenant with its key active, before its limit was repaired. | Each tenant has a state (`gateway.dev/tenant-state`: onboarding, active, offboarding). An interrupted onboarding resumes with the key inactive and activates it only after the proxy enforces the limit. | Fixed |
| 2 | Blocking | The stricter tenant-auth selector had no migration, so existing tenants lost access and `check` could pass with zero keys checked. | `make up` marks keys created before activation existed as active before applying the new selector, in the shared namespace and in every dedicated tenant namespace; tenant commands refuse to run against an old selector. | Fixed |
| 3 | Blocking | The final revocation calculation chose the refusal run after the last success, so a success between two refusal runs was hidden. | The boundary that allowed removal to continue is kept, and any success after it fails the command. | Fixed |
| 4 | Blocking | The mock's own 401 (a bad provider key) counted as the gateway refusing the tenant key. | Revocation counts only 401 responses that carry no upstream answer (verdict `blocked`). | Fixed |
| 5 | Blocking | The configuration fingerprint included the design, so shared and dedicated runs could never be compared. | The design is recorded but left out of the fingerprint. | Fixed |
| 6 | Blocking | Leftover keys with no tenant objects could not be cleaned up. | Stored keys count as leftovers, and `tenant-remove` removes them (verified with a keys-only tenant). | Fixed |
| 7 | Non-blocking | Orphaned dedicated cluster roles were detected but never removed, and partial cleanup reported success without checking. | Cluster roles carrying that release's Helm ownership annotations are deleted, and cleanup succeeds only when nothing is left. | Fixed |
| 8 | Non-blocking | A failed onboarding kept no evidence. | The probe records and a run record with the reason are saved before the command fails. | Fixed |
| 9 | Non-blocking | `gateway-config` showed no route backend for dedicated tenants. | Dedicated routes are matched without the shared design's header condition. | Fixed |

### Security review (3 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | MEDIUM | Reapplying a tenant reactivated a key that offboarding had deactivated. | Reapply acts on the tenant's state: active tenants stay active, onboarding resumes with the staged activation, and a tenant being removed is refused with instructions to finish the removal. | Fixed |
| 2 | MEDIUM | The duplicate check skipped every ConfigMap labelled with the departing tenant, so a copy in another namespace escaped it. | Only the tenant's own ConfigMap, by namespace and name, is excluded; a copied hash stopped removal in a live test. | Fixed |
| 3 | MEDIUM | Cleaning up an incomplete tenant skipped the duplicate check and never proved that the key was refused. | Cleanup runs the duplicate check, deactivates the key, and requires every gateway in the cluster to refuse it at authentication before deleting anything. | Fixed |


## Milestone 5: calibration, load, and the non-failure scenarios

Reviewed commit `9feaa7b`. Fixes are in the commit "Fix the Milestone 5 to 8 review findings", which
covers the reviews of Milestones 5 to 8 because they changed the same scripts.

### Rubber-duck review (7 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | A failed tenant listing produced an empty journal snapshot, and restore then fell back to the cluster's current limits, which an experiment may have raised. | Every snapshot value is read into a variable first, the journal is written only when it holds every working-set tenant with a limit, key hash, and active state, and restore uses only journal limits when a journal exists. | Fixed |
| 2 | Blocking | The entry and recovery checks tested only existence and one request, so a stopped controller, a partly rejected policy, or a proxy still enforcing a raised limit passed. | The checks now require each working-set tenant to be active, its controller and proxy ready, its limit policy fully accepted, and its proxy to enforce the expected limit (the journal's), before the request check. A failure to read the cluster counts as unhealthy. | Fixed |
| 3 | Blocking | Calibration counted requests rather than verified responses, ignored probe outcomes and rates, and read missing telemetry as zero. | Calibration requires verified responses for 95 percent of the target and no other outcome, verified probes at their planned rate, and present mock request, in-flight, and throttling telemetry. | Fixed |
| 4 | Blocking | Latency validity counted only verified responses, so 429s, drops, and errors could hide behind the count threshold. | Each measurement also records unverified responses, drops, and 429s (from new per-stream status counts in k6); any of them makes the run invalid with a stated reason. | Fixed |
| 5 | Blocking | Calibration, scenario, and scale runs sampled the other node's CPU but never recorded it. | Sampling moved into every run record (`contention` in run.json, samples in other-node-cpu.txt), including onboarding and offboarding; the report excludes confounded runs and runs without a verdict. | Fixed |
| 6 | Blocking | Configuration fingerprints left out the tenant population, the limits, and the mock replicas, and `make load` recorded unresolved settings. | Every experiment adds the tenants, their limits, and the mock replicas at the start of the run to its configuration; `make load` records its resolved profile, rate, duration, and upstream. | Fixed |
| 7 | Non-blocking | `make load` probes ended before the attack's last requests. | Probes run 75 seconds longer than the attack and are stopped after it finishes. | Fixed |

### Security review (1 finding)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | MEDIUM | Restore reapplied every tenant as active, so it could reactivate the key of a tenant whose offboarding had been interrupted. | The journal records each tenant's state; restore reapplies only active tenants and leaves onboarding and offboarding tenants as they are; experiments refuse to start while any tenant is part-way through a lifecycle change. Verified live with a tenant labelled offboarding. | Fixed |


## Milestone 6: the ten failure modes

Reviewed commit `233820c`. Fixes are in the commit "Fix the Milestone 5 to 8 review findings".

### Rubber-duck review (9 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | The flood invocation check accepted any refusal as proof of throttling, so 401s or 404s would pass. | k6 now counts HTTP statuses per stream, and the check requires 429 responses. | Fixed |
| 2 | Blocking | Unverifiable responses and 429s in attack streams, which write no records, did not affect validity. | Validity reads the attack summary's verdicts and statuses as well as the records. | Fixed |
| 3 | Blocking | Attack delivery allowed up to 20 percent dropped iterations and never checked the achieved request count. | An attack is invalid with any dropped iteration (except proxy-memory, whose overloaded proxy is killed) or with less than 80 percent of its planned requests. | Fixed |
| 4 | Blocking | The forged-header and cross-gateway streams escaped delivery checks, and the forged-header invocation counted baseline requests. | Delivery checks cover every stream that writes records, and the forged-header check requires 90 percent of the planned requests in each half. | Fixed |
| 5 | Blocking | A failed snapshot could lose the original limits (same as Milestone 5 finding 1). | Fixed with Milestone 5 finding 1. | Fixed |
| 6 | Blocking | Failure fingerprints left out tenant limits and the tenant population. | Fixed with Milestone 5 finding 6. | Fixed |
| 7 | Blocking | Validity was decided before the final recovery check, so a run could be valid although the cluster failed that check. | The recovery check runs first, and its failure is a validity reason. | Fixed |
| 8 | Non-blocking | The restore-start mark was taken before the invocation check, which includes deliberate waits, and was set even with `KEEP=1`. | A separate observe-end mark precedes the check; restore-start is taken immediately before the restore and is null with `KEEP=1`. | Fixed |
| 9 | Non-blocking | Leak counts, extra-stream totals, and the during-restore bucket were not bounded by the end mark. | Every count uses only requests that started before the end mark; attack-stream leaks are added to the total. | Fixed |

### Security review

No findings.


## Milestone 7: the scale sweep

Reviewed commit `8fd1155`. Fixes are in the commit "Fix the Milestone 5 to 8 review findings".

### Rubber-duck review (9 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | A failed `tenant-remove` was not checked inside the convergence loop, which runs where `set -e` does not apply, so it could loop forever. | Every command in the convergence is checked explicitly and ends the sweep with a recorded reason; a tenant still present after removal stops it. | Fixed |
| 2 | Blocking | A measurement error exited without returning to the working set. | An exit hook returns an unfinished sweep to three tenants and checks their health, also after Ctrl-C. | Fixed |
| 3 | Blocking | An existing but incomplete tenant counted as onboarded. | Convergence completes any tenant that is not active with `tenant-add`, requires every tenant to be active, and the sweep ends with the full health check. | Fixed |
| 4 | Blocking | Stop conditions were checked only before adding a tenant. | They are also checked after converging, before each measurement, and after its load; a condition during a measurement makes that record invalid and stops the sweep. | Fixed |
| 5 | Blocking | Scale records were never validated for delivery or contention. | Each step requires verified responses for 99 percent of every tenant's requests with no drops, and records contention like every other run. | Fixed |
| 6 | Blocking | Missing telemetry became zero. | Each sample records how many gateway pods its CPU and memory figures cover; anything other than the expected count (2 shared, 2 per tenant dedicated), or missing reserved-capacity or series figures, makes the record invalid. | Fixed |
| 7 | Blocking | The load window was measured from when the Job finished, including cleanup. | Scale streams write per-request records, and the load window is taken from the first and last request. | Fixed |
| 8 | Blocking | Free memory came from summed container usage, ignored VM memory outside containers, and read zero when `docker stats` failed. | Free memory is `MemAvailable` from the Kind node's `/proc/meminfo`, which describes the whole Docker Desktop VM, and a failed read stops the sweep. | Fixed |
| 9 | Non-blocking | CPU and memory rows were joined on the pod name only. | They are joined on namespace and pod. | Fixed |

### Security review (1 finding)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | MEDIUM | Convergence removed the highest tenant regardless of whether it was in range or existed before the sweep, and supplied `CONFIRM=1` to `tenant-remove` itself, so it could delete an unrelated tenant and its keys. | The sweep refuses to start while any tenant outside tenant-01 to tenant-16 exists, and needs `CONFIRM=1` when it would remove tenants that existed before it started; convergence re-checks both before each removal. | Fixed |


## Milestone 8: the report and documentation

Reviewed commit `e9f3bdc`. Fixes are in the commit "Fix the Milestone 5 to 8 review findings".

### Rubber-duck review (8 findings)

| # | Severity | Finding | Resolution | Status |
| --- | --- | --- | --- | --- |
| 1 | Blocking | Some sections showed runs with different configuration fingerprints side by side, and the latest run of each cluster could hide an older matching pair. | Every comparison uses the latest pair whose fingerprints match; without one, each section says the runs are not compared. | Fixed |
| 2 | Blocking | Failed offboarding records and underloaded scale records counted as usable. | Onboarding and offboarding must finish cleanly and scale records must be valid to be used. | Fixed |
| 3 | Blocking | Only failure runs had a confounding verdict. | Fixed with Milestone 5 finding 5. | Fixed |
| 4 | Blocking | A bystander with material latency degradation but no single slow request showed as not affected. | Material impact now implies impact, and the report shows it first. | Fixed |
| 5 | Blocking | The leak warning looked only at usable runs and at one field name. | The warning lists leaks from every record, whichever field holds them, and says which runs are excluded. | Fixed |
| 6 | Blocking | Lifecycle figures mixed runs made at different tenant counts, and medians of an even number of runs were wrong. | Lifecycle rows are grouped by configuration fingerprint, and even-sized medians average the middle two values. | Fixed |
| 7 | Blocking | "Matching calibration" ignored the mock's replica count. | A calibration matches only with the same profile and mock replicas. | Fixed |
| 8 | Non-blocking | Usable runs that no section showed disappeared without explanation. | The report adds a Foundry smoke section and lists every other usable run with the reason it is not shown. | Fixed |

### Security review

No findings.
