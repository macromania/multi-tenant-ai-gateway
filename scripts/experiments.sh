#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/tenants.sh"

WORKING_SET="tenant-01 tenant-02 tenant-03"
BASELINE_SECONDS=30
OBSERVE_SECONDS=120
RECOVERY_SECONDS=300
RAISED_LIMIT=1000000000
MOCK_URL=http://mock.mock-upstream.svc:8080/v1/chat/completions
SAY_FILE=

# Prints a summary line to the terminal and, during a run, to the run's summary.txt.
say_row() {
    row "$1" "$2"
    [[ -z "$SAY_FILE" ]] || printf '  %-31s %s\n' "$1" "$2" >>"$SAY_FILE"
}
say_section() {
    section "$1"
    [[ -z "$SAY_FILE" ]] || printf '\n=== %s\n\n' "$1" >>"$SAY_FILE"
}

# ---------------------------------------------------------------------------------------------
# Workload profiles. The mock counts prompt tokens as characters / 4 and completion tokens as
# min(max_completion_tokens, 100); every profile says which limit it runs under.
# ---------------------------------------------------------------------------------------------
profile_json() {
    case "$1" in
        probe)   printf '%s' '{"rate":5,"prompt_chars":40,"max_completion_tokens":16}' ;;
        latency) printf '%s' '{"rate":50,"prompt_chars":40,"max_completion_tokens":16,"latency_ms":100,"raised_limit":true}' ;;
        flood)   printf '%s' '{"rate":2000,"prompt_chars":40,"max_completion_tokens":16,"latency_ms":100,"raised_limit":false}' ;;
        slow)    printf '%s' '{"rate":50,"prompt_chars":40,"max_completion_tokens":16,"latency_ms":30000,"timeout":"60s","raised_limit":true}' ;;
        memory)  printf '%s' '{"rate":50,"prompt_chars":262144,"max_completion_tokens":16,"latency_ms":30000,"timeout":"60s","job_memory":"6Gi","raised_limit":true}' ;;
        scale)   printf '%s' '{"rate":1,"prompt_chars":40,"max_completion_tokens":16}' ;;
        *) die "Unknown workload profile: $1 (probe, latency, flood, slow, memory, scale)." ;;
    esac
}

# stream_json <name> <tenant> <profile> <target: gateway|mock> <duration> [extra JSON merged last]
stream_json() {
    local name=$1 tenant=$2 profile=$3 target=$4 duration=$5 extra=${6:-'{}'} url key
    if [[ "$target" == mock ]]; then url=$MOCK_URL; key="$tenant.mock"; else url=$(gateway_url "$tenant"); key="$tenant.api"; fi
    jq -nc --arg name "$name" --arg tenant "$tenant" --arg url "$url" --arg key "$key" --arg duration "$duration" \
        --arg gateway "$(tenant_namespace "$tenant")/$GATEWAY" --argjson profile "$(profile_json "$profile")" \
        --argjson extra "$extra" '
      ($profile | del(.raised_limit)) + {name:$name, tenant:$tenant, key:$key, url:$url, duration:$duration,
       gateway:$gateway} + $extra'
}

# Probe streams for every working-set tenant through its own gateway.
probe_streams() {
    local duration=$1 tenant streams=()
    for tenant in $WORKING_SET; do
        streams+=("$(stream_json "probe-$tenant" "$tenant" probe gateway "$duration" '{"role":"probe","records":true,"timeout":"10s"}')")
    done
    printf '%s\n' "${streams[@]}" | jq -sc '.'
}

# ---------------------------------------------------------------------------------------------
# Recovery journal: written before an experiment changes anything, removed only after recovery
# passes. make restore converges the cluster to it from whatever stage was reached.
# ---------------------------------------------------------------------------------------------
journal_file() { printf '%s/experiment.json' "$CLUSTER_STATE"; }

journal_update() {
    local file
    new_temp; file=$TEMP_FILE
    jq "$@" "$(journal_file)" >"$file"
    chmod 600 "$file"
    mv -f -- "$file" "$(journal_file)"
}

# Prints every tenant's limit, key hash, and state. Each value is read into a variable first, so a
# failed read stops the experiment instead of producing a partial snapshot that restore would trust.
snapshot_json() {
    local tenant listed limit hash state tenants=()
    load_tenant_env
    listed=$(tenant_list)
    for tenant in $listed; do
        limit=$(stored_limit "$tenant")
        hash=$(key_hash "$tenant")
        state=$(tenant_state "$tenant")
        tenants+=("$(jq -nc --arg tenant "$tenant" --argjson limit "$limit" --arg hash "$hash" --arg state "$state" \
            '{tenant:$tenant, limit:$limit, key_hash:$hash, state:$state}')")
    done
    printf '%s\n' "${tenants[@]+"${tenants[@]}"}" | jq -sc '.'
}

journal_start() {
    local kind=$1 name=$2 file
    private_state
    [[ ! -e "$(journal_file)" ]] || die "A recovery journal exists from an earlier experiment. Run make restore CLUSTER=$CLUSTER first."
    local snapshot
    snapshot=$(snapshot_json)
    jq -e --arg set "$WORKING_SET" '($set | split(" ")) as $want |
      [$want[] as $t | any(.[]; .tenant == $t and (.limit | type) == "number" and .limit > 0 and
         (.key_hash | test("^sha256:[0-9a-f]{64}$")) and .state == "active")] | all' <<<"$snapshot" >/dev/null ||
        die "The snapshot of the working set is incomplete; nothing was changed."
    new_temp; file=$TEMP_FILE
    jq -n --arg kind "$kind" --arg name "$name" --arg run "$RUN_ID" --argjson tenants "$snapshot" \
        '{run_id:$run, kind:$kind, name:$name, stage:"started", tenants:$tenants, notes:{}}' >"$file"
    chmod 600 "$file"
    mv -f -- "$file" "$(journal_file)"
}

journal_stage() { journal_update --arg stage "$1" '.stage = $stage'; }

