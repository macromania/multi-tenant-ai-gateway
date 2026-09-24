#!/bin/bash
# The ten deliberate failure modes. Sourced by scripts/experiments.sh after its own functions.
#
# Every failure follows the same steps: the entry check, a recovery journal, probes for the working
# set, 30 seconds of baseline, the trigger, 120 seconds of observation, restore (unless KEEP=1),
# recovery to a healthy streak, and a run record. Each failure also proves that it really happened
# (its invocation check); a run whose check fails is invalid rather than "no impact".

FAILURES="proxy-crash bad-tenant-config duplicate-key flood slow-upstream proxy-memory controller-outage credential-rotation wrong-credential forged-tenant-header"
CAUSE=tenant-01
INVOCATION='{"ok":false,"evidence":"not checked"}'
FAILURE_NOTES='{}'
EXTRA_STREAMS='[]'
ATTACK_PROFILE=
HALVES=

note() { FAILURE_NOTES=$(jq -c --arg key "$1" --argjson value "$2" '. + {($key): $value}' <<<"$FAILURE_NOTES"); }
invocation() { INVOCATION=$(jq -nc --argjson ok "$1" --arg evidence "$2" '{ok:$ok, evidence:$evidence}'); }
cause_namespace() { tenant_namespace "$CAUSE"; }

# The controller serving a tenant: the one shared controller, or the tenant's own.
controller_deployment() {
    if [[ "$CLUSTER" == shared ]]; then printf 'agentgateway'; else printf 'agw-%s-agentgateway' "$1"; fi
}

