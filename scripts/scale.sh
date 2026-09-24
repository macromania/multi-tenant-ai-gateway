#!/bin/bash
# make scale TENANTS=1,5,10: footprint and onboarding at each tenant count, then back to the working set.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/experiments.sh"

IDLE_SECONDS=60
SCALE_LOAD_SECONDS=120
MIN_FREE_BYTES=$((2 * 1073741824))
MAX_SCALE_TENANTS=16
INITIAL_TENANTS=
SWEEP_ACTIVE=
SCALE_PRESSURE=
STOPPED=

tenant_name() { printf 'tenant-%02d' "$1"; }
tenant_number() { printf '%d' "$((10#${1#tenant-}))"; }

# Runs a tenant command in its own process, so each onboarding or offboarding measures itself exactly
# as it would when typed by hand.
tenant_command() {
    CLUSTER=$CLUSTER TENANT=$2 CONFIRM=1 TOKENS_PER_MINUTE= /bin/bash "$ROOT/scripts/tenants.sh" "$1"
}

# Memory available in the Docker Desktop VM. The Kind node shares the VM's kernel, so its
# /proc/meminfo describes the whole VM, including memory used outside containers.
vm_available_bytes() {
    local kib
    kib=$(node_exec awk '/^MemAvailable:/ { print $2 }' /proc/meminfo | tr -d '\r')
    [[ "$kib" =~ ^[0-9]+$ ]] || die "Cannot read the Docker Desktop VM's available memory."
    printf '%s' $((kib * 1024))
}

# Prints why the sweep must stop now, or nothing. A check that cannot be made is itself a reason.
stop_reason() {
    local pods nodes pending pressure free
    pods=$(kube get pods -A -o json) || { printf 'the pods could not be listed'; return 0; }
    pending=$(jq -r '[.items[] | select(.status.phase == "Pending") |
      select(((now - (.metadata.creationTimestamp | fromdateiso8601)) > 120)) | .metadata.namespace + "/" + .metadata.name] | join(", ")' <<<"$pods")
    [[ -z "$pending" ]] || { printf 'pods pending for more than 2 minutes: %s' "$pending"; return 0; }
    nodes=$(kube get nodes -o json) || { printf 'the nodes could not be read'; return 0; }
    pressure=$(jq -r '[.items[].status.conditions[] | select(.type == "MemoryPressure" and .status == "True")] | length' <<<"$nodes")
    [[ "$pressure" == 0 ]] || { printf 'the Kind node reports memory pressure'; return 0; }
    free=$(vm_available_bytes) || { printf 'the Docker Desktop VM memory could not be read'; return 0; }
    [[ "$free" -ge "$MIN_FREE_BYTES" ]] || printf 'the Docker Desktop VM has only %s MiB available' $((free / 1048576))
}

# A tenant may be removed only if it is in tenant-01..tenant-16 and either the sweep created it or
# the user confirmed removing tenants that existed before (CONFIRM=1). Sets STOPPED otherwise.
removable() {
    local tenant=$1 number
    [[ "$tenant" =~ ^tenant-[0-9]{2}$ ]] || { STOPPED="$tenant is not a tenant this sweep manages"; return 1; }
    number=$(tenant_number "$tenant")
    [[ "$number" -ge 1 && "$number" -le "$MAX_SCALE_TENANTS" ]] ||
        { STOPPED="$tenant is outside tenant-01 to tenant-$MAX_SCALE_TENANTS"; return 1; }
    if grep -qx "$tenant" <<<"$INITIAL_TENANTS" && [[ "${CONFIRM:-}" != 1 ]]; then
        STOPPED="$tenant existed before the sweep; rerun with CONFIRM=1 to allow removing it"; return 1
    fi
}

