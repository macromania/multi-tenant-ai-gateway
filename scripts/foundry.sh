#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

RECORD="$STATE/foundry.json"
ARM_VERSION=2025-06-01
SUBSCRIPTION=
SUBSCRIPTION_NAME=
CANDIDATES=
REGIONS_FILE=

azure() { az "$@" --subscription "$SUBSCRIPTION" --only-show-errors; }
saved() { jq -er --arg key "$1" '.[$key] | select(. != null)' "$RECORD"; }

validate_record() {
    private_file "$RECORD"
    jq -e '
      (.owner | test("^[a-f0-9]{32}$")) and
      (.subscription | test("^[a-fA-F0-9-]{36}$")) and
      (.region | test("^[a-z][a-z0-9]+$")) and
      .group == ("rg-mtag-" + .owner[0:8]) and
      .account == ("ai-mtag-" + .owner[0:8]) and
      .project == "gateway-dev" and .deployment == "gateway-chat" and
      (.model | test("^gpt-[a-zA-Z0-9.-]+$")) and
      (.version | test("^[a-zA-Z0-9.-]+$")) and
      (.sku == "Standard" or .sku == "GlobalStandard") and
      (.capacity | type == "number" and . > 0 and floor == .) and
      .groupId == ("/subscriptions/" + .subscription + "/resourceGroups/" + .group) and
      .accountId == (.groupId + "/providers/Microsoft.CognitiveServices/accounts/" + .account) and
      .projectId == (.accountId + "/projects/" + .project) and
      .deploymentId == (.accountId + "/deployments/" + .deployment) and
      (.phase | IN("planned","provisioned","configured","cloud-deleted","deleted"))
    ' "$RECORD" >/dev/null || die "Invalid Foundry ownership record. Refusing cloud operations."
}

phase() {
    local file
    new_temp; file=$TEMP_FILE
    jq --arg phase "$1" '.phase=$phase' "$RECORD" >"$file"
    mv -f -- "$file" "$RECORD"
}

azure_context() {
    need az; need jq
    local account version
    version=$(az version --output json)
    jq -e '.["azure-cli"] | split(".") | map(tonumber) |
      .[0] > 2 or (.[0] == 2 and .[1] >= 80)' <<<"$version" >/dev/null ||
        die "Azure CLI 2.80 or later is required. Upgrade explicitly before proceeding."
    [[ "$(az cloud show --query name --output tsv)" == AzureCloud ]] ||
        die "This development workflow supports AzureCloud, not a sovereign-cloud endpoint."
    account=$(az account show --output json) || die "Azure login is required. Run az login."
    jq -e '.state == "Enabled" and (.id | test("^[a-fA-F0-9-]{36}$"))' <<<"$account" >/dev/null ||
        die "The current Azure subscription is not enabled."
    SUBSCRIPTION=$(jq -r .id <<<"$account")
    SUBSCRIPTION_NAME=$(jq -r .name <<<"$account")
    if [[ -e "$RECORD" ]]; then
        validate_record
        if [[ "$(saved phase)" != deleted && "$(saved subscription)" != "$SUBSCRIPTION" ]]; then
            die "Current subscription differs from the saved project. Select the original subscription explicitly."
        fi
    fi
    section 'AZURE SUBSCRIPTION'
    info "$SUBSCRIPTION_NAME"
    info "$SUBSCRIPTION"
}

registration_state() {
    azure provider show --namespace Microsoft.CognitiveServices --query registrationState --output tsv
}

require_registered() {
    local status
    status=$(registration_state)
    [[ "$status" == Registered ]] ||
        die "Microsoft.CognitiveServices is $status. Run make foundry-register, then retry."
}

register_provider() {
    azure_context
    section 'REGISTERING THE FOUNDRY SERVICE'
    if [[ "$(registration_state)" == Registered ]]; then ok 'Service is already registered'; return; fi
    info 'Register Microsoft.CognitiveServices in the subscription shown above.'
    info 'This enables the service; it does not create an account or deploy a model.'
    confirm_action
    azure provider register --namespace Microsoft.CognitiveServices --output none
    local attempt status
    for ((attempt=0; attempt<60; attempt++)); do
        status=$(registration_state)
        if [[ "$status" == Registered ]]; then
            ok 'Microsoft.CognitiveServices is registered'
            info 'Next: make foundry-up (guides region and model selection).'
            return
        fi
        sleep 5
    done
    die "Registration is still $status. Rerun make foundry-register to check it; no model was created."
}