proxy_container_state() {
    kube -n "$1" get pods -l "gateway.networking.k8s.io/gateway-name=$GATEWAY" -o json | jq -c '
      [.items[] | select(.metadata.deletionTimestamp == null)] | first |
      {pod: .metadata.name, uid: .metadata.uid, restarts: (.status.containerStatuses[0].restartCount // 0),
       started_at: (.status.containerStatuses[0].state.running.startedAt // null),
       last: (.status.containerStatuses[0].lastState.terminated // null)}'
}

# The kubelet delays each restart of a container that restarted recently (10 s, 20 s, 40 s, and so
# on) and resets that back-off after the container has run for 10 minutes. A crash is measured only
# from a proxy that has run that long, so both designs see a first-crash restart.
wait_for_restart_backoff_reset() {
    local namespace=$1 state age wait
    state=$(proxy_container_state "$namespace")
    note restart_history "$state"
    [[ "$(jq '.restarts' <<<"$state")" -gt 0 ]] || return 0
    age=$(jq -r '(now - (.started_at | fromdateiso8601)) | floor' <<<"$state")
    if [[ "$age" -lt 600 ]]; then
        wait=$((600 - age + 5))
        info "The proxy in $namespace restarted $age seconds ago; waiting $wait seconds for the kubelet's restart back-off to reset."
        sleep "$wait"
    fi
}

raise_cause_limit() {
    journal_update '.notes.raised_limit = true'
    set_limit_quiet "$CAUSE" "$RAISED_LIMIT"
    render_limits "$CAUSE"
    wait_enforced "$RAISED_LIMIT" "$CAUSE"
}

attack_stream() {
    stream_json "attack-$1" "$CAUSE" "$1" gateway "${OBSERVE_SECONDS}s" '{"role":"attack"}'
}

# ---------------------------------------------------------------------------------------------
# Triggers and invocation checks, one pair per failure.
# ---------------------------------------------------------------------------------------------
prepare_proxy-crash() {
    wait_for_restart_backoff_reset "$(cause_namespace)"
    note before "$(proxy_container_state "$(cause_namespace)")"
}
# Kills the proxy process with SIGKILL from the Kind node, then reads the killed container's exit
# code from the container runtime before the kubelet replaces it (Kubernetes does not always keep it).
trigger_proxy-crash() {
    local id pid attempt exited
    id=$(proxy_container_id "$(cause_namespace)")
    pid=$(proxy_pid "$(cause_namespace)")
    node_exec kill -KILL "$pid"
    for ((attempt=0; attempt<40; attempt++)); do
        exited=$(node_exec crictl inspect "$id" 2>/dev/null | jq -c 'select(.status.state == "CONTAINER_EXITED") |
          {exit_code: .status.exitCode, reason: .status.reason, finished_at: .status.finishedAt}' || true)
        [[ -z "$exited" ]] || break
        sleep 0.25
    done
    note killed_container "${exited:-null}"
}
check_proxy-crash() {
    local after before deadline
    before=$(jq -c '.before' <<<"$FAILURE_NOTES")
    deadline=$(( $(date +%s) + 90 ))
    while :; do
        after=$(proxy_container_state "$(cause_namespace)")
        if jq -e --argjson before "$before" --argjson killed "$(jq -c '.killed_container' <<<"$FAILURE_NOTES")" \
            --argjson trigger "$TRIGGER_START" '
            .uid == $before.uid and .restarts == $before.restarts + 1 and $killed.exit_code == 137 and
            ((.started_at | fromdateiso8601) * 1000 >= $trigger - 2000)' <<<"$after" >/dev/null; then
            invocation true "the killed container exited with code 137; the same pod restarted it (restartCount $(jq '.restarts' <<<"$after"))"
            return
        fi
        [[ "$(date +%s)" -lt "$deadline" ]] || break
        sleep 1
    done
    invocation false "restartCount $(jq '.restarts' <<<"$after"), killed container $(jq -c '.killed_container' <<<"$FAILURE_NOTES")"
}

# The limit policy holding the cause tenant's entry: the shared tenant-limits, or the tenant's own.
limits_policy_json() { kube -n "$(cause_namespace)" get agentgatewaypolicy tenant-limits -o json; }
trigger_bad-tenant-config() {
    local file
    new_temp; file=$TEMP_FILE
    limits_policy_json | jq --arg condition "apiKey.tenant == \"$CAUSE\"" '
      {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels},
       spec: (.spec | .traffic.rateLimit.conditional |= map(if .condition == $condition then .condition = "apiKey.tenant ==" else . end))}' >"$file"
    kube_apply -f "$file" >/dev/null
}
check_bad-tenant-config() {
    local policy status tenant limits=()
    sleep 10
    policy=$(limits_policy_json)
    status=$(jq -c '[.status.ancestors[]?.conditions[]? | {type, status, reason, message: (.message // "" | .[0:200])}]' <<<"$policy")
    for tenant in $WORKING_SET; do
        limits+=("$(jq -nc --arg tenant "$tenant" --arg limit "$( (enforced_limit "$tenant") 2>/dev/null || true)" '{tenant:$tenant, enforced:$limit}')")
    done
    note policy_status "$status"
    note enforced_limits "$(printf '%s\n' "${limits[@]}" | jq -sc '.')"
    if jq -e '[.spec.traffic.rateLimit.conditional[].condition] | index("apiKey.tenant ==")' <<<"$policy" >/dev/null; then
        invocation true "the applied policy holds the invalid expression; status $(jq -r 'map("\(.type)=\(.status)") | join(",")' <<<"$status")"
    else
        invocation false "the invalid expression is not in the applied policy"
    fi
}

duplicate_target() { printf '%s' tenant-02; }
trigger_duplicate-key() {
    local target file hash
    target=$(duplicate_target)
    hash=$(key_hash "$CAUSE")
    new_temp; file=$TEMP_FILE
    kube -n "$(tenant_namespace "$target")" get configmap "$(key_configmap "$target")" -o json |
        jq --arg target "$target" --arg hash "$hash" '
          {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace,
            labels: .metadata.labels, annotations: .metadata.annotations},
           data: {($target): ({keyHash: $hash, metadata: {tenant: $target}} | tojson)}}' >"$file"
    kube_apply -f "$file" >/dev/null
}
check_duplicate-key() {
    local target hash stored
    target=$(duplicate_target)
    hash=$(key_hash "$CAUSE")
    stored=$(kube -n "$(tenant_namespace "$target")" get configmap "$(key_configmap "$target")" -o json |
        jq -r --arg target "$target" '.data[$target] | fromjson | .keyHash')
    if [[ "$stored" == "$hash" ]]; then
        invocation true "$target's key entry holds $CAUSE's key hash"
    else
        invocation false "$target's key entry does not hold $CAUSE's key hash"
    fi
}
extra_streams_duplicate-key() {
    # In the dedicated cluster, tenant-01's key is also sent to tenant-02's gateway, where the
    # duplicated entry now accepts it.
    if [[ "$CLUSTER" == dedicated ]]; then
        jq -nc --argjson stream "$(stream_json cross-tenant-01-at-tenant-02 "$CAUSE" probe gateway 600s '{"role":"extra","records":true,"timeout":"10s"}')" \
            '[$stream | .url = "http://agentgateway-proxy.tenant-02.svc/mock/v1/chat/completions" | .gateway = "tenant-02/agentgateway-proxy"]'
    else
        printf '[]'
    fi
}

prepare_flood() { if [[ "${RAISE_LIMIT:-}" == 1 ]]; then raise_cause_limit; fi; ATTACK_PROFILE=flood; }
trigger_flood() { :; }
check_flood() {
    local a rate
    a=$(jq -c '.streams | to_entries[0].value' "$RUN_DIR/k6-summary-attack.json")
    rate=$(profile_json flood | jq '.rate')
    if [[ "${RAISE_LIMIT:-}" == 1 ]]; then
        if jq -e --argjson target "$(( rate * OBSERVE_SECONDS ))" '.verdicts.verified >= 0.8 * $target' <<<"$a" >/dev/null; then
            invocation true "$(jq -r '"\(.verdicts.verified) of \(.requests) flood requests reached the mock"' <<<"$a")"
        else
            invocation false "$(jq -r '"only \(.verdicts.verified) flood requests reached the mock"' <<<"$a")"
        fi
    elif jq -e --argjson target "$(( rate * OBSERVE_SECONDS ))" '.requests >= 0.8 * $target and .verdicts.blocked > 0' <<<"$a" >/dev/null; then
        invocation true "$(jq -r '"\(.requests) flood requests sent, \(.verdicts.blocked) refused with 429 at the tenant limit"' <<<"$a")"
    else
        invocation false "$(jq -r '"\(.requests) flood requests sent, \(.verdicts.blocked) refused"' <<<"$a")"
    fi
}

prepare_slow-upstream() { raise_cause_limit; ATTACK_PROFILE=slow; }
trigger_slow-upstream() { :; }
check_slow-upstream() {
    local peak
    peak=$(prom_instant "max_over_time(sum(mock_in_flight)[$(( OBSERVE_SECONDS + 30 ))s:5s])" "$(( RESTORE_START / 1000 ))" |
        jq '[.data.result[].value[1] | tonumber] | max // 0')
    note mock_in_flight_max "$peak"
    if awk -v p="$peak" 'BEGIN { exit !(p > 1000) }'; then
        invocation true "the mock held up to $peak requests in flight"
    else
        invocation false "the mock held at most $peak requests in flight"
    fi
}

prepare_proxy-memory() {
    wait_for_restart_backoff_reset "$(cause_namespace)"
    raise_cause_limit
    ATTACK_PROFILE=memory
    note before "$(proxy_container_state "$(cause_namespace)")"
}
trigger_proxy-memory() { :; }
check_proxy-memory() {
    local after before peak
    before=$(jq -c '.before' <<<"$FAILURE_NOTES")
    after=$(proxy_container_state "$(cause_namespace)")
    peak=$(prom_instant "max_over_time(max(container_memory_working_set_bytes{namespace=\"$(cause_namespace)\",pod=~\"$GATEWAY-.*\",container=\"agentgateway\"})[$(( OBSERVE_SECONDS + 30 ))s:5s])" \
        "$(( RESTORE_START / 1000 ))" | jq '[.data.result[].value[1] | tonumber] | max // 0')
    note proxy_max_sampled_working_set_bytes "$peak"
    if jq -e --argjson before "$before" --argjson trigger "$TRIGGER_START" '
        .restarts > $before.restarts and .last.reason == "OOMKilled" and
        ((.last.finishedAt | fromdateiso8601) * 1000 >= $trigger - 2000)' <<<"$after" >/dev/null; then
        invocation true "the proxy was OOM-killed at $(jq -r '.last.finishedAt' <<<"$after"); maximum sampled working set $((peak / 1048576)) MiB"
    else
        note not_reproduced true
        invocation true "no OOM at these parameters; maximum sampled working set $((peak / 1048576)) MiB (5-second samples)"
    fi
}

prepare_controller-outage() { note controller "\"$(controller_deployment "$CAUSE")\""; }
trigger_controller-outage() {
    local deadline
    kube -n "$(cause_namespace)" scale deployment "$(controller_deployment "$CAUSE")" --replicas=0 >/dev/null
    deadline=$(( $(date +%s) + 120 ))
    until [[ "$(kube -n "$(cause_namespace)" get deployment "$(controller_deployment "$CAUSE")" -o jsonpath='{.status.readyReplicas}')" == "" ]]; do
        [[ "$(date +%s)" -lt "$deadline" ]] || die "The controller did not stop."
        sleep 1
    done
    note controller_ready_replicas_during 0
    sleep 20
    # Change two tenants' limits while the controller is stopped and see which changes reach a proxy.
    local tenant limit changes=()
    for tenant in tenant-01 tenant-02; do
        limit=$(( $(jq -r --arg t "$tenant" '.tenants[] | select(.tenant == $t) | .limit' "$(journal_file)") + 1000 ))
        set_limit_quiet "$tenant" "$limit"
        RENDER_WAIT=0 render_limits "$tenant"
        changes+=("$(jq -nc --arg tenant "$tenant" --argjson limit "$limit" '{tenant:$tenant, requested:$limit}')")
    done
    note requested_changes "$(printf '%s\n' "${changes[@]}" | jq -sc '.')"
    CHANGED_AT=$(node_now_ms)
}
check_controller-outage() {
    local ready tenant results=() requested enforced
    ready=$(kube -n "$(cause_namespace)" get deployment "$(controller_deployment "$CAUSE")" -o jsonpath='{.status.readyReplicas}')
    sleep 30
    for tenant in tenant-01 tenant-02; do
        requested=$(jq -r --arg t "$tenant" '.requested_changes[] | select(.tenant == $t) | .requested' <<<"$FAILURE_NOTES")
        enforced=$( (enforced_limit "$tenant") 2>/dev/null || true)
        results+=("$(jq -nc --arg tenant "$tenant" --argjson requested "$requested" --arg enforced "$enforced" \
            '{tenant:$tenant, requested:$requested, enforced_after_30s:($enforced | tonumber? // null), applied:(($enforced | tonumber? // 0) == $requested)}')")
    done
    note changes_during_outage "$(printf '%s\n' "${results[@]}" | jq -sc '.')"
    if [[ -z "$ready" ]]; then
        invocation true "the controller had zero ready replicas; changes applied during the outage: $(printf '%s\n' "${results[@]}" | jq -sr 'map("\(.tenant)=\(.applied)") | join(", ")')"
    else
        invocation false "the controller still had $ready ready replicas"
    fi
}
restore_controller-outage() {
    local tenant requested
    kube -n "$(cause_namespace)" scale deployment "$(controller_deployment "$CAUSE")" --replicas=1 >/dev/null
    kube -n "$(cause_namespace)" rollout status deployment "$(controller_deployment "$CAUSE")" --timeout=300s >/dev/null
    for tenant in tenant-01 tenant-02; do
        requested=$(jq -r --arg t "$tenant" '.requested_changes[] | select(.tenant == $t) | .requested' <<<"$FAILURE_NOTES")
        wait_enforced "$requested" "$tenant"
    done
    note pending_changes_applied_after_restart true
}

# Sends a request with the given key (on standard input) to every mock replica directly and prints
# each replica's HTTP status.
MOCK_TRY_KEY='import sys, urllib.request, urllib.error
key = sys.stdin.read().strip()
request = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=b"{\"messages\":[]}", method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(request, timeout=10).status)
except urllib.error.HTTPError as error:
    print(error.code)'
mock_statuses_for_key() {
    local pod pods statuses=()
    pods=$(kube -n "$MOCK_NAMESPACE" get pods -l app.kubernetes.io/name=mock --field-selector=status.phase=Running -o name)
    for pod in $pods; do
        statuses+=("$(kube -n "$MOCK_NAMESPACE" exec -i "$pod" -- python -c "$MOCK_TRY_KEY" <"$1" | tr -d '\r\n')")
    done
    printf '%s\n' "${statuses[@]}" | jq -R . | jq -sc '.'
}
trigger_credential-rotation() {
    local old new additions
    load_tenant_env
    new_temp; old=$TEMP_FILE
    tenant_key "$CAUSE" MOCK >"$old"
    journal_update --rawfile old "$old" '.notes.old_mock_key = ($old | rtrimstr("\n")) | .notes.rotation = "forward"'
    new_temp; additions=$TEMP_FILE
    openssl rand -hex 32 | tr -d '\n' | jq -R --arg key "$(tenant_key_name "$CAUSE" MOCK)" '{($key): .}' >"$additions"
    save_env_file "$TENANT_ENV" "$additions"
    TENANT_JSON=
    load_tenant_env
    journal_stage rotation-new-key-saved
    mock_push_keys
    journal_stage rotation-mock-updated
    ROTATION_MOCK_AT=$(node_now_ms)
    apply_tenant_objects "$CAUSE" "$(cause_namespace)" "$(stored_limit "$CAUSE")" "$(key_configmap "$CAUSE")" \
        "$( [[ "$CLUSTER" == shared ]] && printf 'mock-provider-%s' "$CAUSE" || printf 'mock-provider')" \
        "$( [[ "$CLUSTER" == shared ]] && printf 'mock-%s' "$CAUSE" || printf 'mock')" active
    journal_stage rotation-gateway-updated
    ROTATION_GATEWAY_AT=$(node_now_ms)
    note rotation_steps "$(jq -nc --argjson mock "$ROTATION_MOCK_AT" --argjson gateway "$ROTATION_GATEWAY_AT" --argjson trigger "$TRIGGER_START" \
        '{mock_rejects_old_key_after_ms: ($mock - $trigger), gateway_copy_updated_after_ms: ($gateway - $trigger)}')"
}
check_credential-rotation() {
    local old new old_statuses new_statuses
    new_temp; old=$TEMP_FILE
    jq -r '.notes.old_mock_key' "$(journal_file)" >"$old"
    new_temp; new=$TEMP_FILE
    tenant_key "$CAUSE" MOCK >"$new"
    old_statuses=$(mock_statuses_for_key "$old")
    new_statuses=$(mock_statuses_for_key "$new")
    note mock_replica_statuses "$(jq -nc --argjson old "$old_statuses" --argjson new "$new_statuses" '{old_key:$old, new_key:$new}')"
    if jq -e --argjson new "$new_statuses" 'all(. == "401") and ($new | all(. == "200"))' <<<"$old_statuses" >/dev/null; then
        invocation true "every mock replica refuses the old key and accepts the new one"
    else
        invocation false "mock replicas answered the old key with $old_statuses and the new key with $new_statuses"
    fi
}

wrong_target() { printf '%s' tenant-02; }
target_backend() { if [[ "$CLUSTER" == shared ]]; then printf 'mock-%s' "$1"; else printf 'mock'; fi; }
target_secret() { if [[ "$CLUSTER" == shared ]]; then printf 'mock-provider-%s' "$1"; else printf 'mock-provider'; fi; }
trigger_wrong-credential() {
    local target file
    target=$(wrong_target)
    HALVES=true
    new_temp; file=$TEMP_FILE
    kube -n "$(tenant_namespace "$target")" get agentgatewaybackend "$(target_backend "$target")" -o json |
        jq --arg secret "mock-provider-$CAUSE" '{apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace,
          labels: .metadata.labels}, spec: (.spec | .policies.auth.secretRef.name = $secret)}' >"$file"
    kube_apply -f "$file" >/dev/null
    sleep 5
    note reference_mistake "$(kube -n "$(tenant_namespace "$target")" get agentgatewaybackend "$(target_backend "$target")" -o json |
        jq -c '{secretRef: .spec.policies.auth.secretRef.name, status: [.status.conditions[]? | {type, status, reason, message: (.message // "" | .[0:200])}]}')"
    sleep $(( OBSERVE_SECONDS / 2 - 5 ))
    HALF_AT=$(node_now_ms)
    # Second half: the reference is correct again, but the target's own provider Secret now holds the
    # cause tenant's key. A namespace does not protect against a wrong value.
    apply_tenant_objects "$target" "$(tenant_namespace "$target")" "$(stored_limit "$target")" "$(key_configmap "$target")" \
        "$(target_secret "$target")" "$(target_backend "$target")" active
    new_temp; file=$TEMP_FILE
    tenant_key "$CAUSE" MOCK | jq -Rs --arg name "$(target_secret "$target")" --arg namespace "$(tenant_namespace "$target")" \
        --arg tenant "$target" '{apiVersion:"v1",kind:"Secret",type:"Opaque",
        metadata:{name:$name,namespace:$namespace,labels:{"gateway.dev/tenant":$tenant}},stringData:{Authorization:.}}' >"$file"
    kube_apply -f "$file" >/dev/null
}
check_wrong-credential() {
    local target stored wanted
    target=$(wrong_target)
    stored=$(kube -n "$(tenant_namespace "$target")" get secret "$(target_secret "$target")" -o jsonpath='{.data.Authorization}' |
        base64 -d | openssl dgst -sha256 -r | awk '{print $1}')
    wanted=$(tenant_key "$CAUSE" MOCK | openssl dgst -sha256 -r | awk '{print $1}')
    if [[ "$(jq -r '.reference_mistake.secretRef' <<<"$FAILURE_NOTES")" == "mock-provider-$CAUSE" && "$stored" == "$wanted" ]]; then
        invocation true "first half: $target's backend referenced mock-provider-$CAUSE; second half: $target's Secret held $CAUSE's key (compared by hash)"
    else
        invocation false "the reference or the Secret value did not hold the mistake"
    fi
}

