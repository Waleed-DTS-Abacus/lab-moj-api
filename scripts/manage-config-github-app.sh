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
#   ./manage-config-github-app.sh --github-token "YOUR_BOOTSTRAP_TOKEN"
# ==============================================================================

set -uo pipefail
umask 077

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

CALLBACK_LISTENER_PID=""
CALLBACK_TEMP_DIR=""
CALLBACK_CODE_FILE=""
CALLBACK_HANDLER_PATH=""
CALLBACK_LISTENER_LOG=""

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

if [[ "$APP_MODE" == "create" ]]; then
    for dependency in jq socat gh curl openssl mktemp chmod; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo -e "${COLOR_RED}Error: '$dependency' is required for GitHub App creation.${COLOR_RESET}" >&2
            exit 1
        fi
    done

    if ! GH_TOKEN="$GITHUB_TOKEN" gh auth status --hostname github.com >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: GitHub CLI is not authenticated. Check GH_TOKEN and GitHub CLI access.${COLOR_RESET}" >&2
        exit 1
    fi
fi

# Resolve Keys Directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${KEY_DIRECTORY// /}" || "$KEY_DIRECTORY" == "/keys" || "$KEY_DIRECTORY" == '\keys' ]]; then
    KEY_DIRECTORY="${SCRIPT_DIR}/keys"
fi
if ! mkdir -p "$KEY_DIRECTORY" || ! chmod 700 "$KEY_DIRECTORY"; then
    echo -e "${COLOR_RED}Error: Could not create or secure the private-key directory.${COLOR_RESET}" >&2
    exit 1
fi

cleanup_callback_resources() {
    if [[ -n "$CALLBACK_LISTENER_PID" ]]; then
        kill "$CALLBACK_LISTENER_PID" 2>/dev/null || true
        wait "$CALLBACK_LISTENER_PID" 2>/dev/null || true
        CALLBACK_LISTENER_PID=""
    fi

    [[ -n "$CALLBACK_CODE_FILE" ]] && rm -f -- "$CALLBACK_CODE_FILE"
    [[ -n "$CALLBACK_HANDLER_PATH" ]] && rm -f -- "$CALLBACK_HANDLER_PATH"
    [[ -n "$CALLBACK_LISTENER_LOG" ]] && rm -f -- "$CALLBACK_LISTENER_LOG"
    if [[ -n "$CALLBACK_TEMP_DIR" ]]; then
        rmdir -- "$CALLBACK_TEMP_DIR" 2>/dev/null || true
        CALLBACK_TEMP_DIR=""
    fi
    CALLBACK_CODE_FILE=""
    CALLBACK_HANDLER_PATH=""
    CALLBACK_LISTENER_LOG=""
}

