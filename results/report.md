# Shared versus dedicated agentgateway: results

Generated 2026-09-24T22:09:40Z from commit `6587122fdd95cd5f2fa46b804a12b98527ffb777`. This report is written by `make results` from the run records under `results/`; do not edit it by hand.

> **Leaks recorded** in 5 run(s). A leak is a response served with another tenant's provider key. Some failures create a cross-tenant mistake on purpose; their leaks show whether a design stops that mistake.
>
> - dedicated failure duplicate-key: 635 leaks
> - dedicated failure wrong-credential: 329 leaks
> - shared failure duplicate-key: 628 leaks
> - shared failure wrong-credential: 629 leaks
> - shared failure forged-tenant-header: 345 leaks

## What is compared

- **Shared** (`mtag-shared`): one agentgateway, one controller and one proxy, serves every tenant. Tenants are entries in shared objects.
- **Dedicated** (`mtag-dedicated`): each tenant has its own complete agentgateway, controller and proxy, in its own namespace.

"Separation" means what namespaces and separate gateways give tenants that share a cluster. "Isolation" would mean a dedicated cluster per tenant, which this comparison does not test.

What the data cannot prove: both clusters run on one laptop, each on a single Kind node that shares Docker Desktop's CPU and memory; the upstream is a mock except for small Foundry smoke tests; token limits are local to each proxy; every proxy has one replica; probe timing precision is 200 ms (five requests per second); memory figures are the maximum of 5-second samples; other software on the host (such as device management or antivirus scans) competes for the same CPUs, and its effect is recorded as the host load average (mean and maximum of 1-minute averages, on 10 CPUs here) in each run but is not a gate. A valid run proves the apparatus delivered its workload; it does not prove that host load left timings unbiased, so compare timings together with the host load shown beside them. The campaign waited up to 15 minutes before each step for the host to settle, which is a best-effort wait, not a guarantee. Most lifecycle and footprint figures come from a single run each. Security limitations accepted for this proof of concept are listed in FINDINGS.md.

A run of any kind is compared only if it used committed code that still matches the current implementation, passed its own validity checks, and was not confounded by load on the other cluster (whose Kind node must have averaged at most 0.5 CPU). A shared run and a dedicated run are compared only when their configuration fingerprints match: the same workload, windows, tenants, limits, and mock replicas. Excluded runs, and usable runs not shown in a section, are listed at the end.

Each run links to its record under `results/` and to the matching time range in Grafana. The Grafana links work only while that cluster and its Prometheus data still exist (Prometheus keeps 15 days).

## Calibration

Each workload profile first ran directly against the mock, without a gateway, to prove that k6 and the mock deliver it.

| Profile | Cluster | Verified responses | Dropped | Attack p99 | Mock max in flight | Mock throttled | Mock replicas | Run |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| latency | shared | 6000 | 0 | 105 ms | 12 | 0% | 2 | [run](shared/20260924T175733Z-calibration-latency) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790272657240&to=1790272783073&var-tenant=All) |
| latency | dedicated | 6000 | 0 | 106 ms | 8 | 0% | 2 | [run](dedicated/20260924T180746Z-calibration-latency) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790273270580&to=1790273396355&var-tenant=All) |
| flood | shared | 240001 | 0 | 103 ms | 237 | 0% | 2 | [run](shared/20260924T175951Z-calibration-flood) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790272795541&to=1790272921808&var-tenant=All) |
| flood | dedicated | 240000 | 0 | 103 ms | 223 | 0% | 2 | [run](dedicated/20260924T181004Z-calibration-flood) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790273410029&to=1790273537141&var-tenant=All) |
| slow | shared | 6001 | 0 | 30006 ms | 1508 | 0% | 2 | [run](shared/20260924T180210Z-calibration-slow) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790272934237&to=1790273089335&var-tenant=All) |
| slow | dedicated | 6001 | 0 | 30007 ms | 1504 | 0% | 2 | [run](dedicated/20260924T181225Z-calibration-slow) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790273549752&to=1790273705868&var-tenant=All) |
| memory | shared | 6001 | 0 | 30006 ms | 1519 | 0% | 2 | [run](shared/20260924T180454Z-calibration-memory) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790273099589&to=1790273256605&var-tenant=All) |
| memory | dedicated | 6001 | 0 | 30006 ms | 1502 | 0% | 2 | [run](dedicated/20260924T215801Z-calibration-memory) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790287085415&to=1790287242278&var-tenant=All) |

## Tenant separation

**shared** ([run](shared/20260924T184141Z-scenario-separation) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790275306491&to=1790275333853&var-tenant=All)), every check passed:

- Pass: No key is refused (agentgateway-system) (HTTP 401)
- Pass: An invalid key is refused (agentgateway-system) (HTTP 401)
- Pass: tenant-01 is served with its own provider key (HTTP 200, key owner tenant-01)
- Pass: tenant-02 is served with its own provider key (HTTP 200, key owner tenant-02)
- Pass: tenant-03 is served with its own provider key (HTTP 200, key owner tenant-03)
- Pass: A forged x-tenant header does not reach tenant-02 (HTTP 200, key owner tenant-01)
- Pass: tenant-01 is limited after spending its budget (429 on request 1 at 100 tokens per minute)
- Pass: tenant-02 is not limited by tenant-01's budget (HTTP 200)
- Pass: tenant-03 is not limited by tenant-01's budget (HTTP 200)
- Pass: No probe reached another tenant's provider key (432 probe requests, 0 leaks)
- Pass: The leak detector flags a wrong key owner (101 control requests, 101 flagged)
- Pass: The leak detector flags a wrong echoed probe ID (101 control requests, 101 flagged)
- Pass: Gateway metrics attribute traffic to each tenant (tenant-01=164, tenant-02=163, tenant-03=163)
- Pass: Recorded: the shared controller can list Secrets outside its namespace (yes)