# Makes tenant-01..tenant-<target> exist and be active, and removes every higher tenant, highest
# first. An existing tenant that is not active is completed with tenant-add. Returns 1 with STOPPED
# set when a stop condition or a failed command ends it; every failure is checked explicitly,
# because callers run it inside if or ||, where set -e does not apply.
converge_to() {
    local target=$1 index tenant existing state reason extra count
    existing=$(tenant_list) || { STOPPED='the tenants could not be listed'; return 1; }
    extra=$(printf '%s\n' "$existing" | awk -v t="$target" 'NF { n = $0; sub(/^tenant-/, "", n); if (n + 0 > t) print }' | sort -r)
    for tenant in $extra; do
        removable "$tenant" || return 1
        info "Removing $tenant (towards $target tenants)."
        if ! tenant_command tenant-remove "$tenant" >&2; then STOPPED="tenant-remove $tenant failed; see its output"; return 1; fi
        existing=$(tenant_list) || { STOPPED='the tenants could not be listed'; return 1; }
        if grep -qx "$tenant" <<<"$existing"; then STOPPED="$tenant is still present after tenant-remove"; return 1; fi
    done
    for ((index=1; index<=target; index++)); do
        tenant=$(tenant_name "$index")
        state=
        if grep -qx "$tenant" <<<"$existing"; then
            state=$(tenant_state "$tenant") || { STOPPED="the state of $tenant could not be read"; return 1; }
        fi
        [[ "$state" != active ]] || continue
        reason=$(stop_reason) || reason='the stop conditions could not be checked'
        [[ -z "$reason" ]] || { STOPPED="$reason"; return 1; }
        if [[ -n "$state" ]]; then info "Completing $tenant, which is ${state}."; else info "Adding $tenant (towards $target tenants)."; fi
        if ! tenant_command tenant-add "$tenant" >&2; then STOPPED="tenant-add $tenant failed; see its run record"; return 1; fi
    done
    existing=$(tenant_list) || { STOPPED='the tenants could not be listed'; return 1; }
    count=$(printf '%s' "$existing" | grep -c . || true)
    [[ "$count" -eq "$target" ]] || { STOPPED="expected $target tenants, found $count"; return 1; }
    for tenant in $existing; do
        state=$(tenant_state "$tenant") || { STOPPED="the state of $tenant could not be read"; return 1; }
        [[ "$state" == active ]] || { STOPPED="$tenant is ${state:-without a state} after converging"; return 1; }
    done
}

