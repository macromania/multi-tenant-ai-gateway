#!/bin/bash
set -euo pipefail
if [[ "${1:-help}" == help ]]; then exec 2>&1; fi
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

LEGACY_CLUSTER=multi-tenant-ai-gateway

help_menu() {
    printf '\n%s  MULTI-TENANT AI GATEWAY | SHARED VERSUS DEDICATED%s\n' "$BOLD" "$RESET" >&2
    info "Clusters: mtag-shared (one gateway for all tenants), mtag-dedicated (one gateway per tenant)"
    info "Every cluster command needs CLUSTER=shared or CLUSTER=dedicated; some accept CLUSTER=both."
    section 'CLUSTERS'
    row 'make up' 'Create or update a cluster and its components'
    row 'make status' 'Show workloads, gateways, and routing (both)'
    row 'make down CONFIRM=1' 'Delete one project cluster'
    section 'TENANTS'
    row 'make tenant-add' 'Add TENANT (optional TOKENS_PER_MINUTE)'
    row 'make tenant-limit' 'Set TOKENS_PER_MINUTE for TENANT or all'
    row 'make tenants' 'List tenants and their limits'
    row 'make tenant-objects' 'Show every object holding TENANT settings'
    row 'make gateway-config' 'Show what the proxy enforces for TENANT'
    row 'make tenant-remove CONFIRM=1' 'Remove TENANT and delete its keys'
    section 'TRAFFIC'
    row 'make prompt' 'Send one chat request as TENANT'
    row 'make load' 'Run PROFILE load as TENANT, with probes'
    info ''
    info 'Usage: make prompt CLUSTER=shared TENANT=tenant-01 PROMPT="Hello"'
    info '       make prompt CLUSTER=shared TENANT=tenant-01 UPSTREAM=mock PROMPT="Hello"'
    info '       make load CLUSTER=shared TENANT=tenant-01 PROFILE=flood DURATION=60s'
    section 'EXPERIMENTS'
    row 'make calibrate' 'Prove k6 and the mock deliver each profile'
    row 'make scenario NAME=...' 'separation, latency, rollout, foundry-smoke'
    row 'make restore' 'Return a cluster to its recorded state'
    section 'OBSERVABILITY'
    row 'make grafana' 'Open Grafana on localhost until Ctrl-C'
    row 'make prometheus' 'Open Prometheus on localhost until Ctrl-C'
    row 'make dashboard' 'Open a proxy admin UI (TENANT in dedicated)'
    row 'make logs' 'Follow proxy logs (TENANT in dedicated)'
    row 'make gateway-forward' 'Open gateway access (TENANT in dedicated)'
    row 'make k9s' 'Open K9s using the cluster kubeconfig'
    section 'FOUNDRY MODEL'
    row 'make foundry-register' 'Register the Azure service after confirmation'
    row 'make foundry-regions' 'List supported region choices'
    row 'make foundry-models' 'Discover available chat models in REGION'
    row 'make foundry-up' 'Deploy the model (no gateway changes)'
    row 'make foundry-status' 'Inspect the owned cloud deployment'
    row 'make gateway-configure' 'Connect a cluster to the saved model'
    row 'make endpoints' 'Show URLs, never credentials'
    section 'DIAGNOSTICS'
    row 'make doctor' 'Check tools, Docker Desktop, and clusters'
    row 'make check' 'Check gateways without calling a model (both)'
    section 'CLEANUP'
    row 'make down CONFIRM=1' 'Delete only the selected project cluster'
    row 'make tenant-remove CONFIRM=1' 'Delete one tenant and its keys'
    row 'make legacy-down CONFIRM=1' 'Delete the retired single-user cluster'
    row 'make foundry-down CONFIRM=1' 'Delete only owned Azure resources'
    section 'GETTING STARTED'
    info 'Prerequisites: Docker Desktop, Kind, kubectl, Helm, curl, jq, OpenSSL, lsof.'
    info 'Cloud setup also needs Azure CLI 2.80+, az login, and quota.'
    info ''
    info 'make doctor'
    info 'make up CLUSTER=shared'
    info 'make up CLUSTER=dedicated'
    info 'make tenant-add CLUSTER=shared TENANT=tenant-01'
    info 'make prompt CLUSTER=shared TENANT=tenant-01 UPSTREAM=mock PROMPT="Hello"'
    info 'make grafana CLUSTER=shared'
    section 'DOCUMENTATION'
    info 'Development guide:     docs/local-development.md'
    info 'Implementation plan:   docs/plans/tenancy-comparison-execplan.md'
    info 'Review findings:       FINDINGS.md'
    printf '\n' >&2
}