**dedicated** ([run](dedicated/20260924T184240Z-scenario-separation) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790275366296&to=1790275396998&var-tenant=All)), every check passed:

- Pass: No key is refused (tenant-01) (HTTP 401)
- Pass: An invalid key is refused (tenant-01) (HTTP 401)
- Pass: No key is refused (tenant-02) (HTTP 401)
- Pass: An invalid key is refused (tenant-02) (HTTP 401)
- Pass: No key is refused (tenant-03) (HTTP 401)
- Pass: An invalid key is refused (tenant-03) (HTTP 401)
- Pass: tenant-01 is served with its own provider key (HTTP 200, key owner tenant-01)
- Pass: tenant-02 is served with its own provider key (HTTP 200, key owner tenant-02)
- Pass: tenant-03 is served with its own provider key (HTTP 200, key owner tenant-03)
- Pass: tenant-01's key is refused by tenant-02's gateway (HTTP 401)
- Pass: tenant-01's key is refused by tenant-03's gateway (HTTP 401)
- Pass: tenant-02's key is refused by tenant-01's gateway (HTTP 401)
- Pass: tenant-02's key is refused by tenant-03's gateway (HTTP 401)
- Pass: tenant-03's key is refused by tenant-01's gateway (HTTP 401)
- Pass: tenant-03's key is refused by tenant-02's gateway (HTTP 401)
- Pass: A forged x-tenant header does not reach tenant-02 (HTTP 200, key owner tenant-01)
- Pass: tenant-01 is limited after spending its budget (429 on request 1 at 100 tokens per minute)
- Pass: tenant-02 is not limited by tenant-01's budget (HTTP 200)
- Pass: tenant-03 is not limited by tenant-01's budget (HTTP 200)
- Pass: No probe reached another tenant's provider key (483 probe requests, 0 leaks)
- Pass: The leak detector flags a wrong key owner (101 control requests, 101 flagged)
- Pass: The leak detector flags a wrong echoed probe ID (101 control requests, 101 flagged)
- Pass: Gateway metrics attribute traffic to each tenant (tenant-01=173, tenant-02=190, tenant-03=186)
- Pass: Recorded: tenant-01's controller can list Secrets in tenant-02 (yes (the chart grants cluster-wide Secret read))

## Failure modes

In the tables below, a probe counts as failed when it was not verified: a transport failure (status 0), an error status such as 401 or 500, or a leak, which can carry status 200. Failed time and episodes therefore include leaked responses, which are a confidentiality failure rather than unavailability.

## Noisy neighbour

### One tenant floods

tenant-01 sends 2,000 requests per second for 2 minutes and keeps its normal token limit, so the gateway refuses most of them with 429. tenant-02 and tenant-03 keep sending probes. With `RAISE_LIMIT=1`, tenant-01's limit is raised so the flood reaches the mock.

**shared** ([run](shared/20260924T200531Z-failure-flood) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790280337392&to=1790280513626&var-tenant=All)). Target: proxy agentgateway-system/agentgateway-proxy (serves 3). Invocation: 240003 flood requests sent, 237923 refused with 429 at the tenant limit. Host load average during the run: 4.98 (max 6.20) on 10 CPUs.

Matching calibration: [flood](shared/20260924T175951Z-calibration-flood).

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 (cause) | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 7.5 s; health was confirmed 12.8 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

**dedicated** ([run](dedicated/20260924T200853Z-failure-flood) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790280540954&to=1790280719567&var-tenant=All)). Target: proxy tenant-01/agentgateway-proxy (serves 1). Invocation: 239999 flood requests sent, 237267 refused with 429 at the tenant limit. Host load average during the run: 5.61 (max 6.36) on 10 CPUs.

Matching calibration: [flood](dedicated/20260924T181004Z-calibration-flood).

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 (cause) | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 10.3 s; health was confirmed 15.6 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

### Slow upstream for one tenant

tenant-01's requests take 30 seconds at the mock, holding about 1,500 requests in flight through its gateway.

**shared** ([run](shared/20260924T201539Z-failure-slow-upstream) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790280946405&to=1790281152962&var-tenant=All)). Target: proxy agentgateway-system/agentgateway-proxy (serves 3). Invocation: the mock held up to 1503 requests in flight. Host load average during the run: 4.85 (max 6.29) on 10 CPUs.

Matching calibration: [slow](shared/20260924T180210Z-calibration-slow).

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 7.7 s; health was confirmed 13.1 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- mock in flight max: `1503`

**dedicated** ([run](dedicated/20260924T201933Z-failure-slow-upstream) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790281180174&to=1790281388435&var-tenant=All)). Target: proxy tenant-01/agentgateway-proxy (serves 1). Invocation: the mock held up to 1504 requests in flight. Host load average during the run: 7.71 (max 11.75) on 10 CPUs.

Matching calibration: [slow](dedicated/20260924T181225Z-calibration-slow).

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 9.9 s; health was confirmed 15.2 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- mock in flight max: `1504`

### Proxy memory exhaustion

tenant-01 sends 256 KiB prompts that the mock holds for 30 seconds (about 1,500 in flight), aiming at the proxy's 512 MiB limit.

**shared** ([run](shared/20260924T210906Z-failure-proxy-memory) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790284154126&to=1790284380512&var-tenant=All)). Target: proxy agentgateway-system/agentgateway-proxy (serves 3). Invocation: the proxy was OOM-killed at 2026-09-24T21:11:35Z; maximum sampled working set 406 MiB. Host load average during the run: 6.4 (max 7.52) on 10 CPUs.