prepare_callback_handler() {
    CALLBACK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/github-app-callback.XXXXXX")" || {
        echo -e "${COLOR_RED}Error: Could not create a private callback work directory.${COLOR_RESET}" >&2
        return 1
    }
    chmod 700 "$CALLBACK_TEMP_DIR"
    CALLBACK_CODE_FILE="${CALLBACK_TEMP_DIR}/code"
    CALLBACK_HANDLER_PATH="${CALLBACK_TEMP_DIR}/callback-handler.sh"
    CALLBACK_LISTENER_LOG="${CALLBACK_TEMP_DIR}/socat.log"

    if ! chmod 700 "$CALLBACK_TEMP_DIR"; then
        echo -e "${COLOR_RED}Error: Could not secure the callback work directory.${COLOR_RESET}" >&2
        cleanup_callback_resources
        return 1
    fi

    if ! cat > "$CALLBACK_HANDLER_PATH" <<'CALLBACK_HANDLER'
#!/usr/bin/env bash
set -euo pipefail
umask 077
local_decode_query_value() {
    local LC_ALL=C
    local input="$1"
    local output=""
    local character hex index=0

    while (( index < ${#input} )); do
        character="${input:index:1}"
        case "$character" in
            %)
                hex="${input:$((index + 1)):2}"
                [[ "$hex" =~ ^[[:xdigit:]]{2}$ && "$hex" != "00" ]] || return 1
                printf -v character '%b' "\\x${hex}"
                output+="$character"
                index=$((index + 3))
                ;;
            +)
                output+=" "
                index=$((index + 1))
                ;;
            *)
                output+="$character"
                index=$((index + 1))
                ;;
        esac
    done

    printf '%s' "$output"
}

send_response() {
    local status="$1"
    local body="$2"
    printf 'HTTP/1.1 %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$status" "${#body}" "$body"
}

IFS= read -r request_line || exit 1
request_line="${request_line%$'\r'}"
while IFS= read -r header; do
    [[ -z "$header" || "$header" == $'\r' ]] && break
done

if [[ "$request_line" != GET\ *\ HTTP/1.0 && "$request_line" != GET\ *\ HTTP/1.1 ]]; then
    send_response "400 Bad Request" "<html><body>Invalid callback request.</body></html>"
    exit 0
fi

request_target="${request_line#GET }"
request_target="${request_target%% *}"
if [[ "$request_target" != /callback\?* ]]; then
    send_response "404 Not Found" "<html><body>Callback not found.</body></html>"
    exit 0
fi

query="${request_target#*\?}"
callback_code=""
IFS='&' read -r -a query_fields <<< "$query"
for field in "${query_fields[@]}"; do
    if [[ "${field%%=*}" == "code" && "$field" == *=* ]]; then
        callback_code="$(local_decode_query_value "${field#*=}")" || {
            send_response "400 Bad Request" "<html><body>Invalid callback code.</body></html>"
            exit 0
        }
        break
    fi
done

if [[ -z "$callback_code" || "$callback_code" =~ [[:cntrl:]] ]]; then
    send_response "400 Bad Request" "<html><body>Invalid callback code.</body></html>"
    exit 0
fi

if [[ -e "$CALLBACK_CODE_FILE" ]] || ! (set -o noclobber; printf '%s\n' "$callback_code" > "$CALLBACK_CODE_FILE") 2>/dev/null; then
    send_response "409 Conflict" "<html><body>Callback already received.</body></html>"
    exit 0
fi

send_response "200 OK" "<html><body style='font-family:sans-serif;text-align:center;padding:50px;'><h2>App Created Successfully!</h2><p>You can close this tab and return to your terminal.</p></body></html>"
CALLBACK_HANDLER
    then
        echo -e "${COLOR_RED}Error: Could not create the callback handler.${COLOR_RESET}" >&2
        cleanup_callback_resources
        return 1
    fi

    if ! chmod 700 "$CALLBACK_HANDLER_PATH"; then
        echo -e "${COLOR_RED}Error: Could not secure the callback handler.${COLOR_RESET}" >&2
        cleanup_callback_resources
        return 1
    fi
}

