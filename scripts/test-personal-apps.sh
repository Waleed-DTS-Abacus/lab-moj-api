#!/usr/bin/env bash
# ==============================================================================
# SYNOPSIS
#   Test script for creating dedicated GitHub Apps and provisioning secrets on a
#   GitHub account configured through runtime parameters.
#
# DESCRIPTION
#   Tailored test runner for:
#     - Account: Configurable GitHub owner
#     - App 1: Configurable application and target repository
#     - App 2: Additional application/repository pair (optional)
#   Automates:
#     1. Manifest flow targeting https://github.com/settings/apps/new
#     2. Local callback listener on http://localhost:<port>/callback
#     3. Credential exchange (App ID, Client ID, PEM Private Key)
#     4. Secure local backup to ./keys/<app>-private-key.pem
#     5. Automated upload of CONFIG_APP_CLIENT_ID, CONFIG_APP_PRIVATE_KEY,
#        CONFIG_REPO, and CONFIG_APP_ID
#
# EXAMPLE
#   ./test-personal-apps.sh --github-token "YOUR_BOOTSTRAP_TOKEN"
# ==============================================================================

set -uo pipefail

# ANSI Color Codes
COLOR_MAGENTA='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_DARKGRAY='\033[0;90m'
COLOR_YELLOW='\033[0;33m'
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

# Default Parameter Values
GITHUB_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

OWNER="${GITHUB_OWNER:-}"
CONFIG_REPO="${CONFIG_REPO:-}"

CALLBACK_PORT="${CALLBACK_PORT:-0}"
KEY_DIRECTORY="${KEY_DIRECTORY:-}"
APP_MODE="${APP_MODE:-}"
EXISTING_APP_ID="${EXISTING_APP_ID:-}"
EXISTING_APP_KEY="${EXISTING_APP_KEY:-}"
CONFIG_FILE_PATH="${CONFIG_FILE_PATH:-}"

APP_NAMES=()
REPOS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") --github-token <TOKEN> [OPTIONS]

Options:
  -t, --github-token <TOKEN>        GitHub Personal Access Token (Mandatory if GH_TOKEN not set)
  -o, --owner <OWNER>               GitHub Account Owner (default: $OWNER)
  -c, --config-repo <OWNER/REPO>    Config repository (default: $CONFIG_REPO)
  -p, --callback-port <PORT>        Local callback port (default: auto-detect from 8181)
  -k, --key-directory <DIR>         Directory to store generated private keys (default: ./keys)
  -h, --help
  --repo <REPO>                     Target repository (repeatable)
  --app-name <NAME>                 GitHub App name (repeatable)                        Show this help message
EOF
}

# Parse Command-Line Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--github-token|-GitHubToken)
            GITHUB_TOKEN="${2:-}"
            shift 2
            ;;
        -o|--owner|-Owner)
            OWNER="${2:-}"
            shift 2
            ;;
        -c|--config-repo|-ConfigRepo)
            CONFIG_REPO="${2:-}"
            shift 2
            ;;
        -p|--callback-port|-CallbackPort)
            CALLBACK_PORT="${2:-0}"
            shift 2
            ;;
        -k|--key-directory|-KeyDirectory)
            KEY_DIRECTORY="${2:-}"
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

        --existing-app-id)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "Error: --existing-app-id requires an App ID" >&2
                exit 1
            fi
            EXISTING_APP_ID="$2"
            shift 2
            ;;

        --existing-app-key)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "Error: --existing-app-key requires a key file path" >&2
                exit 1
            fi
            EXISTING_APP_KEY="$2"
            shift 2
            ;;

        --confirm-create)
            CREATE_CONFIRMED=true
            shift
            ;;

        --mode)
            if [[ $# -lt 2 || "$2" != "create" && "$2" != "reuse" ]]; then
                echo "Error: --mode must be create or reuse" >&2
                exit 1
            fi
            APP_MODE="$2"
            shift 2
            ;;

        --repo)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "Error: --repo requires a repository name" >&2
                exit 1
            fi
            REPOS+=("$2")
            shift 2
            ;;

        --app-name)
            if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                echo "Error: --app-name requires an app name" >&2
                exit 1
            fi
            APP_NAMES+=("$2")
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$GITHUB_TOKEN" && ! "$1" =~ ^- ]]; then
                GITHUB_TOKEN="$1"
                shift
            else
                echo -e "${COLOR_RED}Error: Unknown argument '$1'${COLOR_RESET}" >&2
                usage
                exit 1
            fi
            ;;
                esac