Matching calibration: [memory](shared/20260924T180454Z-calibration-memory).

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | yes (material) | 3 | 27.6 s | 0×138 | 80 (max 7310 ms) | 0 | 130.3 s |
| tenant-02 | yes (material) | 6 | 28.4 s | 0×142 | 76 (max 7308 ms) | 0 | 136.5 s |
| tenant-03 | yes (material) | 15 | 30 s | 0×150 | 68 (max 7308 ms) | 0 | 137.5 s |

Restore took 8.6 s; health was confirmed 14 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- proxy max sampled working set bytes: `426115072`

**dedicated** ([run](dedicated/20260924T211322Z-failure-proxy-memory) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790284409975&to=1790284640570&var-tenant=All)). Target: proxy tenant-01/agentgateway-proxy (serves 1). Invocation: the proxy was OOM-killed at 2026-09-24T21:15:53Z; maximum sampled working set 474 MiB. Host load average during the run: 7.86 (max 14.72) on 10 CPUs.

Matching calibration: [memory](dedicated/20260924T215801Z-calibration-memory).

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | yes (material) | 16 | 32.2 s | 0×161 | 61 (max 7310 ms) | 0 | 140.5 s |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 12.4 s; health was confirmed 18 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- proxy max sampled working set bytes: `497201152`

## Blast radius

### Proxy crash

The proxy serving tenant-01 is killed with SIGKILL (the one shared proxy, or tenant-01's own). Each run starts from a proxy that has run for 10 minutes, so the kubelet's restart back-off does not lengthen the outage.

**shared** ([run](shared/20260924T192637Z-failure-proxy-crash) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790278004305&to=1790278174533&var-tenant=All)). Target: proxy agentgateway-system/agentgateway-proxy (serves 3). Invocation: the killed container exited with code 137; the same pod restarted it (restartCount 9). Host load average during the run: 4.35 (max 5.43) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | yes | 1 | 0.8 s | 0×4 | 8 (max 2190 ms) | 0 | 1.3 s |
| tenant-02 | yes | 2 | 1 s | 0×5 | 7 (max 2191 ms) | 0 | 2.1 s |
| tenant-03 | yes | 1 | 0.8 s | 0×4 | 8 (max 2190 ms) | 0 | 1.3 s |

Restore took 7.8 s; health was confirmed 12.9 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- killed container: `{"exit_code":137,"reason":"Error","finished_at":"2026-09-24T19:27:15.791767922Z"}`

**dedicated** ([run](dedicated/20260924T192954Z-failure-proxy-crash) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790278200280&to=1790278374603&var-tenant=All)). Target: proxy tenant-01/agentgateway-proxy (serves 1). Invocation: the killed container exited with code 137; the same pod restarted it (restartCount 5). Host load average during the run: 6.91 (max 9.00) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | yes (material) | 1 | 2.4 s | 0×12 | 3 (max 1153 ms) | 0 | 3 s |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 9.7 s; health was confirmed 17.2 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- killed container: `{"exit_code":137,"reason":"Error","finished_at":"2026-09-24T19:30:31.802849721Z"}`

### Bad configuration for one tenant

tenant-01's token limit entry gets an invalid CEL expression, in the shared limit policy or in tenant-01's own.

**shared** ([run](shared/20260924T193514Z-failure-bad-tenant-config) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790278519970&to=1790278704191&var-tenant=All)). Target: token limit policy agentgateway-system/tenant-limits (serves 3). Invocation: the applied policy holds the invalid expression; status Accepted=True,Attached=True. Host load average during the run: 6.49 (max 8.06) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 7.8 s; health was confirmed 15.4 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- policy status: `[{"type":"Accepted","status":"True","reason":"PartiallyValid","message":"condition CEL expression is invalid: apiKey.tenant =="},{"type":"Attached","status":"True","reason":"Attached","message":"Attached to all targets"}]`
- enforced limits: `[{"tenant":"tenant-01","enforced":""},{"tenant":"tenant-02","enforced":"20000"},{"tenant":"tenant-03","enforced":"20000"}]`

**dedicated** ([run](dedicated/20260924T193843Z-failure-bad-tenant-config) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790278728780&to=1790278912949&var-tenant=All)). Target: token limit policy tenant-01/tenant-limits (serves 1). Invocation: the applied policy holds the invalid expression; status Accepted=True,Attached=True. Host load average during the run: 7.37 (max 8.74) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 10.3 s; health was confirmed 15.6 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- policy status: `[{"type":"Accepted","status":"True","reason":"PartiallyValid","message":"condition CEL expression is invalid: apiKey.tenant =="},{"type":"Attached","status":"True","reason":"Attached","message":"Attached to all targets"}]`
- enforced limits: `[{"tenant":"tenant-01","enforced":""},{"tenant":"tenant-02","enforced":"20000"},{"tenant":"tenant-03","enforced":"20000"}]`

### Controller outage

The controller serving tenant-01 is stopped; traffic continues, and limits for tenant-01 and tenant-02 are changed during the outage.

**shared** ([run](shared/20260924T202550Z-failure-controller-outage) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790281556131&to=1790281773108&var-tenant=All)). Target: controller agentgateway-system/agentgateway (serves 3). Invocation: the controller had zero ready replicas; changes applied during the outage: tenant-01=false, tenant-02=false. Host load average during the run: 4.22 (max 11.49) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 23.2 s; health was confirmed 28.5 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- controller: agentgateway
- controller ready replicas during: `0`
- requested changes: `[{"tenant":"tenant-01","requested":21000},{"tenant":"tenant-02","requested":21000}]`
- changes during outage: `[{"tenant":"tenant-01","requested":21000,"enforced_after_30s":20000,"applied":false},{"tenant":"tenant-02","requested":21000,"enforced_after_30s":20000,"applied":false}]`
- pending changes applied after restart: `true`