tools_ready() {
    local tool kind_version
    for tool in docker kind kubectl helm curl jq lsof openssl; do need "$tool"; ok "$tool available"; done
    kind_version=$(kind version)
    [[ "$kind_version" == "kind v$KIND_VERSION "* ]] ||
        die "Expected Kind $KIND_VERSION; found $kind_version. See versions.env."
    [[ "$(docker_local info --format '{{.OperatingSystem}}')" == 'Docker Desktop' ]] ||
        die "Start Docker Desktop. This project does not use Colima or another daemon."
    ok 'Docker Desktop is responsive'
}

# Converts a docker stats size such as 1.489GiB or 512MiB to bytes.
to_bytes() {
    awk -v value="$1" 'BEGIN {
      n = value; sub(/[A-Za-z]+$/, "", n); unit = value; sub(/^[0-9.]+/, "", unit)
      f = 1; if (unit == "KiB" || unit == "kB") f = 1024; else if (unit == "MiB" || unit == "MB") f = 1048576;
      else if (unit == "GiB" || unit == "GB") f = 1073741824; else if (unit == "TiB") f = 1099511627776;
      printf "%.0f", n * f }'
}

memory_report() {
    local total used=0 name usage bytes free
    total=$(docker_local info --format '{{.MemTotal}}')
    while IFS=$'\t' read -r name usage; do
        [[ -n "$name" ]] || continue
        bytes=$(to_bytes "${usage%% *}")
        used=$((used + bytes))
        case "$name" in *-control-plane) info "Kind node $name uses $(awk -v b="$bytes" 'BEGIN{printf "%.1f GiB", b/1073741824}')" ;; esac
    done < <(docker_local stats --no-stream --format '{{.Name}}\t{{.MemUsage}}')
    free=$((total - used))
    info "Docker Desktop memory: $(awk -v t="$total" -v f="$free" 'BEGIN{printf "%.1f GiB total, %.1f GiB not used by running containers", t/1073741824, f/1073741824}')"
    if [[ "$free" -lt $((6 * 1073741824)) ]]; then
        warn 'Less than 6 GiB remains. A second cluster or large experiments may not fit.'
    else
        ok 'At least 6 GiB of Docker Desktop memory remains'
    fi
}

cluster_readiness() {
    if cluster_exists; then
        verify_cluster
        ok "$KIND_CLUSTER identity verified"
    else
        port_free "$KUBERNETES_PORT"
        ok "$KIND_CLUSTER not created; API port $KUBERNETES_PORT is free"
    fi
}

doctor() {
    section 'PREREQUISITES'
    tools_ready
    section 'DOCKER DESKTOP MEMORY'
    memory_report
    section 'PROJECT CLUSTERS'
    local target
    for target in shared dedicated; do
        CLUSTER=$target; select_cluster; cluster_readiness
    done
    if kind_local get clusters 2>/dev/null | grep -Fxq "$LEGACY_CLUSTER"; then
        warn "The retired single-user cluster $LEGACY_CLUSTER still runs. Remove it with make legacy-down CONFIRM=1."
    fi
    section 'AZURE READINESS'
    if command -v az >/dev/null 2>&1; then
        info 'Azure CLI is installed. Cloud commands validate login and quota separately.'
    else
        warn 'Azure CLI is missing. Local clusters still work; install it before foundry-up.'
    fi
}

record_node() {
    local node id file
    node=$(docker_local inspect "$NODE_NAME") || return 1
    id=$(jq -er '.[0].Id' <<<"$node") || return 1
    new_temp; file=$TEMP_FILE
    jq --arg node "$id" '.nodeId=$node' "$CLUSTER_STATE/cluster.json" >"$file"
    mv -f -- "$file" "$CLUSTER_STATE/cluster.json"
}

