# Renders results/report.md from every run record. Input: {runs: [...], current_fingerprint, commit,
# generated_at, structure: {shared, dedicated}}. Each run carries .dir (its directory under results/).

def ms(v): if v == null then "n/a" else "\(v) ms" end;
def sec(v): if v == null then "n/a" else "\((v / 100 | round) / 10) s" end;
def yesno(v): if v then "yes" else "no" end;
def cell(v): if v == null then "n/a" else (v | tostring) end;
def link(r): "[run](\(r.dir))" + (if r.grafana.tenants? then " · [Grafana](\(r.grafana.tenants))" else "" end);
def median($v): ($v | sort) as $s | ($s | length) as $n |
  if $n == 0 then null elif $n % 2 == 1 then $s[($n - 1) / 2] else (($s[$n / 2 - 1] + $s[$n / 2]) / 2) end;
# Leaks outside the positive controls, wherever each kind of record keeps them.
def leak_count: (.leaks_total // .leaks // .load.verdicts.leak // 0);

# Why a run cannot be used in a comparison, or null when it can. Every kind of record needs a
# contention verdict: the other cluster's Kind node averaged at most 0.5 CPU during the run.
def exclusion($fp):
  if .inputs_committed != true then "made with uncommitted code"
  elif .inputs_changed_during_run == true then "code changed during the run"
  elif .input_fingerprint != $fp then "stale: the implementation changed after this run"
  elif .failed == true then "failed: " + (.reason // "unknown")
  elif .contention == null then "no record of the other cluster's load during the run"
  elif .contention.confounded == null then "the other cluster's load during the run is unknown (no CPU samples)"
  elif .contention.confounded then "confounded: the other Kind node averaged \(.contention.mean_cpu) CPU"
  elif .stopped == true then null
  elif .kind == "failure" and (.validity.valid | not) then "invalid: " + (.validity.reasons | join("; "))
  elif (.kind == "calibration" or .kind == "scale" or (.kind == "scenario" and .name == "latency")) and (.valid != true) then
    "invalid: " + ((.reasons // ["no validity verdict"]) | join("; "))
  elif .kind == "onboarding" and (.usable_after_ms == null or (.leaks // 0) > 0) then "onboarding did not complete cleanly"
  elif .kind == "offboarding" and ((.leaks // 0) > 0 or (.success_after_revocation // 0) > 0 or .revoked_between_ms[1] == null or .cleaned_after_ms == null)
    then "offboarding did not complete cleanly"
  else null end;

(.current_fingerprint) as $fp |
[.runs[] | . + {excluded: exclusion($fp)}] as $all |
[$all[] | select(.excluded == null)] as $usable |

# The latest pair of usable runs of a kind and name whose configuration fingerprints match. Without
# such a pair, the latest run from each cluster is shown and marked as not compared.
def pair($kind; $name):
  ([$usable[] | select(.kind == $kind and .name == $name and .cluster == "shared")] | sort_by(.started_ms // 0)) as $s |
  ([$usable[] | select(.kind == $kind and .name == $name and .cluster == "dedicated")] | sort_by(.started_ms // 0)) as $d |
  ([$s[] as $a | $d[] | select(.config_fingerprint == $a.config_fingerprint) |
    {shared: $a, dedicated: ., at: ([$a.started_ms, .started_ms] | max)}] | sort_by(.at) | last) as $m |
  if $m != null then {shared: $m.shared, dedicated: $m.dedicated, comparable: true}
  else {shared: ($s | last), dedicated: ($d | last), comparable: false} end;

def compare_note($p):
  if $p.comparable then ""
  elif $p.shared != null and $p.dedicated != null then "\n_Not compared: the two runs were made under different configurations (their fingerprints differ)._\n"
  elif $p.shared != null or $p.dedicated != null then "\n_Only one design has a usable run, so there is nothing to compare yet._\n"
  else "" end;

# The calibration that proved a workload on the same apparatus: same cluster, profile, and mock replicas.
def calibration_for($r):
  [$usable[] | select(.kind == "calibration" and .cluster == $r.cluster and .config.profile == $r.config.attack_profile and
                      .config.mock_replicas == $r.config.mock_replicas)] | sort_by(.started_ms) | last;

def impact_rows($r):
  if $r == null then ["| n/a | | | | | | | |"]
  else [$r.impact[] | "| \(.tenant)\(if .cause then " (cause)" else "" end) | \(if .material_impact then "yes (material)" elif .any_impact then "yes" else "no" end) | \(.episodes | length) | \(sec(.failed_time_ms)) | \((.statuses | to_entries | map("\(.key)×\(.value)") | join(" ")) // "") | \(if (.slow.count // 0) > 0 then "\(.slow.count) (max \(.slow.max_ms) ms)" else "0" end) | \(.leaks) | \(sec(.recovery_after_trigger_ms)) |"] end;

# Notes are small facts each failure records about itself, such as policy status or enforced limits.
def note_lines($notes):
  [$notes | del(.before, .restart_history) | to_entries[] |
   "- \(.key | gsub("_"; " ")): " + (if (.value | type) == "string" then .value else "`\(.value | tojson)`" end)] | join("\n");

def failure_section($name; $title; $explain):
  pair("failure"; $name) as $p |
  "### \($title)\n\n\($explain)\n\n" +
  (if ($p.shared == null and $p.dedicated == null) then "No usable run yet.\n"
   else
     ([("shared", $p.shared), ("dedicated", $p.dedicated)] | . as $pairs |
      [range(0; 2) as $i | [$pairs[$i * 2], $pairs[$i * 2 + 1]]] |
      map(.[0] as $cluster | .[1] as $r |
        "**\($cluster)**" + (if $r == null then ": no usable run.\n" else
          " (\(link($r))). Target: \($r.target.component // "n/a") (serves \($r.target.serves // "n/a")). Invocation: \($r.invocation.evidence).\n\n" +
          (if $r.config.attack_profile != null then
            calibration_for($r) as $cal |
            (if $cal == null then "_No usable calibration matches this workload profile and mock replica count._\n\n"
             else "Matching calibration: [\($cal.name)](\($cal.dir)).\n\n" end)
           else "" end) +
          "| Tenant | Affected | Episodes | Failed time | Failed statuses | Slow requests | Leaks | Healthy after the trigger |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n" +
          (impact_rows($r) | join("\n")) + "\n" +
          (if ($r.extra_streams | length) > 0 then "\nExtra streams: " + ([$r.extra_streams[] | "\(.stream): \(.verdicts | to_entries | map("\(.key) \(.value)") | join(", "))"] | join("; ")) + "\n" else "" end) +
          (if $r.halves != null then "\nLeaks: first half \($r.halves.first_half.leaks), second half \($r.halves.second_half.leaks)" + (if $r.halves.during_restore != null then ", during the restore \($r.halves.during_restore.leaks)" else "" end) + ".\n" else "" end) +
          (if $r.recovery != null and $r.recovery.restored then "\nRestore took \(sec($r.recovery.restore_ms)); health was confirmed \(sec($r.recovery.healthy_after_restore_ms)) after it began (25 verified probes per tenant once it finished, so at least 5 seconds more).\n" else "" end) +
          (if $r.leaks_total > 0 then "\n**Leaks: \($r.leaks_total).**\n" else "" end) +
          (if ($r.notes | del(.before, .restart_history) | length) > 0 then "\nRecorded facts:\n\n" + note_lines($r.notes) + "\n" else "" end)
        end)) | join("\n")) + compare_note($p)
   end) + "\n";

# $m names a field of the record, and optionally an index into it.
def stat($runs; $m):
  [$runs[] | .[$m.field] | (if $m.index != null and . != null then .[$m.index] else . end) | select(. != null)] as $v |
  if ($v | length) == 0 then "n/a"
  elif ($v | length) == 1 then "\($v[0]) ms (1 run)"
  else "median \(median($v) | round) ms (\($v | length) runs, \($v | min) to \($v | max))" end;

# Lifecycle runs grouped by configuration fingerprint (tenant count before, limit, mock replicas,
# Foundry), so each row compares the two designs under the same conditions.
def lifecycle_rows($kind; $measures):
  [$usable[] | select(.kind == $kind)] | group_by(.config_fingerprint) | sort_by(.[0].config.tenant_count_before) | map(
    . as $group | [$group[] | select(.cluster == "shared")] as $s | [$group[] | select(.cluster == "dedicated")] as $d |
    ($group[0].config) as $c |
    ($measures[] | "| \($c.tenant_count_before) | \(.label) | \(stat($s; .)) | \(stat($d; .)) |")) | flatten;

# Every run directory that a section below shows, so the rest can be accounted for.
def selected_dirs:
  ([[ "latency", "flood", "slow", "memory" ][] as $profile | ("shared", "dedicated") as $c |
     [$usable[] | select(.kind == "calibration" and .name == $profile and .cluster == $c)] | sort_by(.started_ms) | last | .dir?] +
   [(["separation", "latency", "rollout", "foundry-smoke"][] | pair("scenario"; .)),
    ([$usable[] | select(.kind == "failure") | .name] | unique[] | pair("failure"; .)),
    ([$usable[] | select(.kind == "scale" and (.stopped | not)) | .name] | unique[] | pair("scale"; .)) |
    .shared.dir?, .dedicated.dir?] +
   [$usable[] | select(.kind == "onboarding" or .kind == "offboarding" or (.kind == "scale" and .stopped == true)) | .dir]) |
  map(select(. != null)) | unique;

"# Shared versus dedicated agentgateway: results\n\n" +
"Generated \(.generated_at) from commit `\(.commit)`. This report is written by `make results` from the run records under `results/`; do not edit it by hand.\n\n" +
([$all[] | select(leak_count > 0)] as $leaky |
 if ($leaky | length) > 0 then
   "> **Leaks recorded** in \($leaky | length) run(s). A leak is a response served with another tenant's provider key. Some failures create a cross-tenant mistake on purpose; their leaks show whether a design stops that mistake.\n>\n" +
   ([$leaky[] | "> - \(.cluster) \(.kind) \(.name): \(leak_count) leaks" + (if .excluded == null then "" else " (excluded from comparisons: \(.excluded))" end)] | join("\n")) + "\n\n"
 else "" end) +
"## What is compared\n\n" +
"- **Shared** (`mtag-shared`): one agentgateway, one controller and one proxy, serves every tenant. Tenants are entries in shared objects.\n" +
"- **Dedicated** (`mtag-dedicated`): each tenant has its own complete agentgateway, controller and proxy, in its own namespace.\n\n" +
"\"Separation\" means what namespaces and separate gateways give tenants that share a cluster. \"Isolation\" would mean a dedicated cluster per tenant, which this comparison does not test.\n\n" +
"What the data cannot prove: both clusters run on one laptop, each on a single Kind node that shares Docker Desktop's CPU and memory; the upstream is a mock except for small Foundry smoke tests; token limits are local to each proxy; every proxy has one replica; probe timing precision is 200 ms (five requests per second); memory figures are the maximum of 5-second samples. Security limitations accepted for this proof of concept are listed in FINDINGS.md.\n\n" +
"A run of any kind is compared only if it used committed code that still matches the current implementation, passed its own validity checks, and was not confounded by load on the other cluster (whose Kind node must have averaged at most 0.5 CPU). A shared run and a dedicated run are compared only when their configuration fingerprints match: the same workload, windows, tenants, limits, and mock replicas. Excluded runs, and usable runs not shown in a section, are listed at the end.\n\n" +
"Each run links to its record under `results/` and to the matching time range in Grafana. The Grafana links work only while that cluster and its Prometheus data still exist (Prometheus keeps 15 days).\n\n" +

"## Calibration\n\nEach workload profile first ran directly against the mock, without a gateway, to prove that k6 and the mock deliver it.\n\n" +
"| Profile | Cluster | Verified responses | Dropped | Attack p99 | Mock max in flight | Mock throttled | Mock replicas | Run |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n" +
([[ "latency", "flood", "slow", "memory" ][] as $profile | ("shared", "dedicated") as $c |
  ([$usable[] | select(.kind == "calibration" and .name == $profile and .cluster == $c)] | sort_by(.started_ms) | last) as $r |
  if $r == null then "| \($profile) | \($c) | no usable run | | | | | | |"
  else "| \($profile) | \($c) | \($r.attack.verdicts.verified) | \($r.attack.dropped_iterations) | \($r.attack.duration_ms["p(99)"] | floor) ms | \($r.mock.max_in_flight) | \($r.mock.max_throttled_ratio * 100 | floor)% | \($r.config.mock_replicas) | \(link($r)) |" end] | map(. + "\n") | join("")) + "\n" +

"## Tenant separation\n\n" +
(pair("scenario"; "separation") as $p |
 ([("shared", $p.shared), ("dedicated", $p.dedicated)] | [.[0:2], .[2:4]] | map(.[0] as $c | .[1] as $r |
   "**\($c)**" + (if $r == null then ": no usable run.\n" else " (\(link($r))), \(if $r.passed then "every check passed" else "**some checks failed**" end):\n\n" +
     ([$r.checks[] | "- \(if .passed then "Pass" else "**Fail**" end): \(.name) (\(.evidence))"] | join("\n")) + "\n" end)) | join("\n")) + compare_note($p) + "\n") +

"## Noisy neighbour\n\n" +
failure_section("flood"; "One tenant floods"; "tenant-01 sends 2,000 requests per second for 2 minutes and keeps its normal token limit, so the gateway refuses most of them with 429. tenant-02 and tenant-03 keep sending probes. With `RAISE_LIMIT=1`, tenant-01's limit is raised so the flood reaches the mock.") +
failure_section("slow-upstream"; "Slow upstream for one tenant"; "tenant-01's requests take 30 seconds at the mock, holding about 1,500 requests in flight through its gateway.") +
failure_section("proxy-memory"; "Proxy memory exhaustion"; "tenant-01 sends 256 KiB prompts that the mock holds for 30 seconds (about 1,500 in flight), aiming at the proxy's 512 MiB limit.") +

"## Blast radius\n\n" +
failure_section("proxy-crash"; "Proxy crash"; "The proxy serving tenant-01 is killed with SIGKILL (the one shared proxy, or tenant-01's own). Each run starts from a proxy that has run for 10 minutes, so the kubelet's restart back-off does not lengthen the outage.") +
failure_section("bad-tenant-config"; "Bad configuration for one tenant"; "tenant-01's token limit entry gets an invalid CEL expression, in the shared limit policy or in tenant-01's own.") +
failure_section("controller-outage"; "Controller outage"; "The controller serving tenant-01 is stopped; traffic continues, and limits for tenant-01 and tenant-02 are changed during the outage.") +

"## Cross-tenant leakage\n\n" +
failure_section("duplicate-key"; "The same API key stored for two tenants"; "tenant-02's key entry is given tenant-01's key hash.") +
failure_section("wrong-credential"; "Wrong provider credential"; "First half: tenant-02's backend references a Secret named after tenant-01's provider key. Second half: tenant-02's own provider Secret holds tenant-01's key.") +
failure_section("forged-tenant-header"; "Forged tenant header"; "tenant-01 sends `x-tenant: tenant-02`. In the second half of the shared run, the routing policy is changed to trust a client-supplied header, simulating a platform mistake.") +
failure_section("credential-rotation"; "Credential rotation"; "tenant-01's provider key is rotated: the mock stops accepting the old key first, then the gateway's copy is updated.") +

"## Gateway latency overhead\n\n" +
(pair("scenario"; "latency") as $p |
 "Three pairs of 2-minute measurements at 50 requests per second (100 ms mock latency), each after a 30-second warm-up, alternating which of direct-to-mock and through-the-gateway went first. The figures are differences in percentiles, not per-request costs.\n\n" +
 "| Cluster | p50 difference | p95 difference | p99 difference | Run |\n| --- | --- | --- | --- | --- |\n" +
 ([("shared", $p.shared), ("dedicated", $p.dedicated)] | [.[0:2], .[2:4]] | map(.[0] as $c | .[1] as $r |
   if $r == null then "| \($c) | no usable run | | | |" else
   "| \($c) | \($r.difference_ms.p50.median) ms (\($r.difference_ms.p50.min) to \($r.difference_ms.p50.max)) | \($r.difference_ms.p95.median) ms (\($r.difference_ms.p95.min) to \($r.difference_ms.p95.max)) | \($r.difference_ms.p99.median) ms (\($r.difference_ms.p99.min) to \($r.difference_ms.p99.max)) | \(link($r)) |" end) | join("\n")) + "\n" + compare_note($p) + "\n") +

"## Configuration rollout\n\n" +
(pair("scenario"; "rollout") as $p |
 "Every tenant's limit changed by the same amount through the normal command.\n\n" +
 "| Cluster | Records written | Enforcement objects written | Enforced for every tenant after | Run |\n| --- | --- | --- | --- | --- |\n" +
 ([("shared", $p.shared), ("dedicated", $p.dedicated)] | [.[0:2], .[2:4]] | map(.[0] as $c | .[1] as $r |
   if $r == null then "| \($c) | no usable run | | | |" else
   "| \($c) | \($r.records_written) | \($r.enforcement_objects_written) | \(ms($r.enforced_everywhere_after_ms)) | \(link($r)) |" end) | join("\n")) + "\n" + compare_note($p) + "\n") +

"## Foundry smoke test\n\n" +
(pair("scenario"; "foundry-smoke") as $p |
 "One real prompt per tenant through Foundry (at most 32 completion tokens).\n\n" +
 ([("shared", $p.shared), ("dedicated", $p.dedicated)] | [.[0:2], .[2:4]] | map(.[0] as $c | .[1] as $r |
   "- **\($c)**: " + (if $r == null then "no usable run" else ([$r.results[] | "\(.tenant) HTTP \(.status // "none")"] | join(", ")) + " (\(link($r)))" end)) | join("\n")) +
 "\n" + compare_note($p) + "\n") +

"## Onboarding and offboarding\n\n" +
"Every `tenant-add` and `tenant-remove` measures itself with a probe started before anything changes. Times are from the Kind node's clock.\n\n" +
"Rows are grouped by configuration: the number of tenants before the change, the limit, the mock replicas, and whether Foundry was connected. Medians of an even number of runs average the middle two.\n\n" +
"**Onboarding**\n\n| Tenants before | Measure | Shared | Dedicated |\n| --- | --- | --- | --- |\n" +
(lifecycle_rows("onboarding"; [{label: "Limit enforced after (key still inactive)", field: "enforced_after_ms"},
   {label: "Usable after", field: "usable_after_ms"}, {label: "Own Foundry connection after", field: "foundry_connected_after_ms"}])
   | if length == 0 then "| n/a | | | |" else join("\n") end) + "\n\n" +
"**Offboarding**\n\n| Tenants before | Measure | Shared | Dedicated |\n| --- | --- | --- | --- |\n" +
(lifecycle_rows("offboarding"; [{label: "Refused by authentication after (upper bound)", field: "revoked_between_ms", index: 1},
   {label: "Cleaned after", field: "cleaned_after_ms"}]) | if length == 0 then "| n/a | | | |" else join("\n") end) + "\n\n" +
"Objects created per tenant: shared \([$usable[] | select(.kind == "onboarding" and .cluster == "shared") | .objects_created | length] | first // "n/a"), dedicated \([$usable[] | select(.kind == "onboarding" and .cluster == "dedicated") | .objects_created | length] | first // "n/a"). Shared objects changed per tenant: shared \([$usable[] | select(.kind == "onboarding" and .cluster == "shared") | .shared_objects_changed | length] | first // "n/a"), dedicated \([$usable[] | select(.kind == "onboarding" and .cluster == "dedicated") | .shared_objects_changed | length] | first // "n/a").\n\n" +
"Revocation (from deactivating the key to authentication refusing it) is reported per run as an interval between the last success and the first of 25 refusals: " +
([$usable[] | select(.kind == "offboarding") | "\(.cluster) \(.name) \(.revoked_between_ms | map(cell(.)) | join(" to ")) ms"] | if length == 0 then "no usable run" else join("; ") end) + ".\n\n" +

"## Footprint\n\n" +
"Gateway pods only (controllers and proxies), at each tenant count, idle and under 1 request per second per tenant. Memory is the maximum of 5-second samples.\n\n" +
"| Tenants | Cluster | Gateway pods | CPU idle / load (cores) | Memory idle / load (MiB) | Reserved requests (CPU, MiB) | Active gateway series | Kind node MiB | Run |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n" +
([$usable[] | select(.kind == "scale" and (.stopped | not))] | map(.config.tenants) | unique | map(
   pair("scale"; "tenants-\(.)") as $p | [$p.shared, $p.dedicated][] | select(. != null) |
   "| \(.config.tenants) | \(.cluster)\(if $p.comparable then "" else " (not compared)" end) | \(.under_load.gateway_pods) | \(.idle.cpu_cores_total) / \(.under_load.cpu_cores_total) | \(.idle.memory_mib_total_max_sampled) / \(.under_load.memory_mib_total_max_sampled) | \(.under_load.reserved.cpu_request_cores), \(.under_load.reserved.memory_request_mib) | \(.under_load.active_gateway_series) | \(.kind_node_memory_mib) | \(link(.)) |") | join("\n")) + "\n" +
([$usable[] | select(.kind == "scale" and .stopped)] | if length > 0 then "\nStopped sweeps: " + (map("\(.cluster) at \(.config.tenants) tenants: \(.reason)") | join("; ")) + "\n" else "" end) + "\n" +

"## Structural findings\n\n" +
"- **Shared-design ceiling**: one conditional rate-limit policy and one HTTPRoute each hold at most 16 entries (`rateLimit.conditional` and HTTPRoute `rules` have `maxItems: 16`), so the shared design as built holds at most 16 tenants.\n" +
"- **Controller Secret access**: every agentgateway controller's ClusterRole, as granted by the v1.5.0 chart, can list and read Secrets in every namespace, so the dedicated design does not separate tenant credentials at the Kubernetes permission level.\n" +
"- **Foundry key copies**: the shared cluster holds one copy of the Azure key; the dedicated cluster holds one per tenant.\n" +
"- **Parked**: shared provider quota exhaustion (both designs sit in front of one 10,000-token-per-minute deployment; local limits cannot cap the total across separate proxies).\n\n" +
(if .structure.shared != null or .structure.dedicated != null then
  "Objects holding tenant-01's settings, and how many tenants share each (from `make tenant-objects`):\n\n" +
  ([("shared", .structure.shared), ("dedicated", .structure.dedicated)] | [.[0:2], .[2:4]] | map(.[0] as $c | .[1] as $objects |
    if $objects == null then "" else "**\($c)**\n\n| Object | Holds | Shared by |\n| --- | --- | --- |\n" +
      ([$objects[] | "| \(.object) | \(.holds) | \(.shared_by) |"] | join("\n")) + "\n" end) | join("\n")) + "\n"
 else "" end) +

"## Excluded runs\n\n" +
([$all[] | select(.excluded != null)] | if length == 0 then "None.\n" else
  "| Run | Reason |\n| --- | --- |\n" + (map("| [\(.cluster) \(.kind) \(.name)](\(.dir)) | \(.excluded) |") | join("\n")) + "\n" end) + "\n" +
"## Usable runs not shown above\n\n" +
(selected_dirs as $shown | [$usable[] | select(.dir as $d | $shown | index($d) | not)] |
 if length == 0 then "None.\n" else
  "| Run | Why it is not shown |\n| --- | --- |\n" +
  (map("| [\(.cluster) \(.kind) \(.name)](\(.dir)) | \(if .kind == "load" then "a manual make load run, kept for context" else "superseded by a later run, or no matching run in the other design" end) |") | join("\n")) + "\n" end)