**dedicated** ([run](dedicated/20260924T202953Z-failure-controller-outage) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790281799318&to=1790282018278&var-tenant=All)). Target: controller tenant-01/agw-tenant-01-agentgateway (serves 1). Invocation: the controller had zero ready replicas; changes applied during the outage: tenant-01=false, tenant-02=true. Host load average during the run: 10.94 (max 22.77) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 26.1 s; health was confirmed 31.4 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- controller: agw-tenant-01-agentgateway
- controller ready replicas during: `0`
- requested changes: `[{"tenant":"tenant-01","requested":21000},{"tenant":"tenant-02","requested":21000}]`
- changes during outage: `[{"tenant":"tenant-01","requested":21000,"enforced_after_30s":20000,"applied":false},{"tenant":"tenant-02","requested":21000,"enforced_after_30s":21000,"applied":true}]`
- pending changes applied after restart: `true`

## Cross-tenant leakage

### The same API key stored for two tenants

tenant-02's key entry is given tenant-01's key hash.

**shared** ([run](shared/20260924T195717Z-failure-duplicate-key) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790279842348&to=1790280013076&var-tenant=All)). Target: key authentication in agentgateway-system/tenant-auth (serves 3). Invocation: tenant-02's key entry holds tenant-01's key hash. Host load average during the run: 8.09 (max 10.89) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | yes (material) | 1 | 125.6 s | 200×628 | 0 | 628 | 126.2 s |
| tenant-02 | yes (material) | 1 | 125.6 s | 401×628 | 0 | 0 | 126.2 s |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 8.5 s; health was confirmed 13.8 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

**Leaks: 628.**

**dedicated** ([run](dedicated/20260924T200033Z-failure-duplicate-key) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790280038524&to=1790280210775&var-tenant=All)). Target: key authentication in tenant-02/tenant-auth (serves 1). Invocation: tenant-02's key entry holds tenant-01's key hash. Host load average during the run: 5.94 (max 9.08) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | yes (material) | 1 | 127 s | 401×635 | 0 | 0 | 127.5 s |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Extra streams: cross-tenant-01-at-tenant-02: blocked 231, leak 635

Restore took 10.1 s; health was confirmed 15.4 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

**Leaks: 635.**

### Wrong provider credential

First half: tenant-02's backend references a Secret named after tenant-01's provider key. Second half: tenant-02's own provider Secret holds tenant-01's key.

**shared** ([run](shared/20260924T204439Z-failure-wrong-credential) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790282686869&to=1790282858090&var-tenant=All)). Target: backend agentgateway-system/mock-tenant-02 (serves 1). Invocation: first half: tenant-02's backend referenced mock-provider-tenant-01; second half: tenant-02's Secret held tenant-01's key (compared by hash). Host load average during the run: 16.43 (max 30.49) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | yes (material) | 2 | 125.8 s | 200×629 | 0 | 629 | 126.6 s |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Leaks: first half 301, second half 302, during the restore 26.

Restore took 8.1 s; health was confirmed 13.6 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

**Leaks: 629.**

Recorded facts:

- reference mistake: `{"secretRef":"mock-provider-tenant-01","status":[{"type":"Accepted","status":"True","reason":"Accepted","message":"Backend successfully accepted"}]}`

**dedicated** ([run](dedicated/20260924T204800Z-failure-wrong-credential) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790282886360&to=1790283059657&var-tenant=All)). Target: backend tenant-02/mock (serves 1). Invocation: first half: tenant-02's backend referenced mock-provider-tenant-01; second half: tenant-02's Secret held tenant-01's key (compared by hash). Host load average during the run: 8.28 (max 10.89) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | yes (material) | 2 | 127 s | 200×329 500×306 | 0 | 329 | 128 s |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Leaks: first half 0, second half 296, during the restore 33.

Restore took 10.7 s; health was confirmed 16 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

**Leaks: 329.**

Recorded facts:

- reference mistake: `{"secretRef":"mock-provider-tenant-01","status":[{"type":"Accepted","status":"False","reason":"TranslationError","message":"failed to translate backend: secret tenant-02/mock-provider-tenant-01 not found"}]}`

### Forged tenant header

tenant-01 sends `x-tenant: tenant-02`. In the second half of the shared run, the routing policy is changed to trust a client-supplied header, simulating a platform mistake.

**shared** ([run](shared/20260924T205922Z-failure-forged-tenant-header) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790283568465&to=1790283741448&var-tenant=All)). Target: tenant routing in proxy agentgateway-system/agentgateway-proxy (serves 3). Invocation: 766 forged requests sent; in the second half the routing policy trusted the client header. Host load average during the run: 6.82 (max 10.21) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Extra streams: forged-tenant-01: leak 345, verified 525

Leaks: first half 0, second half 307, during the restore 38.

Restore took 8.9 s; health was confirmed 14.8 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

**Leaks: 345.**

Recorded facts:

- mistaken routing value: "x-tenant" in request.headers ? request.headers["x-tenant"] : apiKey.tenant

**dedicated** ([run](dedicated/20260924T210244Z-failure-forged-tenant-header) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790283770945&to=1790283944571&var-tenant=All)). Target: tenant routing in proxy tenant-01/agentgateway-proxy (serves 1). Invocation: 1527 forged requests sent to tenant-01's own gateway and to tenant-02's gateway. Host load average during the run: 13.67 (max 20.04) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Extra streams: forged-tenant-01: verified 872; forged-tenant-01-at-tenant-02: blocked 872