cluster_up() {
    private_state
    if cluster_exists; then
        verify_cluster
        if [[ ! -f "$KUBECONFIG_FILE" ]]; then
            kind_local export kubeconfig --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
            chmod 600 "$KUBECONFIG_FILE"
        fi
        verify_context
        ok "Reusing the verified cluster $KIND_CLUSTER"
        return
    fi
    [[ ! -L "$CLUSTER_STATE/cluster.json" ]] || die "Cluster ownership state must not be a symlink."
    port_free "$KUBERNETES_PORT"
    sed "s/KUBERNETES_PORT/$KUBERNETES_PORT/" "$ROOT/deploy/kind.yaml.tmpl" >"$CLUSTER_STATE/kind.yaml"
    local file
    new_temp; file=$TEMP_FILE
    jq -n --arg name "$KIND_CLUSTER" --arg image "$KIND_IMAGE" --argjson port "$KUBERNETES_PORT" \
        '{name:$name,image:$image,apiPort:$port,nodeId:null}' >"$file"
    mv -f -- "$file" "$CLUSTER_STATE/cluster.json"
    if ! kind_local create cluster --name "$KIND_CLUSTER" --image "$KIND_IMAGE" \
        --config "$CLUSTER_STATE/kind.yaml" --kubeconfig "$KUBECONFIG_FILE" --wait 180s; then
        if record_node; then warn 'Recorded the partial node for explicit inspection/teardown.'; fi
        die "Kind creation failed. No automatic deletion was performed."
    fi
    record_node || die "Cannot record the new Kind node identity."
    chmod 600 "$KUBECONFIG_FILE"
    verify_context
}

apply_namespace() {
    local file
    new_temp; file=$TEMP_FILE
    jq -n --arg name "$1" --arg component "$2" \
        '{apiVersion:"v1",kind:"Namespace",metadata:{name:$name,labels:{"gateway.dev/component":$component}}}' >"$file"
    kube_apply -f "$file" >/dev/null
}

install_gateway_api() {
    section 'GATEWAY API'
    local crds
    new_temp; crds=$TEMP_FILE
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GATEWAY_API_VERSION/standard-install.yaml" >"$crds"
    kube apply --server-side -f "$crds"
    kube wait crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io \
        --for=condition=Established --timeout=120s
}

grafana_secret() {
    local password_file="$CLUSTER_STATE/grafana-admin" secret
    if [[ ! -e "$password_file" ]]; then
        openssl rand -hex 24 | tr -d '\n' >"$password_file"
        chmod 600 "$password_file"
    fi
    private_file "$password_file"
    new_temp; secret=$TEMP_FILE
    jq -n --rawfile password "$password_file" --arg namespace "$MONITORING_NAMESPACE" '{
      apiVersion:"v1",kind:"Secret",type:"Opaque",
      metadata:{name:"grafana-admin",namespace:$namespace},
      stringData:{"admin-user":"admin","admin-password":$password}}' >"$secret"
    kube_apply -f "$secret" >/dev/null
}

install_observability() {
    section 'OBSERVABILITY'
    apply_namespace "$MONITORING_NAMESPACE" monitoring
    grafana_secret
    helm_local upgrade --install monitoring oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
        --version "$KUBE_PROMETHEUS_STACK_VERSION" --namespace "$MONITORING_NAMESPACE" \
        --values "$ROOT/deploy/observability/values.yaml" --wait --timeout 10m
    ok 'Prometheus, Grafana, and kube-state-metrics are running'
}

install_agentgateway_crds() {
    section 'AGENTGATEWAY CRDS'
    helm_local upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
        --version "$AGENTGATEWAY_VERSION" --namespace "$NAMESPACE" --create-namespace --wait --timeout 5m
    kube wait crd/agentgatewayparameters.agentgateway.dev crd/agentgatewaybackends.agentgateway.dev \
        crd/agentgatewaypolicies.agentgateway.dev --for=condition=Established --timeout=120s
}

# Sets RENDERED to a temporary copy of a template with its namespace filled in.
# In the dedicated cluster, each tenant namespace gets the current tenant-auth and tenant-telemetry.
update_tenant_policies() {
    local namespace namespaces
    namespaces=$(gateway_namespaces)
    for namespace in $namespaces; do
        migrate_tenant_keys "$namespace"
        render_namespace "$ROOT/deploy/agentgateway/tenant-auth.yaml.tmpl" "$namespace"
        kube_apply -f "$RENDERED" >/dev/null
        render_namespace "$ROOT/deploy/agentgateway/tenant-telemetry.yaml.tmpl" "$namespace"
        kube_apply -f "$RENDERED" >/dev/null
    done
}