extra_streams_forged-tenant-header() {
    local streams=()
    streams+=("$(stream_json forged-tenant-01 "$CAUSE" probe gateway 600s '{"role":"extra","records":true,"timeout":"10s","forged_tenant":"tenant-02"}')")
    if [[ "$CLUSTER" == dedicated ]]; then
        streams+=("$(stream_json forged-tenant-01-at-tenant-02 "$CAUSE" probe gateway 600s '{"role":"extra","records":true,"timeout":"10s","forged_tenant":"tenant-02"}' |
            jq -c '.url = "http://agentgateway-proxy.tenant-02.svc/mock/v1/chat/completions" | .gateway = "tenant-02/agentgateway-proxy"')")
    fi
    printf '%s\n' "${streams[@]}" | jq -sc '.'
}
trigger_forged-tenant-header() {
    HALVES=true
    sleep $(( OBSERVE_SECONDS / 2 ))
    HALF_AT=$(node_now_ms)
    if [[ "$CLUSTER" == shared ]]; then
        # A platform mistake: trust a client-supplied x-tenant header when one is present.
        local file
        new_temp; file=$TEMP_FILE
        kube -n "$NAMESPACE" get agentgatewaypolicy tenant-routing -o json | jq '{apiVersion, kind,
          metadata: {name: .metadata.name, namespace: .metadata.namespace},
          spec: (.spec | .traffic.transformation.request.set = [{name: "x-tenant",
            value: "\"x-tenant\" in request.headers ? request.headers[\"x-tenant\"] : apiKey.tenant"}])}' >"$file"
        kube_apply -f "$file" >/dev/null
    fi
}
check_forged-tenant-header() {
    local sent value
    sent=$(current_records | jq '[.[] | select(.stream | startswith("forged-")) | select(.sent_tenant_header == "tenant-02")] | length')
    if [[ "$CLUSTER" == shared ]]; then
        value=$(kube -n "$NAMESPACE" get agentgatewaypolicy tenant-routing -o jsonpath='{.spec.traffic.transformation.request.set[0].value}')
        note mistaken_routing_value "$(jq -Rn --arg v "$value" '$v')"
        if [[ "$sent" -gt 0 && "$value" == *'in request.headers'* ]]; then
            invocation true "$sent forged requests sent; in the second half the routing policy trusted the client header"
        else
            invocation false "forged requests $sent; routing value $value"
        fi
    elif [[ "$sent" -gt 0 ]]; then
        invocation true "$sent forged requests sent to tenant-01's own gateway and to tenant-02's gateway"
    else
        invocation false "no forged request was recorded"
    fi
}

