#!/bin/bash
# Run records under results/<cluster>/. Sourced after common.sh.
#
# Every record names the commit, whether the implementation inputs matched it, and a fingerprint of
# those inputs. Generated results are never part of the inputs, so committing results never makes a
# later run look like it used uncommitted code.

RESULTS="$ROOT/results"
INPUT_PATHS=(Makefile scripts deploy versions.env ports.env)
RUN_ID=
RUN_DIR=
RUN_PROVENANCE=

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
    local now
    new_temp; now=$TEMP_FILE
    provenance_json >"$now"
    jq -s '
      .[0] as $start | .[1] as $end | .[2] as $fields |
      $start + {inputs_changed_during_run: ($start.input_fingerprint != $end.input_fingerprint or
                                            $start.commit != $end.commit)} |
      if .inputs_changed_during_run then .inputs_committed = false else . end |
      . + $fields' "$RUN_PROVENANCE" "$now" "$1" >"$RUN_DIR/run.json"
    if jq -e 'has("config")' "$RUN_DIR/run.json" >/dev/null; then
        local digest
        # The design is recorded but left out of the hash, so the same conditions in the two
        # clusters give the same fingerprint.
        digest=$(jq -S -c '.config | del(.design)' "$RUN_DIR/run.json" | openssl dgst -sha256 -r | awk '{print $1}')
        jq --arg digest "$digest" '.config_fingerprint = $digest' "$RUN_DIR/run.json" >"$now"
        cp -- "$now" "$RUN_DIR/run.json"
    fi
}