render_namespace() {
    new_temp; RENDERED=$TEMP_FILE
    sed "s/@NAMESPACE@/$2/g" "$1" >"$RENDERED"
}

install_shared_gateway() {
    section 'SHARED AGENTGATEWAY'
    helm_local upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
        --version "$AGENTGATEWAY_VERSION" --namespace "$NAMESPACE" \
        --values "$ROOT/deploy/agentgateway/values.yaml" --wait --timeout 5m
    kube_apply -f "$ROOT/deploy/agentgateway/gateway.yaml"
    migrate_tenant_keys "$NAMESPACE"
    render_namespace "$ROOT/deploy/agentgateway/tenant-auth.yaml.tmpl" "$NAMESPACE"
    kube_apply -f "$RENDERED"
    kube_apply -f "$ROOT/deploy/agentgateway/tenant-routing.yaml"
    render_namespace "$ROOT/deploy/agentgateway/tenant-telemetry.yaml.tmpl" "$NAMESPACE"
    kube_apply -f "$RENDERED"
}

install_mock() {
    section 'MOCK UPSTREAM'
    local manifest secret digest existing
    apply_namespace "$MOCK_NAMESPACE" mock-upstream
    kube -n "$MOCK_NAMESPACE" create configmap mock-server \
        --from-file=server.py="$ROOT/deploy/mock/server.py" --dry-run=client -o json | kube_apply -f - >/dev/null
    # Only a successful lookup that finds nothing creates the empty key Secret; an existing one
    # holds the tenants' provider keys and is never overwritten here.
    existing=$(kube -n "$MOCK_NAMESPACE" get secret mock-upstream-keys --ignore-not-found -o name) ||
        die "Cannot read the mock key Secret."
    if [[ -z "$existing" ]]; then
        new_temp; secret=$TEMP_FILE
        jq -n --arg namespace "$MOCK_NAMESPACE" '{apiVersion:"v1",kind:"Secret",type:"Opaque",
          metadata:{name:"mock-upstream-keys",namespace:$namespace},stringData:{keys:""}}' >"$secret"
        kube_apply -f "$secret" >/dev/null
    fi
    digest=$(openssl dgst -sha256 "$ROOT/deploy/mock/server.py" | awk '{print $NF}')
    new_temp; manifest=$TEMP_FILE
    sed -e "s|@SERVER_SHA@|$digest|g" -e "s|@PYTHON_IMAGE@|$PYTHON_IMAGE|g" \
        "$ROOT/deploy/mock/mock.yaml.tmpl" >"$manifest"
    kube_apply -f "$manifest"
    kube -n "$MOCK_NAMESPACE" rollout status deployment/mock --timeout=300s
}

install_dashboards() {
    section 'DASHBOARDS'
    local dashboard rendered
    new_temp; dashboard=$TEMP_FILE
    jq -n --arg cluster "$CLUSTER" -f "$ROOT/deploy/observability/dashboards/tenants.jq" >"$dashboard"
    kube -n "$MONITORING_NAMESPACE" create configmap mtag-dashboard-tenants \
        --from-file=tenants.json="$dashboard" --dry-run=client -o json |
        jq '.metadata.labels={"grafana_dashboard":"1"}' | kube_apply -f - >/dev/null
    new_temp; rendered=$TEMP_FILE
    helm template agentgateway oci://cr.agentgateway.dev/charts/agentgateway --version "$AGENTGATEWAY_VERSION" \
        --namespace "$MONITORING_NAMESPACE" --set monitoring.enabled=true \
        --set monitoring.grafanaDashboard.enabled=true --show-only templates/monitoring.yaml >"$rendered"
    kube create --dry-run=client -o json -f "$rendered" |
        jq 'if .kind == "List" then .items[] else . end | select(.kind == "ConfigMap") |
            .metadata = {name:"mtag-dashboard-agentgateway",namespace:"monitoring",labels:{"grafana_dashboard":"1"}}' |
        kube_apply -f - >/dev/null
    ok 'Tenancy comparison and agentgateway dashboards are loaded'
}

