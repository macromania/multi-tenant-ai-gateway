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
# Set to 0 to apply rendered policies without waiting for their status, for example while a
# controller is deliberately stopped and cannot report status.
RENDER_WAIT=${RENDER_WAIT:-1}

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

# apply_tenant_objects <tenant> <namespace> <limit> <key ConfigMap> <provider Secret> <backend> <state>
# The state (onboarding, active, or offboarding) is stored as gateway.dev/tenant-state, and the key is
# marked gateway.dev/key-active "true" only when the state is active; tenant-auth accepts only such keys.
apply_tenant_objects() {
    local tenant=$1 namespace=$2 limit=$3 key_name=$4 secret_name=$5 backend_name=$6 state=$7 file hash active=false
    case "$state" in onboarding|offboarding) ;; active) active=true ;; *) die "Internal error: tenant state $state." ;; esac
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
        --arg limit "$limit" --arg active "$active" --arg state "$state" '{
      apiVersion:"v1",kind:"ConfigMap",
      metadata:{name:$name,namespace:$namespace,
                labels:{"gateway.dev/component":"tenant-key","gateway.dev/tenant":$tenant,
                        "gateway.dev/key-active":$active,"gateway.dev/tenant-state":$state},
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
    jq --argjson max "$MAX_TOKENS_PER_MINUTE" '[.items[] | {name: .metadata.name, tenant: (.metadata.labels["gateway.dev/tenant"] // ""),
                     limit: (.metadata.annotations["gateway.dev/tokens-per-minute"] // "")} |
         select(.tenant | test("^tenant-[0-9]{2}$"))] | sort_by(.tenant) |
        (map(select((.limit | test("^[1-9][0-9]{0,9}$") | not) or ((.limit | tonumber) > $max))) | map(.name)) as $bad |
        if ($bad | length) == 0 then map(.limit |= tonumber)
        else error("invalid limit annotation on " + ($bad | join(", "))) end' "$configmaps" >"$tenants" ||
        die "A tenant key ConfigMap has a limit that is not an integer from 1 to $MAX_TOKENS_PER_MINUTE."
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
    [[ "$RENDER_WAIT" == 1 ]] || return 0
    wait_status "$NAMESPACE" agentgatewaypolicy/tenant-limits policy Accepted
    wait_status "$NAMESPACE" httproute/mock-chat route Accepted
    wait_status "$NAMESPACE" httproute/mock-chat route ResolvedRefs
}

# Rebuilds one dedicated tenant's limit policy and mock route from its key ConfigMap. The policy
# keeps the conditional form, with a single entry, so that a configuration mistake has the same
# shape in both designs; only the number of tenants sharing the object differs.
render_tenant() {
    local tenant=$1 limit policy route
    limit=$(kube -n "$tenant" get configmap tenant-key -o jsonpath='{.metadata.annotations.gateway\.dev/tokens-per-minute}')
    validate_limit "$limit"
    new_temp; policy=$TEMP_FILE
    jq -n --arg namespace "$tenant" --arg gateway "$GATEWAY" --arg tenant "$tenant" --argjson limit "$limit" '{
      apiVersion:"agentgateway.dev/v1alpha1",kind:"AgentgatewayPolicy",
      metadata:{name:"tenant-limits",namespace:$namespace,labels:{"gateway.dev/component":"tenant-limits"}},
      spec:{targetRefs:[{group:"gateway.networking.k8s.io",kind:"Gateway",name:$gateway}],
            traffic:{rateLimit:{conditional:[{condition:("apiKey.tenant == \"" + $tenant + "\""),
                                              policy:{local:[{tokens:$limit,unit:"Minutes"}]}}]}}}}' >"$policy"
    new_temp; route=$TEMP_FILE
    jq -n --arg namespace "$tenant" --arg gateway "$GATEWAY" --arg tenant "$tenant" '{
      apiVersion:"gateway.networking.k8s.io/v1",kind:"HTTPRoute",
      metadata:{name:"mock-chat",namespace:$namespace,labels:{"gateway.dev/component":"tenant-routes"}},
      spec:{parentRefs:[{name:$gateway,sectionName:"http"}],
            rules:[{name:$tenant,
              matches:[{method:"POST",path:{type:"Exact",value:"/mock/v1/chat/completions"}}],
              backendRefs:[{group:"agentgateway.dev",kind:"AgentgatewayBackend",name:"mock"}]}]}}' >"$route"
    kube_apply -f "$policy" >/dev/null
    kube_apply -f "$route" >/dev/null
    [[ "$RENDER_WAIT" == 1 ]] || return 0
    wait_status "$tenant" agentgatewaypolicy/tenant-limits policy Accepted
    wait_status "$tenant" httproute/mock-chat route Accepted
    wait_status "$tenant" httproute/mock-chat route ResolvedRefs
}

foundry_configured() {
    [[ -f "$STATE/foundry.json" ]] && jq -e '.phase == "configured"' "$STATE/foundry.json" >/dev/null
}