# Reapplies every active tenant's configuration from the journal (or the cluster, without one) and
# the stored keys: limits, key hashes, active keys, provider Secrets, backends, routes, and policies.
# A tenant that was onboarding or offboarding is left as it is, so a restore never reactivates a key
# that offboarding had deactivated. With a journal, its limits are used and never the cluster's
# current ones, which an experiment may have changed. Every step is safe to repeat. Inside an
# experiment, that experiment's own probe Job is kept, because it measures the recovery.
restore_cluster() {
    local journal tenant limit state namespace listed selector=gateway.dev/run
    journal=$(journal_file)
    load_tenant_env
    [[ -z "${RUN_ID:-}" ]] || selector="gateway.dev/run,gateway.dev/run!=$RUN_ID"
    kube -n "$LOAD_NAMESPACE" delete jobs,configmaps,secrets -l "$selector" --ignore-not-found --wait=false >/dev/null
    if [[ "$CLUSTER" == shared ]]; then
        kube -n "$NAMESPACE" scale deployment agentgateway --replicas=1 >/dev/null
    fi
    mock_push_keys
    listed=$(tenant_list)
    for tenant in $listed; do
        if [[ -e "$journal" ]]; then
            state=$(jq -r --arg tenant "$tenant" '.tenants[] | select(.tenant == $tenant) | .state // "active"' "$journal")
            limit=$(jq -r --arg tenant "$tenant" '.tenants[] | select(.tenant == $tenant) | .limit' "$journal")
            if [[ -z "$state" ]]; then
                warn "$tenant is not in the recovery journal; it is left as it is."
                continue
            fi
            [[ "$state" != active || "$limit" =~ ^[0-9]+$ ]] || die "The journal holds no limit for $tenant; the journal is kept."
        else
            state=$(tenant_state "$tenant")
            limit=
            [[ "$state" != active ]] || limit=$(stored_limit "$tenant")
        fi
        if [[ "$state" != active ]]; then
            warn "$tenant is ${state:-without a state}, so it is left as it is. Finish it with make tenant-add or make tenant-remove CONFIRM=1."
            continue
        fi
        namespace=$(tenant_namespace "$tenant")
        [[ "$CLUSTER" == shared ]] || kube -n "$tenant" scale deployment "agw-$tenant-agentgateway" --replicas=1 >/dev/null
        if [[ "$CLUSTER" == shared ]]; then
            apply_tenant_objects "$tenant" "$NAMESPACE" "$limit" "$tenant-key" "mock-provider-$tenant" "mock-$tenant" active
        else
            apply_tenant_objects "$tenant" "$tenant" "$limit" tenant-key mock-provider mock active
            render_namespace_template tenant-auth.yaml.tmpl "$tenant"
            render_namespace_template tenant-telemetry.yaml.tmpl "$tenant"
            kube -n "$tenant" rollout status "deployment/agw-$tenant-agentgateway" --timeout=300s >/dev/null
            render_tenant "$tenant"
        fi
    done
    if [[ "$CLUSTER" == shared ]]; then
        render_namespace_template tenant-auth.yaml.tmpl "$NAMESPACE"
        render_namespace_template tenant-telemetry.yaml.tmpl "$NAMESPACE"
        kube_apply -f "$ROOT/deploy/agentgateway/tenant-routing.yaml" >/dev/null
        kube -n "$NAMESPACE" rollout status deployment/agentgateway --timeout=300s >/dev/null
        render_shared
    fi
}

render_namespace_template() {
    local file
    new_temp; file=$TEMP_FILE
    sed "s/@NAMESPACE@/$2/g" "$ROOT/deploy/agentgateway/$1" >"$file"
    kube_apply -f "$file" >/dev/null
}

# Prints the first reason the working set is not healthy, or nothing. Healthy means: every tenant
# exists and is active; its controller and proxy are ready; its limit policy is fully accepted; its
# proxy enforces the expected limit (the journal's, when a journal exists); and a request with its
# key is served by the mock with its own provider key.
recovery_problem() {
    local journal=$1 tenant state namespace ready controller policy expected enforced
    for tenant in $WORKING_SET; do
        tenant_exists "$tenant" || { printf '%s is missing' "$tenant"; return 0; }
        state=$(tenant_state "$tenant")
        [[ "$state" == active ]] || { printf '%s is %s, not active' "$tenant" "${state:-without a state}"; return 0; }
    done
    for tenant in $WORKING_SET; do
        namespace=$(tenant_namespace "$tenant")
        if [[ "$CLUSTER" == shared ]]; then controller=agentgateway; else controller="agw-$tenant-agentgateway"; fi
        for ready in "$controller" "$GATEWAY"; do
            state=$(kube -n "$namespace" get deployment "$ready" -o jsonpath='{.status.readyReplicas}')
            [[ "${state:-0}" -ge 1 ]] || { printf 'deployment %s/%s is not ready' "$namespace" "$ready"; return 0; }
        done
        policy=$(kube -n "$namespace" get agentgatewaypolicy tenant-limits -o json)
        jq -e '[.status.ancestors[]?.conditions[]? | select(.type == "Accepted")] |
               length > 0 and all(.status == "True" and .reason != "PartiallyValid")' <<<"$policy" >/dev/null ||
            { printf 'policy %s/tenant-limits is not fully accepted' "$namespace"; return 0; }
        if [[ -e "$journal" ]]; then
            expected=$(jq -r --arg tenant "$tenant" '.tenants[] | select(.tenant == $tenant) | .limit' "$journal")
        else
            expected=$(stored_limit "$tenant")
        fi
        enforced=$(enforced_limit "$tenant")
        [[ "$enforced" == "$expected" ]] ||
            { printf '%s is enforced at %s tokens per minute, expected %s' "$tenant" "${enforced:-no limit}" "$expected"; return 0; }
    done
    for tenant in $WORKING_SET; do
        node_request "$tenant" "$(tenant_namespace "$tenant")" /mock/v1/chat/completions
        if [[ "$REQ_STATUS" != 200 || "$REQ_OWNER" != "$tenant" || "$REQ_ECHO_OK" != true ]]; then
            printf '%s got %s (key owner %s)' "$tenant" "${REQ_STATUS:-no response}" "${REQ_OWNER:-none}"; return 0
        fi
    done
}

# Retries recovery_problem until it finds nothing or the deadline passes. A failure to read the
# cluster counts as a problem, never as health.
recovery_checks() {
    local seconds=${1:-$RECOVERY_SECONDS} deadline failed journal
    load_tenant_env
    journal=$(journal_file)
    deadline=$(( $(date +%s) + seconds ))
    while :; do
        failed=$(recovery_problem "$journal") || failed='the cluster state could not be read'
        [[ -n "$failed" ]] || return 0
        [[ "$(date +%s)" -lt "$deadline" ]] || { warn "Recovery check failed: $failed"; return 1; }
        sleep 2
    done
}

entry_check() {
    local tenant listed state
    [[ ! -e "$(journal_file)" ]] || die "A recovery journal exists from an earlier experiment. Run make restore CLUSTER=$CLUSTER first."
    for tenant in $WORKING_SET; do
        tenant_exists "$tenant" || die "The working set needs $WORKING_SET. Run make scale CLUSTER=$CLUSTER TENANTS=3."
    done
    # An unfinished onboarding or offboarding anywhere would be changed by the restore, so it must be
    # finished first.
    listed=$(tenant_list)
    for tenant in $listed; do
        state=$(tenant_state "$tenant")
        [[ "$state" == active ]] ||
            die "$tenant is ${state:-without a state}. Finish it with make tenant-add or make tenant-remove CONFIRM=1 first."
    done
    # 120 seconds covers a token budget that an earlier load spent; local limits refill each minute.
    recovery_checks 120 || die "The cluster is not healthy; nothing was changed. Run make restore CLUSTER=$CLUSTER."
}

set_limit_quiet() {
    if [[ "$CLUSTER" == shared ]]; then
        kube -n "$NAMESPACE" annotate configmap "$1-key" "gateway.dev/tokens-per-minute=$2" --overwrite >/dev/null
    else
        kube -n "$1" annotate configmap tenant-key "gateway.dev/tokens-per-minute=$2" --overwrite >/dev/null
    fi
}

render_limits() {
    local tenant
    if [[ "$CLUSTER" == shared ]]; then render_shared; else for tenant in "$@"; do render_tenant "$tenant"; done; fi
}