install_loadgen() {
    apply_namespace "$LOAD_NAMESPACE" loadgen
    if compgen -G "$ROOT/deploy/k6/*.js" >/dev/null; then
        kube -n "$LOAD_NAMESPACE" create configmap k6-scripts --from-file="$ROOT/deploy/k6" \
            --dry-run=client -o json | kube_apply -f - >/dev/null
    fi
}

gateway_install() {
    verify_context
    install_gateway_api
    install_observability
    install_agentgateway_crds
    if [[ "$CLUSTER" == shared ]]; then install_shared_gateway; else update_tenant_policies; fi
    install_mock
    install_dashboards
    install_loadgen
    gateway_ready
}

tenant_gateway_ready() {
    local namespace=$1 controller
    controller=$(kube -n "$namespace" get deployment -l "app.kubernetes.io/name=agentgateway,app.kubernetes.io/instance=agw-$namespace" \
        -o jsonpath='{.items[0].metadata.name}')
    [[ -n "$controller" ]] || die "No agentgateway controller in $namespace."
    kube -n "$namespace" rollout status "deployment/$controller" --timeout=300s
    kube -n "$namespace" rollout status "deployment/$GATEWAY" --timeout=300s
    wait_condition "$namespace" "gatewayclass/agw-$namespace" Accepted
    wait_condition "$namespace" "gateway/$GATEWAY" Programmed
    wait_status "$namespace" agentgatewaypolicy/tenant-auth policy Accepted
}

shared_components_ready() {
    kube wait crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io \
        crd/agentgatewaypolicies.agentgateway.dev crd/agentgatewaybackends.agentgateway.dev \
        crd/podmonitors.monitoring.coreos.com --for=condition=Established --timeout=120s >/dev/null
    kube -n "$MONITORING_NAMESPACE" rollout status deployment/prometheus-operator --timeout=300s
    kube -n "$MONITORING_NAMESPACE" rollout status deployment/kube-state-metrics --timeout=300s
    kube -n "$MONITORING_NAMESPACE" rollout status statefulset/prometheus-monitoring --timeout=300s
    kube -n "$MONITORING_NAMESPACE" rollout status deployment/grafana --timeout=300s
    kube -n "$MOCK_NAMESPACE" rollout status deployment/mock --timeout=300s
}

gateway_ready() {
    verify_context
    shared_components_ready
    if [[ "$CLUSTER" == shared ]]; then
        kube -n "$NAMESPACE" rollout status deployment/agentgateway --timeout=300s
        kube -n "$NAMESPACE" rollout status "deployment/$GATEWAY" --timeout=300s
        wait_condition "$NAMESPACE" gatewayclass/agentgateway Accepted
        wait_condition "$NAMESPACE" "gateway/$GATEWAY" Accepted
        wait_condition "$NAMESPACE" "gateway/$GATEWAY" Programmed
        wait_status "$NAMESPACE" agentgatewaypolicy/tenant-auth policy Accepted
        wait_status "$NAMESPACE" agentgatewaypolicy/tenant-routing policy Accepted
        wait_status "$NAMESPACE" agentgatewaypolicy/tenant-telemetry policy Accepted
    fi
    local namespace namespaces
    namespaces=$(gateway_namespaces)
    if [[ "$CLUSTER" == dedicated ]]; then
        for namespace in $namespaces; do tenant_gateway_ready "$namespace"; done
    fi
    for namespace in $namespaces; do
        [[ "$(kube -n "$namespace" get "service/$GATEWAY" -o jsonpath='{.spec.type}')" == ClusterIP ]] ||
            die "The gateway in $namespace must use a ClusterIP Service."
    done
}