done

# Validate required configuration
if [[ -z "$OWNER" ]]; then
    echo "Error: GitHub owner is required. Use --owner" >&2
    exit 1
fi

if [[ -z "$CONFIG_REPO" ]]; then
    echo "Error: Config repository is required. Use --config-repo" >&2
    exit 1
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "Error: At least one --repo is required" >&2
    exit 1
fi

if [[ ${#APP_NAMES[@]} -ne ${#REPOS[@]} ]]; then
    echo "Error: Each repository must have a matching --app-name" >&2
    exit 1
fi

# Validate application mode
if [[ "$APP_MODE" != "create" && "$APP_MODE" != "reuse" ]]; then
    echo "Error: APP_MODE must be create or reuse" >&2
    exit 1
fi

# Validate existing app credentials in reuse mode
if [[ "$APP_MODE" == "reuse" ]]; then
    if [[ -z "$CONFIG_FILE_PATH" ]]; then
        echo "Error: Reuse mode requires --config-file-path" >&2
        exit 1
    fi

    if [[ -z "$EXISTING_APP_ID" ]]; then
        echo "Error: Reuse mode requires --existing-app-id" >&2
        exit 1
    fi

    if [[ -z "$EXISTING_APP_KEY" || ! -f "$EXISTING_APP_KEY" ]]; then
        echo "Error: Reuse mode requires a valid --existing-app-key file" >&2
        exit 1
    fi
fi

if [[ "$APP_MODE" == "create" && -z "${GITHUB_TOKEN// /}" ]]; then
    echo -e "${COLOR_RED}Error: GitHubToken is required. Pass --github-token <TOKEN> or set GH_TOKEN.${COLOR_RESET}" >&2
    usage
    exit 1
fi

# Helper: Find an unreserved, available local port
get_available_port() {
    local preferred="${1:-8181}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$preferred" <<'PYEOF'
import socket, sys
start = int(sys.argv[1])
for p in range(start, start + 50):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", p))
            print(p)
            sys.exit(0)
        except OSError:
            continue
print(start)
PYEOF
    else
        echo "$preferred"
    fi
}

# Auto-detect available port if not specified or defaulting to 0 / 8080
if [[ "$CALLBACK_PORT" -eq 0 || "$CALLBACK_PORT" -eq 8080 ]]; then
    CALLBACK_PORT="$(get_available_port 8181)"
fi

# Resolve Keys Directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${KEY_DIRECTORY// /}" || "$KEY_DIRECTORY" == "/keys" || "$KEY_DIRECTORY" == '\keys' ]]; then
    KEY_DIRECTORY="${SCRIPT_DIR}/keys"
fi
mkdir -p "$KEY_DIRECTORY"

# Helper: Open file or URL in browser across Windows / Linux / WSL / macOS
open_browser() {
    local target="$1"

    # Windows (Git Bash / MSYS2 / Cygwin): none of the *nix openers exist here,
    # and a POSIX-style path (/tmp/...) is meaningless to a Windows browser, so
    # translate it first. Mirrors `Start-Process` in test-personal-apps.ps1.
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            local winpath="$target"
            if [[ "$target" != http://* && "$target" != https://* ]] \
               && command -v cygpath >/dev/null 2>&1; then
                winpath="$(cygpath -w "$target")"
            fi
            # //c stops MSYS from mangling the argument into a path.
            cmd.exe //c start "" "$winpath" >/dev/null 2>&1 &
            return 0
            ;;
    esac

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$target" >/dev/null 2>&1 &
    elif command -v wslview >/dev/null 2>&1; then
        wslview "$target" >/dev/null 2>&1 &
    elif command -v sensible-browser >/dev/null 2>&1; then
        sensible-browser "$target" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$target" >/dev/null 2>&1 &
    else
        echo -e "    ${COLOR_YELLOW}[INFO] Please open the following in your browser manually:${COLOR_RESET}"
        echo "           $target"
    fi
}

# --- Helper: Upload Secret (gh CLI -> Python PyNaCl) ---
set_personal_secret() {
    local repo_name="$1"
    local secret_name="$2"
    local secret_value="$3"

    # 1. Try GitHub CLI
    local gh_path=""
    if command -v gh >/dev/null 2>&1; then
        gh_path="$(command -v gh)"
    elif [[ -x "/usr/local/bin/gh" ]]; then
        gh_path="/usr/local/bin/gh"
    fi

    if [[ -n "$gh_path" ]]; then
        export GH_TOKEN="$GITHUB_TOKEN"
        if "$gh_path" secret set "$secret_name" -R "$OWNER/$repo_name" --body "$secret_value"; then
            echo -e "    ${COLOR_GREEN}[OK] Secret '$secret_name' set via gh CLI in $repo_name${COLOR_RESET}"
            return 0
        fi
    fi

    # 2. Try Python PyNaCl fallback
    if command -v python3 >/dev/null 2>&1; then
        local key_url="https://api.github.com/repos/$OWNER/$repo_name/actions/secrets/public-key"
        local pub_key_json
        pub_key_json="$(curl -fsSL \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "User-Agent: CAIT-Test-Runner" \
            "$key_url" 2>/dev/null || true)"

        if [[ -n "$pub_key_json" ]]; then
            local payload
            payload="$( SECRET_VALUE="$secret_value" PUB_KEY_JSON="$pub_key_json" python3 - <<'PYEOF' 2>/dev/null || true
import base64, json, os
from nacl import encoding, public

pub = json.loads(os.environ["PUB_KEY_JSON"])
secret = os.environ["SECRET_VALUE"]
public_key = public.PublicKey(pub["key"].encode("utf-8"), encoding.Base64Encoder())
sealed_box = public.SealedBox(public_key)
encrypted = base64.b64encode(sealed_box.encrypt(secret.encode("utf-8"))).decode("utf-8")
print(json.dumps({"encrypted_value": encrypted, "key_id": pub["key_id"]}))
PYEOF
)"
            if [[ -n "$payload" ]]; then
                local secret_url="https://api.github.com/repos/$OWNER/$repo_name/actions/secrets/$secret_name"
                if curl -fsSL -X PUT \
                    -H "Authorization: Bearer $GITHUB_TOKEN" \
                    -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    -H "User-Agent: CAIT-Test-Runner" \
                    -d "$payload" \
                    "$secret_url" >/dev/null 2>&1; then
                    echo -e "    ${COLOR_GREEN}[OK] Secret '$secret_name' set via Python PyNaCl in $repo_name${COLOR_RESET}"
                    return 0
                fi
            fi
        fi
    fi

    echo -e "    ${COLOR_YELLOW}[WARN] Could not encrypt secret automatically because neither 'gh' CLI nor 'python3 with PyNaCl' was found.${COLOR_RESET}" >&2
    echo -e "    ${COLOR_YELLOW}[TIP] Install GitHub CLI (gh) and run 'gh auth login' to enable 1-click encryption!${COLOR_RESET}"
    return 1
}

# --- Helper: Set Repository Variable ---
set_personal_variable() {
    local repo_name="$1"
    local var_name="$2"
    local var_value="$3"

    local var_url="https://api.github.com/repos/$OWNER/$repo_name/actions/variables/$var_name"
    local body
    body="$(printf '{"name":"%s","value":"%s"}' "$var_name" "$var_value")"

    if curl -fsSL -X PATCH \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "User-Agent: CAIT-Test-Runner" \
        -d "$body" \
        "$var_url" >/dev/null 2>&1; then
        echo -e "    ${COLOR_GREEN}[OK] Variable '$var_name' updated in $repo_name${COLOR_RESET}"
    else
        local create_url="https://api.github.com/repos/$OWNER/$repo_name/actions/variables"
        if curl -fsSL -X POST \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "User-Agent: CAIT-Test-Runner" \
            -d "$body" \
            "$create_url" >/dev/null 2>&1; then
            echo -e "    ${COLOR_GREEN}[OK] Variable '$var_name' created in $repo_name${COLOR_RESET}"
        else
            echo -e "    ${COLOR_YELLOW}[WARN] Could not set variable '$var_name' in $repo_name${COLOR_RESET}" >&2
        fi
    fi
}

# --- Helper: Register App via Manifest for Personal User Account ---
# Populates global variables: REG_APP_ID, REG_CLIENT_ID, REG_SLUG, REG_PEM_PATH, REG_PEM_STRING
register_personal_app_manifest() {
    local app_name="$1"
    local redirect_url="http://localhost:${CALLBACK_PORT}/callback"

    local manifest
    manifest="$(printf '{"name":"%s","url":"https://github.com/%s","hook_attributes":{"url":"https://example.com/webhook","active":false},"redirect_url":"%s","public":false,"default_permissions":{"contents":"read"},"default_events":[]}' \
        "$app_name" "$OWNER" "$redirect_url")"

    # HTML-encode the manifest so it survives as an HTML attribute value.
    # Equivalent to [System.Net.WebUtility]::HtmlEncode() in the .ps1.
    #
    # NOTE: the backslashes before each & are REQUIRED. Since bash 5.2, an
    # unescaped & in the replacement half of ${var//pat/repl} expands to the
    # MATCHED TEXT (sed-style), so "&quot;" silently became '"quot;' and
    # corrupted every quote in the manifest -> GitHub rejected it with
    # "The manifest is not valid JSON". Do not remove the backslashes.
    #
    # & must be encoded FIRST, or it would re-encode the & of its own output.
    local encoded_manifest="${manifest//&/\&amp;}"
    encoded_manifest="${encoded_manifest//\"/\&quot;}"
    encoded_manifest="${encoded_manifest//</\&lt;}"
    encoded_manifest="${encoded_manifest//>/\&gt;}"
    local temp_html="/tmp/github-app-${app_name}.html"

    cat > "$temp_html" <<EOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Registering GitHub App - ${app_name}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #0d1117; color: #c9d1d9; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
    .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 32px; max-width: 520px; text-align: center; }
    h2 { color: #58a6ff; margin-top: 0; }
    p { color: #8b949e; font-size: 14px; line-height: 1.6; }
    .badge { display: inline-block; background: #21262d; border: 1px solid #30363d; padding: 4px 10px; border-radius: 12px; font-family: monospace; color: #7ee787; margin-bottom: 16px; }
    button { background: #238636; color: white; border: none; padding: 10px 24px; font-size: 15px; font-weight: 600; border-radius: 6px; cursor: pointer; }
    button:hover { background: #2ea043; }
  </style>
</head>
<body onload="document.forms[0].submit()">
  <div class="card">
    <h2>Submitting GitHub App Manifest</h2>
    <div class="badge">${app_name}</div>
    <p>Transferring pre-configured permissions, redirect URL, and settings directly to GitHub...</p>
    <form method="post" action="https://github.com/settings/apps/new">
      <input type="hidden" name="manifest" value="${encoded_manifest}" />
      <button type="submit">Click here if not redirected automatically</button>
    </form>
  </div>
</body>
</html>
EOF

    echo -e "\n${COLOR_CYAN}>>> [APP: $app_name] Opening browser to register GitHub App on personal account...${COLOR_RESET}"
    echo -e "${COLOR_DARKGRAY}    Form file: $temp_html${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}    ACTION: In your browser, review pre-filled settings and click 'Create GitHub App'.${COLOR_RESET}"
    open_browser "$temp_html"

    echo -e "${COLOR_CYAN}    Listening on port $CALLBACK_PORT for GitHub authorization code...${COLOR_RESET}"
    local code=""
    if command -v python3 >/dev/null 2>&1; then
        code="$(python3 - "$CALLBACK_PORT" <<'PYEOF'
import http.server, sys, urllib.parse

port = int(sys.argv[1])

class CallbackHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        if "callback" in parsed.path and "code" in params:
            code = params["code"][0]
            body = b"<html><body style='font-family:sans-serif;text-align:center;padding:50px;'><h2>App Created Successfully!</h2><p>You can close this tab and return to your terminal.</p></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            print(code, flush=True)
            raise SystemExit(0)
        else:
            self.send_response(204)
            self.end_headers()

server = http.server.HTTPServer(("127.0.0.1", port), CallbackHandler)
server.serve_forever()
PYEOF
)"
    else
        echo -e "${COLOR_RED}Error: python3 is required to run the local HTTP callback listener.${COLOR_RESET}" >&2
        return 1
    fi

    if [[ -z "$code" ]]; then
        echo -e "${COLOR_RED}Error: No authorization code returned for $app_name${COLOR_RESET}" >&2
        return 1
    fi

    # 4. Exchange code for App credentials (Code conversion must NOT include Bearer token)
    echo -e "    ${COLOR_GREEN}[OK] Received code! Exchanging for App credentials via REST API...${COLOR_RESET}"
    local conversion_url="https://api.github.com/app-manifests/${code}/conversions"
    local conversion_resp
    conversion_resp="$(curl -fsSL -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "User-Agent: CAIT-Test-Runner" \
        "$conversion_url")" || {
        echo -e "${COLOR_RED}Error: Failed to exchange manifest code for $app_name${COLOR_RESET}" >&2
        return 1
    }

    local pem_path="${KEY_DIRECTORY}/${app_name}-private-key.pem"

    # Extract fields and write PEM via python3
    eval "$(CONVERSION_JSON="$conversion_resp" PEM_OUT="$pem_path" python3 - <<'PYEOF'
import json, os, shlex

data = json.loads(os.environ["CONVERSION_JSON"])
pem_path = os.environ["PEM_OUT"]
with open(pem_path, "w", encoding="utf-8") as f:
    f.write(data["pem"])

print(f"REG_APP_ID={shlex.quote(str(data['id']))}")
print(f"REG_CLIENT_ID={shlex.quote(str(data['client_id']))}")
print(f"REG_SLUG={shlex.quote(str(data['slug']))}")
PYEOF
)"
    chmod 600 "$pem_path"
    REG_PEM_PATH="$pem_path"
    REG_PEM_STRING="$(cat "$pem_path")"
    echo -e "    ${COLOR_GREEN}[SAVED] Private key saved to: $pem_path${COLOR_RESET}"
    return 0
}

# Reuse Mode - Verify existing GitHub App without creating a new one
if [[ "$APP_MODE" == "reuse" ]]; then
    VERIFY_SCRIPT="${SCRIPT_DIR}/verify-app-token.sh"

    if [[ ! -f "$VERIFY_SCRIPT" ]]; then
        echo "Error: Verification script not found: $VERIFY_SCRIPT" >&2
        exit 1
    fi

    echo "Verifying existing GitHub App..."

    if ! bash "$VERIFY_SCRIPT" \
        --app-id "$EXISTING_APP_ID" \
        --private-key-path "$EXISTING_APP_KEY" \
        --org-name "$OWNER" \
        --config-repo "${CONFIG_REPO#*/}" \
        --config-file-path "${CONFIG_FILE_PATH}"; then

        echo "Error: GitHub App verification failed." >&2
        exit 1
    fi

    echo "SUCCESS: Existing GitHub App verified."
    exit 0
fi

# ==================== MAIN EXECUTION ====================
echo -e "${COLOR_MAGENTA}=====================================================================${COLOR_RESET}"
echo -e "${COLOR_MAGENTA}   CAIT: TEST RUNNER FOR PERSONAL GITHUB ACCOUNT ($OWNER)            ${COLOR_RESET}"
echo -e "${COLOR_MAGENTA}=====================================================================${COLOR_RESET}"
echo "Target Account   : $OWNER"
echo "Target Repos     : ${REPOS[*]}"
echo "Config Repo      : $CONFIG_REPO"
echo -e "Keys Directory   : $KEY_DIRECTORY\n"


SUMMARY_ROWS=()

for i in "${!APP_NAMES[@]}"; do
    APP_NAME="${APP_NAMES[$i]}"
    REPO="${REPOS[$i]}"

    echo -e "\n${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}STEP 1: Registering GitHub App '$APP_NAME' for Repository '$OWNER/$REPO'${COLOR_RESET}"
    echo -e "${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"

    REG_APP_ID=""
    REG_CLIENT_ID=""
    REG_SLUG=""
    REG_PEM_PATH=""
    REG_PEM_STRING=""

    if [[ "${CREATE_CONFIRMED:-false}" != "true" ]]; then
        echo "ERROR: App creation requires --confirm-create" >&2
        exit 1
    fi

    # Creation disabled until duplicate-app preflight is implemented.
    echo "ERROR: Create mode requires approved duplicate-app preflight." >&2
    exit 1
    if ! register_personal_app_manifest "$APP_NAME"; then
        echo -e "${COLOR_RED}Error: Failed to create GitHub App for $REPO. Skipping to next.${COLOR_RESET}" >&2
        continue
    fi

    echo -e "\n${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}STEP 2: Installing '$APP_NAME' on Your Personal Account ($OWNER)${COLOR_RESET}"
    echo -e "${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"
    INSTALL_URL="https://github.com/settings/apps/${REG_SLUG}/installations"
    echo -e "${COLOR_CYAN}    Launching browser to install App: $INSTALL_URL${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}    ACTION: Select 'Only select repositories' -> choose '$REPO' (and '$CONFIG_REPO' if available) -> click 'Install'.${COLOR_RESET}"
    open_browser "$INSTALL_URL"

    read -r -p "    Press ENTER after you have installed the App in your browser" _

    echo -e "\n${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}STEP 3: Provisioning Secrets & Variables in '$OWNER/$REPO'${COLOR_RESET}"
    echo -e "${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"

    SECRET_SET_1=false
    SECRET_SET_2=false
    if set_personal_secret "$REPO" "CONFIG_APP_CLIENT_ID" "$REG_CLIENT_ID"; then
        SECRET_SET_1=true
    fi
    if set_personal_secret "$REPO" "CONFIG_APP_PRIVATE_KEY" "$REG_PEM_STRING"; then
        SECRET_SET_2=true
    fi
    set_personal_variable "$REPO" "CONFIG_REPO" "$CONFIG_REPO"
    set_personal_variable "$REPO" "CONFIG_APP_ID" "$REG_APP_ID"

    if [[ "$SECRET_SET_1" == "true" && "$SECRET_SET_2" == "true" ]]; then
        SECRET_STATUS_TEXT="Provisioned"
    else
        SECRET_STATUS_TEXT="Check Manual Setup"
    fi

    SUMMARY_ROWS+=("${OWNER}/${REPO}|${APP_NAME}|${REG_APP_ID}|${REG_CLIENT_ID}|${APP_NAME}-private-key.pem|Installed|${SECRET_STATUS_TEXT}")
done

echo -e "\n${COLOR_GREEN}=====================================================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}                       TEST EXECUTION SUMMARY                        ${COLOR_RESET}"
echo -e "${COLOR_GREEN}=====================================================================${COLOR_RESET}"

printf "%-35s %-18s %-10s %-22s %-30s %-14s %-18s\n" \
    "TargetRepository" "GitHubAppName" "AppId" "ClientId" "PrivateKeyFile" "InstallStatus" "SecretStatus"
printf "%-35s %-18s %-10s %-22s %-30s %-14s %-18s\n" \
    "----------------" "-------------" "-----" "--------" "--------------" "-------------" "------------"

for row in "${SUMMARY_ROWS[@]}"; do
    IFS='|' read -r r_repo r_app r_id r_client r_pem r_inst r_sec <<< "$row"
    printf "%-35s %-18s %-10s %-22s %-30s %-14s %-18s\n" \
        "$r_repo" "$r_app" "$r_id" "$r_client" "$r_pem" "$r_inst" "$r_sec"
done

echo -e "\n${COLOR_GREEN}Both test applications have been created and keys are saved in: $KEY_DIRECTORY${COLOR_RESET}"