# ---------------------------------------------------------------------------------------------
# The common runner.
# ---------------------------------------------------------------------------------------------
fn_exists() { declare -F "$1" >/dev/null; }

# The component a failure acts on, and how many tenants that component serves in this design.
failure_target() {
    local count serves component
    count=$(tenant_list | grep -c . || true)
    if [[ "$CLUSTER" == shared ]]; then serves=$count; else serves=1; fi
    case "$1" in
        controller-outage) component="controller $(cause_namespace)/$(controller_deployment "$CAUSE")" ;;
        bad-tenant-config) component="token limit policy $(cause_namespace)/tenant-limits" ;;
        duplicate-key) component="key authentication in $(tenant_namespace "$(duplicate_target)")/tenant-auth" ;;
        credential-rotation) component="$CAUSE's provider key, at the mock and in $(cause_namespace)"; serves=1 ;;
        wrong-credential) component="backend $(tenant_namespace "$(wrong_target)")/$(target_backend "$(wrong_target)")"; serves=1 ;;
        forged-tenant-header) component="tenant routing in proxy $(cause_namespace)/$GATEWAY" ;;
        *) component="proxy $(cause_namespace)/$GATEWAY" ;;
    esac
    jq -nc --arg component "$component" --argjson serves "$serves" '{component:$component, serves:$serves}'
}

