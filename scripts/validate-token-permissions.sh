#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required to validate installation token permissions"
fi

response="$(cat)"

if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$response"; then
    fail "Malformed JSON or invalid response object"
fi

if ! jq -e '.permissions | type == "object"' >/dev/null 2>&1 <<< "$response"; then
    fail "Invalid permissions object"
fi

if ! jq -e '
    .permissions
    | to_entries
    | all(.[]; (.value | type) == "string")
' >/dev/null 2>&1 <<< "$response"; then
    fail "Invalid permissions object"
fi

if ! jq -e '.permissions.contents == "read"' >/dev/null 2>&1 <<< "$response"; then
    fail "Contents permission must be read-only"
fi

excessive="$(jq -r '
    .permissions
    | to_entries
    | map(select(.value == "write" or .value == "admin") | .key)
    | join(", ")
' <<< "$response")"

if [[ -n "$excessive" ]]; then
    fail "Excessive permissions: $excessive"
fi

printf 'PASS: Installation token permissions are read-only\n'

if [[ $# -gt 0 ]]; then
    expected_repo="$1"

    if [[ -z "$expected_repo" ]]; then
        fail "Repository scope does not match the expected repository"
    fi

    if ! jq -e '
        (.repositories | type == "array")
        and all(.repositories[]; type == "object" and (.full_name | type == "string" and length > 0))
    ' >/dev/null 2>&1 <<< "$response"; then
        fail "Repository scope missing from token response"
    fi

    if ! jq -e --arg expected "$expected_repo" \
        '.repositories | length == 1 and .[0].full_name == $expected' \
        >/dev/null 2>&1 <<< "$response"; then
        fail "Repository scope does not match the expected repository"
    fi

    printf 'PASS: Installation token restricted to expected repository\n'
fi
