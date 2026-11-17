#!/usr/bin/env bash
# ==============================================================================
# SYNOPSIS
#   Tier 3 Programmatic Verification: Validates that a generated GitHub App and
#   PEM private key can successfully authenticate, mint ephemeral tokens, and
#   read configuration repositories.
#
# DESCRIPTION
#   Uses OpenSSL to generate an RS256 JWT, authenticates as the GitHub App,
#   fetches an installation access token, and tests reading the target
#   configuration file.
#
# EXAMPLE
#   ./verify-app-token.sh --app-id "1029384" --private-key-path "./keys/iht-private-key.pem" --pse "iht"
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
COLOR_MAGENTA='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

# Default Parameter Values
APP_ID=""
PRIVATE_KEY_PATH=""
PSE="${PSE:-}"
ORG_NAME="${GITHUB_OWNER:-}"
CONFIG_REPO="${CONFIG_REPO:-}"
CONFIG_FILE_PATH="${CONFIG_FILE_PATH:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") --app-id <APP_ID> --private-key-path <PEM_PATH> [OPTIONS]

Options:
  -a, --app-id <APP_ID>             GitHub App ID (Mandatory)
  -k, --private-key-path <PATH>     Path to the GitHub App PEM private key (Mandatory)
  -p, --pse <PSE>                   Target PSE identifier (default: $PSE)
  -o, --org-name <ORG>              GitHub Organization or Owner name (default: $ORG_NAME)
  -c, --config-repo <REPO>          Configuration repository name (default: $CONFIG_REPO)
  --config-file-path <PATH>         Configuration file path inside the repository
  -h, --help                        Show this help message
EOF
}

# Parse Command-Line Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--app-id|-AppId)
            APP_ID="${2:-}"
            shift 2
            ;;
        -k|--private-key-path|-PrivateKeyPath)
            PRIVATE_KEY_PATH="${2:-}"
            shift 2
            ;;
        -p|--pse|-Pse)
            PSE="${2:-}"
            shift 2
            ;;
        -o|--org-name|-OrgName)
            ORG_NAME="${2:-}"
            shift 2
            ;;
        -c|--config-repo|-ConfigRepo)
            CONFIG_REPO="${2:-}"
            shift 2
            ;;
        --config-file-path)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "Error: --config-file-path requires a file path" >&2
                exit 1
            fi
            CONFIG_FILE_PATH="$2"
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${COLOR_RED}Error: Unknown argument '$1'${COLOR_RESET}" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${APP_ID// /}" || -z "${PRIVATE_KEY_PATH// /}" ]]; then
    echo -e "${COLOR_RED}Error: Both --app-id and --private-key-path are required.${COLOR_RESET}" >&2
    usage
    exit 1
fi

echo -e "${COLOR_MAGENTA}=====================================================================${COLOR_RESET}"
echo -e "${COLOR_MAGENTA}   TIER 3 VERIFICATION: GitHub App RS256 JWT & Token Exchange Test   ${COLOR_RESET}"
echo -e "${COLOR_MAGENTA}=====================================================================${COLOR_RESET}"
echo "Target PSE     : $PSE"
echo "App ID         : $APP_ID"
echo "Private Key    : $PRIVATE_KEY_PATH"
echo -e "Config Repo    : $ORG_NAME/$CONFIG_REPO\n"

# 1. Locate OpenSSL
if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${COLOR_RED}Error: OpenSSL not found in PATH. Please ensure openssl is installed.${COLOR_RESET}" >&2
    exit 1
fi
OPENSSL_BIN="$(command -v openssl)"

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
    echo -e "${COLOR_RED}Error: Private key not found at: $PRIVATE_KEY_PATH${COLOR_RESET}" >&2
    exit 1
fi

# Helper: Base64Url Encoding (reads from stdin)
base64url_encode() {
    "$OPENSSL_BIN" base64 -e -A | tr '+/' '-_' | tr -d '='
}

# 2. Build RS256 JWT
echo -e "${COLOR_CYAN}[1/4] Constructing JWT Claims for App ID $APP_ID...${COLOR_RESET}"
NOW_EPOCH="$(date -u +%s)"
IAT=$((NOW_EPOCH - 60))
EXP=$((NOW_EPOCH + 540)) # 9 minutes

HEADER_JSON='{"alg":"RS256","typ":"JWT"}'
PAYLOAD_JSON="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$IAT" "$EXP" "$APP_ID")"

ENCODED_HEADER="$(printf '%s' "$HEADER_JSON" | base64url_encode)"
ENCODED_PAYLOAD="$(printf '%s' "$PAYLOAD_JSON" | base64url_encode)"
HEADER_AND_PAYLOAD="${ENCODED_HEADER}.${ENCODED_PAYLOAD}"

ENCODED_SIG="$(printf '%s' "$HEADER_AND_PAYLOAD" | "$OPENSSL_BIN" dgst -sha256 -sign "$PRIVATE_KEY_PATH" | base64url_encode)"
JWT="${HEADER_AND_PAYLOAD}.${ENCODED_SIG}"

echo -e "${COLOR_GREEN}      [OK] RS256 JWT generated successfully.${COLOR_RESET}"

# Helper: Parse JSON via jq or python3
json_extract() {
    local expr="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r "$expr"
    else
        python3 -c 'import json, sys
data = json.load(sys.stdin)
expr = sys.argv[1]
if expr == "app_info":
    print("{} (Slug: {})".format(data.get("name", ""), data.get("slug", "")))
elif expr.startswith("install_id:"):
    org = expr.split(":", 1)[1]
    for item in data:
        if item.get("account", {}).get("login") == org:
            print(item.get("id", ""))
            break
elif expr == "token_info":
    print("{}|{}".format(data.get("token", ""), data.get("expires_at", "")))
' "$expr"
    fi
}