# Waits until every working-set probe stream shows 25 consecutive verified requests after the given
# time, or the recovery timeout passes.
wait_healthy_after() {
    local after=$1 deadline healthy
    deadline=$(( $(node_now_ms) + RECOVERY_SECONDS * 1000 ))
    while :; do
        healthy=$(current_records | jq --argjson after "$after" --arg set "$WORKING_SET" '
          ($set | split(" ")) as $tenants |
          [$tenants[] as $t | [.[] | select(.stream == ("probe-" + $t) and .start_ms > $after and .verdict != "censored")] |
           (length >= 25 and (.[-25:] | all(.verdict == "verified")))] | all')
        [[ "$healthy" != true ]] || return 0
        [[ "$(node_now_ms)" -lt "$deadline" ]] || return 1
        sleep 2
    done
}

run_failure() {
    local failure=$1
    case " $FAILURES " in *" $failure "*) ;; *) die "FAILURE must be one of: $FAILURES." ;; esac
    entry_check
    begin_run failure "$failure"
    journal_start failure "$failure"
    on_exit restore_on_exit
    say_section "$(printf '%s' "$failure" | tr '[:lower:]-' '[:upper:] ') | $KIND_CLUSTER"
    FAILURE_NOTES='{}'
    ATTACK_PROFILE=
    HALVES=
    HALF_AT=
    HEALTHY_AT=
    TARGET=$(failure_target "$failure")
    say_row 'Target' "$(jq -r '"\(.component) (serves \(.serves) tenant\(if .serves == 1 then "" else "s" end))"' <<<"$TARGET")"
    if fn_exists "prepare_$failure"; then "prepare_$failure"; fi
    local extra plan attack_plan probe_start end recovered=true
    extra='[]'
    if fn_exists "extra_streams_$failure"; then extra=$("extra_streams_$failure"); fi
    new_temp; plan=$TEMP_FILE
    jq -n --argjson probes "$(probe_streams 600s)" --argjson extra "$extra" '{streams: ($probes + $extra)}' >"$plan"
    load_start "$RUN_ID" probe "$plan"
    load_first_record "$RUN_ID" probe
    probe_start=$(node_now_ms)
    info "Baseline for $BASELINE_SECONDS seconds."
    sleep "$BASELINE_SECONDS"
    prom_open
    TRIGGER_START=$(node_now_ms)
    journal_stage triggered
    if [[ -n "$ATTACK_PROFILE" ]]; then
        new_temp; attack_plan=$TEMP_FILE
        jq -n --argjson attack "$(attack_stream "$ATTACK_PROFILE")" '{streams:[$attack]}' >"$attack_plan"
        load_start "$RUN_ID-a" attack "$attack_plan"
    fi
    "trigger_$failure"
    TRIGGER_END=$(node_now_ms)
    info "Triggered $failure; observing until $OBSERVE_SECONDS seconds after the trigger."
    while [[ "$(node_now_ms)" -lt $(( TRIGGER_START + OBSERVE_SECONDS * 1000 )) ]]; do sleep 1; done
    if [[ -n "$ATTACK_PROFILE" ]]; then
        load_wait "$RUN_ID-a" attack 240
        load_finish "$RUN_ID-a" attack "$RUN_DIR" >/dev/null
    fi
    RESTORE_START=$(node_now_ms)
    "check_$failure"
    if [[ "${KEEP:-}" == 1 ]]; then
        warn 'KEEP=1: the failure is left in place; run make restore when done.'
        RESTORE_END=
    else
        journal_stage restoring
        if fn_exists "restore_$failure"; then "restore_$failure"; fi
        restore_cluster
        RESTORE_END=$(node_now_ms)
        if wait_healthy_after "$RESTORE_END"; then HEALTHY_AT=$(node_now_ms); else recovered=false; fi
        sleep 5
    fi
    end=$(node_now_ms)
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    # Resource figures for the run window. Each query result is assigned first (see prom_instant).
    local window resources gateway_cpu gateway_memory gateway_throttled
    window=$(( (end - probe_start) / 1000 + 10 ))
    gateway_cpu=$(prom_instant "max by (namespace, pod) (max_over_time(rate(container_cpu_usage_seconds_total{namespace=~\"agentgateway-system|tenant-[0-9]+\",container!=\"\",container!=\"POD\"}[1m])[${window}s:15s]))" "$(( end / 1000 ))")
    gateway_memory=$(prom_instant "max by (namespace, pod) (max_over_time(container_memory_working_set_bytes{namespace=~\"agentgateway-system|tenant-[0-9]+\",container!=\"\",container!=\"POD\"}[${window}s]))" "$(( end / 1000 ))")
    gateway_throttled=$(prom_instant "max by (namespace, pod) (max_over_time((rate(container_cpu_cfs_throttled_periods_total{namespace=~\"agentgateway-system|tenant-[0-9]+\",container!=\"\"}[1m]) / rate(container_cpu_cfs_periods_total{namespace=~\"agentgateway-system|tenant-[0-9]+\",container!=\"\"}[1m]))[${window}s:15s]))" "$(( end / 1000 ))")
    resources=$(jq -n --argjson cpu "$gateway_cpu" --argjson memory "$gateway_memory" --argjson throttled "$gateway_throttled" '
      # f is a filter applied to each sample; Prometheus reports 0/0 ratios as "NaN", which are skipped.
      def rows($r; f): [$r.data.result[] | select(.value[1] != "NaN") | {namespace: .metric.namespace, pod: .metric.pod, value: (.value[1] | tonumber | f)}];
      {max_cpu_cores: rows($cpu; . * 1000 | round / 1000), max_working_set_mib: rows($memory; . / 1048576 | round),
       max_throttled_ratio: rows($throttled; . * 1000 | round / 1000)}')
    # Validity inputs from Prometheus: the mock's CPU throttling over the observe window, and any k6
    # container killed for memory.
    local observe_s mock_throttled k6_oom
    observe_s=$(( (RESTORE_START - TRIGGER_START) / 1000 ))
    mock_throttled=$(prom_instant "max(sum by (pod) (increase(container_cpu_cfs_throttled_periods_total{namespace=\"$MOCK_NAMESPACE\",container=\"mock\"}[${observe_s}s])) / sum by (pod) (increase(container_cpu_cfs_periods_total{namespace=\"$MOCK_NAMESPACE\",container=\"mock\"}[${observe_s}s])))" \
        "$(( RESTORE_START / 1000 ))" | jq '[.data.result[].value[1] | tonumber] | max // 0')
    k6_oom=$(prom_instant "max(max_over_time(kube_pod_container_status_terminated_reason{namespace=\"$LOAD_NAMESPACE\",reason=\"OOMKilled\"}[${window}s]))" \
        "$(( end / 1000 ))" | jq '[.data.result[].value[1] | tonumber] | max // 0')
    prom_close
    cp -- "$PROM_LOG" "$RUN_DIR/prometheus.json"
    save_events "$probe_start" "$end"
    # Validity inputs specific to this run.
    local extra_reasons oom_pods
    oom_pods=$(kube get pods -n "$MOCK_NAMESPACE" -o json | jq --argjson trigger "$TRIGGER_START" '
      [.items[].status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled" and
        ((.lastState.terminated.finishedAt | fromdateiso8601) * 1000 >= $trigger))] | length')
    extra_reasons=$(jq -nc --argjson invocation "$INVOCATION" --argjson oom "$oom_pods" --arg recovered "$recovered" \
        --argjson throttled "$mock_throttled" --argjson k6_oom "$k6_oom" '[
      (if $invocation.ok then empty else "the invocation check failed: " + $invocation.evidence end),
      (if $oom > 0 then "a mock replica was OOM-killed" else empty end),
      (if $k6_oom > 0 then "a k6 container was OOM-killed" else empty end),
      (if $throttled > 0.1 then "the mock was CPU-throttled in \($throttled * 100 | floor) percent of the observe window" else empty end),
      (if $recovered == "false" then "tenants did not recover within the recovery timeout" else empty end)]')
    printf '%s' "$extra_reasons" >"$RUN_DIR/validity-extra.json"
    local attack_rate=0 raised=false validity marks impact fields
    if [[ -n "$ATTACK_PROFILE" ]]; then attack_rate=$(profile_json "$ATTACK_PROFILE" | jq '.rate'); fi
    [[ "$(jq -r '.notes.raised_limit // false' "$(journal_file)")" != true ]] || raised=true
    validity=$(validity_json "$RUN_DIR" "$attack_rate" "$raised")
    marks=$(jq -nc --argjson probe "$probe_start" --argjson trigger "$TRIGGER_START" --argjson trigger_end "$TRIGGER_END" \
        --arg half "$HALF_AT" --argjson restore "$RESTORE_START" --arg restore_end "$RESTORE_END" --argjson end "$end" '{
      probe_start:$probe, trigger_start:$trigger, trigger_end:$trigger_end, half:($half | tonumber? // null),
      restore_start:$restore, restore_end:($restore_end | tonumber? // null), end:$end}')
    local cause_arg=null
    if [[ "$failure" == flood ]]; then cause_arg="\"$CAUSE\""; fi
    impact=$(jq -s -c --argjson m "$marks" --argjson cause "$cause_arg" "$IMPACT_JQ"' map(select(.stream | startswith("probe-"))) | impact($m; $cause)' \
        "$RUN_DIR/probes-probe.jsonl")
    # Extra streams (forged or cross-gateway requests) are expected to be refused; only their verdicts matter.
    local extras
    extras=$(jq -s -c '[.[] | select(.stream | startswith("probe-") | not)] | group_by(.stream) |
      map({stream: .[0].stream, requests: length, verdicts: (group_by(.verdict) | map({(.[0].verdict): length}) | add)})' \
        "$RUN_DIR/probes-probe.jsonl")
    local halves='null'
    if [[ -n "$HALVES" ]]; then
        halves=$(jq -s -c --argjson m "$marks" '
          [.[] | select(.verdict == "leak")] as $leaks |
          {first_half: {leaks: ([$leaks[] | select(.start_ms >= $m.trigger_start and .start_ms < $m.half)] | length),
                        by_stream: ([$leaks[] | select(.start_ms >= $m.trigger_start and .start_ms < $m.half) | .stream] | group_by(.) | map({(.[0]): length}) | add // {})},
           second_half: {leaks: ([$leaks[] | select(.start_ms >= $m.half and .start_ms < $m.restore_start)] | length),
                         by_stream: ([$leaks[] | select(.start_ms >= $m.half and .start_ms < $m.restore_start) | .stream] | group_by(.) | map({(.[0]): length}) | add // {})},
           during_restore: {leaks: ([$leaks[] | select(.start_ms >= $m.restore_start)] | length),
                            by_stream: ([$leaks[] | select(.start_ms >= $m.restore_start) | .stream] | group_by(.) | map({(.[0]): length}) | add // {})}}' \
            "$RUN_DIR/probes-probe.jsonl")
    fi
    local checks_passed=null
    if [[ "${KEEP:-}" != 1 ]]; then
        if [[ "$recovered" == true ]] && recovery_checks 60; then
            checks_passed=true
            rm -f -- "$(journal_file)"
        else
            checks_passed=false
            warn "The cluster did not fully recover; the journal is kept. Run make restore CLUSTER=$CLUSTER."
        fi
    fi
    new_temp; fields=$TEMP_FILE
    jq -n --arg run "$RUN_ID" --arg failure "$failure" --argjson marks "$marks" --argjson impact "$impact" \
        --argjson validity "$validity" --argjson invocation "$INVOCATION" --argjson notes "$FAILURE_NOTES" \
        --argjson resources "$resources" --argjson halves "$halves" --arg cause "$CAUSE" --arg keep "${KEEP:-}" \
        --argjson extras "$extras" --argjson target "$TARGET" --arg recovered "$recovered" --arg healthy "$HEALTHY_AT" \
        --argjson checks "$checks_passed" \
        --arg raise "${RAISE_LIMIT:-}" --arg profile "$ATTACK_PROFILE" \
        --argjson profile_json "$( [[ -n "$ATTACK_PROFILE" ]] && profile_json "$ATTACK_PROFILE" || printf 'null')" \
        --argjson replicas "$(kube -n "$MOCK_NAMESPACE" get deployment mock -o jsonpath='{.spec.replicas}')" \
        --argjson links "$(grafana_links "$probe_start" "$end")" --argjson set "$(printf '%s' "$WORKING_SET" | jq -R 'split(" ")')" '{
      kind:"failure", name:$failure, run_id:$run, clock:"kind-node", started_ms:$marks.probe_start, ended_ms:$marks.end,
      config:{failure:$failure, cause:$cause, working_set:$set, baseline_s:30, observe_s:120, probe_rate:5,
              attack_profile:$profile_json, raise_limit:($raise == "1"), keep:($keep == "1"), mock_replicas:$replicas, design:env.CLUSTER},
      target:$target,
      marks:$marks, invocation:$invocation, notes:$notes, impact:$impact, extra_streams:$extras, halves:$halves,
      leaks_total:(([$impact[].leaks] | add // 0) + ([$extras[].verdicts.leak // 0] | add // 0)),
      recovery:{restored:($keep != "1"), healthy:($keep != "1" and $recovered == "true"),
                restore_ms:(if $marks.restore_end == null then null else $marks.restore_end - $marks.restore_start end),
                healthy_after_restore_ms:($healthy | tonumber? // null | if . == null then null else . - $marks.restore_start end),
                recovery_checks_passed:$checks},
      validity:$validity, resources:$resources, grafana:$links}' >"$fields"
    finish_run "$fields"
    print_failure_summary
}

print_failure_summary() {
    local run=$RUN_DIR/run.json
    say_row 'Invocation check' "$(jq -r 'if .invocation.ok then "[OK] " else "[FAILED] " end + .invocation.evidence' "$run")"
    say_row 'Validity' "$(jq -r '.validity | if .valid then "valid" else "invalid: " + (.reasons | join("; ")) end + (if .confounded then " (confounded: other node averaged \(.other_node_cpu) CPU)" else "" end)' "$run")"
    jq -r '.impact[] | [.stream, (
        (if .any_impact then (if .material_impact then "affected (material)" else "affected" end) else "not affected" end) +
        ", \(.episodes | length) episodes, \(.failed_time_ms) ms failed" +
        (if (.statuses | length) > 0 then ", statuses " + (.statuses | to_entries | map("\(.key) x\(.value)") | join(" ")) else "" end) +
        (if .slow.count > 0 then ", \(.slow.count) slow (over \(.slow.threshold_ms) ms, max \(.slow.max_ms) ms)" else "" end) +
        (if .observe.expected_429 > 0 then ", \(.observe.expected_429) expected 429" else "" end) +
        (if .leaks > 0 then ", LEAKS \(.leaks)" else "" end) +
        (if .recovery_after_trigger_ms != null then ", healthy \(.recovery_after_trigger_ms) ms after the trigger" else "" end))] | @tsv' "$run" |
        while IFS=$'\t' read -r stream detail; do say_row "$stream" "$detail"; done
    jq -r '.extra_streams[] | [.stream, (.verdicts | to_entries | map("\(.key) \(.value)") | join(", "))] | @tsv' "$run" |
        while IFS=$'\t' read -r stream detail; do say_row "$stream" "$detail"; done
    if jq -e '.halves != null' "$run" >/dev/null; then
        say_row 'Leaks, first half' "$(jq -r '.halves.first_half | "\(.leaks) \(.by_stream)"' "$run")"
        say_row 'Leaks, second half' "$(jq -r '.halves.second_half | "\(.leaks) \(.by_stream)"' "$run")"
        say_row 'Leaks, during restore' "$(jq -r '.halves.during_restore | "\(.leaks) \(.by_stream)"' "$run")"
    fi
    say_row 'Leaks' "$(jq -r '.leaks_total' "$run")"
    say_row 'Recovery' "$(jq -r --arg cluster "$CLUSTER" '.recovery |
      if .restored | not then "not restored (KEEP=1); run make restore CLUSTER=\($cluster)"
      elif .healthy and .recovery_checks_passed then "[OK] restore took \(.restore_ms) ms; health confirmed \(.healthy_after_restore_ms) ms after it began (25 verified probes per tenant once it finished)"
      else "[FAILED] the tenants were not healthy after the restore; the journal is kept" end' "$run")"
    say_row 'Run record' "${RUN_DIR#$ROOT/}"
    say_row 'Grafana' "$(jq -r '.grafana.tenants' "$run")"
}