Leaks: first half 0, second half 0, during the restore 0.

Restore took 10.6 s; health was confirmed 16 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

### Credential rotation

tenant-01's provider key is rotated: the mock stops accepting the old key first, then the gateway's copy is updated.

**shared** ([run](shared/20260924T203638Z-failure-credential-rotation) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790282203527&to=1790282378183&var-tenant=All)). Target: tenant-01's provider key, at the mock and in agentgateway-system (serves 1). Invocation: every mock replica refuses the old key and accepts the new one. Host load average during the run: 11.59 (max 25.64) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | yes (material) | 1 | 2.8 s | 401×14 | 0 | 0 | 5.1 s |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 7.8 s; health was confirmed 15.3 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- rotation steps: `{"mock_rejects_old_key_after_ms":4621,"gateway_copy_updated_after_ms":5632}`
- mock replica statuses: `{"old_key":["401","401"],"new_key":["200","200"]}`

**dedicated** ([run](dedicated/20260924T203958Z-failure-credential-rotation) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790282404408&to=1790282578891&var-tenant=All)). Target: tenant-01's provider key, at the mock and in tenant-01 (serves 1). Invocation: every mock replica refuses the old key and accepts the new one. Host load average during the run: 6.98 (max 10.33) on 10 CPUs.

| Tenant | Affected | Episodes | Failed time | Statuses of failed or leaked probes | Slow requests | Leaks | Healthy after the trigger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenant-01 | yes (material) | 1 | 2.8 s | 401×14 | 0 | 0 | 4.7 s |
| tenant-02 | no | 0 | 0 s |  | 0 | 0 | n/a |
| tenant-03 | no | 0 | 0 s |  | 0 | 0 | n/a |

Restore took 10.4 s; health was confirmed 15.6 s after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).

Recorded facts:

- rotation steps: `{"mock_rejects_old_key_after_ms":4273,"gateway_copy_updated_after_ms":5300}`
- mock replica statuses: `{"old_key":["401","401"],"new_key":["200","200"]}`

## Gateway latency overhead

Three pairs of 2-minute measurements at 50 requests per second (100 ms mock latency), each after a 30-second warm-up, alternating which of direct-to-mock and through-the-gateway went first. The figures are differences in percentiles, not per-request costs.

| Cluster | p50 difference | p95 difference | p99 difference | Host load | Run |
| --- | --- | --- | --- | --- | --- |
| shared | 1 ms (1 to 1) | 1 ms (1 to 2) | 1 ms (1 to 4) | 6.83 (max 10.46) | [run](shared/20260924T185204Z-scenario-latency) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790275926952&to=1790276867867&var-tenant=All) |
| dedicated | 0 ms (0 to 1) | 1 ms (1 to 1) | 0 ms (-1 to 2) | 6.03 (max 9.87) | [run](dedicated/20260924T190808Z-scenario-latency) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790276892543&to=1790277834090&var-tenant=All) |

## Configuration rollout

Every tenant's limit changed by the same amount through the normal command.

| Cluster | Records written | Enforcement objects written | Enforced for every tenant after | Host load | Run |
| --- | --- | --- | --- | --- | --- |
| shared | 3 | 1 | 2892 ms | 5.44 (max 5.70) | [run](shared/20260924T184426Z-scenario-rollout) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790275468891&to=1790275471783&var-tenant=All) |
| dedicated | 3 | 3 | 4245 ms | 6.78 (max 7.36) | [run](dedicated/20260924T184451Z-scenario-rollout) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790275494146&to=1790275498391&var-tenant=All) |

## Foundry smoke test

One real prompt per tenant through Foundry (at most 32 completion tokens).

- **shared**: tenant-01 HTTP 200, tenant-02 HTTP 200, tenant-03 HTTP 200 ([run](shared/20260924T184802Z-scenario-foundry-smoke) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790275673251&to=1790275705938&var-tenant=All))
- **dedicated**: tenant-01 HTTP 200, tenant-02 HTTP 200, tenant-03 HTTP 200 ([run](dedicated/20260924T184823Z-scenario-foundry-smoke) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790275695022&to=1790275725901&var-tenant=All))

## Onboarding and offboarding

Every `tenant-add` and `tenant-remove` measures itself with a probe started before anything changes. Times are from the Kind node's clock.

Rows are grouped by configuration: the number of tenants before the change, the limit, the mock replicas, and whether Foundry was connected. Medians of an even number of runs average the middle two.

**Onboarding**

