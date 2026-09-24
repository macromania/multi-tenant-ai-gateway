#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
source "$ROOT/scripts/load.sh"
source "$ROOT/scripts/record.sh"

DEFAULT_TOKENS_PER_MINUTE=20000
MAX_TOKENS_PER_MINUTE=1000000000
# One conditional rate-limit entry and one HTTPRoute rule per tenant; both lists hold at most 16.
SHARED_TENANT_CEILING=16
MOCK_HOST=mock.mock-upstream.svc.cluster.local
PROBE_RATE=5

validate_limit() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,9}$ ]] && (( 10#$1 <= MAX_TOKENS_PER_MINUTE )) ||
        die "TOKENS_PER_MINUTE must be an integer from 1 to $MAX_TOKENS_PER_MINUTE."
}

tenant_exists() {
    local found
    if [[ "$CLUSTER" == shared ]]; then
        found=$(kube -n "$NAMESPACE" get configmap "$1-key" --ignore-not-found -o name) ||
            die "Cannot read tenant $1."
    else
        found=$(kube get namespace "$1" --ignore-not-found -o name) || die "Cannot read tenant $1."
    fi
    [[ -n "$found" ]]
}

# Creates any missing gateway or mock provider key for the tenant in .env.tenants.
ensure_keys() {
    local tenant=$1 kind name additions
    load_tenant_env
    for kind in API MOCK; do
        name=$(tenant_key_name "$tenant" "$kind")
        if ! jq -e --arg key "$name" '(.[$key] // "") | test("^[a-f0-9]{64}$")' "$TENANT_JSON" >/dev/null; then
            new_temp; additions=$TEMP_FILE
            openssl rand -hex 32 | tr -d '\n' | jq -R --arg key "$name" '{($key): .}' >"$additions"
            save_env_file "$TENANT_ENV" "$additions"
        fi
    done
    TENANT_JSON=
    load_tenant_env
}

key_hash() {
    tenant_key "$1" API | openssl dgst -sha256 -r | awk '{print "sha256:" $1}'
}

gateway_url() {
    printf 'http://%s.%s.svc/mock/v1/chat/completions' "$GATEWAY" "$(tenant_namespace "$1")"
}

# apply_tenant_objects <tenant> <namespace> <limit> <key ConfigMap name> <provider Secret name> <backend name>
apply_tenant_objects() {
    local tenant=$1 namespace=$2 limit=$3 key_name=$4 secret_name=$5 backend_name=$6 file hash
    hash=$(key_hash "$tenant")
    new_temp; file=$TEMP_FILE
    tenant_key "$tenant" MOCK | jq -Rs --arg name "$secret_name" --arg namespace "$namespace" --arg tenant "$tenant" '{
      apiVersion:"v1",kind:"Secret",type:"Opaque",
      metadata:{name:$name,namespace:$namespace,labels:{"gateway.dev/tenant":$tenant}},
      stringData:{Authorization:.}}' >"$file"
    kube_apply -f "$file" >/dev/null
    new_temp; file=$TEMP_FILE
    jq -n --arg name "$backend_name" --arg namespace "$namespace" --arg tenant "$tenant" \
        --arg secret "$secret_name" --arg host "$MOCK_HOST" '{
      apiVersion:"agentgateway.dev/v1alpha1",kind:"AgentgatewayBackend",
      metadata:{name:$name,namespace:$namespace,labels:{"gateway.dev/tenant":$tenant}},
      spec:{ai:{provider:{openai:{model:"mock-chat"},host:$host,port:8080}},
            policies:{auth:{secretRef:{name:$secret}}}}}' >"$file"
    kube_apply -f "$file" >/dev/null
    new_temp; file=$TEMP_FILE
    jq -n --arg name "$key_name" --arg namespace "$namespace" --arg tenant "$tenant" --arg hash "$hash" \
        --arg limit "$limit" '{
      apiVersion:"v1",kind:"ConfigMap",
      metadata:{name:$name,namespace:$namespace,
                labels:{"gateway.dev/component":"tenant-key","gateway.dev/tenant":$tenant},
                annotations:{"gateway.dev/tokens-per-minute":$limit}},
      data:{($tenant):({keyHash:$hash,metadata:{tenant:$tenant}} | tojson)}}' >"$file"
    kube_apply -f "$file" >/dev/null
}

