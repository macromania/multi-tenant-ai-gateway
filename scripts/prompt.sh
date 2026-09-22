#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

need jq
need curl
load_env
[[ -f "$STATE/foundry.json" ]] || die "No model is configured. Run make foundry-up."
jq -e '.phase == "configured"' "$STATE/foundry.json" >/dev/null ||
    die "Foundry setup is incomplete. Run make foundry-up or make gateway-configure."
jq -e --slurpfile state "$STATE/foundry.json" \
    '.AZURE_MODEL_DEPLOYMENT == $state[0].deployment' "$ENV_JSON" >/dev/null ||
    die ".env does not match the configured model deployment. Run make gateway-configure."
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
    die 'Provide text: make prompt PROMPT="Hello" or PROMPT_FILE=path'
fi
[[ -s "$input" ]] || die "The prompt is empty."
[[ "$(wc -c <"$input")" -le 32768 ]] || die "Development prompts are limited to 32 KiB."

model=$(config AZURE_MODEL_DEPLOYMENT)
[[ "$model" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid model deployment name."
new_temp; payload=$TEMP_FILE
jq -n --arg model "$model" --rawfile prompt "$input" \
    '{model:$model,messages:[{role:"user",content:$prompt}],stream:false,max_completion_tokens:1024}' >"$payload"

section 'PROMPT REQUEST'
info "Deployment: $model"
info "Gateway: http://127.0.0.1:$REQUEST_PORT/v1/chat/completions"
info 'This request uses the hosted model and can incur charges.'
start_forward "$REQUEST_PORT"
gateway_header
http_call "http://127.0.0.1:$REQUEST_PORT/v1/chat/completions" "$HEADER_FILE" "$payload"
[[ "$HTTP_STATUS" == 200 ]] ||
    die "Gateway returned HTTP $HTTP_STATUS. Check model permissions/quota and make logs. No retry was made."
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
if [[ "${FORMAT:-}" == json ]]; then
    cat "$RESPONSE_FILE"
    printf '\n'
else
    jq -r '.choices[0].message.refusal // .choices[0].message.content' "$RESPONSE_FILE"
fi
