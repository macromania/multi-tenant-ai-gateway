#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

need jq
need curl
select_cluster
validate_tenant "${TENANT:-}"
case "${UPSTREAM:-foundry}" in
    foundry) path=/v1/chat/completions ;;
    mock) path=/mock/v1/chat/completions ;;
    *) die "UPSTREAM must be foundry or mock." ;;
esac
upstream=${UPSTREAM:-foundry}
if [[ "$upstream" == foundry ]]; then
    load_env
    [[ -f "$STATE/foundry.json" ]] || die "No model is configured. Run make foundry-up."
    jq -e '.phase == "configured"' "$STATE/foundry.json" >/dev/null ||
        die "Foundry setup is incomplete. Run make foundry-up or make gateway-configure CLUSTER=$CLUSTER."
    jq -e --slurpfile state "$STATE/foundry.json" \
        '.AZURE_MODEL_DEPLOYMENT == $state[0].deployment' "$ENV_JSON" >/dev/null ||
        die ".env does not match the configured model deployment. Run make gateway-configure CLUSTER=$CLUSTER."
    model=$(config AZURE_MODEL_DEPLOYMENT)
else
    model=mock-chat
fi
[[ "$model" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid model deployment name."
verify_context
[[ "${FORMAT:-text}" == text || "${FORMAT:-}" == json || -z "${FORMAT:-}" ]] ||
    die "FORMAT must be text or json."
[[ -z "${PROMPT:-}" || -z "${PROMPT_FILE:-}" ]] || die "Use PROMPT or PROMPT_FILE, not both."

new_temp; input=$TEMP_FILE
if [[ -n "${PROMPT_FILE:-}" ]]; then
    [[ -f "$PROMPT_FILE" ]] || die "PROMPT_FILE must name an existing text file."
    cat -- "$PROMPT_FILE" >"$input"
elif [[ -n "${PROMPT:-}" ]]; then
    printf '%s' "$PROMPT" >"$input"
elif [[ -t 0 ]]; then
    printf '  Prompt: ' >&2
    IFS= read -r prompt
    printf '%s' "$prompt" >"$input"
else
    die 'Provide text: make prompt CLUSTER=shared TENANT=tenant-01 PROMPT="Hello" or PROMPT_FILE=path'
fi
[[ -s "$input" ]] || die "The prompt is empty."
[[ "$(wc -c <"$input")" -le 32768 ]] || die "Development prompts are limited to 32 KiB."

new_temp; payload=$TEMP_FILE
jq -n --arg model "$model" --rawfile prompt "$input" \
    '{model:$model,messages:[{role:"user",content:$prompt}],stream:false,max_completion_tokens:1024}' >"$payload"

namespace=$(tenant_namespace "$TENANT")
section "PROMPT REQUEST | $KIND_CLUSTER | $TENANT"
info "Upstream: $upstream ($model)"
info "Gateway: $namespace/$GATEWAY via http://127.0.0.1:$REQUEST_PORT$path"
if [[ "$upstream" == foundry ]]; then info 'This request uses the hosted model and can incur charges.'; fi
tenant_header "$TENANT"
start_forward "$REQUEST_PORT" "$namespace" "service/$GATEWAY" 80
http_call "http://127.0.0.1:$REQUEST_PORT$path" "$HEADER_FILE" "$payload"
[[ "$HTTP_STATUS" == 200 ]] ||
    die "Gateway returned HTTP $HTTP_STATUS: $(jq -r '.error.message? // empty' "$RESPONSE_FILE" 2>/dev/null | head -c 300). No retry was made."
if jq -e 'any(.choices[]?; .finish_reason == "content_filter")' "$RESPONSE_FILE" >/dev/null 2>&1; then
    die "The provider content filter blocked the response. No retry was made."
fi
if ! jq -e '
    type == "object" and .object == "chat.completion" and .error == null and
    (.choices | type == "array" and length > 0) and
    .choices[0].message.role == "assistant" and
    ((.choices[0].message.content | type == "string" and length > 0) or
     (.choices[0].message.refusal | type == "string" and length > 0))
  ' "$RESPONSE_FILE" >/dev/null; then
    die "Invalid/empty chat completion (including token-limit exhaustion). No answer was substituted."
fi
section 'MODEL RESPONSE'
if [[ "$(jq -r '.choices[0].message.refusal // empty' "$RESPONSE_FILE")" != '' ]]; then
    warn 'The model returned an explicit refusal.'
fi
info "Model: $(jq -r '.model // "not reported"' "$RESPONSE_FILE")"
info "Tokens: $(jq -r '.usage.total_tokens // "not reported"' "$RESPONSE_FILE")"
if [[ "$upstream" == mock ]]; then
    owner=$(response_header x-mock-key-owner)
    info "Provider key owner seen by the mock: ${owner:-missing}"
    [[ "$owner" == "$TENANT" ]] || die "The mock did not receive $TENANT's provider key (it saw ${owner:-none})."
fi
if [[ "${FORMAT:-}" == json ]]; then
    cat "$RESPONSE_FILE"
    printf '\n'
else
    jq -r '.choices[0].message.refusal // .choices[0].message.content' "$RESPONSE_FILE"
fi