# A complete agentgateway for one tenant in its own namespace: its own Helm release (controller and
# GatewayClass), Gateway and proxy, authentication, telemetry, key, limit, mock route, and backend.
apply_dedicated_tenant() {
    local tenant=$1 limit=$2 state=$3 file values attempt
    new_temp; file=$TEMP_FILE
    jq -n --arg tenant "$tenant" '{apiVersion:"v1",kind:"Namespace",
      metadata:{name:$tenant,labels:{"gateway.dev/tenant":$tenant,"gateway.dev/component":"tenant"}}}' >"$file"
    kube_apply -f "$file" >/dev/null
    new_temp; values=$TEMP_FILE
    jq -n --arg tenant "$tenant" '{gatewayClassName:("agw-" + $tenant), controllerName:("agentgateway.dev/" + $tenant),
      rbac:{gatewayNamespaces:[$tenant]},
      discoveryNamespaceSelectors:[{matchLabels:{"kubernetes.io/metadata.name":$tenant}}],
      monitoring:{proxy:{gatewayClassNames:[("agw-" + $tenant)]}}}' >"$values"
    helm_local upgrade --install "agw-$tenant" oci://cr.agentgateway.dev/charts/agentgateway \
        --version "$AGENTGATEWAY_VERSION" --namespace "$tenant" \
        --values "$ROOT/deploy/agentgateway/tenant-values.yaml" --values "$values" --wait --timeout 5m >&2
    new_temp; file=$TEMP_FILE
    sed "s/@NAMESPACE@/$tenant/g" "$ROOT/deploy/agentgateway/tenant-gateway.yaml.tmpl" >"$file"
    kube_apply -f "$file" >/dev/null
    kube wait "gatewayclass/agw-$tenant" --for=condition=Accepted --timeout=300s >/dev/null
    kube -n "$tenant" wait "gateway/$GATEWAY" --for=condition=Programmed --timeout=300s >/dev/null
    for ((attempt=0; attempt<120; attempt++)); do
        kube -n "$tenant" get "deployment/$GATEWAY" >/dev/null 2>&1 && break
        sleep 1
    done
    kube -n "$tenant" rollout status "deployment/$GATEWAY" --timeout=300s >/dev/null
    new_temp; file=$TEMP_FILE
    sed "s/@NAMESPACE@/$tenant/g" "$ROOT/deploy/agentgateway/tenant-auth.yaml.tmpl" >"$file"
    kube_apply -f "$file" >/dev/null
    new_temp; file=$TEMP_FILE
    sed "s/@NAMESPACE@/$tenant/g" "$ROOT/deploy/agentgateway/tenant-telemetry.yaml.tmpl" >"$file"
    kube_apply -f "$file" >/dev/null
    apply_tenant_objects "$tenant" "$tenant" "$limit" tenant-key mock-provider mock "$state"
    render_tenant "$tenant"
    wait_status "$tenant" agentgatewaypolicy/tenant-auth policy Accepted
    wait_status "$tenant" agentgatewaypolicy/tenant-telemetry policy Accepted
}

dedicated_cluster_objects() {
    printf '%s\n' "clusterrole/agentgateway-$1" "clusterrole/agentgateway-$1-deployer" \
        "clusterrolebinding/agentgateway-role-$1" "clusterrolebinding/agentgateway-write-role-$1" \
        "gatewayclass/agw-$1"
}

# Removes a dedicated tenant: its Gateway (and so its proxy), its Helm release, the GatewayClass its
# controller created (neither Helm nor namespace deletion removes it), and its namespace.
remove_dedicated_tenant() {
    local tenant=$1 controller attempt
    kube -n "$tenant" delete gateway "$GATEWAY" --ignore-not-found --wait=true --timeout=120s >/dev/null
    for ((attempt=0; attempt<120; attempt++)); do
        kube -n "$tenant" get "deployment/$GATEWAY" >/dev/null 2>&1 || break
        sleep 1
    done
    helm_local uninstall "agw-$tenant" --namespace "$tenant" --ignore-not-found --wait --timeout 5m >&2
    # Helm cannot uninstall a release whose record is gone; its cluster roles are then deleted here,
    # but only if they carry that release's Helm ownership annotations.
    local object owner
    for object in $(dedicated_cluster_objects "$tenant" | grep -v '^gatewayclass/'); do
        owner=$(kube get "$object" --ignore-not-found -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}/{.metadata.annotations.meta\.helm\.sh/release-namespace}')
        [[ -n "$owner" && "$owner" != / ]] || continue
        [[ "$owner" == "agw-$tenant/$tenant" ]] || die "$object belongs to $owner, not to $tenant; it was not deleted."
        kube delete "$object" --ignore-not-found >/dev/null
    done
    controller=$(kube get gatewayclass "agw-$tenant" --ignore-not-found -o jsonpath='{.spec.controllerName}')
    if [[ -n "$controller" ]]; then
        [[ "$controller" == "agentgateway.dev/$tenant" ]] ||
            die "GatewayClass agw-$tenant belongs to $controller, not to $tenant; it was not deleted."
        kube delete gatewayclass "agw-$tenant" --wait=true >/dev/null
    fi
    kube delete namespace "$tenant" --ignore-not-found --wait=true --timeout=300s >/dev/null
}

dedicated_cleaned() {
    local objects
    objects=$(kube get namespace "$1" --ignore-not-found -o name) || return 1
    [[ -z "$objects" ]] || return 1
    objects=$(dedicated_cluster_objects "$1" | xargs kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
        get --ignore-not-found -o name) || return 1
    [[ -z "$objects" ]]
}

