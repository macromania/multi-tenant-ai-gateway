#!/bin/bash
set -euo pipefail
if [[ "${1:-help}" == help ]]; then exec 2>&1; fi
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

help_menu() {
    printf '\n%s  MULTI-TENANT AI GATEWAY | DEVELOPMENT%s\n' "$BOLD" "$RESET" >&2
    info "Kind: $CLUSTER   Gateway: http://127.0.0.1:$GATEWAY_PORT"
    section 'LOCAL ENVIRONMENT'
    row 'make up' 'Start Kind and install agentgateway'
    row 'make status' 'Show local readiness and routing'
    row 'make k9s' 'Open K9s using the project kubeconfig'
    row 'make dashboard' 'Expose the read-only gateway UI on localhost'
    row 'make gateway-forward' 'Open local gateway access until Ctrl-C'
    section 'FOUNDRY MODEL'
    row 'make foundry-register' 'Register the Azure service after confirmation'
    row 'make foundry-regions' 'List supported region choices'
    row 'make foundry-models' 'Discover available chat models in REGION'
    row 'make foundry-up' 'Deploy a model and connect the gateway'
    row 'make foundry-status' 'Inspect the owned cloud deployment'
    row 'make endpoints' 'Show URLs, never credentials'
    row 'make gateway-configure' 'Reapply the saved model connection'
    section 'PROMPTING'
    row 'make prompt' 'Send an OpenAI-compatible curl request'
    info ''
    info 'Usage: make prompt PROMPT="Hello from agentgateway"'
    info '       make prompt PROMPT_FILE=prompt.txt FORMAT=json'
    section 'DIAGNOSTICS'
    row 'make doctor' 'Check tools, Docker Desktop, and cloud readiness'
    row 'make check' 'Check the gateway without calling the model'
    row 'make logs' 'Follow proxy logs until Ctrl-C'
    row 'make test' 'Run offline automation tests'
    section 'CLEANUP'
    row 'make down CONFIRM=1' 'Delete only the local project cluster'
    row 'make foundry-down CONFIRM=1' 'Delete only owned Azure resources'
    section 'GETTING STARTED'
    info 'Prerequisites: Docker Desktop, Kind, kubectl, Helm, curl, jq.'
    info 'Cloud setup also needs Azure CLI 2.80+, az login, and quota.'
    info ''
    info 'make doctor -> make up -> make foundry-up -> make prompt'
    info 'Foundry setup guides region selection; REGION=<name> also works.'
    info 'Foundry setup requires deployment confirmation. Model calls can incur charges.'
    info ''
    info 'Guide: docs/local-development.md'
    printf '\n' >&2
}

doctor() {
    section 'PREREQUISITES'
    local tool kind_version
    for tool in docker kind kubectl helm curl jq lsof openssl; do need "$tool"; ok "$tool available"; done
    kind_version=$(kind version)
    [[ "$kind_version" == "kind v$KIND_VERSION "* ]] ||
        die "Expected Kind $KIND_VERSION; found $kind_version. See versions.env."
    [[ "$(docker_local info --format '{{.OperatingSystem}}')" == 'Docker Desktop' ]] ||
        die "Start Docker Desktop. This project does not use Colima or another daemon."
    ok 'Docker Desktop is responsive'
    if cluster_exists; then verify_cluster; ok 'Project cluster identity verified'
    else port_free "$KUBERNETES_PORT"; ok "API port $KUBERNETES_PORT available"; fi
    section 'AZURE READINESS'
    if command -v az >/dev/null 2>&1; then
        info 'Azure CLI is installed. Cloud commands validate login and quota separately.'
    else
        warn 'Azure CLI is missing. Local startup still works; install it before foundry-up.'
    fi
}

record_node() {
    local node id file
    node=$(docker_local inspect "$CLUSTER-control-plane") || return 1
    id=$(jq -er '.[0].Id' <<<"$node") || return 1
    new_temp; file=$TEMP_FILE
    jq --arg node "$id" '.nodeId=$node' "$STATE/cluster.json" >"$file"
    mv -f -- "$file" "$STATE/cluster.json"
}

cluster_up() {
    private_state
    if cluster_exists; then
        verify_cluster
        if [[ ! -f "$KUBECONFIG_FILE" ]]; then
            kind_local export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
            chmod 600 "$KUBECONFIG_FILE"
        fi
        verify_context
        ok 'Reusing the verified project cluster'
        return
    fi
    [[ ! -L "$STATE/cluster.json" ]] || die "Cluster ownership state must not be a symlink."
    port_free "$KUBERNETES_PORT"
    sed "s/KUBERNETES_PORT/$KUBERNETES_PORT/" "$ROOT/deploy/kind.yaml.tmpl" >"$STATE/kind.yaml"
    local file
    new_temp; file=$TEMP_FILE
    jq -n --arg name "$CLUSTER" --arg image "$KIND_IMAGE" --argjson port "$KUBERNETES_PORT" \
        '{name:$name,image:$image,apiPort:$port,nodeId:null}' >"$file"
    mv -f -- "$file" "$STATE/cluster.json"
    if ! kind_local create cluster --name "$CLUSTER" --image "$KIND_IMAGE" \
        --config "$STATE/kind.yaml" --kubeconfig "$KUBECONFIG_FILE" --wait 180s; then
        if record_node; then warn 'Recorded the partial node for explicit inspection/teardown.'; fi
        die "Kind creation failed. No automatic deletion was performed."
    fi
    record_node || die "Cannot record the new Kind node identity."
    chmod 600 "$KUBECONFIG_FILE"
    verify_context
}