check_gateway() {
    section "GATEWAY CHECK | $(printf '%s' "$CLUSTER" | tr '[:lower:]' '[:upper:]')"
    gateway_ready
    local namespaces namespace tenant tenants checked=0
    namespaces=$(gateway_namespaces)
    load_tenant_env
    if [[ -z "$namespaces" ]]; then
        ok 'No tenant gateways exist yet; shared components are ready'
        return
    fi
    for namespace in $namespaces; do
        start_forward "$REQUEST_PORT" "$namespace" "service/$GATEWAY" 80
        http_call "http://127.0.0.1:$REQUEST_PORT/v1/chat/completions"
        [[ "$HTTP_STATUS" == 401 ]] || die "$namespace: requests without a key must get 401, got $HTTP_STATUS."
        ok "$namespace rejects requests without a key"
        tenants=$(tenants_served_by "$namespace")
        for tenant in $tenants; do
            tenant_header "$tenant"
            http_call "http://127.0.0.1:$REQUEST_PORT/__gateway_unmatched__" "$HEADER_FILE"
            [[ "$HTTP_STATUS" == 404 ]] || die "$tenant: expected 404 for an unmatched path, got $HTTP_STATUS."
            ok "$tenant key is accepted by its gateway"
            checked=$((checked + 1))
        done
        stop_forward
    done
    ok "Gateways are responsive; $checked tenant keys checked; no model request was made"
}

status() {
    section "PROJECT CONTEXT | $KIND_CLUSTER"
    info "Kubeconfig: .local/$CLUSTER/kubeconfig   Context: $CONTEXT"
    if ! cluster_exists; then warn "$KIND_CLUSTER does not exist. Run make up CLUSTER=$CLUSTER."; return; fi
    verify_context
    section 'WORKLOADS'
    kube get pods -A -l 'app.kubernetes.io/name in (agentgateway,agentgateway-proxy,mock,grafana,prometheus,kube-state-metrics,kube-prometheus-stack-prometheus-operator)' \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
    section 'GATEWAYS AND ROUTING'
    kube get gatewayclass
    kube get gateways,httproutes,agentgatewaybackends,agentgatewaypolicies -A
    section 'TENANTS'
    local tenants
    tenants=$(tenant_list)
    if [[ -z "$tenants" ]]; then info 'No tenants yet.'; else printf '  %s\n' $tenants >&2; fi
    section 'ACCESS'
    info "Grafana: make grafana CLUSTER=$CLUSTER (http://127.0.0.1:$GRAFANA_PORT)"
    info "Gateway: make gateway-forward CLUSTER=$CLUSTER (http://127.0.0.1:$GATEWAY_PORT)"
}

down() {
    section "CLUSTER CLEANUP | $KIND_CLUSTER"
    [[ "${CONFIRM:-}" == 1 ]] || die "This deletes only $KIND_CLUSTER. Rerun: make down CLUSTER=$CLUSTER CONFIRM=1"
    if ! cluster_exists; then
        ok "$KIND_CLUSTER is already absent"
        return
    fi
    verify_cluster
    [[ ! -e "$CLUSTER_STATE/experiment.json" ]] ||
        warn 'An experiment recovery journal exists; it is removed with the cluster.'
    kind_local delete cluster --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
    if cluster_exists; then die "Kind still reports $KIND_CLUSTER after deletion."; fi
    rm -rf -- "$CLUSTER_STATE"
    ok "Deleted only $KIND_CLUSTER"
    warn 'Azure resources, .env, and this cluster'"'"'s keys in .env.tenants are preserved.'
}

legacy_down() {
    section "RETIRING THE SINGLE-USER CLUSTER | $LEGACY_CLUSTER"
    [[ "${CONFIRM:-}" == 1 ]] || die "This deletes only $LEGACY_CLUSTER. Rerun: make legacy-down CONFIRM=1"
    CLUSTER=legacy
    KIND_CLUSTER=$LEGACY_CLUSTER
    CONTEXT="kind-$LEGACY_CLUSTER"
    CLUSTER_STATE="$STATE/legacy"
    KUBECONFIG_FILE="$CLUSTER_STATE/kubeconfig"
    NODE_NAME="$LEGACY_CLUSTER-control-plane"
    KUBERNETES_PORT=$LEGACY_KUBERNETES_PORT
    local additions
    if cluster_exists; then
        verify_cluster
        kind_local delete cluster --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
        if cluster_exists; then die "Kind still reports $KIND_CLUSTER after deletion."; fi
        ok "Deleted $LEGACY_CLUSTER"
    else
        ok "$LEGACY_CLUSTER is already absent"
    fi
    rm -rf -- "$CLUSTER_STATE"
    # Later temporary files must not recreate the deleted state directory.
    CLUSTER_STATE=
    if [[ -f "$ROOT/.env" ]]; then
        new_temp; additions=$TEMP_FILE
        printf '{"AGENTGATEWAY_BASE_URL":null,"AGENTGATEWAY_API_KEY":null}\n' >"$additions"
        save_env "$additions"
        ok 'Removed the single-user gateway key from .env'
    fi
}