| Tenants before | Measure | Shared | Dedicated |
| --- | --- | --- | --- |
| 1 | Limit enforced after (key still inactive) | 1637 ms (1 run) | 9259 ms (1 run) |
| 1 | Usable after | 2470 ms (1 run) | 10264 ms (1 run) |
| 1 | Own Foundry connection after | n/a | 18902 ms (1 run) |
| 2 | Limit enforced after (key still inactive) | 1603 ms (1 run) | 9075 ms (1 run) |
| 2 | Usable after | 2406 ms (1 run) | 9633 ms (1 run) |
| 2 | Own Foundry connection after | n/a | 18415 ms (1 run) |
| 3 | Limit enforced after (key still inactive) | 1511 ms (1 run) | 8646 ms (1 run) |
| 3 | Usable after | 2417 ms (1 run) | 9617 ms (1 run) |
| 3 | Own Foundry connection after | n/a | 17269 ms (1 run) |
| 4 | Limit enforced after (key still inactive) | 1447 ms (1 run) | 9183 ms (1 run) |
| 4 | Usable after | 2196 ms (1 run) | 9876 ms (1 run) |
| 4 | Own Foundry connection after | n/a | 18296 ms (1 run) |
| 5 | Limit enforced after (key still inactive) | 1508 ms (1 run) | 8843 ms (1 run) |
| 5 | Usable after | 2502 ms (1 run) | 9692 ms (1 run) |
| 5 | Own Foundry connection after | n/a | 17441 ms (1 run) |
| 6 | Limit enforced after (key still inactive) | 1549 ms (1 run) | 9281 ms (1 run) |
| 6 | Usable after | 2434 ms (1 run) | 9845 ms (1 run) |
| 6 | Own Foundry connection after | n/a | 18945 ms (1 run) |
| 7 | Limit enforced after (key still inactive) | 2555 ms (1 run) | 9471 ms (1 run) |
| 7 | Usable after | 3170 ms (1 run) | 10279 ms (1 run) |
| 7 | Own Foundry connection after | n/a | 19170 ms (1 run) |
| 8 | Limit enforced after (key still inactive) | 1466 ms (1 run) | 8222 ms (1 run) |
| 8 | Usable after | 2228 ms (1 run) | 9502 ms (1 run) |
| 8 | Own Foundry connection after | n/a | 17896 ms (1 run) |
| 9 | Limit enforced after (key still inactive) | 1500 ms (1 run) | 8886 ms (1 run) |
| 9 | Usable after | 2288 ms (1 run) | 9413 ms (1 run) |
| 9 | Own Foundry connection after | n/a | 17988 ms (1 run) |

Runs behind these rows:

- 1 tenant before: dedicated tenant-02 ([run](dedicated/20260924T214235Z-onboarding-tenant-02) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286149938&to=1790286188840&var-tenant=All); host load 10.51 (max 11.73)); shared tenant-02 ([run](shared/20260924T212536Z-onboarding-tenant-02) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285129696&to=1790285152166&var-tenant=All); host load 7.79 (max 7.80))
- 2 tenants before: dedicated tenant-03 ([run](dedicated/20260924T214306Z-onboarding-tenant-03) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286180482&to=1790286218897&var-tenant=All); host load 9.73 (max 10.43)); shared tenant-03 ([run](shared/20260924T212556Z-onboarding-tenant-03) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285150973&to=1790285173379&var-tenant=All); host load 11.34 (max 11.55))
- 3 tenants before: dedicated tenant-04 ([run](dedicated/20260924T214336Z-onboarding-tenant-04) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286210117&to=1790286247386&var-tenant=All); host load 8.94 (max 10.68)); shared tenant-04 ([run](shared/20260924T212617Z-onboarding-tenant-04) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285171755&to=1790285194172&var-tenant=All); host load 10.76 (max 11.16))
- 4 tenants before: dedicated tenant-05 ([run](dedicated/20260924T214405Z-onboarding-tenant-05) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286239486&to=1790286277782&var-tenant=All); host load 9.73 (max 9.82)); shared tenant-05 ([run](shared/20260924T212637Z-onboarding-tenant-05) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285191484&to=1790285213680&var-tenant=All); host load 9.89 (max 10.46))
- 5 tenants before: dedicated tenant-06 ([run](dedicated/20260924T214753Z-onboarding-tenant-06) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286467003&to=1790286504444&var-tenant=All); host load 9.23 (max 9.28)); shared tenant-06 ([run](shared/20260924T213016Z-onboarding-tenant-06) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285412143&to=1790285434645&var-tenant=All); host load 8.87 (max 8.95))
- 6 tenants before: dedicated tenant-07 ([run](dedicated/20260924T214821Z-onboarding-tenant-07) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286495502&to=1790286534447&var-tenant=All); host load 7.96 (max 8.37)); shared tenant-07 ([run](shared/20260924T213038Z-onboarding-tenant-07) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285434205&to=1790285456639&var-tenant=All); host load 8.3 (max 8.39))
- 7 tenants before: dedicated tenant-08 ([run](dedicated/20260924T214852Z-onboarding-tenant-08) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286526081&to=1790286565251&var-tenant=All); host load 7.51 (max 7.80)); shared tenant-08 ([run](shared/20260924T213100Z-onboarding-tenant-08) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285454062&to=1790285477232&var-tenant=All); host load 8.87 (max 9.21))
- 8 tenants before: dedicated tenant-09 ([run](dedicated/20260924T214922Z-onboarding-tenant-09) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286556240&to=1790286594136&var-tenant=All); host load 7.17 (max 7.56)); shared tenant-09 ([run](shared/20260924T213120Z-onboarding-tenant-09) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285474646&to=1790285496874&var-tenant=All); host load 9.73 (max 9.92))
- 9 tenants before: dedicated tenant-10 ([run](dedicated/20260924T214952Z-onboarding-tenant-10) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286586466&to=1790286624454&var-tenant=All); host load 9.41 (max 9.76)); shared tenant-10 ([run](shared/20260924T213140Z-onboarding-tenant-10) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285495343&to=1790285517631&var-tenant=All); host load 9.63 (max 9.74))

**Offboarding**

