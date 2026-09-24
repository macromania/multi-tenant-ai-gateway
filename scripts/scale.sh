#!/bin/bash
# make scale TENANTS=1,5,10: footprint and onboarding at each tenant count, then back to the working set.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/experiments.sh"

IDLE_SECONDS=60
SCALE_LOAD_SECONDS=120
MIN_FREE_BYTES=$((2 * 1073741824))

tenant_name() { printf 'tenant-%02d' "$1"; }

# Runs a tenant command in its own process, so each onboarding or offboarding measures itself exactly
# as it would when typed by hand.
tenant_command() {
    CLUSTER=$CLUSTER TENANT=$2 CONFIRM=1 TOKENS_PER_MINUTE= /bin/bash "$ROOT/scripts/tenants.sh" "$1"
}

docker_free_bytes() {
    local total used=0 usage bytes
    total=$(docker_local info --format '{{.MemTotal}}')
    while IFS= read -r usage; do
        bytes=$(awk -v value="${usage%% *}" 'BEGIN {
          n = value; sub(/[A-Za-z]+$/, "", n); unit = value; sub(/^[0-9.]+/, "", unit)
          f = 1; if (unit == "KiB") f = 1024; else if (unit == "MiB") f = 1048576; else if (unit == "GiB") f = 1073741824
          printf "%.0f", n * f }')
        used=$((used + bytes))
    done < <(docker_local stats --no-stream --format '{{.MemUsage}}')
    printf '%s' $((total - used))
}

# Why the sweep must stop now, or nothing.
stop_reason() {
    local pending pressure free
    pending=$(kube get pods -A -o json | jq -r '[.items[] | select(.status.phase == "Pending") |
      select(((now - (.metadata.creationTimestamp | fromdateiso8601)) > 120)) | .metadata.namespace + "/" + .metadata.name] | join(", ")')
    [[ -z "$pending" ]] || { printf 'pods pending for more than 2 minutes: %s' "$pending"; return; }
    pressure=$(kube get nodes -o json | jq -r '[.items[].status.conditions[] | select(.type == "MemoryPressure" and .status == "True")] | length')
    [[ "$pressure" == 0 ]] || { printf 'the Kind node reports memory pressure'; return; }
    free=$(docker_free_bytes)
    [[ "$free" -ge "$MIN_FREE_BYTES" ]] || printf 'Docker Desktop has only %s MiB free' $((free / 1048576))
}

converge_to() {
    local target=$1 count index tenant existing
    existing=$(tenant_list)
    count=$(printf '%s' "$existing" | grep -c . || true)
    while [[ "$count" -gt "$target" ]]; do
        tenant=$(printf '%s\n' "$existing" | sort | tail -1)
        info "Removing $tenant ($count tenants to $target)."
        tenant_command tenant-remove "$tenant" >&2
        existing=$(tenant_list)
        count=$(printf '%s' "$existing" | grep -c . || true)
    done
    for ((index=1; index<=target; index++)); do
        tenant=$(tenant_name "$index")
        if ! grep -qx "$tenant" <<<"$existing"; then
            local reason
            reason=$(stop_reason)
            [[ -z "$reason" ]] || { STOPPED="$reason"; return 1; }
            info "Adding $tenant (towards $target tenants)."
            tenant_command tenant-add "$tenant" >&2 || { STOPPED="tenant-add $tenant failed; see its run record"; return 1; }
        fi
    done
    existing=$(tenant_list)
    [[ "$(printf '%s' "$existing" | grep -c . || true)" -eq "$target" ]]
}