# Rebuilds the shared cluster's one limit policy and one mock route from the tenant key ConfigMaps,
# which are the only record of which tenants exist and what their limits are.
render_shared() {
    local configmaps tenants policy route count
    new_temp; configmaps=$TEMP_FILE
    kube -n "$NAMESPACE" get configmaps -l gateway.dev/component=tenant-key -o json >"$configmaps"
    new_temp; tenants=$TEMP_FILE
    jq '[.items[] | {tenant: (.metadata.labels["gateway.dev/tenant"] // ""),
                     limit: (.metadata.annotations["gateway.dev/tokens-per-minute"] // "")} |
         select(.tenant | test("^tenant-[0-9]{2}$"))] | sort_by(.tenant) |
        if all(.[]; .limit | test("^[1-9][0-9]{0,9}$")) then map(.limit |= tonumber)
        else error("a tenant key ConfigMap has an invalid limit annotation") end' "$configmaps" >"$tenants" ||
        die "A tenant key ConfigMap has an invalid limit annotation."
    count=$(jq length "$tenants")
    if [[ "$count" -eq 0 ]]; then
        kube -n "$NAMESPACE" delete agentgatewaypolicy tenant-limits --ignore-not-found >/dev/null
        kube -n "$NAMESPACE" delete httproute mock-chat --ignore-not-found >/dev/null
        return
    fi
    [[ "$count" -le "$SHARED_TENANT_CEILING" ]] ||
        die "The shared design holds at most $SHARED_TENANT_CEILING tenants: one rate-limit entry and one route rule each."
    new_temp; policy=$TEMP_FILE
    jq --arg namespace "$NAMESPACE" --arg gateway "$GATEWAY" '{
      apiVersion:"agentgateway.dev/v1alpha1",kind:"AgentgatewayPolicy",
      metadata:{name:"tenant-limits",namespace:$namespace,labels:{"gateway.dev/component":"tenant-limits"}},
      spec:{targetRefs:[{group:"gateway.networking.k8s.io",kind:"Gateway",name:$gateway}],
            traffic:{rateLimit:{conditional:[.[] |
              {condition:("apiKey.tenant == \"" + .tenant + "\""),
               policy:{local:[{tokens:.limit,unit:"Minutes"}]}}]}}}}' "$tenants" >"$policy"
    new_temp; route=$TEMP_FILE
    jq --arg namespace "$NAMESPACE" --arg gateway "$GATEWAY" '{
      apiVersion:"gateway.networking.k8s.io/v1",kind:"HTTPRoute",
      metadata:{name:"mock-chat",namespace:$namespace,labels:{"gateway.dev/component":"tenant-routes"}},
      spec:{parentRefs:[{name:$gateway,sectionName:"http"}],
            rules:[.[] | {name:.tenant,
              matches:[{method:"POST",path:{type:"Exact",value:"/mock/v1/chat/completions"},
                        headers:[{type:"Exact",name:"x-tenant",value:.tenant}]}],
              backendRefs:[{group:"agentgateway.dev",kind:"AgentgatewayBackend",name:("mock-" + .tenant)}]}]}}' \
        "$tenants" >"$route"
    kube_apply -f "$policy" >/dev/null
    kube_apply -f "$route" >/dev/null
    wait_status "$NAMESPACE" agentgatewaypolicy/tenant-limits policy Accepted
    wait_status "$NAMESPACE" httproute/mock-chat route Accepted
    wait_status "$NAMESPACE" httproute/mock-chat route ResolvedRefs
}

# The token limit the proxy actually enforces for a tenant, or nothing. The proxy stores a single
# conditional entry as an object and several as a list.
enforced_limit() {
    local tenant=$1
    proxy_config "$(tenant_namespace "$tenant")" | jq -r --arg condition "apiKey.tenant == \"$tenant\"" '
      [.policies[]? | select(.name.name == "tenant-limits") |
       (.policy.traffic.localRateLimit | if type == "array" then .[] else . end) |
       select(.condition? == $condition) | .pol[0].maxTokens] | first // empty'
}