| Tenants before | Measure | Shared | Dedicated |
| --- | --- | --- | --- |
| 2 | Refused by authentication after (upper bound) | 295 ms (1 run) | 303 ms (1 run) |
| 2 | Cleaned after | 9902 ms (1 run) | 13300 ms (1 run) |
| 3 | Refused by authentication after (upper bound) | 164 ms (1 run) | 202 ms (1 run) |
| 3 | Cleaned after | 8179 ms (1 run) | 14262 ms (1 run) |
| 4 | Refused by authentication after (upper bound) | 123 ms (1 run) | 232 ms (1 run) |
| 4 | Cleaned after | 8281 ms (1 run) | 14300 ms (1 run) |
| 5 | Refused by authentication after (upper bound) | 296 ms (1 run) | 256 ms (1 run) |
| 5 | Cleaned after | 8491 ms (1 run) | 14568 ms (1 run) |
| 6 | Refused by authentication after (upper bound) | 191 ms (1 run) | 136 ms (1 run) |
| 6 | Cleaned after | 8134 ms (1 run) | 15128 ms (1 run) |
| 7 | Refused by authentication after (upper bound) | 255 ms (1 run) | 184 ms (1 run) |
| 7 | Cleaned after | 7523 ms (1 run) | 13891 ms (1 run) |
| 8 | Refused by authentication after (upper bound) | 293 ms (1 run) | 244 ms (1 run) |
| 8 | Cleaned after | 7968 ms (1 run) | 16906 ms (1 run) |
| 9 | Refused by authentication after (upper bound) | 106 ms (1 run) | 193 ms (1 run) |
| 9 | Cleaned after | 7851 ms (1 run) | 13986 ms (1 run) |
| 10 | Refused by authentication after (upper bound) | 220 ms (1 run) | 152 ms (1 run) |
| 10 | Cleaned after | 8227 ms (1 run) | 15556 ms (1 run) |

Runs behind these rows:

- 2 tenants before: dedicated tenant-02 ([run](dedicated/20260924T213843Z-offboarding-tenant-02) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790285918799&to=1790285952099&var-tenant=All); host load 11.61 (max 12.41)); shared tenant-02 ([run](shared/20260924T212147Z-offboarding-tenant-02) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790284902899&to=1790284932801&var-tenant=All); host load 8.53 (max 13.52))
- 3 tenants before: dedicated tenant-03 ([run](dedicated/20260924T213812Z-offboarding-tenant-03) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790285888179&to=1790285922441&var-tenant=All); host load 11 (max 12.43)); shared tenant-03 ([run](shared/20260924T212121Z-offboarding-tenant-03) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790284877243&to=1790284905422&var-tenant=All); host load 6.13 (max 6.46))
- 4 tenants before: dedicated tenant-04 ([run](dedicated/20260924T215633Z-offboarding-tenant-04) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286988317&to=1790287022617&var-tenant=All); host load 10.97 (max 11.59)); shared tenant-04 ([run](shared/20260924T213738Z-offboarding-tenant-04) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285853567&to=1790285881848&var-tenant=All); host load 11.31 (max 11.71))
- 5 tenants before: dedicated tenant-05 ([run](dedicated/20260924T215603Z-offboarding-tenant-05) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286958583&to=1790286993151&var-tenant=All); host load 10.86 (max 11.77)); shared tenant-05 ([run](shared/20260924T213712Z-offboarding-tenant-05) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285827926&to=1790285856417&var-tenant=All); host load 9.61 (max 10.27))
- 6 tenants before: dedicated tenant-06 ([run](dedicated/20260924T215532Z-offboarding-tenant-06) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286926643&to=1790286961771&var-tenant=All); host load 11.37 (max 12.31)); shared tenant-06 ([run](shared/20260924T213649Z-offboarding-tenant-06) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285804566&to=1790285832700&var-tenant=All); host load 8.37 (max 8.56))
- 7 tenants before: dedicated tenant-07 ([run](dedicated/20260924T215504Z-offboarding-tenant-07) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286898871&to=1790286932762&var-tenant=All); host load 13.27 (max 14.40)); shared tenant-07 ([run](shared/20260924T213625Z-offboarding-tenant-07) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285780711&to=1790285808234&var-tenant=All); host load 9.62 (max 9.92))
- 8 tenants before: dedicated tenant-08 ([run](dedicated/20260924T215431Z-offboarding-tenant-08) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286866559&to=1790286903465&var-tenant=All); host load 9.2 (max 9.93)); shared tenant-08 ([run](shared/20260924T213602Z-offboarding-tenant-08) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285757447&to=1790285785415&var-tenant=All); host load 9.89 (max 10.44))
- 9 tenants before: dedicated tenant-09 ([run](dedicated/20260924T215404Z-offboarding-tenant-09) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286838731&to=1790286872717&var-tenant=All); host load 10.68 (max 11.16)); shared tenant-09 ([run](shared/20260924T213538Z-offboarding-tenant-09) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285733215&to=1790285761066&var-tenant=All); host load 9.42 (max 9.73))
- 10 tenants before: dedicated tenant-10 ([run](dedicated/20260924T215335Z-offboarding-tenant-10) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286809938&to=1790286845494&var-tenant=All); host load 11.16 (max 11.43)); shared tenant-10 ([run](shared/20260924T213515Z-offboarding-tenant-10) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285710052&to=1790285738279&var-tenant=All); host load 8.43 (max 9.21))

Objects created per tenant: shared 3, dedicated 15. Shared objects changed per tenant: shared 2, dedicated 0.

Revocation (from deactivating the key to authentication refusing it) is reported per run as an interval between the last success and the first of 25 refusals: dedicated tenant-03 3 to 202 ms; dedicated tenant-02 102 to 303 ms; dedicated tenant-10 -50 to 152 ms; dedicated tenant-09 -7 to 193 ms; dedicated tenant-08 45 to 244 ms; dedicated tenant-07 -16 to 184 ms; dedicated tenant-06 -63 to 136 ms; dedicated tenant-05 56 to 256 ms; dedicated tenant-04 31 to 232 ms; shared tenant-03 -36 to 164 ms; shared tenant-02 93 to 295 ms; shared tenant-10 20 to 220 ms; shared tenant-09 -95 to 106 ms; shared tenant-08 92 to 293 ms; shared tenant-07 54 to 255 ms; shared tenant-06 -9 to 191 ms; shared tenant-05 96 to 296 ms; shared tenant-04 -77 to 123 ms.