# 3. Authenticate to GitHub API as App
echo -e "${COLOR_CYAN}[2/4] Authenticating to GitHub API as GitHub App...${COLOR_RESET}"
if ! APP_RESPONSE="$(curl -fsSL \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: CAIT-DevOps-Verification" \
    "https://api.github.com/app")"; then
    echo -e "${COLOR_RED}Error: Failed to authenticate with GitHub App JWT.${COLOR_RESET}" >&2
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    APP_DISPLAY="$(printf '%s' "$APP_RESPONSE" | jq -r '"\(.name) (Slug: \(.slug))"')"
else
    APP_DISPLAY="$(printf '%s' "$APP_RESPONSE" | json_extract "app_info")"
fi
echo -e "${COLOR_GREEN}      [OK] Verified as App: $APP_DISPLAY${COLOR_RESET}"

# 4. Find Installation for OrgName
echo -e "${COLOR_CYAN}[3/4] Locating installation for organization '$ORG_NAME'...${COLOR_RESET}"
if ! INSTALLS_RESPONSE="$(curl -fsSL \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: CAIT-DevOps-Verification" \
    "https://api.github.com/app/installations")"; then
    echo -e "${COLOR_RED}Error: Failed to list installations.${COLOR_RESET}" >&2
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    INSTALLATION_ID="$(printf '%s' "$INSTALLS_RESPONSE" | jq -r --arg org "$ORG_NAME" '.[] | select(.account.login == $org) | .id' | head -n 1)"
else
    INSTALLATION_ID="$(printf '%s' "$INSTALLS_RESPONSE" | json_extract "install_id:$ORG_NAME")"
fi

if [[ -z "${INSTALLATION_ID// /}" ]]; then
    echo -e "${COLOR_RED}Error: App is NOT yet installed on organization '$ORG_NAME'. Please install it first!${COLOR_RESET}" >&2
    exit 1
fi
echo -e "${COLOR_GREEN}      [OK] Found Installation ID: $INSTALLATION_ID (Target: $ORG_NAME)${COLOR_RESET}"

# 5. Mint Short-Lived Installation Token
echo -e "${COLOR_CYAN}[4/4] Minting ephemeral installation access token...${COLOR_RESET}"
TOKEN_URL="https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens"

TOKEN_REQUEST_BODY="$(python3 - "$CONFIG_REPO" <<'PYEOF'
import json
import sys

repo = sys.argv[1].split("/")[-1]
print(json.dumps({
    "repositories": [repo],
    "permissions": {"contents": "read"}
}))
PYEOF
)"

if ! TOKEN_RESPONSE="$(curl -fsSL -X POST \
    -H "Content-Type: application/json" \
    -d "$TOKEN_REQUEST_BODY" \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: CAIT-DevOps-Verification" \
    "$TOKEN_URL")"; then
    echo -e "${COLOR_RED}Error: Failed to mint installation access token.${COLOR_RESET}" >&2
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    INSTALLATION_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.token')"
    EXPIRES_AT="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.expires_at')"
else
    IFS='|' read -r INSTALLATION_TOKEN EXPIRES_AT <<< "$(printf '%s' "$TOKEN_RESPONSE" | json_extract "token_info")"
fi

# Validate Installation Token Permissions
# Fail if Contents is not read-only or any other write permission is granted.
if ! printf '%s' "$TOKEN_RESPONSE" | python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/validate-token-permissions.py"; then
    echo "Error: Installation token permissions validation failed." >&2
    exit 1
fi

echo -e "${COLOR_GREEN}      [OK] Ephemeral token minted! Expires at: $EXPIRES_AT${COLOR_RESET}"

# Test reading the configuration file
# Resolve configuration file path
if [[ -z "$CONFIG_FILE_PATH" && -n "$PSE" ]]; then
    CONFIG_FILE_PATH="workflows/${PSE}-3-api.env"
fi

if [[ -z "$CONFIG_FILE_PATH" ]]; then
    echo "Error: --config-file-path or --pse is required" >&2
    exit 1
fi

CONFIG_URL="https://api.github.com/repos/${ORG_NAME}/${CONFIG_REPO}/contents/${CONFIG_FILE_PATH}"
if FILE_CONTENT="$(curl -fsSL \
    -H "Authorization: Bearer $INSTALLATION_TOKEN" \
    -H "Accept: application/vnd.github.raw+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: CAIT-DevOps-Verification" \
    "$CONFIG_URL" 2>/dev/null)"; then
    echo -e "\n${COLOR_GREEN}=====================================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}           VERIFICATION COMPLETE: 100% SUCCESS!                      ${COLOR_RESET}"
    echo -e "${COLOR_GREEN}=====================================================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN}Successfully read configuration file from '$CONFIG_REPO':${COLOR_RESET}"
    echo "Configuration file access verified successfully (content hidden)."
    echo -e "\n${COLOR_GREEN}The GitHub App and Private Key credentials are 100% operational!${COLOR_RESET}"
else
    echo -e "${COLOR_RED}Error: Cannot read '$CONFIG_FILE_PATH' from '$ORG_NAME/$CONFIG_REPO'.${COLOR_RESET}" >&2
    exit 1
fi