read_regions() {
    local locations provider
    new_temp; locations=$TEMP_FILE
    new_temp; provider=$TEMP_FILE
    azure rest --method get \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION/locations?api-version=2022-12-01" \
        --query value --output json >"$locations"
    azure provider show --namespace Microsoft.CognitiveServices --output json >"$provider"
    new_temp; REGIONS_FILE=$TEMP_FILE
    jq --slurpfile provider "$provider" '
      [$provider[0].resourceTypes[] | select(.resourceType=="accounts") | .locations[]] as $supported |
      [.[] | select(.displayName as $name | $supported | index($name)) |
        {name,displayName}] | sort_by(.name)
    ' "$locations" >"$REGIONS_FILE"
    jq -e 'length > 0' "$REGIONS_FILE" >/dev/null ||
        die "Azure did not return supported Cognitive Services regions."
}

show_regions() {
    section 'AZURE REGION CHOICES'
    jq -r '.[] | [.name,.displayName] | @tsv' "$REGIONS_FILE" |
        while IFS=$'\t' read -r name display; do row "$name" "$display"; done
    info ''
    info 'These regions support Cognitive Services; model availability is checked separately.'
}

select_region() {
    read_regions
    if [[ -z "${REGION:-}" ]]; then
        show_regions
        [[ -t 0 ]] || die "Choose a region: make foundry-up REGION=<name> (or run it interactively)."
        printf '\n  Enter the region name: ' >&2
        IFS= read -r REGION
    fi
    jq -e --arg region "$REGION" 'any(.[]; .name == $region)' "$REGIONS_FILE" >/dev/null ||
        die "Unsupported region '$REGION'. Run make foundry-regions."
}

