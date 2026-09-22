#!/bin/bash

set +x
set -euo pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STATE="$ROOT/.local"
KUBECONFIG_FILE="$STATE/kubeconfig"
CLUSTER=multi-tenant-ai-gateway
CONTEXT=kind-multi-tenant-ai-gateway
NAMESPACE=agentgateway-system
GATEWAY=agentgateway-proxy
# These are tracked project configuration, never the credential-bearing .env.
source "$ROOT/versions.env"
source "$ROOT/ports.env"

TEMP_FILES=()
FORWARD_PID=
FORWARD_LOG=
ENV_JSON=
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

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$FORWARD_PID" ]]; then
        if kill -0 "$FORWARD_PID" 2>/dev/null; then
            kill "$FORWARD_PID" 2>/dev/null || true
        fi
        wait "$FORWARD_PID" 2>/dev/null || true
    fi
    local file
    for file in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        [[ -f "$file" && ! -L "$file" ]] && rm -f -- "$file"
    done
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

private_state() {
    [[ ! -L "$STATE" ]] || die ".local must not be a symlink."
    mkdir -p -- "$STATE"
    chmod 700 "$STATE"
}

new_temp() {
    private_state
    TEMP_FILE=$(mktemp "$STATE/tmp.XXXXXXXX")
    TEMP_FILES+=("$TEMP_FILE")
}

private_file() {
    [[ -f "$1" && ! -L "$1" ]] || die "Expected a regular private file: $1"
    local mode
    if [[ "$(uname -s)" == Darwin ]]; then
        mode=$(stat -f '%Lp' "$1")
    else
        mode=$(stat -c '%a' "$1")
    fi
    [[ "$mode" == 600 ]] || die "Credentials need owner-only permissions: chmod 600 '$1'"
}

load_env() {
    private_file "$ROOT/.env"
    new_temp
    ENV_JSON=$TEMP_FILE
    jq -Rn -f "$ROOT/scripts/env.jq" "$ROOT/.env" >"$ENV_JSON" ||
        die "Cannot parse .env. It must contain literal KEY=value lines, not shell commands."
}

config() {
    [[ -n "$ENV_JSON" ]] || die "Configuration has not been loaded."
    jq -er --arg key "$1" '.[$key] | select(type == "string" and length > 0)' "$ENV_JSON" ||
        die "Missing $1 in .env. Run make foundry-up to complete configuration."
}

save_env() {
    local additions=$1 existing result
    [[ ! -L "$ROOT/.env" ]] || die "Refusing to replace a symlink at .env."
    if git -C "$ROOT" ls-files --error-unmatch .env >/dev/null 2>&1; then
        die ".env is tracked by Git. Remove it from the index before saving credentials."
    fi
    if ! git -C "$ROOT" check-ignore -q --no-index .env; then
        die ".env must be excluded by .gitignore before credentials are written."
    fi
    new_temp; existing=$TEMP_FILE
    if [[ -e "$ROOT/.env" ]]; then
        private_file "$ROOT/.env"
        jq -Rn -f "$ROOT/scripts/env.jq" "$ROOT/.env" >"$existing"
    else
        printf '{}\n' >"$existing"
    fi
    new_temp; result=$TEMP_FILE
    jq -er --slurpfile addition "$additions" '
      . + $addition[0] | to_entries | sort_by(.key)[] |
      if (.key | test("^[A-Z_][A-Z0-9_]*$")) and
         (.value | type == "string" and (test("[\\r\\n]") | not))
      then "\(.key)=\(.value)" else error("Invalid configuration entry") end
    ' "$existing" >"$result"
    chmod 600 "$result"
    mv -f -- "$result" "$ROOT/.env"
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

cluster_exists() {
    local clusters
    clusters=$(kind_local get clusters) || die "Cannot list Kind clusters on Docker Desktop."
    grep -Fxq "$CLUSTER" <<<"$clusters"
}

verify_cluster() {
    need jq
    [[ -f "$STATE/cluster.json" && ! -L "$STATE/cluster.json" ]] ||
        die "No project ownership record. Run make up; an unexplained existing cluster will not be adopted."
    local node expected
    expected=$(jq -er '.nodeId | select(type == "string" and length > 0)' "$STATE/cluster.json") ||
        die "Cluster creation is incomplete. Inspect the named Kind node before recovery."
    node=$(docker_local inspect "$CLUSTER-control-plane") ||
        die "Project node is unavailable. Run make status for the expected cluster."
    jq -e --arg id "$expected" --arg name "$CLUSTER" --arg image "$KIND_IMAGE" \
        --arg port "$KUBERNETES_PORT" '
      length == 1 and .[0].Id == $id and
      .[0].Config.Labels["io.x-k8s.kind.cluster"] == $name and
      .[0].Config.Image == $image and
      .[0].HostConfig.PortBindings["6443/tcp"] ==
        [{"HostIp":"127.0.0.1","HostPort":$port}]
    ' <<<"$node" >/dev/null ||
        die "Kind identity/image/port differs from this project. Refusing to use or delete it."
    jq -e --arg image "$KIND_IMAGE" --argjson port "$KUBERNETES_PORT" \
        '.image == $image and .apiPort == $port' "$STATE/cluster.json" >/dev/null ||
        die "Kind settings changed. Restore the previous settings before explicit teardown."
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

port_free() {
    local result
    if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
        die "Port $1 is occupied. Stop its owner yourself or change ports.env; no process was killed."
    else
        result=$?
        [[ "$result" -eq 1 ]] || die "Cannot inspect port $1 (lsof exit $result)."
    fi
}

start_forward() {
    local port=$1 attempt
    [[ -z "$FORWARD_PID" ]] || die "A request forward is already active in this command."
    port_free "$port"
    new_temp; FORWARD_LOG=$TEMP_FILE
    kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
        -n "$NAMESPACE" port-forward --address 127.0.0.1 \
        "service/$GATEWAY" "$port:80" >"$FORWARD_LOG" 2>&1 &
    FORWARD_PID=$!
    for ((attempt=0; attempt<60; attempt++)); do
        if ! kill -0 "$FORWARD_PID" 2>/dev/null; then
            cat "$FORWARD_LOG" >&2
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

gateway_header() {
    [[ -n "$ENV_JSON" ]] || load_env
    new_temp; HEADER_FILE=$TEMP_FILE
    local key
    key=$(config AGENTGATEWAY_API_KEY)
    [[ "$key" =~ ^[a-f0-9]{64}$ ]] || die "Invalid local gateway API key format."
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
    HTTP_STATUS=$(curl "${args[@]}" --output "$RESPONSE_FILE" --write-out '%{http_code}' "$url") ||
        die "Gateway request failed. No automatic retry was made."
    [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]] || die "curl did not return a valid HTTP status."
}

wait_condition() {
    local resource=$1 condition=$2
    kube -n "$NAMESPACE" wait "$resource" --for="condition=$condition" --timeout=300s ||
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