probe_plan() {
    local tenant=$1 file=$2
    jq -n --arg tenant "$tenant" --arg url "$(gateway_url "$tenant")" --argjson rate "$PROBE_RATE" \
        --arg gateway "$(tenant_namespace "$tenant")/$GATEWAY" '{streams:[{
      name:("probe-" + $tenant), role:"probe", tenant:$tenant, key:($tenant + ".api"), url:$url,
      gateway:$gateway, rate:$rate, duration:"300s", records:true, timeout:"5s", graceful_stop:"5s"}]}' >"$file"
}

probe_records() {
    kube -n "$LOAD_NAMESPACE" logs "job/$(load_job_name "$RUN_ID" probe)" 2>/dev/null |
        grep '^PROBE ' | cut -c7- || true
}

shared_objects_for() {
    printf '%s\n' "ConfigMap/$1-key" "Secret/mock-provider-$1" "AgentgatewayBackend/mock-$1"
}

tenant_add() {
    validate_tenant "${TENANT:-}"
    local tenant=$TENANT limit=${TOKENS_PER_MINUTE:-$DEFAULT_TOKENS_PER_MINUTE}
    validate_limit "$limit"
    verify_context
    [[ "$CLUSTER" == shared ]] || die "Tenant commands for the dedicated cluster are not available yet."
    section "ADD TENANT | $KIND_CLUSTER | $tenant"
    if tenant_exists "$tenant"; then
        info "$tenant already exists; reapplying its objects with the stored keys."
        ensure_keys "$tenant"
        mock_push_keys
        apply_tenant_objects "$tenant" "$NAMESPACE" "$limit" "$tenant-key" "mock-provider-$tenant" "mock-$tenant"
        render_shared
        ok "$tenant objects reapplied"
        return
    fi
    local count existing
    existing=$(tenant_list)
    count=$(printf '%s' "$existing" | grep -c . || true)
    [[ "$count" -lt "$SHARED_TENANT_CEILING" ]] ||
        die "The shared design holds at most $SHARED_TENANT_CEILING tenants: one rate-limit entry and one route rule each."
    ensure_keys "$tenant"
    info 'Registering the tenant provider key at the mock (provider-side setup, not timed).'
    mock_push_keys
    new_run onboarding "$tenant"
    local plan started applied usable_ms enforced_ms records elapsed deadline enforced now
    new_temp; plan=$TEMP_FILE
    probe_plan "$tenant" "$plan"
    info "Starting the onboarding probe: $PROBE_RATE requests per second with $tenant's key."
    load_start "$RUN_ID" probe "$plan"
    load_first_record "$RUN_ID" probe
    started=$(node_now_ms)
    apply_tenant_objects "$tenant" "$NAMESPACE" "$limit" "$tenant-key" "mock-provider-$tenant" "mock-$tenant"
    render_shared
    applied=$(node_now_ms)
    info "Objects applied $((applied - started)) ms after the start; waiting until the tenant is usable and its limit is enforced."
    usable_ms= enforced_ms=
    deadline=$((started + 300000))
    while :; do
        if [[ -z "$usable_ms" ]]; then
            records=$(probe_records)
            if grep -q '"verdict":"verified"' <<<"$records"; then usable_ms=done; fi
        fi
        if [[ -z "$enforced_ms" ]]; then
            enforced=$(enforced_limit "$tenant")
            if [[ "$enforced" == "$limit" ]]; then now=$(node_now_ms); enforced_ms=$((now - started)); fi
        fi
        [[ -z "$usable_ms" || -z "$enforced_ms" ]] || break
        now=$(node_now_ms)
        [[ "$now" -lt "$deadline" ]] || { warn 'Onboarding did not complete within 300 seconds.'; break; }
        sleep 1
    done
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    usable_ms=$(jq -s --argjson started "$started" \
        '[.[] | select(.verdict == "verified")] | if length > 0 then (min_by(.start_ms).start_ms - $started) else null end' \
        "$RUN_DIR/probes-probe.jsonl")
    local fields
    new_temp; fields=$TEMP_FILE
    jq -n --arg tenant "$tenant" --argjson limit "$limit" --argjson started "$started" --argjson applied "$applied" \
        --argjson usable "$usable_ms" --arg enforced "$enforced_ms" --arg run "$RUN_ID" \
        --argjson count "$((count + 1))" --slurpfile summary "$RUN_DIR/k6-summary-probe.json" \
        --arg created "$(shared_objects_for "$tenant")" '{
      kind:"onboarding", name:$tenant, run_id:$run, tenant:$tenant, tokens_per_minute:$limit,
      tenant_count_after:$count, clock:"kind-node",
      started_ms:$started, objects_applied_after_ms:($applied - $started),
      usable_after_ms:$usable, enforced_after_ms:(if $enforced == "" then null else ($enforced | tonumber) end),
      objects_created:($created | split("\n")),
      shared_objects_changed:["AgentgatewayPolicy/tenant-limits","HTTPRoute/mock-chat"],
      probe:($summary[0].streams | to_entries[0].value)} |
      .complete_after_ms = (if .usable_after_ms == null or .enforced_after_ms == null then null
                            else ([.usable_after_ms, .enforced_after_ms] | max) end)' >"$fields"
    write_run_json "$fields"
    section 'ONBOARDING'
    row 'Usable after' "$(jq -r '.usable_after_ms // "not reached"' "$RUN_DIR/run.json") ms (first successful probe)"
    row 'Limit enforced after' "$(jq -r '.enforced_after_ms // "not reached"' "$RUN_DIR/run.json") ms (proxy configuration)"
    row 'Objects created' "3 (key ConfigMap, provider Secret, backend)"
    row 'Shared objects changed' "2 (tenant-limits, mock-chat), each shared by $((count + 1)) tenants"
    row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.complete_after_ms != null' "$RUN_DIR/run.json" >/dev/null || die "$tenant did not become usable and enforced."
    ok "$tenant is onboarded"
}