discover_models() {
    local catalog usage models row model version sku usage_name capacity quota platform available result
    require_registered
    select_region
    section 'CHECKING MODEL AVAILABILITY'
    info "Region: $REGION"
    new_temp; catalog=$TEMP_FILE
    new_temp; usage=$TEMP_FILE
    new_temp; models=$TEMP_FILE
    new_temp; result=$TEMP_FILE
    azure cognitiveservices model list --location "$REGION" --output json >"$catalog"
    azure cognitiveservices usage list --location "$REGION" --output json >"$usage"
    jq -f "$ROOT/scripts/models.jq" "$catalog" >"$models"
    [[ "$(jq length "$usage")" -gt 0 ]] ||
        die "No subscription quota entries were returned. Check service registration and Azure quota access."
    while IFS= read -r row; do
        model=$(jq -r .model <<<"$row"); version=$(jq -r .version <<<"$row")
        sku=$(jq -r .sku <<<"$row"); usage_name=$(jq -r .usageName <<<"$row")
        capacity=$(jq -r .suggestedCapacity <<<"$row")
        quota=$(jq -er --arg name "$usage_name" '
          [.[] | select(.name.value==$name) | (.limit - .currentValue)] |
          if length==1 then .[0] else 0 end
        ' "$usage")
        if [[ "$quota" -lt "$capacity" ]]; then
            warn "$model $version $sku: insufficient quota ($quota units available)"
            continue
        fi
        new_temp; platform=$TEMP_FILE
        azure rest --method get --url \
            "https://management.azure.com/subscriptions/$SUBSCRIPTION/providers/Microsoft.CognitiveServices/modelCapacities?api-version=2024-10-01&modelFormat=OpenAI&modelName=$model&modelVersion=$version" \
            --output json >"$platform"
        if jq -e '.nextLink != null' "$platform" >/dev/null; then
            die "Capacity response is paginated; no incomplete availability result will be used."
        fi
        available=$(jq -r --arg region "$REGION" --arg sku "$sku" '
          [.value[] | select((.location|ascii_downcase)==$region and .properties.skuName==$sku) |
            .properties.availableCapacity | select(type=="number")] | min // 0
        ' "$platform")
        if ! jq -en --argjson available "$available" --argjson capacity "$capacity" '$available >= $capacity' >/dev/null; then
            warn "$model $version $sku: platform capacity unavailable"
            continue
        fi
        jq -c --argjson quota "$quota" --argjson available "$available" \
            '. + {quota:$quota,available:$available}' <<<"$row" >>"$result"
    done < <(jq -c '.[]' "$models")
    new_temp; CANDIDATES=$TEMP_FILE
    jq -s '.' "$result" >"$CANDIDATES"
    jq -e 'length > 0' "$CANDIDATES" >/dev/null ||
        die "No generally available GPT chat model passed quota and capacity checks in $REGION."
    section 'AVAILABLE CHAT MODELS'
    local index=0
    while IFS= read -r row; do
        index=$((index+1))
        info "$index. $(jq -r '[.model,.version,.sku] | join(" / ")' <<<"$row")"
        info "   Suggested capacity: $(jq -r .suggestedCapacity <<<"$row") units; quota: $(jq -r .quota <<<"$row")"
    done < <(jq -c '.[]' "$CANDIDATES")
    info ''
    info 'Suggestions use the published minimum, or the service default when no minimum is returned.'
    info 'Capacity is a rate allocation, not a spending cap. No model has been deployed.'
}

choose_model() {
    local selection row count
    count=$(jq length "$CANDIDATES")
    if [[ -n "${MODEL:-}" ]]; then
        [[ -n "${MODEL_VERSION:-}" && -n "${SKU:-}" && -n "${CAPACITY:-}" ]] ||
            die "Explicit selection requires MODEL, MODEL_VERSION, SKU, CAPACITY, and REGION."
        row=$(jq -ec --arg model "$MODEL" --arg version "$MODEL_VERSION" --arg sku "$SKU" '
          [.[] | select(.model==$model and .version==$version and .sku==$sku)] |
          if length==1 then .[0] else error("Selection is not an available candidate") end
        ' "$CANDIDATES") || die "The requested model/version/SKU is not an available candidate."
    else
        [[ -t 0 ]] || die "Choose interactively or supply MODEL, MODEL_VERSION, SKU, CAPACITY, REGION, CONFIRM=1."
        printf '\n  Model number [1-%s]: ' "$count" >&2
        IFS= read -r selection
        [[ "$selection" =~ ^[1-9][0-9]*$ && "$selection" -le "$count" ]] || die "Invalid model selection."
        row=$(jq -c --argjson index "$((selection-1))" '.[$index]' "$CANDIDATES")
        MODEL=$(jq -r .model <<<"$row"); MODEL_VERSION=$(jq -r .version <<<"$row")
        SKU=$(jq -r .sku <<<"$row"); CAPACITY=$(jq -r .suggestedCapacity <<<"$row")
    fi
    [[ "$CAPACITY" =~ ^[1-9][0-9]*$ ]] || die "CAPACITY must be a positive integer."
    jq -e --argjson n "$CAPACITY" '
      $n <= .quota and $n <= .available and (.maximum == null or $n <= .maximum) and
      (.allowed == null or (.allowed | index($n)) != null) and
      (.step == null or ($n % .step)==0)
    ' <<<"$row" >/dev/null || die "Capacity does not fit the advertised SKU/quota/platform limits."
}

new_record() {
    local owner group account file
    owner=$(openssl rand -hex 16)
    group="rg-mtag-${owner:0:8}"; account="ai-mtag-${owner:0:8}"
    section 'CONFIRM FOUNDRY DEPLOYMENT'
    info "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION)"
    info "Region: $REGION"
    info "Resource group: $group"
    info "Foundry account/project: $account / gateway-dev"
    info "Model: $MODEL / $MODEL_VERSION"
    info "Deployment: gateway-chat | $SKU | $CAPACITY capacity units"
    info 'Network: public authenticated HTTPS. Authentication: API key for local Kind.'
    warn 'Account policy exception: SecurityControl=Ignore (this Foundry account only).'
    [[ "$SKU" != GlobalStandard ]] || warn 'GlobalStandard can process requests outside the resource region.'
    warn 'Model calls are billable. This is not a spending cap or a free deployment tier.'
    info 'Pricing: https://azure.microsoft.com/pricing/details/cognitive-services/openai-service/'
    info 'No inference request is sent automatically. Use make prompt explicitly after setup.'
    confirm_action
    private_state
    if [[ -f "$RECORD" ]]; then
        [[ "$(saved phase)" == deleted ]] || die "An active resource generation already exists."
        cp -p -- "$RECORD" "$STATE/foundry-history-$(saved owner).json"
    fi
    new_temp; file=$TEMP_FILE
    jq -n --arg owner "$owner" --arg subscription "$SUBSCRIPTION" --arg region "$REGION" \
        --arg group "$group" --arg account "$account" --arg model "$MODEL" \
        --arg version "$MODEL_VERSION" --arg sku "$SKU" --argjson capacity "$CAPACITY" '
      {owner:$owner,subscription:$subscription,region:$region,group:$group,account:$account,
       project:"gateway-dev",deployment:"gateway-chat",model:$model,version:$version,
       sku:$sku,capacity:$capacity,phase:"planned"} |
      .groupId="/subscriptions/\(.subscription)/resourceGroups/\(.group)" |
      .accountId="\(.groupId)/providers/Microsoft.CognitiveServices/accounts/\(.account)" |
      .projectId="\(.accountId)/projects/\(.project)" |
      .deploymentId="\(.accountId)/deployments/\(.deployment)"
    ' >"$file"
    mv -f -- "$file" "$RECORD"
    validate_record
}

owned_group() {
    local group
    group=$(azure group show --name "$(saved group)" --output json)
    jq -e --arg owner "$(saved owner)" --arg id "$(saved groupId)" \
        '.tags.agentgatewayProjectId==$owner and (.id|ascii_downcase)==($id|ascii_downcase)' <<<"$group" >/dev/null ||
        die "Resource-group identity/ownership mismatch. No resources will be adopted."
}

owned_account() {
    local account
    account=$(azure cognitiveservices account show --name "$(saved account)" --resource-group "$(saved group)" --output json)
    jq -e --arg owner "$(saved owner)" --arg region "$(saved region)" --arg id "$(saved accountId)" '
      .tags.agentgatewayProjectId==$owner and (.id|ascii_downcase)==($id|ascii_downcase) and
      .kind=="AIServices" and (.location|ascii_downcase)==$region and
      .properties.allowProjectManagement==true and
      .properties.publicNetworkAccess=="Enabled" and
      (.properties.networkAcls.defaultAction // "Allow")=="Allow"
    ' <<<"$account" >/dev/null || die "Foundry account settings/ownership differ. No security settings were changed."
    if ! jq -e '.properties.disableLocalAuth==false' <<<"$account" >/dev/null; then
        die "Foundry account reports disableLocalAuth=$(jq -c '.properties.disableLocalAuth' <<<"$account"). API-key mode requires false; check the account's approved policy exception. No security settings were changed."
    fi
}

wait_azure() {
    local id=$1 attempt status
    for ((attempt=0; attempt<60; attempt++)); do
        status=$(azure rest --method get --url "https://management.azure.com$id?api-version=$ARM_VERSION" \
            --query properties.provisioningState --output tsv)
        case "$status" in
            Succeeded) return ;;
            Failed|Canceled|Cancelled) die "Azure provisioning $status for $id. Resources were retained." ;;
            '') die "Azure returned no provisioning state for $id." ;;
        esac
        sleep 5
    done
    die "Provisioning timed out for $id (last state: $status). Rerun to resume; no fallback occurred."
}

put_resource() {
    azure rest --method put --url "https://management.azure.com$1?api-version=$ARM_VERSION" \
        --body "@$2" --query '{id:id,state:properties.provisioningState}' --output json
    wait_azure "$1"
}

provision() {
    local exists accounts projects deployments payload
    section 'PROVISIONING OWNED FOUNDRY RESOURCES'
    exists=$(azure group exists --name "$(saved group)" --output tsv)
    case "$exists" in
        false) azure group create --name "$(saved group)" --location "$(saved region)" \
            --tags "agentgatewayProjectId=$(saved owner)" project=multi-tenant-ai-gateway \
            --query '{id:id,state:properties.provisioningState}' --output json ;;
        true) ;;
        *) die "Unexpected resource group existence response." ;;
    esac
    owned_group
    accounts=$(azure cognitiveservices account list --resource-group "$(saved group)" --output json)
    if [[ "$(jq length <<<"$accounts")" == 0 ]]; then
        new_temp; payload=$TEMP_FILE
        jq '{location:.region,kind:"AIServices",sku:{name:"S0"},identity:{type:"SystemAssigned"},
          tags:{agentgatewayProjectId:.owner,project:"multi-tenant-ai-gateway",SecurityControl:"Ignore"},
          properties:{allowProjectManagement:true,customSubDomainName:.account,
            publicNetworkAccess:"Enabled",disableLocalAuth:false,networkAcls:{defaultAction:"Allow"}}}' \
            "$RECORD" >"$payload"
        put_resource "$(saved accountId)" "$payload"
    else
        jq -e --arg account "$(saved account)" 'length==1 and .[0].name==$account' <<<"$accounts" >/dev/null ||
            die "Unexpected accounts in the owned resource group. Refusing to proceed."
    fi
    owned_account
    projects=$(azure cognitiveservices account project list --name "$(saved account)" \
        --resource-group "$(saved group)" --output json)
    if [[ "$(jq length <<<"$projects")" == 0 ]]; then
        new_temp; payload=$TEMP_FILE
        jq '{location:.region,identity:{type:"SystemAssigned"},properties:{}}' "$RECORD" >"$payload"
        put_resource "$(saved projectId)" "$payload"
    else
        jq -e --arg project "$(saved projectId)" \
            'length==1 and (.[0].id|ascii_downcase)==($project|ascii_downcase)' <<<"$projects" >/dev/null ||
            die "Unexpected Foundry projects; the first/default project cannot be assumed."
    fi
    deployments=$(azure cognitiveservices account deployment list --name "$(saved account)" \
        --resource-group "$(saved group)" --output json)
    if [[ "$(jq length <<<"$deployments")" == 0 ]]; then
        new_temp; payload=$TEMP_FILE
        jq '{sku:{name:.sku,capacity:.capacity},properties:{
          model:{format:"OpenAI",name:.model,version:.version},versionUpgradeOption:"NoAutoUpgrade"}}' \
            "$RECORD" >"$payload"
        put_resource "$(saved deploymentId)" "$payload"
    else
        jq -e --slurpfile state "$RECORD" '
          length==1 and (.[0].id|ascii_downcase)==($state[0].deploymentId|ascii_downcase) and
          .[0].properties.model.name==$state[0].model and
          .[0].properties.model.version==$state[0].version and
          .[0].sku.name==$state[0].sku and .[0].sku.capacity==$state[0].capacity and
          .[0].properties.versionUpgradeOption=="NoAutoUpgrade"
        ' <<<"$deployments" >/dev/null || die "Existing deployment differs from the approved selection."
    fi
    wait_azure "$(saved projectId)"
    wait_azure "$(saved deploymentId)"
    phase provisioned
    ok 'Account, default project, and model deployment are provisioned'
}