# ---------------------------------------------------------------------------------------------
# Single requests sent from the Kind node to a gateway's ClusterIP. The tenant key is written to a
# private file and read by curl from standard input, so it never appears in a process argument.
# node_request <tenant|none|invalid> <namespace> <path> [extra header line] [model] [max tokens]
# Sets REQ_STATUS, REQ_OWNER, and REQ_ECHO_OK.
# ---------------------------------------------------------------------------------------------
node_request() {
    local who=$1 namespace=$2 path=$3 extra=${4:-} model=${5:-mock-chat} tokens=${6:-16} ip headers response id
    ip=$(kube -n "$namespace" get service "$GATEWAY" -o jsonpath='{.spec.clusterIP}')
    [[ "$ip" =~ ^[0-9.]+$ ]] || die "No gateway Service in $namespace."
    id="check-$(openssl rand -hex 6)"
    new_temp; headers=$TEMP_FILE
    case "$who" in
        none) : >"$headers" ;;
        invalid) printf 'Authorization: Bearer %s\n' "$(openssl rand -hex 32)" >"$headers" ;;
        *) printf 'Authorization: Bearer %s\n' "$(tenant_key "$who" API)" >"$headers" ;;
    esac
    printf 'x-probe-id: %s\n' "$id" >>"$headers"
    [[ -z "$extra" ]] || printf '%s\n' "$extra" >>"$headers"
    response=$(node_exec curl --disable --silent --output /dev/null --dump-header - --header @- --max-time 60 \
        --header 'Content-Type: application/json' \
        --data "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"check\"}],\"max_completion_tokens\":$tokens}" \
        "http://$ip$path" <"$headers" | tr -d '\r') || response=
    REQ_STATUS=$(awk 'NR == 1 {print $2}' <<<"$response")
    REQ_OWNER=$(awk -F': ' 'tolower($1) == "x-mock-key-owner" {print $2}' <<<"$response")
    REQ_ECHO_OK=false
    if [[ "$(awk -F': ' 'tolower($1) == "x-mock-probe-id" {print $2}' <<<"$response")" == "$id" ]]; then REQ_ECHO_OK=true; fi
}