gateway_ready() {
    verify_context
    kube -n "$NAMESPACE" rollout status deployment/agentgateway --timeout=300s
    kube -n "$NAMESPACE" rollout status "deployment/$GATEWAY" --timeout=300s
    wait_condition gatewayclass/agentgateway Accepted
    wait_condition "gateway/$GATEWAY" Accepted
    wait_condition "gateway/$GATEWAY" Programmed
    [[ "$(kube -n "$NAMESPACE" get "service/$GATEWAY" -o jsonpath='{.spec.type}')" == ClusterIP ]] ||
        die "The gateway must use a ClusterIP Service."
}

gateway_install() {
    verify_context
    section 'INSTALLING GATEWAY API'
    local crds
    new_temp; crds=$TEMP_FILE
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GATEWAY_API_VERSION/standard-install.yaml" >"$crds"
    kube apply --server-side -f "$crds"
    kube wait crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io \
        --for=condition=Established --timeout=120s
    section 'INSTALLING AGENTGATEWAY'
    helm_local upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
        --version "$AGENTGATEWAY_VERSION" --namespace "$NAMESPACE" --create-namespace --wait --timeout 5m
    kube wait crd/agentgatewayparameters.agentgateway.dev crd/agentgatewaybackends.agentgateway.dev \
        crd/agentgatewaypolicies.agentgateway.dev --for=condition=Established --timeout=120s
    helm_local upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
        --version "$AGENTGATEWAY_VERSION" --namespace "$NAMESPACE" \
        --values "$ROOT/deploy/agentgateway/values.yaml" --wait --timeout 5m
    kube apply -f "$ROOT/deploy/agentgateway/gateway.yaml"
    gateway_ready
}

check_gateway() {
    section 'LOCAL GATEWAY CHECK'
    gateway_ready
    start_forward "$REQUEST_PORT"
    local header=
    if kube -n "$NAMESPACE" get agentgatewaypolicy local-client-auth --ignore-not-found -o name | grep -q .; then
        load_env
        gateway_header; header=$HEADER_FILE
        http_call "http://127.0.0.1:$REQUEST_PORT/v1/chat/completions"
        [[ "$HTTP_STATUS" == 401 ]] || die "Unauthenticated requests must return 401, got $HTTP_STATUS."
        ok 'Gateway rejects requests without the client key'
    fi
    http_call "http://127.0.0.1:$REQUEST_PORT/__gateway_unmatched__" "$header"
    [[ "$HTTP_STATUS" == 404 ]] || die "Expected 404 for an unmatched path, got $HTTP_STATUS."
    ok 'Gateway is responsive; no model request was made'
}

status() {
    section 'PROJECT CONTEXT'
    info "Cluster: $CLUSTER"
    info "Kubeconfig: .local/kubeconfig"
    verify_context
    section 'WORKLOADS'
    kube -n "$NAMESPACE" get pods,services
    section 'ROUTING'
    kube get gatewayclass agentgateway
    kube -n "$NAMESPACE" get gateways,httproutes,agentgatewaybackends,agentgatewaypolicies
    section 'ACCESS'
    info "Run make gateway-forward for http://127.0.0.1:$GATEWAY_PORT"
}

down() {
    section 'LOCAL CLUSTER CLEANUP'
    [[ "${CONFIRM:-}" == 1 ]] || die "This deletes only $CLUSTER. Rerun: make down CONFIRM=1"
    if ! cluster_exists; then
        ok 'Project cluster is already absent'
        return
    fi
    verify_cluster
    kind_local delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
    if cluster_exists; then die "Kind still reports the project cluster after deletion."; fi
    rm -f -- "$KUBECONFIG_FILE" "$STATE/kind.yaml" "$STATE/cluster.json"
    ok 'Deleted only the project cluster'
    warn 'Azure resources and .env are preserved. Cloud cleanup is make foundry-down CONFIRM=1.'
}

case "${1:-help}" in
    help) help_menu ;;
    doctor) doctor ;;
    cluster-up) doctor; cluster_up ;;
    gateway-install) gateway_install ;;
    up)
        doctor
        section 'STARTING PROJECT CLUSTER'; cluster_up
        gateway_install
        if [[ -f "$ROOT/.env" || -f "$STATE/foundry.json" ]]; then
            /bin/bash "$ROOT/scripts/foundry.sh" gateway-restore
        fi
        check_gateway
        section 'READY'
        info 'Use make foundry-up to configure a model, or make prompt if already configured.'
        ;;
    check) check_gateway ;;
    status) status ;;
    k9s)
        need k9s
        verify_context
        section 'K9S'
        info "Context: $CONTEXT | Kubeconfig: .local/kubeconfig"
        exec k9s --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT"
        ;;
    logs) verify_context; kube -n "$NAMESPACE" logs -f "deployment/$GATEWAY" --tail=100 ;;
    dashboard)
        verify_context; port_free "$DASHBOARD_PORT"
        section 'GATEWAY DASHBOARD'
        info "Open http://127.0.0.1:$DASHBOARD_PORT/ui/ in your browser."
        info 'Read-only Kubernetes UI. Keep this command running; Ctrl-C stops forwarding.'
        exec kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
            -n "$NAMESPACE" port-forward --address 127.0.0.1 \
            "deployment/$GATEWAY" "$DASHBOARD_PORT:15000"
        ;;
    gateway-forward)
        verify_context; port_free "$GATEWAY_PORT"
        section 'GATEWAY ACCESS'
        info "http://127.0.0.1:$GATEWAY_PORT/v1 | Ctrl-C stops forwarding"
        kube -n "$NAMESPACE" port-forward --address 127.0.0.1 "service/$GATEWAY" "$GATEWAY_PORT:80"
        ;;
    down) down ;;
    *) die "Unknown command: $1" ;;
esac
