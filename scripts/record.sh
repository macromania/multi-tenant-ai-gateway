#!/bin/bash
# Run records under results/<cluster>/. Sourced after common.sh.
#
# Every record names the commit, whether the implementation inputs matched it, and a fingerprint of
# those inputs. Generated results are never part of the inputs, so committing results never makes a
# later run look like it used uncommitted code.

RESULTS="$ROOT/results"
# The report generator only reads run records, so changing it never makes a measurement stale.
INPUT_PATHS=(Makefile scripts deploy versions.env ports.env ':(exclude)scripts/results.sh' ':(exclude)scripts/report.jq')
RUN_ID=
RUN_DIR=
RUN_PROVENANCE=
CONTENTION_FILE=
HOST_LOAD_FILE=
CONTENTION_SAMPLER=
CONTENTION_LIMIT=0.5

# SHA-256 over the path and content hash of every tracked or untracked, non-ignored input file.
input_fingerprint() {
    (
        cd "$ROOT"
        git ls-files -co --exclude-standard -- "${INPUT_PATHS[@]}" | LC_ALL=C sort |
            while IFS= read -r path; do
                [[ -f "$path" ]] || continue
                printf '%s  %s\n' "$(openssl dgst -sha256 -r "$path" | awk '{print $1}')" "$path"
            done
    ) | openssl dgst -sha256 -r | awk '{print $1}'
}

inputs_committed() {
    local changes
    changes=$(git -C "$ROOT" status --porcelain -- "${INPUT_PATHS[@]}") || die "Cannot read Git status."
    if [[ -z "$changes" ]]; then printf 'true'; else printf 'false'; fi
}

# Milliseconds on the Kind node's clock, the same clock that timestamps k6 probe records, so mutation
# times and probe times can be compared without host clock drift.
node_now_ms() {
    node_exec date +%s%3N | tr -d '\r\n'
}