footprint_json() {
    # The CPU rate covers only the sample's own window, so the idle sample excludes the onboarding before it.
    # Each query result is assigned first (see prom_instant). Missing series stay missing: coverage
    # counts how many gateway pods each figure includes, and the caller rejects incomplete samples.
    local at=$1 window=$2 gateway='namespace=~"agentgateway-system|tenant-[0-9]+"' cpu memory pods requests limits series head
    cpu=$(prom_instant "sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{$gateway,container!=\"\",container!=\"POD\"}[${window}s]))" "$at")
    memory=$(prom_instant "max by (namespace, pod) (max_over_time(container_memory_working_set_bytes{$gateway,container!=\"\",container!=\"POD\"}[${window}s]))" "$at")
    pods=$(prom_instant "count(kube_pod_status_phase{$gateway,phase=\"Running\"} == 1)" "$at")
    requests=$(prom_instant "sum by (resource) (kube_pod_container_resource_requests{$gateway})" "$at")
    limits=$(prom_instant "sum by (resource) (kube_pod_container_resource_limits{$gateway})" "$at")
    series=$(prom_instant "count({$gateway,__name__=~\"agentgateway_.*\"})" "$at")
    head=$(prom_instant "max(prometheus_tsdb_head_series)" "$at")
    jq -n --argjson cpu "$cpu" --argjson memory "$memory" --argjson pods "$pods" --argjson requests "$requests" \
        --argjson limits "$limits" --argjson series "$series" --argjson head "$head" '
      # f is a filter applied to each sample; Prometheus reports 0/0 ratios as "NaN", which are skipped.
      def v($r): [$r.data.result[] | select(.value[1] != "NaN") | .value[1] | tonumber];
      def one($r): (v($r) | if length == 0 then null else add end);
      def by($r; f): [$r.data.result[] | select(.value[1] != "NaN") | {namespace: .metric.namespace, pod: .metric.pod, value: (.value[1] | tonumber | f)}];
      def resource($r; $name): ([$r.data.result[] | select(.metric.resource == $name) | .value[1] | tonumber] | if length == 0 then null else add end);
      by($cpu; . * 1000 | round / 1000) as $cpu_pods | by($memory; . / 1048576 | round) as $memory_pods |
      {cpu_cores_total: ([$cpu_pods[].value] | add // 0 | . * 1000 | round / 1000),
       memory_mib_total_max_sampled: ([$memory_pods[].value] | add // 0),
       per_pod: [$cpu_pods[] as $c | $memory_pods[] | select(.namespace == $c.namespace and .pod == $c.pod) |
                 {namespace, pod, cpu_cores: $c.value, memory_mib_max_sampled: .value}],
       gateway_pods: one($pods),
       coverage: {cpu_pods: ($cpu_pods | length), memory_pods: ($memory_pods | length)},
       reserved: {cpu_request_cores: resource($requests; "cpu"), memory_request_mib: (resource($requests; "memory") | if . == null then null else . / 1048576 | round end),
                  cpu_limit_cores: resource($limits; "cpu"), memory_limit_mib: (resource($limits; "memory") | if . == null then null else . / 1048576 | round end)},
       active_gateway_series: one($series), prometheus_head_series_total: one($head)}'
}

node_memory_mib() {
    local usage mib
    usage=$(docker_local stats --no-stream --format '{{.MemUsage}}' "$NODE_NAME")
    mib=$(awk '{
      n = $1; sub(/[A-Za-z]+$/, "", n); unit = $1; sub(/^[0-9.]+/, "", unit)
      f = 1; if (unit == "GiB") f = 1024; else if (unit == "KiB") f = 1 / 1024
      printf "%d", n * f }' <<<"$usage")
    [[ "$mib" =~ ^[0-9]+$ ]] || die "Cannot read the Kind node's memory from Docker."
    printf '%s' "$mib"
}

# Measures the footprint at the current tenant count. It runs as a plain command, never inside if,
# ||, or &&, so that set -e stops the sweep on any measurement error instead of recording nulls.
# Sets SCALE_PRESSURE when a stop condition appears during the measurement.
scale_measure() {
    local target=$1 idle_at started plan streams=() tenant listed fields idle loaded node links window
    local load_from load_to expected pressure
    SCALE_PRESSURE=
    begin_run scale "tenants-$target"
    say_section "SCALE | $KIND_CLUSTER | $target tenants"
    started=$(node_now_ms)
    info "Idle for $IDLE_SECONDS seconds, then 1 request per second per tenant for $SCALE_LOAD_SECONDS seconds."
    sleep "$IDLE_SECONDS"
    idle_at=$(( $(node_now_ms) / 1000 ))
    pressure=$(stop_reason) || pressure='the stop conditions could not be checked'
    listed=$(tenant_list)
    for tenant in $listed; do
        streams+=("$(stream_json "scale-$tenant" "$tenant" scale gateway "${SCALE_LOAD_SECONDS}s" '{"role":"attack","records":true,"timeout":"10s"}')")
    done
    new_temp; plan=$TEMP_FILE
    printf '%s\n' "${streams[@]}" | jq -sc '{streams: .}' >"$plan"
    run_load "$RUN_ID" attack "$plan" "$RUN_DIR" >/dev/null
    # The load window is taken from the requests themselves, not from when the Job finished.
    window=$(jq -s -c '[.[] | select(.verdict != "censored") | .start_ms] | {from: min, to: max}' "$RUN_DIR/probes-attack.jsonl")
    load_from=$(jq -r '.from // empty' <<<"$window")
    load_to=$(jq -r '.to // empty' <<<"$window")
    [[ "$load_from" =~ ^[0-9]+$ && "$load_to" =~ ^[0-9]+$ ]] || die "The scale load recorded no requests."
    [[ -n "$pressure" ]] || { pressure=$(stop_reason) || pressure='the stop conditions could not be checked'; }
    prom_open
    idle=$(footprint_json "$idle_at" "$IDLE_SECONDS")
    loaded=$(footprint_json "$(( load_to / 1000 ))" "$(( (load_to - load_from) / 1000 + 1 ))")
    prom_close
    cp -- "$PROM_LOG" "$RUN_DIR/prometheus.json"
    node=$(node_memory_mib)
    links=$(grafana_links "$started" "$load_to")
    if [[ "$CLUSTER" == shared ]]; then expected=2; else expected=$(( 2 * target )); fi
    new_temp; fields=$TEMP_FILE
    jq -s --arg run "$RUN_ID" --argjson started "$started" --argjson ended "$load_to" --argjson target "$target" \
        --argjson idle "$idle" --argjson loaded "$loaded" --argjson node "$node" --argjson expected "$expected" \
        --argjson idle_s "$IDLE_SECONDS" --argjson load_s "$SCALE_LOAD_SECONDS" --arg pressure "$pressure" \
        --argjson load_from "$load_from" --slurpfile summary "$RUN_DIR/k6-summary-attack.json" --argjson links "$links" '
      [.[] | select(.verdict != "censored")] as $r |
      ($summary[0].streams) as $streams |
      {kind:"scale", name:("tenants-" + ($target | tostring)), run_id:$run, clock:"kind-node",
       started_ms:$started, ended_ms:$ended, load_window_ms:{from:$load_from, to:$ended},
       config:{tenants:$target, idle_s:$idle_s, load_s:$load_s, profile:"scale", design:env.CLUSTER},
       expected_gateway_pods:$expected, idle:$idle, under_load:$loaded, kind_node_memory_mib:$node,
       load:{requests: ([$streams[].requests] | add), dropped: ([$streams[].dropped_iterations] | add),
             verdicts: ($r | group_by(.verdict) | map({(.[0].verdict): length}) | add // {})},
       grafana:$links} |
      .reasons = [
        ($streams | to_entries[] | select(.value.dropped_iterations > 0) | "\(.key) dropped \(.value.dropped_iterations) iterations"),
        ($r | group_by(.stream) | .[] | select(([.[] | select(.verdict == "verified")] | length) < 0.99 * $load_s) |
         "\(.[0].stream) had \([.[] | select(.verdict == "verified")] | length) verified responses of \($load_s)"),
        ([$r[] | select(.verdict != "verified")] | length | if . > 0 then "\(.) responses were not verified" else empty end),
        (["idle", "under_load"][] as $sample | .[$sample] |
         (if .gateway_pods != $expected then "\($sample): \(.gateway_pods // 0) running gateway pods, expected \($expected)" else empty end),
         (if .coverage.cpu_pods != $expected or .coverage.memory_pods != $expected
          then "\($sample): CPU covers \(.coverage.cpu_pods) and memory \(.coverage.memory_pods) of \($expected) gateway pods" else empty end),
         (if .reserved.cpu_request_cores == null or .active_gateway_series == null then "\($sample): reserved capacity or series telemetry is missing" else empty end)),
        (if $pressure != "" then "a stop condition appeared during the measurement: " + $pressure else empty end)] |
      .valid = (.reasons | length == 0)' "$RUN_DIR/probes-attack.jsonl" >"$fields"
    finish_run "$fields"
    SCALE_PRESSURE=$pressure
    say_row 'Gateway pods' "$(jq -r '"\(.under_load.gateway_pods) (expected \(.expected_gateway_pods))"' "$RUN_DIR/run.json")"
    say_row 'CPU idle / under load' "$(jq -r '"\(.idle.cpu_cores_total) / \(.under_load.cpu_cores_total) cores"' "$RUN_DIR/run.json")"
    say_row 'Memory (max sampled)' "$(jq -r '"\(.idle.memory_mib_total_max_sampled) / \(.under_load.memory_mib_total_max_sampled) MiB"' "$RUN_DIR/run.json")"
    say_row 'Reserved requests' "$(jq -r '.under_load.reserved | "\(.cpu_request_cores) cores, \(.memory_request_mib) MiB (limits \(.cpu_limit_cores) cores, \(.memory_limit_mib) MiB)"' "$RUN_DIR/run.json")"
    say_row 'Active gateway series' "$(jq -r '.under_load.active_gateway_series' "$RUN_DIR/run.json")"
    say_row 'Kind node memory' "$(jq -r '.kind_node_memory_mib' "$RUN_DIR/run.json") MiB"
    say_row 'Validity' "$(jq -r 'if .valid then "valid" else "invalid: " + (.reasons | join("; ")) end' "$RUN_DIR/run.json")"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
}

record_stopped() {
    local step=$1 reason=$2 fields
    warn "The sweep stopped before $step tenants: $reason."
    begin_run scale "stopped-at-$step"
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --argjson step "$step" --arg reason "$reason" '{kind:"scale",
      name:("stopped-at-" + ($step | tostring)), run_id:$run, stopped:true, reason:$reason,
      config:{tenants:$step, design:env.CLUSTER}}' >"$fields"
    finish_run "$fields"
}

# Returns a sweep that ended early, by error or interruption, to the working set.
scale_restore_on_exit() {
    [[ -n "$SWEEP_ACTIVE" ]] || return 0
    warn "The sweep ended early; returning $KIND_CLUSTER to the working set."
    STOPPED=
    if ! converge_to 3; then warn "Could not return to 3 tenants: $STOPPED"; return 1; fi
    recovery_checks 120
}

scale_command() {
    local list=${TENANTS:-} step steps=() lowest tenant number would= reason next index
    [[ "$list" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "TENANTS must be a comma-separated list such as 1,5,10."
    IFS=, read -r -a steps <<<"$list"
    for step in "${steps[@]}"; do
        [[ "$step" -ge 1 && "$step" -le "$MAX_SCALE_TENANTS" ]] ||
            die "Each tenant count must be from 1 to $MAX_SCALE_TENANTS (the shared design holds at most 16)."
    done
    [[ ! -e "$(journal_file)" ]] || die "A recovery journal exists. Run make restore CLUSTER=$CLUSTER first."
    INITIAL_TENANTS=$(tenant_list)
    for tenant in $INITIAL_TENANTS; do
        number=$(tenant_number "$tenant")
        [[ "$number" -ge 1 && "$number" -le "$MAX_SCALE_TENANTS" ]] ||
            die "$tenant is outside tenant-01 to tenant-$MAX_SCALE_TENANTS, the range make scale manages. Remove it first with make tenant-remove CLUSTER=$CLUSTER TENANT=$tenant CONFIRM=1."
    done
    # The lowest count the command reaches decides which existing tenants it removes.
    lowest=${steps[0]}
    for step in "${steps[@]}"; do [[ "$step" -ge "$lowest" ]] || lowest=$step; done
    [[ ${#steps[@]} -eq 1 || "$lowest" -le 3 ]] || lowest=3
    for tenant in $INITIAL_TENANTS; do
        [[ "$(tenant_number "$tenant")" -le "$lowest" ]] || would="$would $tenant"
    done
    [[ -z "$would" || "${CONFIRM:-}" == 1 ]] ||
        die "This removes tenants that existed before it started, and deletes their keys:$would. A tenant added again gets new keys. Rerun with CONFIRM=1."
    mock_push_keys
    if [[ ${#steps[@]} -eq 1 ]]; then
        # One number converges to that many tenants and records the footprint there.
        STOPPED=
        converge_to "${steps[0]}" || die "Stopped: ${STOPPED:-could not reach ${steps[0]} tenants}."
        scale_measure "${steps[0]}"
        [[ -z "$SCALE_PRESSURE" ]] || warn "A stop condition appeared during the measurement: $SCALE_PRESSURE"
        [[ "${steps[0]}" -lt 3 ]] || recovery_checks 120 || die "The working set is not healthy. Run make restore CLUSTER=$CLUSTER."
        ok "$KIND_CLUSTER has ${steps[0]} tenants"
        return
    fi
    SWEEP_ACTIVE=1
    on_exit scale_restore_on_exit
    for ((index=0; index<${#steps[@]}; index++)); do
        step=${steps[index]}
        STOPPED=
        if ! converge_to "$step"; then record_stopped "$step" "${STOPPED:-unknown reason}"; break; fi
        reason=$(stop_reason) || reason='the stop conditions could not be checked'
        if [[ -n "$reason" ]]; then record_stopped "$step" "$reason"; break; fi
        scale_measure "$step"
        if [[ -n "$SCALE_PRESSURE" ]]; then
            next=${steps[index + 1]:-}
            if [[ -n "$next" ]]; then record_stopped "$next" "$SCALE_PRESSURE"; else warn "A stop condition appeared during the last step: $SCALE_PRESSURE"; fi
            break
        fi
    done
    section "CONVERGE | $KIND_CLUSTER | back to the working set"
    STOPPED=
    converge_to 3 || die "Could not return to 3 tenants: ${STOPPED:-unknown}."
    recovery_checks 120 || die "The working set is not healthy after the sweep. Run make restore CLUSTER=$CLUSTER."
    SWEEP_ACTIVE=
    ok "$KIND_CLUSTER is back at 3 healthy tenants"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    select_cluster_or_both scale.sh "$@"
    verify_context
    scale_command
fi
