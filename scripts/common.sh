#!/bin/bash

set +x
set -euo pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STATE="$ROOT/.local"
TENANT_ENV="$ROOT/.env.tenants"
# The shared cluster's gateway namespace. Both clusters install the agentgateway CRDs release here.
NAMESPACE=agentgateway-system
GATEWAY=agentgateway-proxy
MOCK_NAMESPACE=mock-upstream
MONITORING_NAMESPACE=monitoring
LOAD_NAMESPACE=loadgen
FIELD_MANAGER=mtag
# These are tracked project configuration, never the credential-bearing .env files.
source "$ROOT/versions.env"
source "$ROOT/ports.env"

# Set only by select_cluster, so nothing can act on a cluster that was not chosen explicitly.
KIND_CLUSTER= CONTEXT= CLUSTER_STATE= KUBECONFIG_FILE= NODE_NAME= NODE_ID=
GATEWAY_PORT= KUBERNETES_PORT= REQUEST_PORT= DASHBOARD_PORT= GRAFANA_PORT= PROMETHEUS_PORT=

TEMP_FILES=()
ON_EXIT_HOOKS=()
FORWARD_PID=
FORWARD_LOG=
ENV_JSON=
TENANT_JSON=
LOADED_JSON=
BOLD= RESET= BLUE= GREEN= YELLOW= RED=
if [[ -t 2 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
    BOLD=$'\033[1m'; RESET=$'\033[0m'; BLUE=$'\033[36m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
fi

section() { printf '\n%s=== %s %s%s\n\n' "$BOLD$BLUE" "$1" "================================" "$RESET" >&2; }
info() { printf '  %s\n' "$*" >&2; }
ok() { printf '  %s[OK]%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn() { printf '  %s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '\n  %s[FAIL]%s %s\n\n' "$RED" "$RESET" "$*" >&2; exit 1; }
row() { printf '  %s%-31s%s %s\n' "$BOLD" "$1" "$RESET" "$2" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1. Install it, then rerun make doctor."; }

stop_forward() {
    if [[ -n "$FORWARD_PID" ]]; then
        if kill -0 "$FORWARD_PID" 2>/dev/null; then
            kill "$FORWARD_PID" 2>/dev/null || true
        fi
        wait "$FORWARD_PID" 2>/dev/null || true
    fi
    FORWARD_PID=
}

# Hooks run in reverse order, each in its own subshell with its own cleanup, so a failing
# hook cannot abort the remaining hooks or leave this process's temporary files behind.
# A hook runs as a plain command, never inside || or &&, so that set -e stays in force.
run_hook() {
    (
        set -euo pipefail
        TEMP_FILES=(); ON_EXIT_HOOKS=(); FORWARD_PID=; LOAD_PENDING=()
        trap cleanup EXIT
        "$1"
    )
}

cleanup() {
    local status=$? index result file
    set +e
    trap - EXIT
    trap '' INT TERM
    stop_forward
    for ((index=${#ON_EXIT_HOOKS[@]}-1; index>=0; index--)); do
        run_hook "${ON_EXIT_HOOKS[index]}"
        result=$?
        if [[ "$result" -ne 0 ]]; then
            warn "Cleanup step ${ON_EXIT_HOOKS[index]} failed (exit $result)."
            [[ "$status" -ne 0 ]] || status=$result
        fi
    done
    for file in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        [[ -f "$file" && ! -L "$file" ]] && rm -f -- "$file"
    done
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

on_exit() { ON_EXIT_HOOKS+=("$1"); }

select_cluster() {
    case "${CLUSTER:-}" in
        shared)
            GATEWAY_PORT=$SHARED_GATEWAY_PORT; KUBERNETES_PORT=$SHARED_KUBERNETES_PORT
            REQUEST_PORT=$SHARED_REQUEST_PORT; DASHBOARD_PORT=$SHARED_DASHBOARD_PORT
            GRAFANA_PORT=$SHARED_GRAFANA_PORT; PROMETHEUS_PORT=$SHARED_PROMETHEUS_PORT ;;
        dedicated)
            GATEWAY_PORT=$DEDICATED_GATEWAY_PORT; KUBERNETES_PORT=$DEDICATED_KUBERNETES_PORT
            REQUEST_PORT=$DEDICATED_REQUEST_PORT; DASHBOARD_PORT=$DEDICATED_DASHBOARD_PORT
            GRAFANA_PORT=$DEDICATED_GRAFANA_PORT; PROMETHEUS_PORT=$DEDICATED_PROMETHEUS_PORT ;;
        *) die "Set CLUSTER=shared or CLUSTER=dedicated. No cluster is ever chosen for you." ;;
    esac
    NODE_ID=
    KIND_CLUSTER="mtag-$CLUSTER"
    CONTEXT="kind-$KIND_CLUSTER"
    CLUSTER_STATE="$STATE/$CLUSTER"
    KUBECONFIG_FILE="$CLUSTER_STATE/kubeconfig"
    NODE_NAME="$KIND_CLUSTER-control-plane"
}

# CLUSTER=both reruns the same command for shared, then dedicated, each in a separate process.
# A shared COMPARISON_ID ties the two runs together.
select_cluster_or_both() {
    local script=$1; shift
    if [[ "${CLUSTER:-}" == both ]]; then
        COMPARISON_ID=${COMPARISON_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}
        export COMPARISON_ID
        local target
        for target in shared dedicated; do
            CLUSTER=$target /bin/bash "$ROOT/scripts/$script" "$@" ||
                die "The $target cluster run failed; the remaining cluster was not run."
        done
        exit 0
    fi
    select_cluster
}

private_state() {
    [[ ! -L "$STATE" ]] || die ".local must not be a symlink."
    mkdir -p -- "$STATE"
    chmod 700 "$STATE"
    if [[ -n "$CLUSTER_STATE" ]]; then
        [[ ! -L "$CLUSTER_STATE" ]] || die "$CLUSTER_STATE must not be a symlink."
        mkdir -p -- "$CLUSTER_STATE"
        chmod 700 "$CLUSTER_STATE"
    fi
}

new_temp() {
    private_state
    TEMP_FILE=$(mktemp "$STATE/tmp.XXXXXXXX")
    TEMP_FILES+=("$TEMP_FILE")
}

file_mode() {
    if [[ "$(uname -s)" == Darwin ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

private_file() {
    [[ -f "$1" && ! -L "$1" ]] || die "Expected a regular private file: $1"
    [[ "$(file_mode "$1")" == 600 ]] || die "Credentials need owner-only permissions: chmod 600 '$1'"
}

load_env_file() {
    private_file "$1"
    new_temp
    LOADED_JSON=$TEMP_FILE
    jq -Rn -f "$ROOT/scripts/env.jq" "$1" >"$LOADED_JSON" ||
        die "Cannot parse $(basename -- "$1"). It must contain literal KEY=value lines, not shell commands."
}

load_env() { load_env_file "$ROOT/.env"; ENV_JSON=$LOADED_JSON; }

load_tenant_env() {
    if [[ -e "$TENANT_ENV" ]]; then
        load_env_file "$TENANT_ENV"
        TENANT_JSON=$LOADED_JSON
    else
        new_temp; TENANT_JSON=$TEMP_FILE
        printf '{}\n' >"$TENANT_JSON"
    fi
}

config() {
    [[ -n "$ENV_JSON" ]] || die "Configuration has not been loaded."
    jq -er --arg key "$1" '.[$key] | select(type == "string" and length > 0)' "$ENV_JSON" ||
        die "Missing $1 in .env. Run make foundry-up to complete configuration."
}

# Merges the additions JSON object into a literal KEY=value file. A null value removes the key.
save_env_file() {
    local target=$1 additions=$2 name existing result
    name=$(basename -- "$target")
    [[ ! -L "$target" ]] || die "Refusing to replace a symlink at $name."
    if git -C "$ROOT" ls-files --error-unmatch "$name" >/dev/null 2>&1; then
        die "$name is tracked by Git. Remove it from the index before saving credentials."
    fi
    if ! git -C "$ROOT" check-ignore -q --no-index "$name"; then
        die "$name must be excluded by .gitignore before credentials are written."
    fi
    new_temp; existing=$TEMP_FILE
    if [[ -e "$target" ]]; then
        private_file "$target"
        jq -Rn -f "$ROOT/scripts/env.jq" "$target" >"$existing"
    else
        printf '{}\n' >"$existing"
    fi
    new_temp; result=$TEMP_FILE
    jq -r --slurpfile addition "$additions" '
      . + $addition[0] | with_entries(select(.value != null)) | to_entries | sort_by(.key)[] |
      if (.key | test("^[A-Z_][A-Z0-9_]*$")) and
         (.value | type == "string" and (test("[\\r\\n]") | not))
      then "\(.key)=\(.value)" else error("Invalid configuration entry") end
    ' "$existing" >"$result"
    chmod 600 "$result"
    mv -f -- "$result" "$target"
}

save_env() { save_env_file "$ROOT/.env" "$1"; }

validate_tenant() {
    [[ "${1:-}" =~ ^tenant-[0-9]{2}$ && "$1" != tenant-00 ]] ||
        die "TENANT must look like tenant-01 (two digits, 01 to 99)."
}

# Prints the .env.tenants variable name for a tenant in the selected cluster,
# for example SHARED_TENANT_01_API_KEY or DEDICATED_TENANT_03_MOCK_KEY.
tenant_key_name() {
    local upper_cluster upper_tenant
    upper_cluster=$(printf '%s' "$CLUSTER" | tr '[:lower:]' '[:upper:]')
    upper_tenant=$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')
    printf '%s_%s_%s_KEY' "$upper_cluster" "$upper_tenant" "$2"
}

# Callers load .env.tenants first (load_tenant_env), because this usually runs inside a command
# substitution, where a lazily created temporary file would escape the exit cleanup.
tenant_key() {
    [[ -n "$TENANT_JSON" ]] || die "Internal error: .env.tenants was not loaded before reading a key."
    local value
    value=$(jq -r --arg key "$(tenant_key_name "$1" "$2")" '.[$key] // empty' "$TENANT_JSON")
    [[ "$value" =~ ^[a-f0-9]{64}$ ]] ||
        die "No valid $2 key for $1 in .env.tenants. Run make tenant-add CLUSTER=$CLUSTER TENANT=$1."
    printf '%s' "$value"
}

docker_local() {
    env -u DOCKER_HOST -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        docker --context desktop-linux "$@"
}

kind_local() {
    env -u DOCKER_HOST -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        DOCKER_CONTEXT=desktop-linux KIND_EXPERIMENTAL_PROVIDER=docker \
        KUBECONFIG="$KUBECONFIG_FILE" kind "$@"
}

kube() { kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" "$@"; }
helm_local() { helm --kubeconfig "$KUBECONFIG_FILE" --kube-context "$CONTEXT" "$@"; }
kube_apply() { kube apply --server-side --field-manager="$FIELD_MANAGER" --force-conflicts "$@"; }

cluster_exists() {
    local clusters errors
    new_temp; errors=$TEMP_FILE
    clusters=$(kind_local get clusters 2>"$errors") || {
        cat "$errors" >&2
        die "Cannot list Kind clusters on Docker Desktop."
    }
    grep -Fxq "$KIND_CLUSTER" <<<"$clusters"
}

verify_cluster() {
    need jq
    [[ -n "$KIND_CLUSTER" ]] || die "Internal error: no cluster selected."
    [[ -f "$CLUSTER_STATE/cluster.json" && ! -L "$CLUSTER_STATE/cluster.json" ]] ||
        die "No ownership record for $KIND_CLUSTER. Run make up CLUSTER=$CLUSTER; an unexplained existing cluster will not be adopted."
    local node expected
    expected=$(jq -er '.nodeId | select(type == "string" and length > 0)' "$CLUSTER_STATE/cluster.json") ||
        die "Cluster creation is incomplete. Inspect the named Kind node before recovery."
    node=$(docker_local inspect "$NODE_NAME") ||
        die "Project node $NODE_NAME is unavailable. Run make status CLUSTER=$CLUSTER."
    jq -e --arg id "$expected" --arg name "$KIND_CLUSTER" --arg image "$KIND_IMAGE" \
        --arg port "$KUBERNETES_PORT" '
      length == 1 and .[0].Id == $id and
      .[0].Config.Labels["io.x-k8s.kind.cluster"] == $name and
      .[0].Config.Image == $image and
      .[0].HostConfig.PortBindings["6443/tcp"] ==
        [{"HostIp":"127.0.0.1","HostPort":$port}]
    ' <<<"$node" >/dev/null ||
        die "Kind identity/image/port differs from this project. Refusing to use or delete it."
    jq -e --arg name "$KIND_CLUSTER" --arg image "$KIND_IMAGE" --argjson port "$KUBERNETES_PORT" \
        '.name == $name and .image == $image and .apiPort == $port' "$CLUSTER_STATE/cluster.json" >/dev/null ||
        die "Kind settings changed. Restore the previous settings before explicit teardown."
    NODE_ID=$expected
}

verify_context() {
    verify_cluster
    private_file "$KUBECONFIG_FILE"
    local configuration
    configuration=$(kube config view --raw -o json) || die "Cannot read the project kubeconfig."
    jq -e --arg context "$CONTEXT" --arg server "https://127.0.0.1:$KUBERNETES_PORT" '
      (.contexts | length) == 1 and (.clusters | length) == 1 and
      (.users | length) == 1 and .contexts[0].name == $context and
      .contexts[0].context.cluster == .clusters[0].name and
      .contexts[0].context.user == .users[0].name and
      .clusters[0].cluster.server == $server and
      .clusters[0].cluster["insecure-skip-tls-verify"] != true and
      .clusters[0].cluster["proxy-url"] == null and
      .users[0].user.exec == null and .users[0].user["auth-provider"] == null
    ' <<<"$configuration" >/dev/null ||
        die "Unexpected project kubeconfig. Never falling back to your current context."
}

# Runs a command inside the verified Kind node container, addressed by its recorded ID.
node_exec() {
    [[ -n "${NODE_ID:-}" ]] || verify_cluster
    docker_local exec -i "$NODE_ID" "$@"
}

# Prints the process ID of the single running proxy container in a gateway namespace.
proxy_pid() {
    local namespace=$1 containers id
    containers=$(node_exec crictl ps --state running --label "io.kubernetes.pod.namespace=$namespace" \
        --label io.kubernetes.container.name=agentgateway -o json) || die "Cannot list containers in the Kind node."
    id=$(jq -er --arg prefix "$GATEWAY-" '
      [.containers[] | select(.labels["io.kubernetes.pod.name"] | startswith($prefix)) | .id] |
      if length == 1 then .[0] else error("expected exactly one running proxy container") end
    ' <<<"$containers") || die "Expected exactly one running proxy in $namespace."
    node_exec crictl inspect "$id" | jq -er '.info.pid | select(type == "number" and . > 1)' ||
        die "Cannot read the proxy process ID in $namespace."
}

# Prints the proxy's effective configuration. The admin endpoint listens on the pod's loopback
# address only, so this enters the pod's network namespace from the Kind node instead of
# exposing the endpoint on the host.
proxy_config() {
    local pid
    pid=$(proxy_pid "$1")
    node_exec nsenter -t "$pid" -n curl --disable --silent --show-error --max-time 10 \
        http://127.0.0.1:15000/config_dump || die "Cannot read the proxy configuration in $1."
}

port_free() {
    local result
    if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
        die "Port $1 is occupied. Stop its owner yourself or change ports.env; no process was killed."
    else
        result=$?
        [[ "$result" -eq 1 ]] || die "Cannot inspect port $1 (lsof exit $result)."
    fi
}

# start_forward <local port> <namespace> <resource> <remote port>
start_forward() {
    local port=$1 namespace=$2 resource=$3 remote=$4 attempt
    [[ -z "$FORWARD_PID" ]] || die "A request forward is already active in this command."
    port_free "$port"
    new_temp; FORWARD_LOG=$TEMP_FILE
    kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
        -n "$namespace" port-forward --address 127.0.0.1 \
        "$resource" "$port:$remote" >"$FORWARD_LOG" 2>&1 &
    FORWARD_PID=$!
    for ((attempt=0; attempt<60; attempt++)); do
        if ! kill -0 "$FORWARD_PID" 2>/dev/null; then
            cat "$FORWARD_LOG" >&2
            FORWARD_PID=
            die "The project port-forward exited before becoming ready."
        fi
        if grep -Fq "Forwarding from 127.0.0.1:$port" "$FORWARD_LOG"; then
            return
        fi
        sleep 0.5
    done
    cat "$FORWARD_LOG" >&2
    die "Timed out waiting for the project port-forward."
}

# Writes the tenant's gateway Authorization header to a private file, so the key never
# appears in a process argument.
tenant_header() {
    local key
    [[ -n "$TENANT_JSON" ]] || load_tenant_env
    key=$(tenant_key "$1" API)
    new_temp; HEADER_FILE=$TEMP_FILE
    printf 'Authorization: Bearer %s\n' "$key" >"$HEADER_FILE"
}

http_call() {
    local url=$1 header=${2:-} payload=${3:-}
    local args=(--silent --show-error --connect-timeout 5 --max-time 120
        --noproxy 127.0.0.1 --proto '=http' --max-redirs 0)
    [[ -z "$header" ]] || args+=(--header "@$header")
    if [[ -n "$payload" ]]; then
        args+=(--header 'Content-Type: application/json' --data-binary "@$payload")
    fi
    new_temp; RESPONSE_FILE=$TEMP_FILE
    new_temp; RESPONSE_HEADERS=$TEMP_FILE
    HTTP_STATUS=$(curl "${args[@]}" --dump-header "$RESPONSE_HEADERS" --output "$RESPONSE_FILE" \
        --write-out '%{http_code}' "$url") || die "Gateway request failed. No automatic retry was made."
    [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]] || die "curl did not return a valid HTTP status."
}

response_header() {
    awk -v name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" -F': ' '
      { key = tolower($1); sub(/\r$/, "", $2) } key == name { value = $2 } END { print value }
    ' "$RESPONSE_HEADERS"
}

wait_condition() {
    local namespace=$1 resource=$2 condition=$3
    kube -n "$namespace" wait "$resource" --for="condition=$condition" --timeout=300s ||
        die "$resource did not become $condition. Inspect make status and make logs."
}

confirm_action() {
    [[ "${CONFIRM:-}" == 1 ]] && return
    [[ -t 0 ]] || die "Confirmation required. Review the choices, then rerun with CONFIRM=1."
    local answer
    printf '\n  Proceed with these exact changes? [y/N] ' >&2
    IFS= read -r answer
    [[ "$answer" == y || "$answer" == Y ]] || die "Cancelled; no changes were made."
}

# Namespaces holding a gateway in the selected cluster: agentgateway-system in the shared
# cluster, and one namespace per tenant in the dedicated cluster.
gateway_namespaces() {
    if [[ "$CLUSTER" == shared ]]; then
        printf '%s\n' "$NAMESPACE"
    else
        kube get namespaces -l gateway.dev/tenant -o json |
            jq -r '.items[].metadata.name | select(test("^tenant-[0-9]{2}$"))' | sort
    fi
}

# The namespace of the gateway that serves a tenant.
tenant_namespace() {
    if [[ "$CLUSTER" == shared ]]; then printf '%s' "$NAMESPACE"; else printf '%s' "$1"; fi
}

# Tenants that exist in the selected cluster, taken from the cluster itself.
tenant_list() {
    if [[ "$CLUSTER" == shared ]]; then
        kube -n "$NAMESPACE" get configmaps -l gateway.dev/component=tenant-key -o json |
            jq -r '.items[].metadata.labels["gateway.dev/tenant"] // empty | select(test("^tenant-[0-9]{2}$"))' | sort
    else
        gateway_namespaces
    fi
}

# Tenants whose key is active on the gateway in the given namespace.
tenants_served_by() {
    local found
    if [[ "$CLUSTER" == shared ]]; then
        kube -n "$NAMESPACE" get configmaps -l gateway.dev/component=tenant-key,gateway.dev/key-active=true -o json |
            jq -r '.items[].metadata.labels["gateway.dev/tenant"] // empty | select(test("^tenant-[0-9]{2}$"))' | sort
    else
        found=$(kube -n "$1" get configmap tenant-key --ignore-not-found \
            -o jsonpath='{.metadata.labels.gateway\.dev/key-active}') || die "Cannot read the tenant key in $1."
        if [[ "$found" == true ]]; then printf '%s\n' "$1"; fi
    fi
}

# Waits for a condition that agentgateway reports per Gateway: policies under status.ancestors,
# routes under status.parents, and other objects under status.conditions.
# wait_status <namespace> <resource> <policy|route|plain> <condition>
wait_status() {
    local namespace=$1 resource=$2 style=$3 condition=$4 attempt document
    for ((attempt=0; attempt<60; attempt++)); do
        document=$(kube -n "$namespace" get "$resource" -o json)
        if jq -e --arg style "$style" --arg condition "$condition" --arg gateway "$GATEWAY" '
          .metadata.generation as $generation |
          (if $style=="policy" then
            [.status.ancestors[]? | select(.ancestorRef.name==$gateway) | .conditions[]?]
           elif $style=="route" then
            [.status.parents[]? | select(.parentRef.name==$gateway) | .conditions[]?]
           else [.status.conditions[]?] end) |
          any(.[]; .type==$condition and .status=="True" and
            (.observedGeneration==null or .observedGeneration==$generation))
        ' <<<"$document" >/dev/null; then return; fi
        sleep 2
    done
    jq .status <<<"$document" >&2
    die "$namespace/$resource has no current $condition=True condition."
}

MOCK_POST_KEYS='import sys, urllib.request
request = urllib.request.Request("http://127.0.0.1:8081/admin/keys", data=sys.stdin.buffer.read(), method="POST")
print(urllib.request.urlopen(request, timeout=10).read().decode())'

# Rebuilds Secret mock-upstream-keys from the selected cluster's tenant mock keys in .env.tenants,
# then sends the same list to every running mock replica on standard input and checks that each
# replica now accepts exactly those owners. A restarted replica loads the Secret at start.
mock_push_keys() {
    load_tenant_env
    local upper list secret expected pods pod result
    upper=$(printf '%s' "$CLUSTER" | tr '[:lower:]' '[:upper:]')
    new_temp; list=$TEMP_FILE
    jq -r --arg prefix "${upper}_TENANT_" '
      to_entries[] | select(.key | test("^" + $prefix + "[0-9]{2}_MOCK_KEY$")) |
      select(.value | test("^[a-f0-9]{64}$")) |
      "tenant-" + (.key | capture("_TENANT_(?<n>[0-9]{2})_MOCK_KEY$").n) + " " + .value
    ' "$TENANT_JSON" | sort >"$list"
    new_temp; secret=$TEMP_FILE
    jq -n --rawfile keys "$list" --arg namespace "$MOCK_NAMESPACE" '{apiVersion:"v1",kind:"Secret",type:"Opaque",
      metadata:{name:"mock-upstream-keys",namespace:$namespace},stringData:{keys:$keys}}' >"$secret"
    kube_apply -f "$secret" >/dev/null
    expected=$(awk '{print $1}' "$list" | jq -R . | jq -sc 'sort')
    # A replica that starts during this update may have mounted the previous Secret, so the push
    # repeats until the same set of ready replicas (by pod and container start) all report the
    # expected owners twice in a row.
    local attempt state previous= stable=0
    kube -n "$MOCK_NAMESPACE" rollout status deployment/mock --timeout=300s >/dev/null
    for ((attempt=0; attempt<30; attempt++)); do
        state=$(kube -n "$MOCK_NAMESPACE" get pods -l app.kubernetes.io/name=mock -o json | jq -r '
          [.items[] | select(.metadata.deletionTimestamp == null) |
           "\(.metadata.name)/\(.status.containerStatuses[0].restartCount // 0)/\(.status.containerStatuses[0].ready // false)"] |
          sort | join(" ")') || die "Cannot list mock replicas."
        [[ -n "$state" && "$state" != *'/false'* ]] || { sleep 2; continue; }
        pods=$(printf '%s' "$state" | tr ' ' '\n' | cut -d/ -f1)
        for pod in $pods; do
            result=$(kube -n "$MOCK_NAMESPACE" exec -i "pod/$pod" -- python -c "$MOCK_POST_KEYS" <"$list") ||
                die "Cannot update the keys of $pod."
            [[ "$(jq -c '.owners | sort' <<<"$result")" == "$expected" ]] ||
                die "$pod did not accept the expected key owners."
        done
        if [[ "$state" == "$previous" ]]; then stable=$((stable + 1)); else stable=0; fi
        previous=$state
        [[ "$stable" -lt 1 ]] || return 0
        sleep 1
    done
    die "Mock replicas did not settle while their keys were being updated."
}