start_callback_listener() {
    local requested_port="$CALLBACK_PORT"
    local first_port last_port port attempt ready listener_output auto_select=false
    local port_number

    if [[ ! "$requested_port" =~ ^[0-9]+$ ]]; then
        echo -e "${COLOR_RED}Error: Callback port must be a number between 0 and 65535.${COLOR_RESET}" >&2
        return 1
    fi
    port_number=$((10#$requested_port))
    if (( port_number < 0 || port_number > 65535 )); then
        echo -e "${COLOR_RED}Error: Callback port must be between 0 and 65535.${COLOR_RESET}" >&2
        return 1
    fi

    if (( port_number == 0 || port_number == 8080 )); then
        auto_select=true
        first_port=8181
        last_port=$((first_port + 49))
    else
        first_port="$port_number"
        last_port="$port_number"
    fi

    for ((port = first_port; port <= last_port; port++)); do
        : > "$CALLBACK_LISTENER_LOG"
        CALLBACK_CODE_FILE="$CALLBACK_CODE_FILE" socat -d -d \
            "TCP-LISTEN:${port},bind=127.0.0.1,reuseaddr,fork" \
            "EXEC:${CALLBACK_HANDLER_PATH}" \
            >/dev/null 2>"$CALLBACK_LISTENER_LOG" &
        CALLBACK_LISTENER_PID=$!

        ready=false
        for ((attempt = 0; attempt < 40; attempt++)); do
            if ! kill -0 "$CALLBACK_LISTENER_PID" 2>/dev/null; then
                wait "$CALLBACK_LISTENER_PID" 2>/dev/null || true
                CALLBACK_LISTENER_PID=""
                break
            fi
            listener_output="$(<"$CALLBACK_LISTENER_LOG")"
            if [[ "$listener_output" == *"listening on"* ]]; then
                ready=true
                break
            fi
            sleep 0.05
        done

        if [[ "$ready" == true ]]; then
            CALLBACK_PORT="$port"
            return 0
        fi

        if [[ -n "$CALLBACK_LISTENER_PID" ]]; then
            kill "$CALLBACK_LISTENER_PID" 2>/dev/null || true
            wait "$CALLBACK_LISTENER_PID" 2>/dev/null || true
            CALLBACK_LISTENER_PID=""
        fi

        if [[ "$auto_select" != true ]]; then
            echo -e "${COLOR_RED}Error: Could not bind the callback listener to port $port. Ensure the port is available.${COLOR_RESET}" >&2
            return 1
        fi
    done

    echo -e "${COLOR_RED}Error: Could not bind the callback listener to any port from $first_port through $last_port.${COLOR_RESET}" >&2
    return 1
}

decode_url_path_segment() {
    local LC_ALL=C
    local input="$1"
    local output=""
    local character hex index

    for ((index = 0; index < ${#input}; index++)); do
        character="${input:index:1}"
        case "$character" in
            [a-zA-Z0-9._~-])
                output+="$character"
                ;;
            *)
                printf -v hex '%02X' "'$character"
                output+="%${hex}"
                ;;
        esac
    done

    printf '%s' "$output"
}

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

# --- Helper: Upload Secret with GitHub CLI ---
set_personal_secret() {
    local repo_name="$1"
    local secret_name="$2"
    local secret_value="$3"
    local gh_path

    if ! gh_path="$(command -v gh)"; then
        echo -e "${COLOR_RED}Error: GitHub CLI (gh) is required to set Actions secrets.${COLOR_RESET}" >&2
        return 1
    fi

    if [[ -z "$GITHUB_TOKEN" ]]; then
        echo -e "${COLOR_RED}Error: A GitHub CLI token is required to set Actions secrets.${COLOR_RESET}" >&2
        return 1
    fi

    if ! printf '%s' "$secret_value" | GH_TOKEN="$GITHUB_TOKEN" "$gh_path" secret set \
        "$secret_name" --repo "$OWNER/$repo_name"; then
        echo -e "${COLOR_RED}Error: Could not set '$secret_name' in '$OWNER/$repo_name'. Verify GitHub CLI authentication and Actions secrets write permission.${COLOR_RESET}" >&2
        return 1
    fi

    echo -e "    ${COLOR_GREEN}[OK] Secret '$secret_name' set via gh CLI in $repo_name${COLOR_RESET}"
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
        return 0
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
            return 0
        else
            echo -e "    ${COLOR_YELLOW}[WARN] Could not set variable '$var_name' in $repo_name${COLOR_RESET}" >&2
            return 1
        fi
    fi
}

# --- Helper: Register App via Manifest for Personal User Account ---
# Populates global variables: REG_APP_ID, REG_CLIENT_ID, REG_SLUG, REG_PEM_PATH, REG_PEM_STRING
register_personal_app_manifest() {
    local app_name="$1"
    local redirect_url
    local manifest
    local code=""
    local encoded_code
    local conversion_url
    local conversion_resp
    local pem_path
    local pem_tmp

    if ! prepare_callback_handler; then
        return 1
    fi
    trap cleanup_callback_resources EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if ! start_callback_listener; then
        cleanup_callback_resources
        trap - EXIT INT TERM
        return 1
    fi

    redirect_url="http://localhost:${CALLBACK_PORT}/callback"
    if ! manifest="$(jq -cn \
        --arg name "$app_name" \
        --arg owner "$OWNER" \
        --arg redirect_url "$redirect_url" \
        '{name:$name,url:("https://github.com/"+$owner),hook_attributes:{url:"https://example.com/webhook",active:false},redirect_url:$redirect_url,public:false,default_permissions:{contents:"read"},default_events:[]}')"; then
        echo -e "${COLOR_RED}Error: Could not create the GitHub App manifest JSON.${COLOR_RESET}" >&2
        cleanup_callback_resources
        trap - EXIT INT TERM
        return 1
    fi

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

    echo -e "${COLOR_CYAN}    Listening on port $CALLBACK_PORT for GitHub authorization code...${COLOR_RESET}"
    echo -e "\n${COLOR_CYAN}>>> [APP: $app_name] Opening browser to register GitHub App on personal account...${COLOR_RESET}"
    echo -e "${COLOR_DARKGRAY}    Form file: $temp_html${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}    ACTION: In your browser, review pre-filled settings and click 'Create GitHub App'.${COLOR_RESET}"
    open_browser "$temp_html"

    while [[ ! -s "$CALLBACK_CODE_FILE" ]]; do
        if ! kill -0 "$CALLBACK_LISTENER_PID" 2>/dev/null; then
            echo -e "${COLOR_RED}Error: The GitHub App callback listener stopped unexpectedly.${COLOR_RESET}" >&2
            cleanup_callback_resources
            trap - EXIT INT TERM
            return 1
        fi
        sleep 0.2
    done
    IFS= read -r code < "$CALLBACK_CODE_FILE" || code=""

    if [[ -z "$code" ]]; then
        echo -e "${COLOR_RED}Error: No authorization code returned for $app_name${COLOR_RESET}" >&2
        cleanup_callback_resources
        trap - EXIT INT TERM
        return 1
    fi

    cleanup_callback_resources
    trap - EXIT INT TERM

    # 4. Exchange code for App credentials (Code conversion must NOT include Bearer token)
    echo -e "    ${COLOR_GREEN}[OK] Received code! Exchanging for App credentials via REST API...${COLOR_RESET}"
    encoded_code="$(decode_url_path_segment "$code")"
    conversion_url="https://api.github.com/app-manifests/${encoded_code}/conversions"
    conversion_resp="$(curl -fsSL --config - <<EOF
url = "$conversion_url"
request = "POST"
header = "Accept: application/vnd.github+json"
header = "X-GitHub-Api-Version: 2022-11-28"
header = "User-Agent: CAIT-Test-Runner"
EOF
    )" || {
        echo -e "${COLOR_RED}Error: Failed to exchange manifest code for $app_name${COLOR_RESET}" >&2
        return 1
    }

    if ! jq -e '
        type == "object"
        and (.id | type == "number" or (type == "string" and length > 0))
        and (.client_id | type == "string" and length > 0)
        and (.slug | type == "string" and length > 0)
        and (.pem | type == "string" and length > 0)
    ' >/dev/null 2>&1 <<< "$conversion_resp"; then
        echo -e "${COLOR_RED}Error: GitHub returned an invalid App manifest conversion response.${COLOR_RESET}" >&2
        return 1
    fi

    REG_APP_ID="$(jq -r '.id' <<< "$conversion_resp")"
    REG_CLIENT_ID="$(jq -r '.client_id' <<< "$conversion_resp")"
    REG_SLUG="$(jq -r '.slug' <<< "$conversion_resp")"
    pem_path="${KEY_DIRECTORY}/${app_name}-private-key.pem"
    pem_tmp="$(mktemp "${pem_path}.tmp.XXXXXX")" || {
        echo -e "${COLOR_RED}Error: Could not create a secure temporary private-key file.${COLOR_RESET}" >&2
        return 1
    }
    if ! jq -jer '.pem | select(type == "string" and length > 0)' <<< "$conversion_resp" > "$pem_tmp"; then
        rm -f -- "$pem_tmp"
        echo -e "${COLOR_RED}Error: Could not extract the private key from GitHub's response.${COLOR_RESET}" >&2
        return 1
    fi
    if ! chmod 600 "$pem_tmp"; then
        rm -f -- "$pem_tmp"
        echo -e "${COLOR_RED}Error: Could not secure the generated private-key file.${COLOR_RESET}" >&2
        return 1
    fi
    if ! mv -f -- "$pem_tmp" "$pem_path"; then
        rm -f -- "$pem_tmp"
        echo -e "${COLOR_RED}Error: Could not save the generated private-key file.${COLOR_RESET}" >&2
        return 1
    fi
    if ! chmod 600 "$pem_path"; then
        rm -f -- "$pem_path"
        echo -e "${COLOR_RED}Error: Could not secure the generated private-key file.${COLOR_RESET}" >&2
        return 1
    fi
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

    # Best-effort duplicate check before opening GitHub registration.
    APP_SLUG="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"

    HTTP_CODE="$(curl -sS -L -o /dev/null -w '%{http_code}' \
        "https://github.com/apps/${APP_SLUG}")" || {
        echo "ERROR: Could not check GitHub App name." >&2
        exit 1
    }

    case "$HTTP_CODE" in
        200)
            echo "ERROR: GitHub App '$APP_SLUG' already exists." >&2
            exit 1
            ;;
        404)
            echo "Preflight passed: No public App found with slug '$APP_SLUG'."
            ;;
        *)
            echo "ERROR: Unexpected GitHub response: $HTTP_CODE" >&2
            exit 1
            ;;
    esac
    if ! register_personal_app_manifest "$APP_NAME"; then
        echo -e "${COLOR_RED}Error: Failed to create GitHub App for $REPO. Skipping to next.${COLOR_RESET}" >&2
        continue
    fi

    echo -e "\n${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}STEP 2: Installing '$APP_NAME' on Your Personal Account ($OWNER)${COLOR_RESET}"
    echo -e "${COLOR_DARKGRAY}---------------------------------------------------------------------${COLOR_RESET}"
    INSTALL_URL="https://github.com/settings/apps/${REG_SLUG}/installations"
    echo -e "${COLOR_CYAN}    Launching browser to install App: $INSTALL_URL${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}    ACTION: Select 'Only select repositories' -> choose ONLY '$CONFIG_REPO' -> click 'Install'.${COLOR_RESET}"
    open_browser "$INSTALL_URL"

    read -r -p "    Press ENTER after you have installed the App in your browser" _

    echo "Verifying GitHub App installation and repository access..."

    if ! bash "${SCRIPT_DIR}/verify-app-token.sh" \
        --app-id "$REG_APP_ID" \
        --private-key-path "$REG_PEM_PATH" \
        --org-name "$OWNER" \
        --config-repo "${CONFIG_REPO#*/}" \
        --config-file-path "$CONFIG_FILE_PATH"; then

        echo "ERROR: GitHub App installation verification failed." >&2
        exit 1
    fi

    echo "SUCCESS: GitHub App installation verified."
    if ! chmod 600 "$REG_PEM_PATH"; then
        echo "ERROR: Could not secure the generated private-key file." >&2
        exit 1
    fi

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
    VARIABLE_SET_1=false
    VARIABLE_SET_2=false

    if set_personal_variable "$REPO" "CONFIG_REPO" "$CONFIG_REPO"; then
        VARIABLE_SET_1=true
    fi

    if set_personal_variable "$REPO" "CONFIG_APP_ID" "$REG_APP_ID"; then
        VARIABLE_SET_2=true
    fi

    if [[ "$SECRET_SET_1" == "true" && "$SECRET_SET_2" == "true" && "$VARIABLE_SET_1" == "true" && "$VARIABLE_SET_2" == "true" ]]; then
        SECRET_STATUS_TEXT="Provisioned"
    else
        SECRET_STATUS_TEXT="Check Manual Setup"
        echo "ERROR: Required GitHub Secrets or Variables provisioning failed." >&2
        exit 1
    fi

    if ! chmod 600 "$REG_PEM_PATH"; then
        echo "ERROR: Could not secure the generated private-key file." >&2
        exit 1
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

echo -e "\n${COLOR_GREEN}${#SUMMARY_ROWS[@]} GitHub App(s) processed successfully. Keys directory: $KEY_DIRECTORY${COLOR_RESET}"