# Waits until the proxy serving each named tenant enforces the given limit.
wait_enforced() {
    local limit=$1 tenant deadline value; shift
    deadline=$(( $(date +%s) + 120 ))
    for tenant in "$@"; do
        while :; do
            value=$( (enforced_limit "$tenant") 2>/dev/null ) || value=
            [[ "$value" != "$limit" ]] || break
            [[ "$(date +%s)" -lt "$deadline" ]] || die "The proxy for $tenant did not enforce $limit within 120 seconds."
            sleep 0.5
        done
    done
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

# apply_design_tenant <tenant> <limit> <state>: all of a tenant's objects in the given state.
apply_design_tenant() {
    if [[ "$CLUSTER" == shared ]]; then
        apply_tenant_objects "$1" "$NAMESPACE" "$2" "$1-key" "mock-provider-$1" "mock-$1" "$3"
        render_shared
    else
        apply_dedicated_tenant "$1" "$2" "$3"
    fi
}

key_configmap() {
    if [[ "$CLUSTER" == shared ]]; then printf '%s-key' "$1"; else printf 'tenant-key'; fi
}

# set_tenant_state <tenant> <onboarding|active|offboarding>
set_tenant_state() {
    local active=false
    [[ "$2" != active ]] || active=true
    kube -n "$(tenant_namespace "$1")" label configmap "$(key_configmap "$1")" \
        "gateway.dev/key-active=$active" "gateway.dev/tenant-state=$2" --overwrite >/dev/null
}

# The tenant's recorded state, or nothing when its key ConfigMap is absent.
tenant_state() {
    local namespace found
    namespace=$(tenant_namespace "$1")
    if [[ "$CLUSTER" == dedicated ]]; then
        found=$(kube get namespace "$1" --ignore-not-found -o name) || die "Cannot read namespace $1."
        [[ -n "$found" ]] || return 0
    fi
    kube -n "$namespace" get configmap "$(key_configmap "$1")" --ignore-not-found \
        -o jsonpath='{.metadata.labels.gateway\.dev/tenant-state}' || die "Cannot read the state of $1."
}

# Refuses to run tenant commands against a tenant-auth policy that predates the key-active selector,
# because that policy would accept inactive keys.
require_current_auth() {
    local namespace=$1 selector
    selector=$(kube -n "$namespace" get agentgatewaypolicy tenant-auth --ignore-not-found \
        -o jsonpath='{.spec.traffic.apiKeyAuthentication.configMapSelector.matchLabels.gateway\.dev/key-active}') ||
        die "Cannot read tenant-auth in $namespace."
    [[ -z "$(kube -n "$namespace" get agentgatewaypolicy tenant-auth --ignore-not-found -o name)" || "$selector" == true ]] ||
        die "tenant-auth in $namespace predates key activation. Run make up CLUSTER=$CLUSTER first."
}

# Sends one request with the tenant's key to every gateway in the cluster and requires each to refuse
# it at authentication (401 without an upstream answer). Retries for up to 60 seconds.
verify_key_refused() {
    local tenant=$1 namespace namespaces deadline accepted
    namespaces=$(gateway_namespaces)
    deadline=$(( $(date +%s) + 60 ))
    while :; do
        accepted=
        for namespace in $namespaces; do
            node_request "$tenant" "$namespace" /mock/v1/chat/completions
            if [[ "$REQ_STATUS" != 401 || -n "$REQ_OWNER" ]]; then accepted="$namespace (HTTP ${REQ_STATUS:-none})"; break; fi
        done
        [[ -n "$accepted" ]] || return 0
        [[ "$(date +%s)" -lt "$deadline" ]] || die "$tenant's key is still accepted by $accepted."
        sleep 2
    done
}

stored_limit() {
    local limit
    limit=$(kube -n "$(tenant_namespace "$1")" get configmap "$(key_configmap "$1")" \
        -o jsonpath='{.metadata.annotations.gateway\.dev/tokens-per-minute}') || die "Cannot read the limit of $1."
    validate_limit "$limit"
    printf '%s' "$limit"
}

# Refuses to continue if the tenant's key hash is also stored for another tenant, because then the
# key would still authenticate, as that other tenant, after this tenant is removed.
duplicate_hash_check() {
    local tenant=$1 hash duplicates canonical
    hash=$(key_hash "$tenant")
    canonical="$(tenant_namespace "$tenant")/$(key_configmap "$tenant")"
    duplicates=$(kube get configmaps -A -l gateway.dev/component=tenant-key -o json | jq -r --arg canonical "$canonical" --arg hash "$hash" '
      [.items[] | select((.metadata.namespace + "/" + .metadata.name) != $canonical) |
       select([.data[]? | (fromjson? // {}) | .keyHash] | index($hash)) |
       .metadata.namespace + "/" + .metadata.name] | join(", ")') || die "Cannot read the tenant key ConfigMaps."
    [[ -z "$duplicates" ]] || die "$tenant's key hash is also stored in $duplicates; fix that first."
}

# Anything left of a tenant, including a partly added or partly removed one.
tenant_artifacts() {
    local tenant=$1 found
    if [[ "$CLUSTER" == shared ]]; then
        found=$(kube -n "$NAMESPACE" get configmaps,secrets,agentgatewaybackends -l "gateway.dev/tenant=$tenant" -o name) ||
            die "Cannot read the objects of $tenant."
    else
        found=$(dedicated_cluster_objects "$tenant" | xargs kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
            get --ignore-not-found -o name) || die "Cannot read the objects of $tenant."
        found="$found$(kube get namespace "$tenant" --ignore-not-found -o name)" || die "Cannot read namespace $tenant."
    fi
    load_tenant_env
    if jq -e --arg api "$(tenant_key_name "$tenant" API)" --arg mock "$(tenant_key_name "$tenant" MOCK)" \
        'has($api) or has($mock)' "$TENANT_JSON" >/dev/null; then found="$found keys"; fi
    printf '%s' "$found"
}

remove_tenant_keys() {
    local removal
    new_temp; removal=$TEMP_FILE
    jq -n --arg api "$(tenant_key_name "$1" API)" --arg mock "$(tenant_key_name "$1" MOCK)" \
        '{($api):null,($mock):null}' >"$removal"
    save_env_file "$TENANT_ENV" "$removal"
    TENANT_JSON=
    mock_push_keys
}

# Removes whatever is left of a tenant without measuring anything, for a tenant-add or tenant-remove
# that was interrupted.
cleanup_partial_tenant() {
    local tenant=$1 has_keys=
    warn "$tenant is incomplete; removing what is left. This is not a measured offboarding."
    load_tenant_env
    if jq -e --arg api "$(tenant_key_name "$tenant" API)" '(.[$api] // "") | test("^[a-f0-9]{64}$")' "$TENANT_JSON" >/dev/null; then
        has_keys=yes
        duplicate_hash_check "$tenant"
    fi
    if [[ -n "$(tenant_state "$tenant")" ]]; then set_tenant_state "$tenant" offboarding; fi
    if [[ -n "$has_keys" && -n "$(gateway_namespaces)" ]]; then verify_key_refused "$tenant"; fi
    if [[ "$CLUSTER" == shared ]]; then
        kube -n "$NAMESPACE" delete configmaps,agentgatewaybackends,secrets -l "gateway.dev/tenant=$tenant" \
            --ignore-not-found --wait=true >/dev/null
        render_shared
    else
        remove_dedicated_tenant "$tenant"
    fi
    local deadline=$(( $(date +%s) + 300 ))
    until tenant_cleaned "$tenant"; do
        [[ "$(date +%s)" -lt "$deadline" ]] || die "Objects of $tenant remain after cleanup: $(tenant_artifacts "$tenant")"
        sleep 2
    done
    remove_tenant_keys "$tenant"
    ok "$tenant is cleaned up and its keys are deleted"
}

# jq function over probe records sorted by start time: the last successful request, the start of the
# first run of 25 consecutive refusals by the gateway's authentication after it (401 without an
# upstream answer; the mock's own 401 for a bad provider key does not count), and the number of leaks.
REVOCATION_JQ='def revocation($started):
  (map(select(.verdict == "verified") | .start_ms) | max) as $last |
  ([range(0; length) as $i | select(.[$i].start_ms >= $started and ($last == null or .[$i].start_ms > $last) and
      (.[$i:$i + 25] | length) == 25 and (.[$i:$i + 25] | all(.status == 401 and .verdict == "blocked"))) | .[$i].start_ms] | first) as $streak |
  {last_success: $last, streak_start: $streak, leaks: (map(select(.verdict == "leak")) | length)};'

current_records() {
    local records
    records=$(probe_records)
    printf '%s
' "$records" | jq -s 'map(select(type == "object")) | sort_by(.start_ms)'
}

# The shared gateway already has the Foundry route; a dedicated tenant gets its own copy of it.
connect_tenant_foundry() {
    if [[ "$CLUSTER" == dedicated ]] && foundry_configured; then
        CLUSTER=dedicated TENANT=$1 /bin/bash "$ROOT/scripts/foundry.sh" gateway-configure-namespace >&2
    fi
}

WATCH_PID=
WATCH_FILE=
stop_enforcement_watch() {
    if [[ -n "$WATCH_PID" ]]; then kill "$WATCH_PID" 2>/dev/null || true; fi
}

# Polls the proxy's configuration in the background from before the tenant's objects are applied,
# and writes the Kind node time at which the tenant's limit first appears. Both designs are
# measured the same way, independently of how long the apply step itself takes.
start_enforcement_watch() {
    local tenant=$1 limit=$2
    new_temp; WATCH_FILE=$TEMP_FILE
    on_exit stop_enforcement_watch
    (
        set +e
        deadline=$(( $(node_now_ms) + 300000 ))
        while :; do
            value=$( (enforced_limit "$tenant") 2>/dev/null )
            if [[ "$value" == "$limit" ]]; then node_now_ms >"$WATCH_FILE"; exit 0; fi
            [[ "$(node_now_ms)" -lt "$deadline" ]] || exit 1
            sleep 0.5
        done
    ) &
    WATCH_PID=$!
}

# The objects a new tenant adds, as recorded in its onboarding run.
created_objects_json() {
    local tenant=$1
    if [[ "$CLUSTER" == shared ]]; then
        jq -nc --arg t "$tenant" '["ConfigMap/" + $t + "-key", "Secret/mock-provider-" + $t, "AgentgatewayBackend/mock-" + $t]'
    else
        jq -nc --arg t "$tenant" --arg foundry "$(foundry_configured && printf yes || true)" '
          ["Namespace/" + $t, "HelmRelease/agw-" + $t + " (controller Deployment, Service, ServiceAccount, Role, RoleBinding, 2 ClusterRoles, 2 ClusterRoleBindings, ServiceMonitor, PodMonitor)",
           "GatewayClass/agw-" + $t, "AgentgatewayParameters/tenant-proxy", "Gateway/agentgateway-proxy (proxy Deployment and Service)",
           "AgentgatewayPolicy/tenant-auth", "AgentgatewayPolicy/tenant-telemetry", "AgentgatewayPolicy/tenant-limits",
           "HTTPRoute/mock-chat", "ConfigMap/tenant-key", "Secret/mock-provider", "AgentgatewayBackend/mock"]
          + (if $foundry == "yes" then ["Secret/foundry-provider", "AgentgatewayBackend/foundry-model", "HTTPRoute/foundry-chat"] else [] end)'
    fi
}

changed_objects_json() {
    if [[ "$CLUSTER" == shared ]]; then printf '%s' '["AgentgatewayPolicy/tenant-limits","HTTPRoute/mock-chat"]'; else printf '[]'; fi
}

# Saves the probe records and a run record explaining the failure, then stops with an error.
onboarding_failed() {
    local started=$1 reason=$2 fields
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null || true
    new_temp; fields=$TEMP_FILE
    jq -n --arg tenant "$TENANT" --arg run "$RUN_ID" --argjson started "$started" --arg reason "$reason" \
        --arg design "$CLUSTER" --argjson rate "$PROBE_RATE" '{kind:"onboarding", name:$tenant, run_id:$run,
        tenant:$tenant, clock:"kind-node", started_ms:$started, failed:true, reason:$reason,
        config:{design:$design, probe_rate:$rate}}' >"$fields"
    write_run_json "$fields"
    die "Onboarding $TENANT failed: $reason. Evidence: ${RUN_DIR#$ROOT/}"
}

ONBOARDING_DONE=
onboarding_hint() {
    [[ -n "$ONBOARDING_DONE" ]] ||
        warn "Onboarding did not finish. Rerun make tenant-add to complete it, or make tenant-remove CONFIRM=1 to clean up."
}

tenant_add() {
    validate_tenant "${TENANT:-}"
    local tenant=$TENANT limit=${TOKENS_PER_MINUTE:-}
    [[ -z "$limit" ]] || validate_limit "$limit"
    verify_context
    section "ADD TENANT | $KIND_CLUSTER | $tenant"
    require_current_auth "$(tenant_namespace "$tenant")"
    local state
    state=$(tenant_state "$tenant")
    case "$state" in
        active)
            [[ -n "$limit" ]] || limit=$(stored_limit "$tenant")
            info "$tenant is active; reapplying its objects with the stored keys and a limit of $limit."
            ensure_keys "$tenant"
            mock_push_keys
            apply_design_tenant "$tenant" "$limit" active
            connect_tenant_foundry "$tenant"
            ok "$tenant objects reapplied"
            return ;;
        onboarding)
            [[ -n "$limit" ]] || limit=$(stored_limit "$tenant")
            info "$tenant was not fully added; resuming with its key inactive until its limit is enforced (not measured)."
            ensure_keys "$tenant"
            duplicate_hash_check "$tenant"
            mock_push_keys
            apply_design_tenant "$tenant" "$limit" onboarding
            wait_enforced "$limit" "$tenant"
            set_tenant_state "$tenant" active
            connect_tenant_foundry "$tenant"
            ok "$tenant is active"
            return ;;
        offboarding) die "$tenant is being removed. Run make tenant-remove CLUSTER=$CLUSTER TENANT=$tenant CONFIRM=1 to finish." ;;
        '') ;;
        *) die "$tenant has an unknown state $state." ;;
    esac
    [[ -n "$limit" ]] || limit=$DEFAULT_TOKENS_PER_MINUTE
    local count existing leftovers
    leftovers=$(tenant_artifacts "$tenant")
    if [[ -n "$leftovers" && "$leftovers" != " keys" ]]; then
        die "$tenant has leftover objects from an interrupted run. Run make tenant-remove CLUSTER=$CLUSTER TENANT=$tenant CONFIRM=1 first."
    fi
    existing=$(tenant_list)
    count=$(printf '%s' "$existing" | grep -c . || true)
    if [[ "$CLUSTER" == shared ]]; then
        [[ "$count" -lt "$SHARED_TENANT_CEILING" ]] ||
            die "The shared design holds at most $SHARED_TENANT_CEILING tenants: one rate-limit entry and one route rule each."
    fi
    on_exit onboarding_hint
    ensure_keys "$tenant"
    info 'Registering the tenant provider key at the mock (provider-side setup, not timed).'
    mock_push_keys
    new_run onboarding "$tenant"
    local plan started written enforced_at published usable_at now deadline records state foundry_ms=
    new_temp; plan=$TEMP_FILE
    probe_plan "$tenant" "$plan"
    info "Starting the onboarding probe: $PROBE_RATE requests per second with $tenant's key."
    load_start "$RUN_ID" probe "$plan"
    load_first_record "$RUN_ID" probe
    started=$(node_now_ms)
    start_enforcement_watch "$tenant" "$limit"
    info 'Applying the tenant with its key inactive, so its limit is enforced before the key is accepted.'
    apply_design_tenant "$tenant" "$limit" onboarding
    written=$(node_now_ms)
    deadline=$((started + 300000))
    until [[ -s "$WATCH_FILE" ]]; do
        [[ "$(node_now_ms)" -lt "$deadline" ]] || onboarding_failed "$started" "the proxy did not enforce the limit within 300 seconds"
        sleep 0.5
    done
    enforced_at=$(cat "$WATCH_FILE")
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=
    duplicate_hash_check "$tenant"
    # Taken before the change, because a request can succeed as soon as the proxy sees it.
    published=$(node_now_ms)
    set_tenant_state "$tenant" active
    info "Limit enforced $((enforced_at - started)) ms after the start; key activated. Waiting for the first successful request."
    deadline=$((published + 120000))
    while :; do
        records=$(probe_records)
        if grep -q '"verdict":"verified"' <<<"$records"; then break; fi
        [[ "$(node_now_ms)" -lt "$deadline" ]] || onboarding_failed "$started" "not usable within 120 seconds of activating the key"
        sleep 1
    done
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    if [[ "$CLUSTER" == dedicated ]] && foundry_configured; then
        connect_tenant_foundry "$tenant"
        now=$(node_now_ms); foundry_ms=$((now - started))
    fi
    local fields mock_replicas
    mock_replicas=$(kube -n "$MOCK_NAMESPACE" get deployment mock -o jsonpath='{.spec.replicas}')
    new_temp; fields=$TEMP_FILE
    jq -s --arg tenant "$tenant" --argjson limit "$limit" --argjson started "$started" --argjson written "$written" \
        --argjson enforced "$enforced_at" --argjson published "$published" --arg foundry "$foundry_ms" \
        --arg run "$RUN_ID" --argjson count "$count" --argjson rate "$PROBE_RATE" --arg design "$CLUSTER" \
        --argjson replicas "$mock_replicas" --arg foundry_on "$(foundry_configured && printf yes || true)" \
        --slurpfile summary "$RUN_DIR/k6-summary-probe.json" \
        --argjson created "$(created_objects_json "$tenant")" --argjson changed "$(changed_objects_json)" '
      ([.[] | select(.verdict == "verified") | .start_ms] | min) as $first |
      {kind:"onboarding", name:$tenant, run_id:$run, tenant:$tenant, clock:"kind-node", started_ms:$started,
       config:{design:$design, probe_rate:$rate, tokens_per_minute:$limit, tenant_count_before:$count,
               mock_replicas:$replicas, foundry_connected:($foundry_on == "yes")},
       objects_written_after_ms:($written - $started), enforced_after_ms:($enforced - $started),
       key_activated_after_ms:($published - $started),
       usable_after_ms:(if $first == null then null else $first - $started end),
       usable_after_activation_ms:(if $first == null then null else $first - $published end),
       foundry_connected_after_ms:(if $foundry == "" then null else ($foundry | tonumber) end),
       leaks:(map(select(.verdict == "leak")) | length),
       objects_created:$created, shared_objects_changed:$changed,
       probe:($summary[0].streams | to_entries[0].value)} |
      .complete_after_ms = (if .usable_after_ms == null then null else ([.usable_after_ms, .enforced_after_ms] | max) end)' \
        "$RUN_DIR/probes-probe.jsonl" >"$fields"
    write_run_json "$fields"
    section 'ONBOARDING'
    row 'Limit enforced after' "$(jq -r '.enforced_after_ms' "$RUN_DIR/run.json") ms (proxy configuration, key still inactive)"
    row 'Key activated after' "$(jq -r '.key_activated_after_ms' "$RUN_DIR/run.json") ms"
    row 'Usable after' "$(jq -r '.usable_after_ms // "not reached"' "$RUN_DIR/run.json") ms (first successful probe)"
    if [[ -n "$foundry_ms" ]]; then row 'Foundry connected after' "$foundry_ms ms (own copy of the Azure key)"; fi
    row 'Objects created' "$(jq -r '.objects_created | length' "$RUN_DIR/run.json")"
    if [[ "$CLUSTER" == shared ]]; then
        row 'Shared objects changed' "2 (tenant-limits, mock-chat), each shared by $((count + 1)) tenants"
    else
        row 'Shared objects changed' "none"
    fi
    row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.leaks == 0' "$RUN_DIR/run.json" >/dev/null || die "Probe responses reached another tenant's provider key."
    jq -e '.complete_after_ms != null' "$RUN_DIR/run.json" >/dev/null || die "$tenant did not become usable."
    ONBOARDING_DONE=1
    ok "$tenant is onboarded"
}