persist_config() {
    local project_doc project_endpoint expected key additions
    new_temp; project_doc=$TEMP_FILE
    azure cognitiveservices account project show --name "$(saved account)" --resource-group "$(saved group)" \
        --project-name "$(saved project)" --output json >"$project_doc"
    expected="https://$(saved account).services.ai.azure.com/api/projects/$(saved project)"
    project_endpoint=$(jq -er --arg expected "$expected" '
      [.properties.endpoints[]?, .properties.endpoint?] |
      map(select(type=="string") | rtrimstr("/")) |
      map(select(.==$expected)) | unique |
      if length==1 then .[0] else error("Expected Foundry project endpoint missing") end
    ' "$project_doc") || die "Azure did not advertise the expected project endpoint; no URL was guessed."
    new_temp; key=$TEMP_FILE
    azure cognitiveservices account keys list --name "$(saved account)" --resource-group "$(saved group)" \
        --query key1 --output tsv >"$key"
    jq -eRs 'rtrimstr("\n") | test("^[A-Za-z0-9+/=_-]{16,}$")' "$key" >/dev/null ||
        die "Azure key retrieval returned an invalid value."
    new_temp; additions=$TEMP_FILE
    jq --arg endpoint "$project_endpoint" --rawfile key "$key" '{
      AZURE_SUBSCRIPTION_ID:.subscription,AZURE_RESOURCE_GROUP:.group,AZURE_LOCATION:.region,
      AZURE_FOUNDRY_RESOURCE_NAME:.account,AZURE_FOUNDRY_PROJECT_NAME:.project,
      AZURE_FOUNDRY_PROJECT_ENDPOINT:$endpoint,AZURE_MODEL_BASE_URL:($endpoint+"/openai/v1"),
      AZURE_MODEL_DEPLOYMENT:.deployment,AZURE_MODEL_NAME:.model,AZURE_MODEL_VERSION:.version,
      AZURE_MODEL_SKU:.sku,AZURE_MODEL_CAPACITY:(.capacity|tostring),
      AZURE_API_KEY:($key|rtrimstr("\n"))
    }' "$RECORD" >"$additions"
    save_env "$additions"
    ok 'Saved protected configuration to .env (credentials are not displayed)'
}