tenant_scope_namespace() {
    if [[ "$CLUSTER" == dedicated ]]; then
        validate_tenant "${TENANT:-}"
        printf '%s' "$TENANT"
    else
        printf '%s' "$NAMESPACE"
    fi
}

case "${1:-help}" in
    help) help_menu ;;
    doctor) doctor ;;
    legacy-down) section 'PREREQUISITES'; tools_ready; legacy_down ;;
    status) select_cluster_or_both dev.sh "$@"; status ;;
    check) select_cluster_or_both dev.sh "$@"; check_gateway ;;
    *)
        select_cluster
        case "$1" in
            cluster-up) section 'PREREQUISITES'; tools_ready; cluster_up ;;
            gateway-install) gateway_install ;;
            up)
                section 'PREREQUISITES'; tools_ready
                section 'DOCKER DESKTOP MEMORY'; memory_report
                section "STARTING $KIND_CLUSTER"; cluster_up
                gateway_install
                if [[ -f "$STATE/foundry.json" ]]; then
                    CLUSTER=$CLUSTER /bin/bash "$ROOT/scripts/foundry.sh" gateway-restore
                fi
                check_gateway
                section 'READY'
                info "Grafana: make grafana CLUSTER=$CLUSTER"
                ;;
            k9s)
                need k9s
                verify_context
                section 'K9S'
                info "Context: $CONTEXT | Kubeconfig: .local/$CLUSTER/kubeconfig"
                exec k9s --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT"
                ;;
            logs)
                verify_context
                namespace=$(tenant_scope_namespace)
                kube -n "$namespace" logs -f "deployment/$GATEWAY" --tail=100
                ;;
            dashboard)
                verify_context; port_free "$DASHBOARD_PORT"
                namespace=$(tenant_scope_namespace)
                section "GATEWAY ADMIN UI | $namespace"
                info "Open http://127.0.0.1:$DASHBOARD_PORT/ui/ in your browser."
                info 'Keep this command running; Ctrl-C stops forwarding.'
                exec kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
                    -n "$namespace" port-forward --address 127.0.0.1 \
                    "deployment/$GATEWAY" "$DASHBOARD_PORT:15000"
                ;;
            gateway-forward)
                verify_context; port_free "$GATEWAY_PORT"
                namespace=$(tenant_scope_namespace)
                section "GATEWAY ACCESS | $namespace"
                info "http://127.0.0.1:$GATEWAY_PORT/v1 | Ctrl-C stops forwarding"
                exec kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
                    -n "$namespace" port-forward --address 127.0.0.1 \
                    "service/$GATEWAY" "$GATEWAY_PORT:80"
                ;;
            grafana)
                verify_context; port_free "$GRAFANA_PORT"
                section "GRAFANA | $KIND_CLUSTER"
                info "Open http://127.0.0.1:$GRAFANA_PORT/d/mtag-tenants in your browser."
                info "Viewing needs no login. Admin user: admin; password file: .local/$CLUSTER/grafana-admin"
                info 'Keep this command running; Ctrl-C stops forwarding.'
                exec kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
                    -n "$MONITORING_NAMESPACE" port-forward --address 127.0.0.1 service/grafana "$GRAFANA_PORT:80"
                ;;
            prometheus)
                verify_context; port_free "$PROMETHEUS_PORT"
                section "PROMETHEUS | $KIND_CLUSTER"
                info "Open http://127.0.0.1:$PROMETHEUS_PORT in your browser."
                info 'Keep this command running; Ctrl-C stops forwarding.'
                exec kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" \
                    -n "$MONITORING_NAMESPACE" port-forward --address 127.0.0.1 \
                    service/monitoring-prometheus "$PROMETHEUS_PORT:9090"
                ;;
            down) down ;;
            *) die "Unknown command: $1" ;;
        esac
        ;;
esac