# True once nothing that held the tenant's settings remains and the proxy no longer enforces it.
tenant_cleaned() {
    local tenant=$1 objects route
    if [[ "$CLUSTER" == dedicated ]]; then dedicated_cleaned "$tenant"; return; fi
    local enforced
    enforced=$( (enforced_limit "$tenant") 2>/dev/null ) || return 1
    [[ -z "$enforced" ]] || return 1
    objects=$(kube -n "$NAMESPACE" get configmap,agentgatewaybackend,secret -l "gateway.dev/tenant=$tenant" -o name) || return 1
    [[ -z "$objects" ]] || return 1
    route=$(kube -n "$NAMESPACE" get httproute mock-chat --ignore-not-found -o json) || return 1
    ! grep -q "\"$tenant\"" <<<"$route"
}

tenant_remove() {
    validate_tenant "${TENANT:-}"
    local tenant=$TENANT
    verify_context
    [[ "${CONFIRM:-}" == 1 ]] || die "This removes $tenant and its keys. Rerun with CONFIRM=1."
    section "REMOVE TENANT | $KIND_CLUSTER | $tenant"
    load_tenant_env
    require_current_auth "$(tenant_namespace "$tenant")"
    if [[ "$(tenant_state "$tenant")" != active ]]; then
        if [[ -n "$(tenant_artifacts "$tenant")" ]]; then cleanup_partial_tenant "$tenant"; return; fi
        die "$tenant does not exist in $KIND_CLUSTER."
    fi
    duplicate_hash_check "$tenant"
    local existing count limit
    existing=$(tenant_list)
    count=$(printf '%s' "$existing" | grep -c . || true)
    limit=$(stored_limit "$tenant")
    new_run offboarding "$tenant"
    local plan started state revoked_seen= boundary= cleaned_ms= now deadline healthy
    new_temp; plan=$TEMP_FILE
    probe_plan "$tenant" "$plan"
    load_start "$RUN_ID" probe "$plan"
    load_first_record "$RUN_ID" probe
    deadline=$(( $(node_now_ms) + 120000 ))
    while :; do
        healthy=$(current_records | jq '[.[-10:][] | select(.verdict == "verified")] | length')
        [[ "$healthy" -lt 10 ]] || break
        [[ "$(node_now_ms)" -lt "$deadline" ]] || die "$tenant was not healthy before removal; nothing was changed."
        sleep 1
    done
    started=$(node_now_ms)
    info 'Deactivating the key first; the rest is removed only after authentication refuses it.'
    set_tenant_state "$tenant" offboarding
    deadline=$((started + 120000))
    while :; do
        state=$(current_records | jq -c --argjson started "$started" "$REVOCATION_JQ revocation(\$started)")
        [[ "$(jq '.leaks' <<<"$state")" -eq 0 ]] || die "Probe responses reached another tenant's provider key; stopping."
        boundary=$(jq '.streak_start' <<<"$state")
        if [[ "$boundary" != null ]]; then revoked_seen=$(node_now_ms); break; fi
        [[ "$(node_now_ms)" -lt "$deadline" ]] ||
            die "Authentication still accepts $tenant's key after 120 seconds. The key is inactive and nothing else was removed."
        sleep 1
    done
    verify_key_refused "$tenant"
    if [[ "$CLUSTER" == shared ]]; then
        kube -n "$NAMESPACE" delete configmap "$tenant-key" --wait=true >/dev/null
        render_shared
        kube -n "$NAMESPACE" delete agentgatewaybackend "mock-$tenant" --ignore-not-found >/dev/null
        kube -n "$NAMESPACE" delete secret "mock-provider-$tenant" --ignore-not-found >/dev/null
    else
        remove_dedicated_tenant "$tenant"
    fi
    deadline=$((started + 600000))
    while :; do
        if tenant_cleaned "$tenant"; then now=$(node_now_ms); cleaned_ms=$((now - started)); break; fi
        [[ "$(node_now_ms)" -lt "$deadline" ]] || { warn 'Cleanup did not finish within 600 seconds.'; break; }
        sleep 1
    done
    load_finish "$RUN_ID" probe "$RUN_DIR" >/dev/null
    local fields mock_replicas
    mock_replicas=$(kube -n "$MOCK_NAMESPACE" get deployment mock -o jsonpath='{.spec.replicas}')
    new_temp; fields=$TEMP_FILE
    # The boundary is the start of the refusal run that allowed removal to continue; any success
    # after it means access came back, which invalidates the result.
    jq -s --arg tenant "$tenant" --argjson started "$started" --arg cleaned "$cleaned_ms" --arg run "$RUN_ID" \
        --argjson seen "$revoked_seen" --argjson count "$count" --argjson limit "$limit" --argjson rate "$PROBE_RATE" \
        --arg design "$CLUSTER" --argjson replicas "$mock_replicas" --argjson boundary "$boundary" \
        --argjson deleted "$(created_objects_json "$tenant")" --argjson changed "$(changed_objects_json)" '
      sort_by(.start_ms) |
      {last_success: ([.[] | select(.verdict == "verified" and .start_ms < $boundary) | .start_ms] | max),
       streak_start: $boundary, leaks: ([.[] | select(.verdict == "leak")] | length)} as $r |
      ([.[] | select(.start_ms >= $boundary and .verdict == "verified")] | length) as $resumed |
      {kind:"offboarding", name:$tenant, run_id:$run, tenant:$tenant, clock:"kind-node", started_ms:$started,
       config:{design:$design, probe_rate:$rate, tokens_per_minute:$limit, tenant_count_before:$count,
               mock_replicas:$replicas},
       revoked_between_ms:[(if $r.last_success == null then null else $r.last_success - $started end),
                           (if $r.streak_start == null then null else $r.streak_start - $started end)],
       revocation_observed_after_ms:($seen - $started),
       success_after_revocation:$resumed, leaks:$r.leaks,
       cleaned_after_ms:(if $cleaned == "" then null else ($cleaned | tonumber) end),
       objects_deleted:$deleted, shared_objects_changed:$changed}' "$RUN_DIR/probes-probe.jsonl" >"$fields"
    write_run_json "$fields"
    remove_tenant_keys "$tenant"
    section 'OFFBOARDING'
    row 'Access revoked between' "$(jq -r '.revoked_between_ms | map(. // "?") | join(" and ")' "$RUN_DIR/run.json") ms after deactivation (last success, then 25 refusals by authentication)"
    row 'Cleaned after' "$(jq -r '.cleaned_after_ms // "not reached"' "$RUN_DIR/run.json") ms"
    row 'Run record' "${RUN_DIR#$ROOT/}"
    jq -e '.leaks == 0 and .success_after_revocation == 0 and .revoked_between_ms[1] != null and
           (.revoked_between_ms[0] == null or .revoked_between_ms[0] <= .revoked_between_ms[1]) and
           .cleaned_after_ms != null' "$RUN_DIR/run.json" >/dev/null ||
        die "$tenant was not cleanly revoked and removed; see the run record."
    ok "$tenant is removed and its keys are deleted"
}