footprint_json() {
    # The CPU rate covers only the sample's own window, so the idle sample excludes the onboarding before it.
    # Each query result is assigned first (see prom_instant).
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
      def by($r; f): [$r.data.result[] | select(.value[1] != "NaN") | {namespace: .metric.namespace, pod: .metric.pod, value: (.value[1] | tonumber | f)}];
      def resource($r; $name): ([$r.data.result[] | select(.metric.resource == $name) | .value[1] | tonumber] | add // 0);
      {cpu_cores_total: (v($cpu) | add // 0 | . * 1000 | round / 1000),
       memory_mib_total_max_sampled: (v($memory) | add // 0 | . / 1048576 | round),
       per_pod: [by($cpu; . * 1000 | round / 1000)[] as $c | by($memory; . / 1048576 | round)[] |
                 select(.pod == $c.pod) | {namespace, pod, cpu_cores: $c.value, memory_mib_max_sampled: .value}],
       gateway_pods: (v($pods) | add // 0),
       reserved: {cpu_request_cores: resource($requests; "cpu"), memory_request_mib: (resource($requests; "memory") / 1048576 | round),
                  cpu_limit_cores: resource($limits; "cpu"), memory_limit_mib: (resource($limits; "memory") / 1048576 | round)},
       active_gateway_series: (v($series) | add // 0), prometheus_head_series_total: (v($head) | add // 0)}'
}

node_memory_mib() {
    docker_local stats --no-stream --format '{{.MemUsage}}' "$NODE_NAME" | awk '{
      n = $1; sub(/[A-Za-z]+$/, "", n); unit = $1; sub(/^[0-9.]+/, "", unit)
      f = 1; if (unit == "GiB") f = 1024; else if (unit == "KiB") f = 1 / 1024
      printf "%d", n * f }'
}

# Measures the footprint at the current tenant count. It runs as a plain command, never inside if,
# ||, or &&, so that set -e stops the sweep on any measurement error instead of recording nulls.
scale_measure() {
    local target=$1 idle_at load_at started plan streams=() tenant fields idle loaded node links
    begin_run scale "tenants-$target"
    say_section "SCALE | $KIND_CLUSTER | $target tenants"
    started=$(node_now_ms)
    info "Idle for $IDLE_SECONDS seconds, then 1 request per second per tenant for $SCALE_LOAD_SECONDS seconds."
    sleep "$IDLE_SECONDS"
    idle_at=$(( $(node_now_ms) / 1000 ))
    for tenant in $(tenant_list); do
        streams+=("$(stream_json "scale-$tenant" "$tenant" scale gateway "${SCALE_LOAD_SECONDS}s" '{"role":"attack"}')")
    done
    new_temp; plan=$TEMP_FILE
    printf '%s\n' "${streams[@]}" | jq -sc '{streams: .}' >"$plan"
    run_load "$RUN_ID" attack "$plan" "$RUN_DIR" >/dev/null
    load_at=$(( $(node_now_ms) / 1000 ))
    prom_open
    idle=$(footprint_json "$idle_at" "$IDLE_SECONDS")
    loaded=$(footprint_json "$load_at" "$SCALE_LOAD_SECONDS")
    prom_close
    cp -- "$PROM_LOG" "$RUN_DIR/prometheus.json"
    node=$(node_memory_mib)
    [[ "$node" =~ ^[0-9]+$ ]] || die "Cannot read the Kind node's memory from Docker."
    links=$(grafana_links "$started" "$(( load_at * 1000 ))")
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --argjson started "$started" --argjson ended "$(( load_at * 1000 ))" --argjson target "$target" \
        --argjson idle "$idle" --argjson loaded "$loaded" --argjson node "$node" \
        --argjson idle_s "$IDLE_SECONDS" --argjson load_s "$SCALE_LOAD_SECONDS" \
        --slurpfile summary "$RUN_DIR/k6-summary-attack.json" --argjson links "$links" '{
      kind:"scale", name:("tenants-" + ($target | tostring)), run_id:$run, clock:"kind-node",
      started_ms:$started, ended_ms:$ended,
      config:{tenants:$target, idle_s:$idle_s, load_s:$load_s, profile:"scale", design:env.CLUSTER},
      idle:$idle, under_load:$loaded, kind_node_memory_mib:$node,
      load:{requests: ([$summary[0].streams[].requests] | add), dropped: ([$summary[0].streams[].dropped_iterations] | add),
            verdicts: ([$summary[0].streams[].verdicts] | reduce .[] as $v ({}; . as $acc | $v | to_entries | reduce .[] as $e ($acc; .[$e.key] += $e.value)))},
      grafana:$links}' >"$fields"
    finish_run "$fields"
    say_row 'Gateway pods' "$(jq -r '.under_load.gateway_pods' "$RUN_DIR/run.json")"
    say_row 'CPU idle / under load' "$(jq -r '"\(.idle.cpu_cores_total) / \(.under_load.cpu_cores_total) cores"' "$RUN_DIR/run.json")"
    say_row 'Memory (max sampled)' "$(jq -r '"\(.idle.memory_mib_total_max_sampled) / \(.under_load.memory_mib_total_max_sampled) MiB"' "$RUN_DIR/run.json")"
    say_row 'Reserved requests' "$(jq -r '.under_load.reserved | "\(.cpu_request_cores) cores, \(.memory_request_mib) MiB (limits \(.cpu_limit_cores) cores, \(.memory_limit_mib) MiB)"' "$RUN_DIR/run.json")"
    say_row 'Active gateway series' "$(jq -r '.under_load.active_gateway_series' "$RUN_DIR/run.json")"
    say_row 'Kind node memory' "$(jq -r '.kind_node_memory_mib' "$RUN_DIR/run.json") MiB"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
}

scale_command() {
    local list=${TENANTS:-} step steps=() count
    [[ "$list" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "TENANTS must be a comma-separated list such as 1,5,10."
    IFS=, read -r -a steps <<<"$list"
    for step in "${steps[@]}"; do
        [[ "$step" -ge 1 && "$step" -le 16 ]] || die "Each tenant count must be from 1 to 16 (the shared design holds at most 16)."
    done
    [[ ! -e "$(journal_file)" ]] || die "A recovery journal exists. Run make restore CLUSTER=$CLUSTER first."
    mock_push_keys
    if [[ ${#steps[@]} -eq 1 ]]; then
        # One number converges to that many tenants and records the footprint there.
        STOPPED=
        converge_to "${steps[0]}" || die "Stopped: ${STOPPED:-could not reach ${steps[0]} tenants}."
        scale_measure "${steps[0]}"
        ok "$KIND_CLUSTER has ${steps[0]} tenants"
        return
    fi
    for step in "${steps[@]}"; do
        STOPPED=
        if ! converge_to "$step"; then
            warn "The sweep stopped before $step tenants: ${STOPPED:-unknown reason}."
            begin_run scale "stopped-at-$step"
            local fields
            new_temp; fields=$TEMP_FILE
            jq -n --arg run "$RUN_ID" --argjson step "$step" --arg reason "${STOPPED:-unknown}" '{kind:"scale",
              name:("stopped-at-" + ($step | tostring)), run_id:$run, stopped:true, reason:$reason,
              config:{tenants:$step, design:env.CLUSTER}}' >"$fields"
            finish_run "$fields"
            break
        fi
        scale_measure "$step"
    done
    section "CONVERGE | $KIND_CLUSTER | back to the working set"
    converge_to 3 || die "Could not return to 3 tenants: ${STOPPED:-unknown}."
    count=$(tenant_list | grep -c . || true)
    ok "$KIND_CLUSTER is back at $count tenants"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    select_cluster_or_both scale.sh "$@"
    verify_context
    scale_command
fi