validate_connection() {
    validate_record
    [[ "$(saved phase)" == provisioned || "$(saved phase)" == configured ]] ||
        die "The recorded Foundry generation has not been provisioned or has been retired."
    load_env
    jq -e --slurpfile state "$RECORD" '
      .AZURE_SUBSCRIPTION_ID==$state[0].subscription and
      .AZURE_RESOURCE_GROUP==$state[0].group and .AZURE_LOCATION==$state[0].region and
      .AZURE_FOUNDRY_RESOURCE_NAME==$state[0].account and
      .AZURE_FOUNDRY_PROJECT_NAME==$state[0].project and
      .AZURE_MODEL_DEPLOYMENT==$state[0].deployment and
      .AZURE_MODEL_NAME==$state[0].model and .AZURE_MODEL_VERSION==$state[0].version and
      .AZURE_MODEL_SKU==$state[0].sku and .AZURE_MODEL_CAPACITY==($state[0].capacity|tostring) and
      .AZURE_FOUNDRY_PROJECT_ENDPOINT==("https://"+$state[0].account+".services.ai.azure.com/api/projects/"+$state[0].project) and
      .AZURE_MODEL_BASE_URL==(.AZURE_FOUNDRY_PROJECT_ENDPOINT+"/openai/v1") and
      (.AZURE_API_KEY | test("^[A-Za-z0-9+/=_-]{16,}$"))
    ' "$ENV_JSON" >/dev/null || die ".env and the owned deployment record disagree. No gateway configuration was applied."
}

