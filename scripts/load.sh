#!/bin/bash
# k6 load Jobs. Sourced by the experiment and tenant scripts after common.sh.
#
# A plan is a JSON file: {"streams": [{"name", "tenant", "key", "url", "rate", "duration", ...}]}.
# "key" names a credential as <tenant>.api (the tenant's gateway key) or <tenant>.mock (its mock
# provider key). Keys are copied from .env.tenants into a short-lived Secret and never appear in a
# process argument, a ConfigMap, or a log.

LOAD_PENDING=()

load_job_name() { printf 'load-%s-%s' "$1" "$2"; }

validate_run_id() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,34}[a-z0-9])?$ ]] || die "Invalid run ID: $1"
}

validate_plan() {
    jq -e '
      (.streams | type == "array" and length > 0 and length <= 64) and
      all(.streams[];
        (.name | test("^[a-z0-9][a-z0-9-]{0,40}$")) and
        (.tenant | test("^tenant-[0-9]{2}$")) and
        (.key | test("^tenant-[0-9]{2}[.](api|mock)$")) and
        (.url | test("^http://[a-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9/_.-]*$")) and
        (.rate | type == "number" and . >= 1 and . <= 5000 and floor == .) and
        (.duration | test("^[0-9]+[sm]$")) and
        ((.start_delay // "0s") | test("^[0-9]+s$")) and
        ((.expected_owner // "tenant-00") | test("^tenant-[0-9]{2}$")) and
        ((.forged_tenant // "tenant-00") | test("^tenant-[0-9]{2}$")) and
        ((.latency_ms // 0) | type == "number" and . >= 0 and . <= 120000) and
        ((.prompt_chars // 40) | type == "number" and . >= 1 and . <= 1000000)) and
      ([.streams[].name] | length == (unique | length))
    ' "$1" >/dev/null || die "Invalid load plan $1."
}

# Prints a JSON object mapping each key name in the plan to its value from .env.tenants.
plan_keys() {
    local upper
    load_tenant_env
    upper=$(printf '%s' "$CLUSTER" | tr '[:lower:]' '[:upper:]')
    jq --slurpfile env "$TENANT_JSON" --arg cluster "$upper" '
      [.streams[].key] | unique | map(
        . as $name | capture("^(?<tenant>tenant-[0-9]{2})[.](?<kind>api|mock)$") as $part |
        {key: $name, value: $env[0][$cluster + "_" + ($part.tenant | ascii_upcase | gsub("-"; "_")) +
                                     "_" + ($part.kind | ascii_upcase) + "_KEY"]}) |
      if any(.[]; (.value // "") | test("^[a-f0-9]{64}$") | not)
      then error("a key named in the plan is missing from .env.tenants") else from_entries end
    ' "$1" || die "A key named in the load plan is missing from .env.tenants."
}

refresh_k6_scripts() {
    kube -n "$LOAD_NAMESPACE" create configmap k6-scripts --from-file="$ROOT/deploy/k6" \
        --dry-run=client -o json | kube_apply -f - >/dev/null
}

load_resources_delete() {
    local run=$1
    kube -n "$LOAD_NAMESPACE" delete jobs,configmaps,secrets -l "gateway.dev/run=$run" \
        --ignore-not-found --wait=false >/dev/null
}

load_cleanup_pending() {
    local entry
    for entry in "${LOAD_PENDING[@]+"${LOAD_PENDING[@]}"}"; do
        load_resources_delete "${entry%%:*}"
    done
}

# load_start <run-id> <probe|attack> <plan-file>: creates the Job and returns at once.
load_start() {
    local run=$1 role=$2 plan=$3 name secret keys job resources mounted
    validate_run_id "$run"
    [[ "$role" == probe || "$role" == attack ]] || die "Load role must be probe or attack."
    validate_plan "$plan"
    name=$(load_job_name "$run" "$role")
    new_temp; keys=$TEMP_FILE
    plan_keys "$plan" >"$keys"
    if [[ ${#LOAD_PENDING[@]} -eq 0 ]]; then on_exit load_cleanup_pending; fi
    LOAD_PENDING+=("$run:$role")
    refresh_k6_scripts
    new_temp; secret=$TEMP_FILE
    jq -n --slurpfile keys "$keys" --arg name "$name-keys" --arg run "$run" --arg namespace "$LOAD_NAMESPACE" '{
      apiVersion:"v1",kind:"Secret",type:"Opaque",
      metadata:{name:$name,namespace:$namespace,labels:{"gateway.dev/run":$run}},
      stringData:$keys[0]}' >"$secret"
    kube_apply -f "$secret" >/dev/null
    new_temp; mounted=$TEMP_FILE
    jq --arg run "$run" --arg cluster "$CLUSTER" '. + {run_id:$run, cluster:$cluster}' "$plan" >"$mounted"
    kube -n "$LOAD_NAMESPACE" create configmap "$name-plan" --from-file=plan.json="$mounted" \
        --dry-run=client -o json |
        jq --arg run "$run" '.metadata.labels={"gateway.dev/run":$run}' | kube_apply -f - >/dev/null
    if [[ "$role" == probe ]]; then
        resources='{"requests":{"cpu":"1","memory":"512Mi"},"limits":{"cpu":"2","memory":"1Gi"}}'
    else
        resources='{"requests":{"cpu":"2","memory":"1Gi"},"limits":{"cpu":"4","memory":"2Gi"}}'
    fi
    new_temp; job=$TEMP_FILE
    jq -n --arg name "$name" --arg run "$run" --arg role "$role" --arg image "$K6_IMAGE" \
        --arg namespace "$LOAD_NAMESPACE" --argjson resources "$resources" '{
      apiVersion:"batch/v1",kind:"Job",
      metadata:{name:$name,namespace:$namespace,labels:{"gateway.dev/run":$run,"gateway.dev/load-role":$role}},
      spec:{backoffLimit:0,ttlSecondsAfterFinished:3600,template:{
        metadata:{labels:{"gateway.dev/run":$run,"gateway.dev/load-role":$role}},
        spec:{restartPolicy:"Never",automountServiceAccountToken:false,enableServiceLinks:false,
          securityContext:{runAsNonRoot:true,runAsUser:12345,runAsGroup:12345,seccompProfile:{type:"RuntimeDefault"}},
          containers:[{name:"k6",image:$image,
            args:["run","--quiet","--no-color","--address","0.0.0.0:6565","--log-format","raw",
                  "--out","experimental-prometheus-rw","/scripts/chat.js"],
            env:[{name:"K6_PROMETHEUS_RW_SERVER_URL",value:"http://monitoring-prometheus.monitoring.svc:9090/api/v1/write"},
                 {name:"K6_FEATURES",value:"native-histograms"},
                 {name:"K6_PROMETHEUS_RW_PUSH_INTERVAL",value:"1s"},
                 {name:"K6_PROMETHEUS_RW_STALE_MARKERS",value:"true"},
                 {name:"K6_NO_USAGE_REPORT",value:"true"}],
            resources:$resources,
            securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}},
            volumeMounts:[{name:"scripts",mountPath:"/scripts",readOnly:true},
                          {name:"plan",mountPath:"/etc/k6/plan",readOnly:true},
                          {name:"keys",mountPath:"/etc/k6/keys",readOnly:true},
                          {name:"tmp",mountPath:"/tmp"}]}],
          volumes:[{name:"scripts",configMap:{name:"k6-scripts"}},
                   {name:"plan",configMap:{name:($name + "-plan")}},
                   {name:"keys",secret:{secretName:($name + "-keys")}},
                   {name:"tmp",emptyDir:{}}]}}}}' >"$job"
    kube_apply -f "$job" >/dev/null
}

load_state() {
    kube -n "$LOAD_NAMESPACE" get job "$(load_job_name "$1" "$2")" -o json |
        jq -r 'if (.status.succeeded // 0) > 0 then "succeeded" elif (.status.failed // 0) > 0 then "failed" else "running" end'
}

# load_first_record <run-id> <role>: waits until the Job has sent and recorded its first probe.
load_first_record() {
    local name attempt
    name=$(load_job_name "$1" "$2")
    for ((attempt=0; attempt<180; attempt++)); do
        if kube -n "$LOAD_NAMESPACE" logs "job/$name" 2>/dev/null | grep -q '^PROBE '; then return; fi
        [[ "$(load_state "$1" "$2")" != failed ]] || die "Load Job $name failed before its first probe."
        sleep 1
    done
    die "Load Job $name recorded no probe within 180 seconds."
}

# Asks k6 to stop through its control API, reached from the Kind node at the pod's address.
load_stop() {
    local name ip
    name=$(load_job_name "$1" "$2")
    ip=$(kube -n "$LOAD_NAMESPACE" get pods -l "job-name=$name" -o jsonpath='{.items[0].status.podIP}')
    [[ "$ip" =~ ^[0-9.]+$ ]] || return 0
    node_exec curl --disable --silent --show-error --max-time 10 -X PATCH \
        -H 'Content-Type: application/json' \
        --data '{"data":{"type":"status","id":"default","attributes":{"stopped":true}}}' \
        "http://$ip:6565/v1/status" >/dev/null || warn "k6 in $name did not accept the stop request."
}

# load_wait <run-id> <role> <timeout seconds>
load_wait() {
    local attempt state
    for ((attempt=0; attempt<$3; attempt++)); do
        state=$(load_state "$1" "$2")
        [[ "$state" == running ]] || return 0
        sleep 1
    done
    die "Load Job $(load_job_name "$1" "$2") did not finish within $3 seconds."
}

# load_finish <run-id> <role> <output directory>: stops the Job if it still runs, saves its
# summary and per-request records, and deletes its Job, plan, and keys.
load_finish() {
    local run=$1 role=$2 out=$3 name log entry kept=()
    name=$(load_job_name "$run" "$role")
    if [[ "$(load_state "$run" "$role")" == running ]]; then load_stop "$run" "$role"; fi
    load_wait "$run" "$role" 180
    mkdir -p -- "$out"
    new_temp; log=$TEMP_FILE
    kube -n "$LOAD_NAMESPACE" logs "job/$name" >"$log" || die "Cannot read the logs of $name."
    grep '^PROBE ' "$log" | cut -c7- >"$out/probes-$role.jsonl" || true
    grep '^K6_SUMMARY ' "$log" | tail -1 | cut -c12- >"$out/k6-summary-$role.json" || true
    grep -v -E '^(PROBE|K6_SUMMARY) ' "$log" | tail -50 >"$out/k6-$role.log" || true
    [[ -s "$out/k6-summary-$role.json" ]] || { cat "$out/k6-$role.log" >&2; die "$name produced no summary."; }
    [[ "$(load_state "$run" "$role")" == succeeded ]] ||
        warn "$name did not finish successfully; its summary is kept for inspection."
    kube -n "$LOAD_NAMESPACE" delete job "$name" --ignore-not-found --wait=false >/dev/null
    kube -n "$LOAD_NAMESPACE" delete configmap "$name-plan" --ignore-not-found >/dev/null
    kube -n "$LOAD_NAMESPACE" delete secret "$name-keys" --ignore-not-found >/dev/null
    for entry in "${LOAD_PENDING[@]+"${LOAD_PENDING[@]}"}"; do
        [[ "$entry" == "$run:$role" ]] || kept+=("$entry")
    done
    LOAD_PENDING=("${kept[@]+"${kept[@]}"}")
    printf '%s\n' "$out/k6-summary-$role.json"
}

# run_load <run-id> <role> <plan-file> <output directory>
run_load() {
    local seconds
    load_start "$1" "$2" "$3"
    seconds=$(jq '[.streams[] | ((.start_delay // "0s") | rtrimstr("s") | tonumber) +
      (.duration | if endswith("m") then (rtrimstr("m") | tonumber * 60) else (rtrimstr("s") | tonumber) end)] | max + 300' "$3")
    load_wait "$1" "$2" "$seconds"
    load_finish "$1" "$2" "$4"
}