tenant_remove() {
    validate_tenant "${TENANT:-}"
    local tenant=$TENANT
    verify_context
    [[ "$CLUSTER" == shared ]] || die "Tenant commands for the dedicated cluster are not available yet."
    [[ "${CONFIRM:-}" == 1 ]] || die "This removes $tenant and its keys. Rerun with CONFIRM=1."
    tenant_exists "$tenant" || die "$tenant does not exist in $KIND_CLUSTER."
    section "REMOVE TENANT | $KIND_CLUSTER | $tenant"
    load_tenant_env
    new_run offboarding "$tenant"
    local plan started records now deadline revoked cleaned_ms healthy
    new_temp; plan=$TEMP_FILE
    probe_plan "$tenant" "$plan"
    load_start "$RUN_ID" probe "$plan"
    load_first_record "$RUN_ID" probe
    deadline=$(( $(node_now_ms) + 120000 ))
    while :; do
        healthy=$(probe_records | jq -s '[.[-10:][] | select(.verdict == "verified")] | length')
        [[ "$healthy" -lt 10 ]] || break
        [[ "$(node_now_ms)" -lt "$deadline" ]] || die "$tenant was not healthy before removal; nothing was changed."
        sleep 1
    done
    started=$(node_now_ms)
    kube -n "$NAMESPACE" delete configmap "$tenant-key" --wait=true >/dev/null
    render_shared
    kube -n "$NAMESPACE" delete agentgatewaybackend "mock-$tenant" --ignore-not-found >/dev/null
    kube -n "$NAMESPACE" delete secret "mock-provider-$tenant" --ignore-not-found >/dev/null
    revoked= cleaned_ms=
    deadline=$((started + 300000))
    while :; do
        if [[ -z "$revoked" ]]; then
            revoked=$(probe_records | jq -s --argjson started "$started" '
              [.[] | select(.start_ms >= $started)] as $after |
              if ($after | length) >= 25 and ($after[-25:] | all(.verdict != "verified")) then "yes" else empty end')
        fi
        if [[ -z "$cleaned_ms" && -z "$(enforced_limit "$tenant")" ]] &&
            ! kube -n "$NAMESPACE" get configmap,agentgatewaybackend,secret -l "gateway.dev/tenant=$tenant" -o name | grep -q . &&
            ! kube -n "$NAMESPACE" get httproute mock-chat -o json --ignore-not-found 2>/dev/null | grep -q "\"$tenant\""; then
            now=$(node_now_ms); cleaned_ms=$((now - started))
        fi
        [[ -z "$revoked" || -z "$cleaned_ms" ]] || break
        [[ "$(node_now_ms)" -lt "$deadline" ]] || { warn 'Offboarding did not complete within 300 seconds.'; break; }
        sleep 1
    done
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    records="$RUN_DIR/probes-probe.jsonl"
    local fields removal
    new_temp; fields=$TEMP_FILE
    jq -s --arg tenant "$tenant" --argjson started "$started" --arg cleaned "$cleaned_ms" --arg run "$RUN_ID" '
      . as $all |
      ([$all[] | select(.verdict == "verified")] | if length > 0 then max_by(.start_ms).start_ms else null end) as $last |
      ([range(0; ($all | length)) as $i | select($all[$i].start_ms >= $started and
         ($all[$i:$i + 25] | length) == 25 and ($all[$i:$i + 25] | all(.verdict != "verified"))) | $all[$i].start_ms]
       | first // null) as $failed |
      {kind:"offboarding", name:$tenant, run_id:$run, tenant:$tenant, clock:"kind-node", started_ms:$started,
       revoked_between_ms:[(if $last == null then null else $last - $started end),
                           (if $failed == null then null else $failed - $started end)],
       cleaned_after_ms:(if $cleaned == "" then null else ($cleaned | tonumber) end),
       objects_deleted:["ConfigMap/" + $tenant + "-key","AgentgatewayBackend/mock-" + $tenant,"Secret/mock-provider-" + $tenant],
       shared_objects_changed:["AgentgatewayPolicy/tenant-limits","HTTPRoute/mock-chat"]}' "$records" >"$fields"
    write_run_json "$fields"
    new_temp; removal=$TEMP_FILE
    jq -n --arg api "$(tenant_key_name "$tenant" API)" --arg mock "$(tenant_key_name "$tenant" MOCK)" \
        '{($api):null,($mock):null}' >"$removal"
    save_env_file "$TENANT_ENV" "$removal"
    TENANT_JSON=
    mock_push_keys
    section 'OFFBOARDING'
    row 'Access revoked between' "$(jq -r '.revoked_between_ms | map(. // "?") | join(" and ")' "$RUN_DIR/run.json") ms after removal started"
    row 'Cleaned after' "$(jq -r '.cleaned_after_ms // "not reached"' "$RUN_DIR/run.json") ms"
    row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.revoked_between_ms[1] != null and .cleaned_after_ms != null' "$RUN_DIR/run.json" >/dev/null ||
        die "$tenant was not fully revoked and cleaned."
    ok "$tenant is removed and its keys are deleted"
}

tenant_limit() {
    local target=${TENANT:-} limit=${TOKENS_PER_MINUTE:-} tenants tenant
    validate_limit "$limit"
    verify_context
    [[ "$CLUSTER" == shared ]] || die "Tenant commands for the dedicated cluster are not available yet."
    if [[ "$target" == all ]]; then
        tenants=$(tenant_list)
    else
        validate_tenant "$target"
        tenant_exists "$target" || die "$target does not exist in $KIND_CLUSTER."
        tenants=$target
    fi
    [[ -n "$tenants" ]] || die "No tenants exist in $KIND_CLUSTER."
    for tenant in $tenants; do
        kube -n "$NAMESPACE" annotate configmap "$tenant-key" "gateway.dev/tokens-per-minute=$limit" --overwrite >/dev/null
    done
    render_shared
    ok "Limit set to $limit tokens per minute for: $(printf '%s ' $tenants)"
}

tenants_show() {
    verify_context
    section "TENANTS | $KIND_CLUSTER"
    local configmaps
    configmaps=$(kube -n "$NAMESPACE" get configmaps -l gateway.dev/component=tenant-key -o json)
    if [[ "$(jq '[.items[] | select(.metadata.labels["gateway.dev/tenant"] // "" | test("^tenant-[0-9]{2}$"))] | length' <<<"$configmaps")" -eq 0 ]]; then
        info 'No tenants yet. Add one: make tenant-add CLUSTER=shared TENANT=tenant-01'
        return
    fi
    jq -r '.items[] | select(.metadata.labels["gateway.dev/tenant"] // "" | test("^tenant-[0-9]{2}$")) |
      [.metadata.labels["gateway.dev/tenant"], .metadata.annotations["gateway.dev/tokens-per-minute"]] | @tsv' <<<"$configmaps" |
        sort | while IFS=$'\t' read -r tenant limit; do row "$tenant" "$limit tokens per minute"; done
}

tenant_objects() {
    validate_tenant "${TENANT:-}"
    local tenant=$TENANT count foundry= existing
    verify_context
    [[ "$CLUSTER" == shared ]] || die "Tenant commands for the dedicated cluster are not available yet."
    tenant_exists "$tenant" || die "$tenant does not exist in $KIND_CLUSTER."
    existing=$(tenant_list)
    count=$(printf '%s' "$existing" | grep -c . || true)
    if kube -n "$NAMESPACE" get secret foundry-provider --ignore-not-found -o name | grep -q .; then foundry=yes; fi
    local objects
    objects=$(jq -n --arg tenant "$tenant" --argjson n "$count" --arg foundry "$foundry" '[
      {object:("ConfigMap agentgateway-system/" + $tenant + "-key"), holds:"gateway key hash, tenant name, limit", shared_by:1},
      {object:("Secret agentgateway-system/mock-provider-" + $tenant), holds:"provider key", shared_by:1},
      {object:("AgentgatewayBackend agentgateway-system/mock-" + $tenant), holds:"upstream and credential reference", shared_by:1},
      {object:"AgentgatewayPolicy agentgateway-system/tenant-limits", holds:"token limit (one conditional entry)", shared_by:$n},
      {object:"HTTPRoute agentgateway-system/mock-chat", holds:"route rule to the tenant backend", shared_by:$n},
      {object:"AgentgatewayPolicy agentgateway-system/tenant-auth", holds:"key authentication", shared_by:$n},
      {object:"AgentgatewayPolicy agentgateway-system/tenant-routing", holds:"x-tenant from the key", shared_by:$n},
      {object:"AgentgatewayPolicy agentgateway-system/tenant-telemetry", holds:"tenant metric and log label", shared_by:$n},
      {object:"Gateway and Deployment agentgateway-system/agentgateway-proxy", holds:"the proxy serving the tenant", shared_by:$n},
      {object:"Deployment agentgateway-system/agentgateway", holds:"the controller", shared_by:$n}]
      + (if $foundry == "yes" then [{object:"Secret, backend, and route for Foundry in agentgateway-system", holds:"one Azure key copy", shared_by:$n}] else [] end)
      + [{object:"CRDs, Kind node, mock upstream", holds:"cluster-wide", shared_by:$n}]')
    if [[ "${FORMAT:-}" == json ]]; then printf '%s\n' "$objects"; return; fi
    section "OBJECTS HOLDING $tenant | $KIND_CLUSTER"
    jq -r '.[] | [.object, "shared by \(.shared_by) | \(.holds)"] | @tsv' <<<"$objects" |
        while IFS=$'\t' read -r object detail; do printf '  %s%s%s\n      %s\n' "$BOLD" "$object" "$RESET" "$detail" >&2; done
}

gateway_config() {
    validate_tenant "${TENANT:-}"
    local tenant=$TENANT namespace config
    verify_context
    namespace=$(tenant_namespace "$tenant")
    config=$(proxy_config "$namespace")
    section "WHAT THE PROXY ENFORCES | $namespace | $tenant"
    jq -r --arg condition "apiKey.tenant == \"$tenant\"" '
      [.policies[]? | select(.name.name == "tenant-limits") |
       (.policy.traffic.localRateLimit | if type == "array" then .[] else . end) |
       select(.condition? == $condition) | "Token limit: \(.pol[0].maxTokens) per \(.pol[0].fillInterval)"] |
      if length == 0 then "Token limit: none enforced" else .[] end' <<<"$config" |
        while IFS= read -r line; do info "$line"; done
    jq -r --arg tenant "$tenant" '[.. | objects | select(.kind? == "HTTPRoute" and .name? == "mock-chat") |
        select([.matches[]?.headers[]? | .value.exact?] | index($tenant)) | .backends[]?.backend] | unique[] |
        "Mock route backend: \(.)"' <<<"$config" | while IFS= read -r line; do info "$line"; done
}

select_cluster
case "${1:-}" in
    tenant-add) tenant_add ;;
    tenant-remove) tenant_remove ;;
    tenant-limit) tenant_limit ;;
    tenants) tenants_show ;;
    tenant-objects) tenant_objects ;;
    gateway-config) gateway_config ;;
    *) die "Unknown tenant command: ${1:-missing}" ;;
esac