# Applies the Foundry provider Secret, backend, and route to one gateway namespace, but only
# after confirming that the gateway rejects requests without a valid tenant key.
configure_namespace() {
    local namespace=$1 invalid_header secret manifest
    wait_status "$namespace" agentgatewaypolicy/tenant-auth policy Accepted
    start_forward "$REQUEST_PORT" "$namespace" "service/$GATEWAY" 80
    http_call "http://127.0.0.1:$REQUEST_PORT/v1/chat/completions"
    [[ "$HTTP_STATUS" == 401 ]] || die "$namespace: strict authentication is not enforced. The paid route was not applied."
    new_temp; invalid_header=$TEMP_FILE
    printf 'Authorization: Bearer invalid-%s\n' "$(openssl rand -hex 8)" >"$invalid_header"
    http_call "http://127.0.0.1:$REQUEST_PORT/v1/chat/completions" "$invalid_header"
    [[ "$HTTP_STATUS" == 401 ]] || die "$namespace: an invalid key was accepted. The paid route was not applied."
    stop_forward
    new_temp; secret=$TEMP_FILE
    jq --arg namespace "$namespace" '{apiVersion:"v1",kind:"Secret",type:"Opaque",
      metadata:{name:"foundry-provider",namespace:$namespace},
      stringData:{Authorization:.AZURE_API_KEY}}' "$ENV_JSON" >"$secret"
    kube_apply -f "$secret" >/dev/null
    new_temp; manifest=$TEMP_FILE
    sed -e "s/@RESOURCE@/$(saved account)/g" -e "s/@PROJECT@/$(saved project)/g" \
        -e "s/@DEPLOYMENT@/$(saved deployment)/g" -e "s/@NAMESPACE@/$namespace/g" \
        "$ROOT/deploy/agentgateway/foundry.yaml.tmpl" >"$manifest"
    kube_apply -f "$manifest" >/dev/null
    wait_status "$namespace" agentgatewaybackend/foundry-model plain Accepted
    wait_status "$namespace" httproute/foundry-chat route Accepted
    wait_status "$namespace" httproute/foundry-chat route ResolvedRefs
    ok "$namespace: Foundry route configured behind tenant authentication"
}

gateway_configure() {
    validate_connection
    verify_context
    section "FOUNDRY CONNECTION | $KIND_CLUSTER"
    local namespaces namespace
    namespaces=$(gateway_namespaces)
    if [[ -z "$namespaces" ]]; then
        ok 'No tenant gateways exist yet; each new tenant receives the connection when it is added'
    fi
    for namespace in $namespaces; do configure_namespace "$namespace"; done
    phase configured
    info "No model request was made. Next: make prompt CLUSTER=$CLUSTER TENANT=<tenant> PROMPT=\"Hello\""
}