tenant_limit() {
    local target=${TENANT:-} limit=${TOKENS_PER_MINUTE:-} tenants tenant
    validate_limit "$limit"
    verify_context
    if [[ "$target" == all ]]; then
        tenants=$(tenant_list)
    else
        validate_tenant "$target"
        tenant_exists "$target" || die "$target does not exist in $KIND_CLUSTER."
        tenants=$target
    fi
    [[ -n "$tenants" ]] || die "No tenants exist in $KIND_CLUSTER."
    for tenant in $tenants; do
        if [[ "$CLUSTER" == shared ]]; then
            kube -n "$NAMESPACE" annotate configmap "$tenant-key" "gateway.dev/tokens-per-minute=$limit" --overwrite >/dev/null
        else
            kube -n "$tenant" annotate configmap tenant-key "gateway.dev/tokens-per-minute=$limit" --overwrite >/dev/null
        fi
    done
    if [[ "$CLUSTER" == shared ]]; then
        render_shared
    else
        for tenant in $tenants; do render_tenant "$tenant"; done
    fi
    ok "Limit set to $limit tokens per minute for: $(printf '%s ' $tenants)"
}

tenants_show() {
    verify_context
    section "TENANTS | $KIND_CLUSTER"
    local configmaps
    if [[ "$CLUSTER" == shared ]]; then
        configmaps=$(kube -n "$NAMESPACE" get configmaps -l gateway.dev/component=tenant-key -o json)
    else
        configmaps=$(kube get configmaps -A -l gateway.dev/component=tenant-key -o json)
    fi
    if [[ "$(jq '[.items[] | select(.metadata.labels["gateway.dev/tenant"] // "" | test("^tenant-[0-9]{2}$"))] | length' <<<"$configmaps")" -eq 0 ]]; then
        info "No tenants yet. Add one: make tenant-add CLUSTER=$CLUSTER TENANT=tenant-01"
        return
    fi
    jq -r '.items[] | select(.metadata.labels["gateway.dev/tenant"] // "" | test("^tenant-[0-9]{2}$")) |
      [.metadata.labels["gateway.dev/tenant"], .metadata.annotations["gateway.dev/tokens-per-minute"],
       (if .metadata.labels["gateway.dev/key-active"] == "true" then "key active" else "key inactive" end)] | @tsv' <<<"$configmaps" |
        sort | while IFS=$'\t' read -r tenant limit state; do row "$tenant" "$limit tokens per minute, $state"; done
}