# ---------------------------------------------------------------------------------------------
# Prometheus, through one short-lived port-forward per session.
# ---------------------------------------------------------------------------------------------
PROM_LOG=
prom_open() {
    start_forward "$PROMETHEUS_PORT" "$MONITORING_NAMESPACE" service/monitoring-prometheus 9090
    new_temp; PROM_LOG=$TEMP_FILE
    printf '[]' >"$PROM_LOG"
}
prom_close() { stop_forward; }

# prom_instant <expression> <unix seconds>: prints the result and appends it to the run's log.
# Assign its output to a variable before passing it on: macOS Bash 3.2 applies brace expansion to
# "{a,b}" inside "$(...)" when the substitution is a command argument, which splits a selector.
prom_instant() {
    local result file
    [[ $# -eq 2 ]] || die "prom_instant needs an expression and a time; got $# arguments, so an expression was split."
    result=$(curl --silent --show-error --max-time 30 -G "http://127.0.0.1:$PROMETHEUS_PORT/api/v1/query" \
        --data-urlencode "query=$1" --data-urlencode "time=$2") || die "Prometheus query failed: $1"
    new_temp; file=$TEMP_FILE
    jq --arg expr "$1" --arg time "$2" --argjson result "$result" '. + [{expr:$expr, time:($time|tonumber), result:$result}]' \
        "$PROM_LOG" >"$file"
    cp -- "$file" "$PROM_LOG"
    jq -e '.status == "success"' <<<"$result" >/dev/null ||
        die "Prometheus rejected a query: $(jq -r '.error // "no error message"' <<<"$result") (query: $1)"
    printf '%s' "$result"
}

other_cluster_busy() {
    local other_config=$STATE/dedicated/kubeconfig other_context=kind-mtag-dedicated jobs
    if [[ "$CLUSTER" == dedicated ]]; then other_config=$STATE/shared/kubeconfig; other_context=kind-mtag-shared; fi
    [[ -f "$other_config" ]] || return 1
    jobs=$(kubectl --kubeconfig "$other_config" --context "$other_context" -n "$LOAD_NAMESPACE" get jobs \
        -l gateway.dev/run -o json 2>/dev/null | jq '[.items[] | select((.status.active // 0) > 0)] | length') || return 1
    [[ "$jobs" -gt 0 ]]
}

# ---------------------------------------------------------------------------------------------
# Probe analysis. Records are classified by their start time against the recorded mutation times.
# ---------------------------------------------------------------------------------------------
IMPACT_JQ='
def pct($values; $q): ($values | sort) as $s | if ($s | length) == 0 then null else $s[((($s | length) - 1) * $q) | floor] end;
def failed($cause): .verdict != "verified" and (($cause != null and .tenant == $cause and .status == 429) | not);
def impact($m; $cause):
  group_by(.stream) | map(
    sort_by(.start_ms) as $all |
    # The analysis window ends at the end mark; a request started later belongs to the stop.
    [$all[] | select(.verdict != "censored" and .start_ms < $m.end)] as $r |
    ($m.restore_start // $m.end) as $restore |
    [$r[] | select(.start_ms < $m.trigger_start)] as $base |
    [$r[] | select(.start_ms >= $m.trigger_start and .start_ms < $restore)] as $observe |
    [$r[] | select(.start_ms >= $restore)] as $recover |
    pct([$base[] | select(.verdict == "verified") | .duration_ms]; 0.95) as $base_p95 |
    pct([$observe[] | select(.verdict == "verified") | .duration_ms]; 0.95) as $observe_p95 |
    [$r[] | select(.start_ms >= $m.trigger_start)] as $after |
    ([$after[] | select(failed($cause))] | length) as $after_failed |
    [$after[] | select($base_p95 != null and .verdict == "verified" and .duration_ms > 5 * $base_p95)] as $slow |
    ((($observe | length) > 0 and ([$observe[] | select(failed($cause))] | length) / ($observe | length) > 0.01) or
     ($base_p95 != null and $observe_p95 != null and $observe_p95 > 2 * $base_p95)) as $material |
    (reduce range(0; $after | length) as $i ({episodes: [], open: null};
       if ($after[$i] | failed($cause)) then (if .open == null then .open = $after[$i].start_ms else . end)
       elif .open != null then .episodes += [{start_ms: (.open - $m.trigger_start), duration_ms: ($after[$i].start_ms - .open)}] | .open = null
       else . end) |
     if .open != null then .episodes += [{start_ms: (.open - $m.trigger_start), duration_ms: ($m.end - .open), unfinished: true}] else . end |
     .episodes) as $episodes |
    ([$after[] | select(failed($cause)) | .start_ms] | max) as $last_failure |
    def healthy_after($from): [range(0; $r | length) as $i | select($r[$i].start_ms > $from and
        ($r[$i:$i + 25] | length) == 25 and ($r[$i:$i + 25] | all(.verdict == "verified"))) | $r[$i].start_ms] | first;
    {stream: $all[0].stream, tenant: $all[0].tenant, cause: ($cause != null and $all[0].tenant == $cause),
     requests: ($all | length), censored: ([$all[] | select(.verdict == "censored")] | length),
     baseline: {requests: ($base | length), failed: ([$base[] | select(failed($cause))] | length), p95_ms: $base_p95},
     observe: {requests: ($observe | length), failed: ([$observe[] | select(failed($cause))] | length), p95_ms: $observe_p95,
               expected_429: ([$observe[] | select($cause != null and .tenant == $cause and .status == 429)] | length)},
     recover: {requests: ($recover | length), failed: ([$recover[] | select(failed($cause))] | length)},
     statuses: ([$after[] | select(failed($cause)) | (.status | tostring)] | group_by(.) | map({(.[0]): length}) | add // {}),
     leaks: ([$r[] | select(.verdict == "leak")] | length),
     unverifiable: ([$r[] | select(.verdict == "unverifiable")] | length),
     slow: {count: ($slow | length), threshold_ms: (if $base_p95 == null then null else 5 * $base_p95 end),
            max_ms: ([$slow[].duration_ms] | max)},
     any_impact: ($after_failed > 0 or ($slow | length) > 0 or $material),
     material_impact: $material,
     episodes: $episodes, failed_time_ms: ([$episodes[].duration_ms] | add // 0),
     recovery_after_trigger_ms: (if $last_failure == null then null else ((healthy_after($last_failure)) as $h | if $h == null then null else $h - $m.trigger_start end) end),
     recovery_after_restore_ms: (if $last_failure == null or $m.restore_start == null then null
        else ((healthy_after([$last_failure, $m.restore_start] | max)) as $h | if $h == null then null else $h - $m.restore_start end) end)});'

# ---------------------------------------------------------------------------------------------
# Validity: the apparatus must have delivered the workload, or a design can look better than it is.
# ---------------------------------------------------------------------------------------------
# validity_json <run dir> <attack rate or 0> <raised limit true|false> <attack seconds> <end ms>
# <drops allowed true|false>: prints {valid, reasons, other_node_cpu, confounded}. Every stream that
# writes records (probes and the extra streams a failure adds) must have delivered its planned rate
# without drops up to the end mark; the attack must have sent at least 80 percent of its plan without
# drops (unless the failure allows drops); no response may be unverifiable; and a raised-limit run
# may see no 429 in any stream.
validity_json() {
    local dir=$1 attack_rate=$2 raised=$3 attack_seconds=$4 end_ms=$5 drops_allowed=${6:-false} contention
    contention=$(contention_json)
    jq -n --slurpfile probe "$dir/k6-summary-probe.json" --slurpfile records <(cat "$dir"/probes-probe.jsonl 2>/dev/null) \
        --argjson attack_rate "$attack_rate" --argjson attack_seconds "$attack_seconds" --arg raised "$raised" \
        --argjson end "$end_ms" --arg drops_allowed "$drops_allowed" --argjson contention "$contention" \
        --slurpfile attack <(cat "$dir/k6-summary-attack.json" 2>/dev/null || printf '{}') \
        --slurpfile extra <(cat "$dir/validity-extra.json" 2>/dev/null || printf '[]') '
      ($probe[0].streams | to_entries | map(select(.value.recorded))) as $recorded |
      ($attack[0].streams // {} | to_entries | map(select(.value.role == "attack"))) as $a |
      [$records[] | select(.start_ms < $end)] as $r |
      [
        ($recorded | map(select(.value.dropped_iterations > 0) | .key) |
         if length > 0 then "iterations were dropped by " + join(", ") else empty end),
        ($r | group_by(.stream) | map(select(length > 1 and length < 0.99 * $probe[0].streams[.[0].stream].target_rate *
             ((map(.start_ms) | max) - (map(.start_ms) | min)) / 1000 - 5)) | map(.[0].stream) |
         if length > 0 then "streams delivered fewer than 99 percent of their planned requests: " + join(", ") else empty end),
        (([$r[] | select(.verdict == "unverifiable")] | length) + ($a | map(.value.verdicts.unverifiable) | add // 0) |
         if . > 0 then "\(.) responses were unverifiable" else empty end),
        (if $raised == "true" then
           (([$r[] | select(.status == 429)] | length) + ($a | map(.value.statuses["429"] // 0) | add // 0) |
            if . > 0 then "a raised-limit run saw \(.) responses with 429" else empty end)
         else empty end),
        (if $attack_rate > 0 then
           if ($a | length) == 0 then "the attack produced no summary"
           else $a[].value |
             (if $drops_allowed != "true" and .dropped_iterations > 0 then "the attack dropped \(.dropped_iterations) iterations" else empty end),
             (if .requests < 0.8 * $attack_rate * $attack_seconds then "the attack sent \(.requests) of \($attack_rate * $attack_seconds) planned requests" else empty end)
           end
         else empty end)
      ] + $extra[0] as $reasons |
      {valid: ($reasons | length == 0), reasons: $reasons, other_node_cpu: $contention.mean_cpu, confounded: $contention.confounded}'
}

grafana_links() {
    jq -nc --arg port "$GRAFANA_PORT" --argjson from "$1" --argjson to "$2" '{
      tenants: ("http://127.0.0.1:" + $port + "/d/mtag-tenants?from=\($from)&to=\($to)&var-tenant=All"),
      agentgateway: ("http://127.0.0.1:" + $port + "/d/agentgateway?from=\($from)&to=\($to)")}'
}

save_events() {
    kube get events -A -o json | jq --argjson from "$1" --argjson to "$2" '[.items[] |
      (.lastTimestamp // .eventTime // .metadata.creationTimestamp) as $t |
      select($t != null and (($t | sub("\\.[0-9]+"; "") | fromdateiso8601) * 1000) >= $from and
             (($t | sub("\\.[0-9]+"; "") | fromdateiso8601) * 1000) <= $to) |
      {time: $t, namespace: .metadata.namespace, object: (.involvedObject.kind + "/" + .involvedObject.name),
       reason, message: (.message // "" | .[0:300])}]' >"$RUN_DIR/events.json"
}

# ---------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------
# The tenants, their limits, and the mock's replicas when a run starts. finish_run adds them to the
# record's config, so runs made under different conditions never share a configuration fingerprint.
apparatus_json() {
    local listed tenant limit replicas entries=()
    listed=$(tenant_list)
    for tenant in $listed; do
        limit=$(stored_limit "$tenant")
        entries+=("$(jq -nc --arg tenant "$tenant" --argjson limit "$limit" '{($tenant): $limit}')")
    done
    replicas=$(kube -n "$MOCK_NAMESPACE" get deployment mock -o jsonpath='{.spec.replicas}')
    [[ "$replicas" =~ ^[0-9]+$ ]] || die "Cannot read the mock's replica count."
    printf '%s\n' "${entries[@]+"${entries[@]}"}" |
        jq -sc --argjson replicas "$replicas" '{tenant_count: length, limits: (add // {}), mock_replicas: $replicas}'
}

APPARATUS=
begin_run() {
    local kind=$1 name=$2
    other_cluster_busy && die "The other cluster is running a load Job; measure one cluster at a time."
    APPARATUS=$(apparatus_json)
    new_run "$kind" "$name"
    SAY_FILE="$RUN_DIR/summary.txt"
    : >"$SAY_FILE"
}

restore_on_exit() {
    [[ -e "$(journal_file)" ]] || return 0
    if [[ "${KEEP:-}" == 1 ]]; then
        warn "KEEP=1: the cluster was left as the experiment changed it. Run make restore CLUSTER=$CLUSTER afterwards."
        return 0
    fi
    warn 'Restoring the cluster after an interrupted experiment.'
    restore_cluster
    recovery_checks && rm -f -- "$(journal_file)"
}

finish_run() {
    local fields=$1 merged
    SAY_FILE=
    new_temp; merged=$TEMP_FILE
    jq --argjson apparatus "${APPARATUS:-null}" 'if has("config") then .config.apparatus = $apparatus else . end' "$fields" >"$merged"
    write_run_json "$merged"
}

check_row() {
    local name=$1 passed=$2 evidence=$3
    CHECKS+=("$(jq -nc --arg name "$name" --argjson passed "$passed" --arg evidence "$evidence" '{name:$name, passed:$passed, evidence:$evidence}')")
    if [[ "$passed" == true ]]; then say_row "[PASS] $name" "$evidence"; else say_row "[FAIL] $name" "$evidence"; fi
}

scenario_separation() {
    entry_check
    begin_run scenario separation
    journal_start scenario separation
    on_exit restore_on_exit
    local plan started tenant other namespace ended checks_file fields streams can_i
    CHECKS=()
    say_section "SEPARATION | $KIND_CLUSTER"
    new_temp; plan=$TEMP_FILE
    streams=$(probe_streams 300s)
    jq -n --argjson probes "$streams" \
        --argjson owner "$(stream_json control-owner tenant-01 probe mock 20s '{"role":"control","records":true,"timeout":"10s","key":"tenant-02.mock","expected_owner":"tenant-01"}')" \
        --argjson echo "$(stream_json control-echo tenant-01 probe mock 20s '{"role":"control","records":true,"timeout":"10s","corrupt_id":true}')" \
        '{streams: ($probes + [$owner, $echo])}' >"$plan"
    load_start "$RUN_ID" probe "$plan"
    load_first_record "$RUN_ID" probe
    started=$(node_now_ms)
    load_tenant_env
    for namespace in $(gateway_namespaces); do
        node_request none "$namespace" /mock/v1/chat/completions
        check_row "No key is refused ($namespace)" "$([[ "$REQ_STATUS" == 401 ]] && echo true || echo false)" "HTTP $REQ_STATUS"
        node_request invalid "$namespace" /mock/v1/chat/completions
        check_row "An invalid key is refused ($namespace)" "$([[ "$REQ_STATUS" == 401 ]] && echo true || echo false)" "HTTP $REQ_STATUS"
    done
    for tenant in $WORKING_SET; do
        node_request "$tenant" "$(tenant_namespace "$tenant")" /mock/v1/chat/completions
        check_row "$tenant is served with its own provider key" \
            "$([[ "$REQ_STATUS" == 200 && "$REQ_OWNER" == "$tenant" && "$REQ_ECHO_OK" == true ]] && echo true || echo false)" \
            "HTTP $REQ_STATUS, key owner ${REQ_OWNER:-none}"
    done
    if [[ "$CLUSTER" == dedicated ]]; then
        for tenant in $WORKING_SET; do
            for other in $WORKING_SET; do
                [[ "$tenant" != "$other" ]] || continue
                node_request "$tenant" "$other" /mock/v1/chat/completions
                check_row "$tenant's key is refused by $other's gateway" "$([[ "$REQ_STATUS" == 401 ]] && echo true || echo false)" "HTTP $REQ_STATUS"
            done
        done
    fi
    node_request tenant-01 "$(tenant_namespace tenant-01)" /mock/v1/chat/completions 'x-tenant: tenant-02'
    check_row "A forged x-tenant header does not reach tenant-02" \
        "$([[ "$REQ_STATUS" == 200 && "$REQ_OWNER" == tenant-01 ]] && echo true || echo false)" "HTTP $REQ_STATUS, key owner ${REQ_OWNER:-none}"
    journal_update '.notes.limit_changed = "tenant-01"'
    set_limit_quiet tenant-01 100
    render_limits tenant-01
    wait_enforced 100 tenant-01
    local attempt limited=
    for ((attempt=0; attempt<20; attempt++)); do
        node_request tenant-01 "$(tenant_namespace tenant-01)" /mock/v1/chat/completions
        if [[ "$REQ_STATUS" == 429 ]]; then limited=$((attempt + 1)); break; fi
    done
    check_row "tenant-01 is limited after spending its budget" "$([[ -n "$limited" ]] && echo true || echo false)" \
        "429 on request ${limited:-never} at 100 tokens per minute"
    for tenant in tenant-02 tenant-03; do
        node_request "$tenant" "$(tenant_namespace "$tenant")" /mock/v1/chat/completions
        check_row "$tenant is not limited by tenant-01's budget" "$([[ "$REQ_STATUS" == 200 ]] && echo true || echo false)" "HTTP $REQ_STATUS"
    done
    set_limit_quiet tenant-01 "$(jq -r '.tenants[] | select(.tenant == "tenant-01") | .limit' "$(journal_file)")"
    render_limits tenant-01
    sleep 20
    ended=$(node_now_ms)
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    local records
    records=$(jq -s -c '.' "$RUN_DIR/probes-probe.jsonl")
    check_row "No probe reached another tenant's provider key" \
        "$(jq '[.[] | select(.stream | startswith("probe-")) | select(.verdict == "leak" or .verdict == "unverifiable")] | length == 0' <<<"$records")" \
        "$(jq -r '[.[] | select(.stream | startswith("probe-"))] | "\(length) probe requests, \([.[] | select(.verdict == "leak")] | length) leaks"' <<<"$records")"
    check_row "The leak detector flags a wrong key owner" \
        "$(jq '[.[] | select(.stream == "control-owner")] | length > 0 and all(.verdict == "leak")' <<<"$records")" \
        "$(jq -r '[.[] | select(.stream == "control-owner")] | "\(length) control requests, \([.[] | select(.verdict == "leak")] | length) flagged"' <<<"$records")"
    check_row "The leak detector flags a wrong echoed probe ID" \
        "$(jq '[.[] | select(.stream == "control-echo")] | length > 0 and all(.verdict == "leak")' <<<"$records")" \
        "$(jq -r '[.[] | select(.stream == "control-echo")] | "\(length) control requests, \([.[] | select(.verdict == "leak")] | length) flagged"' <<<"$records")"
    prom_open
    local attributed
    attributed=$(prom_instant "sum by (tenant) (increase(agentgateway_requests_total{tenant=~\"tenant-0[123]\"}[$(( (ended - started) / 1000 + 30 ))s]))" "$(( ended / 1000 + 15 ))")
    prom_close
    check_row "Gateway metrics attribute traffic to each tenant" \
        "$(jq '[.data.result[] | select((.value[1] | tonumber) > 0) | .metric.tenant] | unique | length == 3' <<<"$attributed")" \
        "$(jq -r '[.data.result[] | "\(.metric.tenant)=\(.value[1] | tonumber | floor)"] | join(", ")' <<<"$attributed")"
    if [[ "$CLUSTER" == shared ]]; then
        can_i=$(kube auth can-i list secrets --as=system:serviceaccount:agentgateway-system:agentgateway -n "$MOCK_NAMESPACE" || true)
        check_row "Recorded: the shared controller can list Secrets outside its namespace" true "$can_i"
    else
        can_i=$(kube auth can-i list secrets --as=system:serviceaccount:tenant-01:agw-tenant-01-agentgateway -n tenant-02 || true)
        check_row "Recorded: tenant-01's controller can list Secrets in tenant-02" true "$can_i (the chart grants cluster-wide Secret read)"
    fi
    restore_cluster
    recovery_checks || die "The cluster did not recover; the journal is kept. Run make restore CLUSTER=$CLUSTER."
    rm -f -- "$(journal_file)"
    save_events "$started" "$ended"
    cp -- "$PROM_LOG" "$RUN_DIR/prometheus.json"
    new_temp; checks_file=$TEMP_FILE
    printf '%s\n' "${CHECKS[@]}" | jq -sc '.' >"$checks_file"
    new_temp; fields=$TEMP_FILE
    local links leaks
    links=$(grafana_links "$started" "$ended")
    leaks=$(jq '[.[] | select((.stream | startswith("probe-")) and .verdict == "leak")] | length' <<<"$records")
    jq -n --arg run "$RUN_ID" --argjson started "$started" --argjson ended "$ended" --slurpfile checks "$checks_file" \
        --argjson links "$links" --argjson leaks "$leaks" --argjson tenants "$(printf '%s' "$WORKING_SET" | wc -w | tr -d ' ')" '{
      kind:"scenario", name:"separation", run_id:$run, clock:"kind-node", started_ms:$started, ended_ms:$ended,
      config:{scenario:"separation", working_set:$tenants, probe_rate:5, design:env.CLUSTER},
      checks:$checks[0], passed:($checks[0] | all(.passed)), leaks:$leaks, grafana:$links}' >"$fields"
    finish_run "$fields"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.passed' "$RUN_DIR/run.json" >/dev/null || die "At least one separation check failed."
    ok 'Every separation check passed'
}

# One latency measurement: a 30-second warm-up, then 120 seconds with per-request records.
latency_measure() {
    local target=$1 label=$2 out=$3 plan run
    new_temp; plan=$TEMP_FILE
    jq -n --argjson warm "$(stream_json warm tenant-01 latency "$target" 30s '{"role":"attack"}')" \
        --argjson measure "$(stream_json measure tenant-01 latency "$target" 120s '{"role":"attack","records":true,"start_delay":"30s","timeout":"10s"}')" \
        '{streams:[$warm, $measure]}' >"$plan"
    run="$RUN_ID-$label"
    run_load "$(printf '%s' "$run" | cut -c1-36 | sed 's/-*$//')" attack "$plan" "$out" >/dev/null
    # Percentiles come from verified responses only, so every other outcome makes the pair invalid.
    jq -s -c --slurpfile summary "$out/k6-summary-attack.json" '
      [.[] | select(.stream == "measure")] as $m |
      ([$m[] | select(.verdict == "verified") | .duration_ms] | sort) as $d |
      {requests: ($d | length), p50: $d[(($d | length) - 1) * 0.5 | floor], p95: $d[(($d | length) - 1) * 0.95 | floor],
       p99: $d[(($d | length) - 1) * 0.99 | floor],
       not_verified: ([$m[] | select(.verdict != "verified" and .verdict != "censored")] | length),
       dropped: ([$summary[0].streams[].dropped_iterations] | add // 0),
       refused_429: ([$summary[0].streams[].statuses["429"] // 0] | add // 0)}' \
        "$out/probes-attack.jsonl"
}

scenario_latency() {
    entry_check
    begin_run scenario latency
    journal_start scenario latency
    on_exit restore_on_exit
    local started ended pair order target result pairs=() fields
    say_section "LATENCY | $KIND_CLUSTER"
    set_limit_quiet tenant-01 "$RAISED_LIMIT"
    render_limits tenant-01
    wait_enforced "$RAISED_LIMIT" tenant-01
    started=$(node_now_ms)
    for pair in 1 2 3; do
        if [[ "$pair" == 2 ]]; then order="gateway mock"; else order="mock gateway"; fi
        local direct= through=
        for target in $order; do
            info "Pair $pair: measuring $target for 2 minutes after a 30-second warm-up."
            result=$(latency_measure "$target" "p$pair-$target" "$RUN_DIR/pair-$pair-$target")
            if [[ "$target" == mock ]]; then direct=$result; else through=$result; fi
        done
        pairs+=("$(jq -nc --argjson pair "$pair" --arg order "$order" --argjson direct "$direct" --argjson gateway "$through" '{
          pair:$pair, order:$order, direct:$direct, gateway:$gateway,
          difference_ms:{p50:($gateway.p50 - $direct.p50), p95:($gateway.p95 - $direct.p95), p99:($gateway.p99 - $direct.p99)}}')")
    done
    ended=$(node_now_ms)
    restore_cluster
    recovery_checks || die "The cluster did not recover; the journal is kept. Run make restore CLUSTER=$CLUSTER."
    rm -f -- "$(journal_file)"
    local pairs_file
    new_temp; pairs_file=$TEMP_FILE
    printf '%s\n' "${pairs[@]}" | jq -sc '.' >"$pairs_file"
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --argjson started "$started" --argjson ended "$ended" --slurpfile pairs "$pairs_file" \
        --argjson links "$(grafana_links "$started" "$ended")" --argjson profile "$(profile_json latency)" '
      def median: sort | .[(length - 1) / 2 | floor];
      {kind:"scenario", name:"latency", run_id:$run, clock:"kind-node", started_ms:$started, ended_ms:$ended,
       config:{scenario:"latency", profile:$profile, pairs:3, warmup_s:30, measure_s:120, design:env.CLUSTER},
       pairs:$pairs[0],
       difference_ms:{p50:{median:([$pairs[0][].difference_ms.p50] | median), min:([$pairs[0][].difference_ms.p50] | min), max:([$pairs[0][].difference_ms.p50] | max)},
                      p95:{median:([$pairs[0][].difference_ms.p95] | median), min:([$pairs[0][].difference_ms.p95] | min), max:([$pairs[0][].difference_ms.p95] | max)},
                      p99:{median:([$pairs[0][].difference_ms.p99] | median), min:([$pairs[0][].difference_ms.p99] | min), max:([$pairs[0][].difference_ms.p99] | max)}},
       grafana:$links} |
      .reasons = ([$pairs[0][] | .pair as $p | (.direct | . + {target:"direct"}), (.gateway | . + {target:"gateway"}) |
        (if .requests < 5900 then "pair \($p) \(.target): \(.requests) verified responses of 6000" else empty end),
        (if .not_verified > 0 then "pair \($p) \(.target): \(.not_verified) responses were not verified" else empty end),
        (if .dropped > 0 then "pair \($p) \(.target): \(.dropped) iterations dropped" else empty end),
        (if .refused_429 > 0 then "pair \($p) \(.target): \(.refused_429) responses with 429" else empty end)]) |
      .valid = (.reasons | length == 0)' >"$fields"
    finish_run "$fields"
    say_row 'Gateway minus direct, p50' "$(jq -r '.difference_ms.p50 | "median \(.median) ms (range \(.min) to \(.max))"' "$RUN_DIR/run.json")"
    say_row 'Gateway minus direct, p95' "$(jq -r '.difference_ms.p95 | "median \(.median) ms (range \(.min) to \(.max))"' "$RUN_DIR/run.json")"
    say_row 'Gateway minus direct, p99' "$(jq -r '.difference_ms.p99 | "median \(.median) ms (range \(.min) to \(.max))"' "$RUN_DIR/run.json")"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.valid' "$RUN_DIR/run.json" >/dev/null || die "The latency run is invalid: $(jq -r '.reasons | join("; ")' "$RUN_DIR/run.json")."
    ok 'Latency differences recorded'
}

scenario_rollout() {
    entry_check
    begin_run scenario rollout
    journal_start scenario rollout
    on_exit restore_on_exit
    local tenants started written enforced new_limit count fields
    say_section "CONFIGURATION ROLLOUT | $KIND_CLUSTER"
    tenants=$(tenant_list)
    count=$(printf '%s\n' "$tenants" | grep -c .)
    new_limit=$(( $(stored_limit tenant-01) + 1000 ))
    started=$(node_now_ms)
    TENANT=all TOKENS_PER_MINUTE=$new_limit tenant_limit
    written=$(node_now_ms)
    # shellcheck disable=SC2086
    wait_enforced "$new_limit" $tenants
    enforced=$(node_now_ms)
    restore_cluster
    recovery_checks || die "The cluster did not recover; the journal is kept. Run make restore CLUSTER=$CLUSTER."
    rm -f -- "$(journal_file)"
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --argjson started "$started" --argjson written "$written" --argjson enforced "$enforced" \
        --argjson count "$count" --arg design "$CLUSTER" --argjson links "$(grafana_links "$started" "$enforced")" '{
      kind:"scenario", name:"rollout", run_id:$run, clock:"kind-node", started_ms:$started, ended_ms:$enforced,
      config:{scenario:"rollout", tenants:$count, design:$design},
      records_written:$count, enforcement_objects_written:(if $design == "shared" then 1 else $count end),
      writes_done_after_ms:($written - $started), enforced_everywhere_after_ms:($enforced - $started), grafana:$links}' >"$fields"
    finish_run "$fields"
    say_row 'Tenants changed' "$count (one limit annotation each)"
    say_row 'Enforcement objects written' "$(jq -r '.enforcement_objects_written' "$RUN_DIR/run.json")"
    say_row 'Enforced for every tenant after' "$(jq -r '.enforced_everywhere_after_ms' "$RUN_DIR/run.json") ms"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
    ok 'Rollout measured and limits restored'
}

scenario_foundry_smoke() {
    [[ "${CONFIRM:-}" == 1 ]] || die "This sends one real prompt per tenant to Foundry and can incur charges. Rerun with CONFIRM=1."
    foundry_configured || die "Foundry is not configured. Run make foundry-up, then make gateway-configure CLUSTER=$CLUSTER."
    entry_check
    begin_run scenario foundry-smoke
    local tenant started ended fields results=()
    say_section "FOUNDRY SMOKE | $KIND_CLUSTER"
    warn 'Sending one real prompt per tenant (at most 32 completion tokens each). This can incur charges.'
    started=$(node_now_ms)
    load_env
    for tenant in $WORKING_SET; do
        node_request "$tenant" "$(tenant_namespace "$tenant")" /v1/chat/completions '' "$(config AZURE_MODEL_DEPLOYMENT)" 32
        say_row "$tenant" "HTTP $REQ_STATUS"
        results+=("$(jq -nc --arg tenant "$tenant" --arg status "$REQ_STATUS" '{tenant:$tenant, status:($status | tonumber? // null)}')")
    done
    ended=$(node_now_ms)
    local results_file
    new_temp; results_file=$TEMP_FILE
    printf '%s\n' "${results[@]}" | jq -sc '.' >"$results_file"
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --argjson started "$started" --argjson ended "$ended" --slurpfile results "$results_file" '{
      kind:"scenario", name:"foundry-smoke", run_id:$run, clock:"kind-node", started_ms:$started, ended_ms:$ended,
      config:{scenario:"foundry-smoke", design:env.CLUSTER, max_completion_tokens:32},
      results:$results[0], passed:($results[0] | all(.status == 200))}' >"$fields"
    finish_run "$fields"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.passed' "$RUN_DIR/run.json" >/dev/null || die "At least one tenant did not get a Foundry answer."
    ok 'Every tenant reached Foundry through its gateway'
}

# ---------------------------------------------------------------------------------------------
# Calibration: each workload runs directly against the mock, with probes, to prove that k6 and the
# mock can deliver it before any gateway is measured with it.
# ---------------------------------------------------------------------------------------------
calibrate_profile() {
    local profile=$1 plan_attack plan_probe started ended tenant probes=() fields rate latency
    begin_run calibration "$profile"
    say_section "CALIBRATION | $KIND_CLUSTER | $profile"
    new_temp; plan_attack=$TEMP_FILE
    jq -n --argjson attack "$(stream_json "attack-$profile" tenant-01 "$profile" mock 120s '{"role":"attack"}')" \
        '{streams:[$attack]}' >"$plan_attack"
    for tenant in $WORKING_SET; do
        probes+=("$(stream_json "probe-$tenant" "$tenant" probe mock 150s '{"role":"probe","records":true,"timeout":"10s"}')")
    done
    new_temp; plan_probe=$TEMP_FILE
    printf '%s\n' "${probes[@]}" | jq -sc '{streams: .}' >"$plan_probe"
    load_start "$RUN_ID" probe "$plan_probe"
    load_first_record "$RUN_ID" probe
    started=$(node_now_ms)
    run_load "$(printf '%s-a' "$RUN_ID" | cut -c1-36)" attack "$plan_attack" "$RUN_DIR" >/dev/null
    ended=$(node_now_ms)
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    prom_open
    # Each answer is kept whole, so missing telemetry is reported instead of being read as zero.
    local throttled_raw in_flight_raw errors_raw total_raw throttled in_flight mock_errors mock_total
    throttled_raw=$(prom_instant "max(sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace=\"mock-upstream\",container=\"mock\"}[2m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace=\"mock-upstream\",container=\"mock\"}[2m])))" "$(( ended / 1000 ))")
    in_flight_raw=$(prom_instant "max_over_time(sum(mock_in_flight)[$(( (ended - started) / 1000 ))s:5s])" "$(( ended / 1000 ))")
    errors_raw=$(prom_instant "sum(increase(mock_requests_total{code!=\"200\"}[$(( (ended - started) / 1000 + 10 ))s]))" "$(( ended / 1000 + 5 ))")
    total_raw=$(prom_instant "sum(increase(mock_requests_total[$(( (ended - started) / 1000 + 10 ))s]))" "$(( ended / 1000 + 5 ))")
    prom_close
    throttled=$(jq '[.data.result[].value[1] | tonumber? // empty] | max' <<<"$throttled_raw")
    in_flight=$(jq '[.data.result[].value[1] | tonumber? // empty] | max' <<<"$in_flight_raw")
    mock_errors=$(jq '[.data.result[].value[1] | tonumber? // empty] | add // 0' <<<"$errors_raw")
    mock_total=$(jq '[.data.result[].value[1] | tonumber? // empty] | add' <<<"$total_raw")
    cp -- "$PROM_LOG" "$RUN_DIR/prometheus.json"
    rate=$(profile_json "$profile" | jq '.rate')
    latency=$(profile_json "$profile" | jq '.latency_ms // 100')
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --arg profile "$profile" --argjson started "$started" --argjson ended "$ended" \
        --argjson profile_json "$(profile_json "$profile")" --argjson rate "$rate" --argjson latency "$latency" \
        --argjson throttled "$throttled" --argjson in_flight "$in_flight" --argjson mock_errors "$mock_errors" \
        --argjson mock_total "$mock_total" --slurpfile records "$RUN_DIR/probes-probe.jsonl" \
        --slurpfile attack "$RUN_DIR/k6-summary-attack.json" --slurpfile probe "$RUN_DIR/k6-summary-probe.json" \
        --argjson replicas "$(kube -n "$MOCK_NAMESPACE" get deployment mock -o jsonpath='{.spec.replicas}')" \
        --argjson links "$(grafana_links "$started" "$ended")" '
      ($attack[0].streams | to_entries[0].value) as $a |
      ($probe[0].streams | to_entries | map(.value)) as $p |
      [$records[] | select(.verdict != "censored")] as $r |
      [
        (if $a.verdicts.verified < 0.95 * $rate * 120 then "attack had \($a.verdicts.verified) verified responses of \($rate * 120) planned" else empty end),
        (($a.verdicts | .leak + .blocked + .unverifiable + .failed) | if . > 0 then "attack had \(.) responses that were not verified" else empty end),
        (if $a.dropped_iterations > 0 then "attack dropped \($a.dropped_iterations) iterations" else empty end),
        (if $mock_total == null or $mock_total == 0 then "no mock request telemetry" else empty end),
        (if $mock_errors > 0 then "the mock returned \($mock_errors) errors" else empty end),
        (if $a.duration_ms["p(99)"] > 1.2 * $latency then "attack p99 \($a.duration_ms["p(99)"] | floor) ms exceeds 120 percent of \($latency) ms" else empty end),
        (if $throttled == null then "no mock CPU throttling telemetry" elif $throttled > 0.1 then "mock CPU throttled \($throttled * 100 | floor) percent" else empty end),
        (if $in_flight == null then "no mock in-flight telemetry" else empty end),
        (if any($p[]; .dropped_iterations > 0) then "probe iterations were dropped" else empty end),
        ([$r[] | select(.verdict != "verified")] | length | if . > 0 then "\(.) probe responses were not verified" else empty end),
        ($r | group_by(.stream) | map(select(length < 0.99 * 5 * ((map(.start_ms) | max) - (map(.start_ms) | min)) / 1000 - 5)) |
         map(.[0].stream) | if length > 0 then "probes delivered fewer than 99 percent of their planned requests: " + join(", ") else empty end)
      ] as $reasons |
      {kind:"calibration", name:$profile, run_id:$run, clock:"kind-node", started_ms:$started, ended_ms:$ended,
       config:{profile:$profile_json, target:"mock", duration_s:120, mock_replicas:$replicas, design:env.CLUSTER},
       attack:$a, probes:$p, mock:{max_throttled_ratio:$throttled, max_in_flight:$in_flight, errors:$mock_errors, requests:$mock_total},
       valid:($reasons | length == 0), reasons:$reasons, grafana:$links}' >"$fields"
    finish_run "$fields"
    say_row 'Attack delivered' "$(jq -r '.attack | "\(.requests) requests, \(.dropped_iterations) dropped, p99 \(.duration_ms["p(99)"] | floor) ms"' "$RUN_DIR/run.json")"
    say_row 'Mock' "$(jq -r '.mock | "max \(.max_in_flight // "unknown") in flight, throttled \(if .max_throttled_ratio == null then "unknown" else "\(.max_throttled_ratio * 100 | floor)%" end), \(.errors) errors"' "$RUN_DIR/run.json")"
    say_row 'Verdict' "$(jq -r 'if .valid then "valid" else "invalid: " + (.reasons | join("; ")) end' "$RUN_DIR/run.json")"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.valid' "$RUN_DIR/run.json" >/dev/null
}

calibrate() {
    local profile failed=
    for tenant in $WORKING_SET; do
        tenant_exists "$tenant" || die "Calibration uses the working set's mock keys. Add $WORKING_SET first."
    done
    mock_push_keys
    for profile in ${PROFILE:-latency flood slow memory}; do
        calibrate_profile "$profile" || failed="$failed $profile"
    done
    [[ -z "$failed" ]] || die "Calibration failed for:$failed. Adjust the apparatus and record the change."
    ok 'Every profile was delivered by the apparatus'
}

# make load: one attack stream for TENANT with PROFILE, plus probes for the working set.
load_command() {
    validate_tenant "${TENANT:-}"
    local profile=${PROFILE:-probe} duration=${DURATION:-60s} target=${UPSTREAM:-gateway} extra plan_attack plan_probe
    [[ "$duration" =~ ^[0-9]+[sm]$ ]] || die "DURATION must look like 60s or 2m."
    [[ "$target" == gateway || "$target" == mock ]] || die "UPSTREAM must be gateway or mock for make load."
    extra='{"role":"attack"}'
    if [[ -n "${RATE:-}" ]]; then
        [[ "$RATE" =~ ^[1-9][0-9]{0,3}$ ]] || die "RATE must be an integer from 1 to 5000."
        extra=$(jq -nc --argjson rate "$RATE" '{role:"attack", rate:$rate}')
    fi
    entry_check
    begin_run load "$profile"
    say_section "LOAD | $KIND_CLUSTER | $TENANT | $profile"
    new_temp; plan_attack=$TEMP_FILE
    jq -n --argjson attack "$(stream_json "attack" "$TENANT" "$profile" "$target" "$duration" "$extra")" '{streams:[$attack]}' >"$plan_attack"
    # Probes outlive the attack (and its slowest request), and are stopped once it has finished.
    local probe_seconds started ended
    if [[ "$duration" == *m ]]; then probe_seconds=$(( ${duration%m} * 60 + 75 )); else probe_seconds=$(( ${duration%s} + 75 )); fi
    new_temp; plan_probe=$TEMP_FILE
    jq -n --argjson probes "$(probe_streams "${probe_seconds}s")" '{streams:$probes}' >"$plan_probe"
    load_start "$RUN_ID" probe "$plan_probe"
    load_first_record "$RUN_ID" probe
    started=$(node_now_ms)
    run_load "$(printf '%s-a' "$RUN_ID" | cut -c1-36)" attack "$plan_attack" "$RUN_DIR" >/dev/null
    ended=$(node_now_ms)
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    local fields
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --argjson started "$started" --argjson ended "$ended" --arg tenant "$TENANT" \
        --slurpfile attack "$RUN_DIR/k6-summary-attack.json" --slurpfile probe "$RUN_DIR/k6-summary-probe.json" \
        --arg profile "$profile" --arg duration "$duration" --arg target "$target" --argjson stream "$extra" \
        --argjson profile_json "$(profile_json "$profile")" --argjson links "$(grafana_links "$started" "$ended")" '{
      kind:"load", name:$tenant, run_id:$run, clock:"kind-node", started_ms:$started, ended_ms:$ended,
      config:{design:env.CLUSTER, tenant:$tenant, profile:$profile, profile_values:$profile_json, duration:$duration,
              upstream:$target, rate:($stream.rate // $profile_json.rate)},
      attack:$attack[0].streams, probes:$probe[0].streams, grafana:$links}' >"$fields"
    finish_run "$fields"
    jq -r '.attack, .probes | to_entries[] | "\(.key)\t\(.value.requests) requests, \(.value.dropped_iterations) dropped, \(.value.verdicts | to_entries | map("\(.key) \(.value)") | join(", "))"' \
        "$RUN_DIR/run.json" | while IFS=$'\t' read -r name detail; do say_row "$name" "$detail"; done
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
}

restore_command() {
    verify_context
    section "RESTORE | $KIND_CLUSTER"
    if [[ -e "$(journal_file)" ]]; then
        info "Restoring from the journal of $(jq -r '"\(.kind) \(.name) (run \(.run_id), stage \(.stage))"' "$(journal_file)")."
    else
        info 'No journal; reapplying every tenant from the cluster and the stored keys.'
    fi
    restore_cluster
    recovery_checks || die "Recovery checks still fail; the journal is kept."
    rm -f -- "$(journal_file)"
    ok 'The cluster is restored and every working-set tenant is healthy'
}

source "$ROOT/scripts/failures.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        break) select_cluster_or_both experiments.sh "$@"; verify_context; run_failure "${FAILURE:-}" ;;
        calibrate) select_cluster_or_both experiments.sh "$@"; verify_context; calibrate ;;
        scenario)
            select_cluster_or_both experiments.sh "$@"; verify_context
            case "${NAME:-}" in
                separation) scenario_separation ;;
                latency) scenario_latency ;;
                rollout) scenario_rollout ;;
                foundry-smoke) scenario_foundry_smoke ;;
                *) die "NAME must be separation, latency, rollout, or foundry-smoke." ;;
            esac
            ;;
        load) select_cluster; verify_context; load_command ;;
        restore) select_cluster_or_both experiments.sh "$@"; restore_command ;;
        *) die "Unknown experiment command: ${1:-missing}" ;;
    esac
fi