endpoints() {
    validate_connection
    verify_context
    section "SERVICE URLS | $KIND_CLUSTER"
    info "Foundry project: $(config AZURE_FOUNDRY_PROJECT_ENDPOINT)"
    info "Foundry inference: $(config AZURE_MODEL_BASE_URL)"
    info "Deployment: $(config AZURE_MODEL_DEPLOYMENT)"
    local namespace namespaces
    namespaces=$(gateway_namespaces)
    for namespace in $namespaces; do
        if [[ "$CLUSTER" == shared ]]; then
            info "Gateway for every tenant: make gateway-forward CLUSTER=shared -> http://127.0.0.1:$GATEWAY_PORT/v1"
        else
            info "Gateway for $namespace: make gateway-forward CLUSTER=dedicated TENANT=$namespace -> http://127.0.0.1:$GATEWAY_PORT/v1"
        fi
    done
    info 'Each tenant uses its own key from .env.tenants. The tenant and Azure keys are different.'
}

remove_env_connection() {
    [[ -f "$ROOT/.env" ]] || return 0
    load_env
    local result
    new_temp; result=$TEMP_FILE
    jq -r 'del(.AZURE_SUBSCRIPTION_ID,.AZURE_RESOURCE_GROUP,.AZURE_LOCATION,
      .AZURE_FOUNDRY_RESOURCE_NAME,.AZURE_FOUNDRY_PROJECT_NAME,.AZURE_FOUNDRY_PROJECT_ENDPOINT,
      .AZURE_MODEL_BASE_URL,.AZURE_MODEL_DEPLOYMENT,.AZURE_MODEL_NAME,.AZURE_MODEL_VERSION,
      .AZURE_MODEL_SKU,.AZURE_MODEL_CAPACITY,.AZURE_API_KEY,.AGENTGATEWAY_BASE_URL,.AGENTGATEWAY_API_KEY) |
      to_entries | sort_by(.key)[] | "\(.key)=\(.value)"' "$ENV_JSON" >"$result"
    chmod 600 "$result"
    mv -f -- "$result" "$ROOT/.env"
}

remove_cluster_connection() {
    CLUSTER=$1
    select_cluster
    cluster_exists || return 0
    verify_context
    local namespace namespaces
    namespaces=$(gateway_namespaces)
    for namespace in $namespaces; do
        kube -n "$namespace" delete httproute foundry-chat --ignore-not-found
        kube -n "$namespace" delete agentgatewaybackend foundry-model --ignore-not-found
        kube -n "$namespace" delete secret foundry-provider --ignore-not-found
    done
}

cleanup_connection() {
    validate_record
    [[ "$(saved phase)" == cloud-deleted ]] || die "Cloud deletion has not been confirmed."
    section 'REMOVING THE RETIRED FOUNDRY CONNECTION'
    local target
    for target in shared dedicated; do (remove_cluster_connection "$target"); done
    remove_env_connection
    phase deleted
    ok 'Removed the retired connection from every project cluster and its managed credentials'
}

gateway_restore() {
    if [[ -f "$RECORD" ]]; then
        validate_record
        case "$(saved phase)" in
            cloud-deleted) cleanup_connection ;;
            deleted) ;;
            provisioned|configured) gateway_configure ;;
            planned) die "Foundry provisioning is incomplete. Run make foundry-up to resume." ;;
        esac
    elif [[ -f "$ROOT/.env" ]]; then
        die ".env has no corresponding ownership record. No connection was adopted."
    fi
}