## Footprint

Gateway pods only (controllers and proxies), at each tenant count, idle and under 1 request per second per tenant. Memory is the maximum of 5-second samples.

| Tenants | Cluster | Gateway pods | CPU idle / load (cores) | Memory idle / load (MiB) | Reserved requests (CPU, MiB) | Active gateway series | Kind node MiB | Host load | Run |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | shared | 2 | 0.003 / 0.005 | 59 / 59 | 0.2, 256 | 538 | 4023 | 9.4 (max 11.44) | [run](shared/20260924T212213Z-scale-tenants-1) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790284934926&to=1790285117785&var-tenant=All) |
| 1 | dedicated | 2 | 0.004 / 0.005 | 55 / 56 | 0.2, 256 | 665 | 3996 | 8.35 (max 10.83) | [run](dedicated/20260924T213913Z-scale-tenants-1) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790285954423&to=1790286136367&var-tenant=All) |
| 5 | shared | 2 | 0.005 / 0.007 | 60 / 62 | 0.2, 256 | 744 | 4108 | 7.33 (max 10.62) | [run](shared/20260924T212652Z-scale-tenants-5) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285213592&to=1790285396770&var-tenant=All) |
| 5 | dedicated | 10 | 0.016 / 0.02 | 253 / 254 | 1, 1280 | 1534 | 4441 | 7.27 (max 9.28) | [run](dedicated/20260924T214432Z-scale-tenants-5) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286273204&to=1790286455859&var-tenant=All) |
| 10 | shared | 2 | 0.004 / 0.007 | 60 / 67 | 0.2, 256 | 1335 | 4073 | 8.07 (max 11.36) | [run](shared/20260924T213158Z-scale-tenants-10) · [Grafana](http://127.0.0.1:38484/d/mtag-tenants?from=1790285520076&to=1790285703121&var-tenant=All) |
| 10 | dedicated | 20 | 0.027 / 0.035 | 507 / 510 | 2, 2560 | 3150 | 4832 | 6.87 (max 8.90) | [run](dedicated/20260924T215020Z-scale-tenants-10) · [Grafana](http://127.0.0.1:38494/d/mtag-tenants?from=1790286621724&to=1790286804867&var-tenant=All) |

## Structural findings

- **Shared-design ceiling**: one conditional rate-limit policy and one HTTPRoute each hold at most 16 entries (`rateLimit.conditional` and HTTPRoute `rules` have `maxItems: 16`), so the shared design as built holds at most 16 tenants.
- **Controller Secret access**: every agentgateway controller's ClusterRole, as granted by the v1.5.0 chart, can list and read Secrets in every namespace, so the dedicated design does not separate tenant credentials at the Kubernetes permission level.
- **Foundry key copies**: the shared cluster holds one copy of the Azure key; the dedicated cluster holds one per tenant.
- **Parked**: shared provider quota exhaustion (both designs sit in front of one 10,000-token-per-minute deployment; local limits cannot cap the total across separate proxies).

Objects holding tenant-01's settings, and how many tenants share each (from `make tenant-objects`):

**shared**

| Object | Holds | Shared by |
| --- | --- | --- |
| ConfigMap agentgateway-system/tenant-01-key | gateway key hash, tenant name, limit | 1 |
| Secret agentgateway-system/mock-provider-tenant-01 | provider key | 1 |
| AgentgatewayBackend agentgateway-system/mock-tenant-01 | upstream and credential reference | 1 |
| AgentgatewayPolicy agentgateway-system/tenant-limits | token limit (one conditional entry) | 3 |
| HTTPRoute agentgateway-system/mock-chat | route rule to the tenant backend | 3 |
| AgentgatewayPolicy agentgateway-system/tenant-auth | key authentication | 3 |
| AgentgatewayPolicy agentgateway-system/tenant-routing | x-tenant from the key | 3 |
| AgentgatewayPolicy agentgateway-system/tenant-telemetry | tenant metric and log label | 3 |
| Gateway and Deployment agentgateway-system/agentgateway-proxy | the proxy serving the tenant | 3 |
| Deployment agentgateway-system/agentgateway | the controller | 3 |
| Secret, backend, and route for Foundry in agentgateway-system | one Azure key copy | 3 |
| CRDs, Kind node, mock upstream | cluster-wide | 3 |

**dedicated**

| Object | Holds | Shared by |
| --- | --- | --- |
| Namespace tenant-01 | every namespaced object below | 1 |
| Helm release agw-tenant-01 (controller Deployment agw-tenant-01-agentgateway) | the tenant own controller | 1 |
| GatewayClass agw-tenant-01 | cluster-wide class owned by the tenant controller | 1 |
| ClusterRoles agentgateway-tenant-01 and agentgateway-tenant-01-deployer | controller permissions, including reading Secrets in every namespace | 1 |
| Gateway, AgentgatewayParameters, and proxy Deployment tenant-01/agentgateway-proxy | the proxy serving the tenant | 1 |
| tenant-01/tenant-auth, tenant-telemetry, tenant-limits | authentication, telemetry, token limit (one conditional entry) | 1 |
| tenant-01/mock-chat, tenant-key, mock-provider, mock | route, key hash and limit, provider key, backend | 1 |
| Secret, backend, and route for Foundry in tenant-01 | one of 3 Azure key copies | 1 |
| CRDs (one version), Kind node, mock upstream, Foundry deployment | cluster-wide and upstream | 3 |

## Excluded runs

| Run | Reason |
| --- | --- |
| [dedicated calibration memory](dedicated/20260924T181511Z-calibration-memory) | confounded: the other Kind node averaged 0.55 CPU |

## Usable runs not shown above

None.

