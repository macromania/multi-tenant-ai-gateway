#!/bin/bash
# make results: writes results/report.md from every run record under results/.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
source "$ROOT/scripts/record.sh"

build_report() {
    local runs structure target objects fingerprint commit generated
    section 'RESULTS REPORT'
    [[ -d "$RESULTS" ]] || die "No results yet. Run experiments first."
    new_temp; runs=$TEMP_FILE
    find "$RESULTS" -mindepth 3 -maxdepth 3 -name run.json -print | LC_ALL=C sort | while IFS= read -r file; do
        jq -c --arg dir "${file#$RESULTS/}" '. + {dir: ($dir | rtrimstr("/run.json"))}' "$file"
    done | jq -s '.' >"$runs"
    info "$(jq length "$runs") run records found."
    # What holds a tenant's settings in each design, read from the live clusters when they exist.
    new_temp; structure=$TEMP_FILE
    printf '{}' >"$structure"
    for target in shared dedicated; do
        objects=$(CLUSTER=$target TENANT=tenant-01 FORMAT=json /bin/bash "$ROOT/scripts/tenants.sh" tenant-objects 2>/dev/null) || objects=null
        jq --arg target "$target" --argjson objects "${objects:-null}" '. + {($target): $objects}' "$structure" >"$structure.next"
        mv -f -- "$structure.next" "$structure"
    done
    fingerprint=$(input_fingerprint)
    commit=$(git -C "$ROOT" rev-parse HEAD)
    generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n -r --slurpfile runs "$runs" --slurpfile structure "$structure" --arg fp "$fingerprint" \
        --arg commit "$commit" --arg generated "$generated" \
        '{runs: $runs[0], structure: $structure[0], current_fingerprint: $fp, commit: $commit, generated_at: $generated}' |
        jq -r -f "$ROOT/scripts/report.jq" >"$RESULTS/report.md"
    ok "Wrote results/report.md ($(jq '[.[] | select(.inputs_committed == true and .input_fingerprint == "'"$fingerprint"'")] | length' "$runs") runs match the current code)"
}

build_report