cloud_down() {
    [[ "${CONFIRM:-}" == 1 ]] || die "Review owned Azure resources, then run make foundry-down CONFIRM=1."
    [[ -f "$RECORD" ]] || die "No ownership record; no Azure resources will be deleted."
    validate_record
    case "$(saved phase)" in
        deleted) ok 'This cloud generation is already deleted'; return ;;
        cloud-deleted) cleanup_connection; return ;;
    esac
    azure_context
    section 'CLOUD RESOURCE CLEANUP'
    info "Resource group: $(saved groupId)"
    info "Account: $(saved accountId)"
    local exists resources projects deployments
    exists=$(azure group exists --name "$(saved group)" --output tsv)
    if [[ "$exists" == true ]]; then
        owned_group
        resources=$(azure resource list --resource-group "$(saved group)" --output json)
        jq -e --slurpfile state "$RECORD" '
          all(.[]; (.id|ascii_downcase) as $id |
            [$state[0].accountId,$state[0].projectId,$state[0].deploymentId] |
            map(ascii_downcase) | index($id)!=null)
        ' <<<"$resources" >/dev/null || die "Unexpected resources in the group; automatic deletion refused."
        if [[ "$(jq length <<<"$resources")" -gt 0 ]]; then
            owned_account
            projects=$(azure cognitiveservices account project list --name "$(saved account)" \
                --resource-group "$(saved group)" --output json)
            deployments=$(azure cognitiveservices account deployment list --name "$(saved account)" \
                --resource-group "$(saved group)" --output json)
            jq -e --arg id "$(saved projectId)" 'all(.[]; (.id|ascii_downcase)==($id|ascii_downcase))' <<<"$projects" >/dev/null ||
                die "Unexpected Foundry project; automatic deletion refused."
            jq -e --arg id "$(saved deploymentId)" 'all(.[]; (.id|ascii_downcase)==($id|ascii_downcase))' <<<"$deployments" >/dev/null ||
                die "Unexpected model deployment; automatic deletion refused."
        fi
        azure group delete --name "$(saved group)" --yes
        [[ "$(azure group exists --name "$(saved group)" --output tsv)" == false ]] ||
            die "Azure still reports the resource group. Credentials were retained for recovery."
    elif [[ "$exists" != false ]]; then
        die "Unexpected resource group existence response."
    fi
    phase cloud-deleted
    cleanup_connection
    info 'Soft-deleted accounts were not purged. Future setup will use newly confirmed names.'
}

foundry_up() {
    if [[ -f "$RECORD" && "$(saved phase)" == cloud-deleted ]]; then cleanup_connection; fi
    azure_context
    require_registered
    if [[ -f "$RECORD" && "$(saved phase)" != deleted ]]; then
        section 'RESUMING THE OWNED DEPLOYMENT'
        info "$(saved model) / $(saved version) / $(saved sku) / $(saved capacity) units"
        info "Region: $(saved region) | Account: $(saved account)"
        [[ -z "${REGION:-}" || "$REGION" == "$(saved region)" ]] || die "REGION differs from the recorded deployment."
        [[ -z "${MODEL:-}" || "$MODEL" == "$(saved model)" ]] || die "MODEL differs from the recorded deployment."
        [[ -z "${MODEL_VERSION:-}" || "$MODEL_VERSION" == "$(saved version)" ]] || die "MODEL_VERSION differs from the recorded deployment."
        [[ -z "${SKU:-}" || "$SKU" == "$(saved sku)" ]] || die "SKU differs from the recorded deployment."
        [[ -z "${CAPACITY:-}" || "$CAPACITY" == "$(saved capacity)" ]] || die "CAPACITY differs from the recorded deployment."
        confirm_action
    else
        discover_models
        choose_model
        new_record
    fi
    provision
    persist_config
    section 'NEXT STEPS'
    info 'The model is deployed. No gateway was changed and no model request was made.'
    info 'Connect each cluster: make gateway-configure CLUSTER=shared (or dedicated, or both)'
}

case "${1:-}" in
    foundry-register) register_provider ;;
    foundry-regions) azure_context; read_regions; show_regions ;;
    foundry-models) azure_context; discover_models ;;
    foundry-up) foundry_up ;;
    gateway-configure) select_cluster_or_both foundry.sh "$@"; gateway_configure ;;
    gateway-restore) select_cluster; gateway_restore ;;
    endpoints) select_cluster_or_both foundry.sh "$@"; endpoints ;;
    foundry-status)
        azure_context; validate_record
        section 'OWNED FOUNDRY DEPLOYMENT'
        jq '{phase,region,account,project,deployment,model,version,sku,capacity}' "$RECORD"
        case "$(saved phase)" in
            deleted|cloud-deleted) ;;
            *) azure cognitiveservices account deployment show --name "$(saved account)" \
                --resource-group "$(saved group)" --deployment-name "$(saved deployment)" \
                --query '{id:id,state:properties.provisioningState,model:properties.model,sku:sku}' --output json ;;
        esac
        ;;
    foundry-down) cloud_down ;;
    *) die "Unknown Foundry command: ${1:-missing}" ;;
esac