# new_run <kind> <name>: sets RUN_ID (a short Kubernetes-safe name) and RUN_DIR.
new_run() {
    local kind=$1 name=$2 stamp short
    [[ "$kind" =~ ^[a-z][a-z-]{1,20}$ && "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || die "Invalid run name."
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    short=$(printf '%s' "$name" | cut -c1-22 | sed 's/-*$//')
    RUN_ID="$short-$(date -u +%H%M%S)"
    RUN_DIR="$RESULTS/$CLUSTER/$stamp-$kind-$name"
    [[ ! -e "$RUN_DIR" ]] || die "Run directory already exists: $RUN_DIR"
    mkdir -p -- "$RUN_DIR"
    # Provenance describes the code at the start of the run; write_run_json checks it again.
    new_temp; RUN_PROVENANCE=$TEMP_FILE
    provenance_json >"$RUN_PROVENANCE"
    start_contention_sampler
}

# The other project cluster's Kind node shares Docker Desktop's CPU. Every run samples its CPU every
# 5 seconds, and write_run_json records the mean, so the report can exclude confounded runs. The
# host's 1-minute load average is sampled too and recorded as evidence only: this run's own load
# raises it, and the delivery checks already catch its effect on the apparatus.
other_node_name() {
    if [[ "$CLUSTER" == shared ]]; then printf 'mtag-dedicated-control-plane'; else printf 'mtag-shared-control-plane'; fi
}
stop_contention_sampler() {
    if [[ -n "$CONTENTION_SAMPLER" ]]; then
        kill "$CONTENTION_SAMPLER" 2>/dev/null || true
        wait "$CONTENTION_SAMPLER" 2>/dev/null || true
    fi
    CONTENTION_SAMPLER=
}
start_contention_sampler() {
    local other
    stop_contention_sampler
    other=$(other_node_name)
    CONTENTION_FILE="$RUN_DIR/other-node-cpu.txt"
    HOST_LOAD_FILE="$RUN_DIR/host-load.txt"
    : >"$CONTENTION_FILE"
    : >"$HOST_LOAD_FILE"
    on_exit stop_contention_sampler
    (
        set +e
        while :; do
            docker_local stats --no-stream --format '{{.CPUPerc}}' "$other" 2>/dev/null | tr -d '%' >>"$CONTENTION_FILE"
            sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }' >>"$HOST_LOAD_FILE"
            sleep 5
        done
    ) &
    CONTENTION_SAMPLER=$!
}
# Prints {other_node, present, samples, mean_cpu, confounded, host_load}. A missing node counts as
# idle; a present node with no samples leaves the verdict unknown (null), which the report excludes.
contention_json() {
    local present=false host cpus
    if docker_local ps --format '{{.Names}}' | grep -Fxq "$(other_node_name)"; then present=true; fi
    cpus=$(sysctl -n hw.ncpu 2>/dev/null || printf 'null')
    host=$(awk '$1 ~ /^[0-9.]+$/ { print $1 }' "${HOST_LOAD_FILE:-/dev/null}" 2>/dev/null |
        jq -s -c --argjson cpus "$cpus" '{samples: length, cpus: $cpus,
          mean_1m: (if length == 0 then null else (add / length * 100 | round / 100) end), max_1m: max}')
    awk '$1 ~ /^[0-9.]+$/ { print $1 / 100 }' "${CONTENTION_FILE:-/dev/null}" 2>/dev/null |
        jq -s -c --arg node "$(other_node_name)" --argjson present "$present" --argjson limit "$CONTENTION_LIMIT" \
            --argjson host "$host" '
          (if length == 0 then null else (add / length * 100 | round / 100) end) as $mean |
          {other_node: $node, present: $present, samples: length, mean_cpu: $mean, limit_cpu: $limit,
           confounded: (if ($present | not) then false elif $mean == null then null else $mean > $limit end),
           host_load: $host}'
}

provenance_json() {
    jq -n --arg commit "$(git -C "$ROOT" rev-parse HEAD)" --arg committed "$(inputs_committed)" \
        --arg fingerprint "$(input_fingerprint)" --arg cluster "$CLUSTER" \
        --arg comparison "${COMPARISON_ID:-}" --arg agentgateway "$AGENTGATEWAY_VERSION" \
        --arg kind "$KIND_VERSION" --arg k6 "$K6_IMAGE" --arg python "$PYTHON_IMAGE" \
        --arg prometheus_stack "$KUBE_PROMETHEUS_STACK_VERSION" --arg gateway_api "$GATEWAY_API_VERSION" '{
      commit: $commit, inputs_committed: ($committed == "true"), input_fingerprint: $fingerprint,
      cluster: $cluster, comparison_id: (if $comparison == "" then null else $comparison end),
      versions: {agentgateway: $agentgateway, kind: $kind, k6: $k6, python: $python,
                 kube_prometheus_stack: $prometheus_stack, gateway_api: $gateway_api}}'
}

# write_run_json <json file with run-specific fields>: merges the provenance captured when the run
# started and writes run.json. If the implementation inputs changed during the run, the record says
# so and does not claim they were committed. A "config" object in the fields (workload, tenant count,
# limits, mock settings, windows) is hashed, without its design field, into config_fingerprint, which
# the report uses to decide which runs of the two designs are comparable.
write_run_json() {
    local now contention
    stop_contention_sampler
    contention=$(contention_json)
    new_temp; now=$TEMP_FILE
    provenance_json >"$now"
    jq -s --argjson contention "$contention" '
      .[0] as $start | .[1] as $end | .[2] as $fields |
      $start + {inputs_changed_during_run: ($start.input_fingerprint != $end.input_fingerprint or
                                            $start.commit != $end.commit)} |
      if .inputs_changed_during_run then .inputs_committed = false else . end |
      . + {contention: $contention} + $fields' "$RUN_PROVENANCE" "$now" "$1" >"$RUN_DIR/run.json"
    if jq -e 'has("config")' "$RUN_DIR/run.json" >/dev/null; then
        local digest
        # The design is recorded but left out of the hash, so the same conditions in the two
        # clusters give the same fingerprint.
        digest=$(jq -S -c '.config | del(.design)' "$RUN_DIR/run.json" | openssl dgst -sha256 -r | awk '{print $1}')
        jq --arg digest "$digest" '.config_fingerprint = $digest' "$RUN_DIR/run.json" >"$now"
        cp -- "$now" "$RUN_DIR/run.json"
    fi
}