tenant_objects() {
    validate_tenant "${TENANT:-}"
    local tenant=$TENANT count foundry= existing found
    verify_context
    tenant_exists "$tenant" || die "$tenant does not exist in $KIND_CLUSTER."
    existing=$(tenant_list)
    count=$(printf '%s' "$existing" | grep -c . || true)
    found=$(kube -n "$(tenant_namespace "$tenant")" get secret foundry-provider --ignore-not-found -o name)
    [[ -z "$found" ]] || foundry=yes
    local objects
    if [[ "$CLUSTER" == dedicated ]]; then
        objects=$(jq -n --arg t "$tenant" --argjson n "$count" --arg foundry "$foundry" '[
          {object:("Namespace " + $t), holds:"every namespaced object below", shared_by:1},
          {object:("Helm release agw-" + $t + " (controller Deployment agw-" + $t + "-agentgateway)"), holds:"the tenant own controller", shared_by:1},
          {object:("GatewayClass agw-" + $t), holds:"cluster-wide class owned by the tenant controller", shared_by:1},
          {object:("ClusterRoles agentgateway-" + $t + " and agentgateway-" + $t + "-deployer"), holds:"controller permissions, including reading Secrets in every namespace", shared_by:1},
          {object:("Gateway, AgentgatewayParameters, and proxy Deployment " + $t + "/agentgateway-proxy"), holds:"the proxy serving the tenant", shared_by:1},
          {object:($t + "/tenant-auth, tenant-telemetry, tenant-limits"), holds:"authentication, telemetry, token limit (one conditional entry)", shared_by:1},
          {object:($t + "/mock-chat, tenant-key, mock-provider, mock"), holds:"route, key hash and limit, provider key, backend", shared_by:1}]
          + (if $foundry == "yes" then [{object:("Secret, backend, and route for Foundry in " + $t), holds:("one of " + ($n|tostring) + " Azure key copies"), shared_by:1}] else [] end)
          + [{object:"CRDs (one version), Kind node, mock upstream, Foundry deployment", holds:"cluster-wide and upstream", shared_by:$n}]')
    else
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
    fi
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
    jq -r --arg tenant "$tenant" --arg design "$CLUSTER" '
      [.. | objects | select(.kind? == "HTTPRoute" and .name? == "mock-chat") |
       select($design == "dedicated" or ([.matches[]?.headers[]? | .value.exact?] | index($tenant))) |
       .backends[]?.backend] | unique |
      if length == 0 then "Mock route backend: none" else .[] | "Mock route backend: \(.)" end' <<<"$config" |
        while IFS= read -r line; do info "$line"; done
}

# Commands run only when this file is executed; scripts/experiments.sh sources it for its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
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
fi
