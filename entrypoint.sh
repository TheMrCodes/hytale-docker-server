#!/bin/bash
# ==============================================================================
# Hytale Server Entrypoint
# ==============================================================================
# Handles server file download, configuration, and startup.
# ==============================================================================

set -e

print_banner() {
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              Dealer Node - Hytale Server                         ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
}

log_info() {
    echo "[Dealer Node] $*"
}

log_warn() {
    echo "[WARNING] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

format_epoch() {
    local timestamp="$1"
    if date -d "@${timestamp}" "+%Y-%m-%d %H:%M:%S %Z" >/dev/null 2>&1; then
        date -d "@${timestamp}" "+%Y-%m-%d %H:%M:%S %Z"
    else
        echo "$timestamp"
    fi
}

validate_integer() {
    local value="$1"
    local name="$2"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "$name must be a number (got '$value')"
        exit 1
    fi
}

normalize_bool() {
    local value="$1"
    echo "${value,,}"
}

# ------------------------------------------------------------------------------
# Configuration Defaults
# ------------------------------------------------------------------------------
SERVER_NAME="${SERVER_NAME:-Hytale Server}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
MAX_PLAYERS="${MAX_PLAYERS:-10}"
VIEW_DISTANCE="${VIEW_DISTANCE:-10}"
MEMORY_MB="${MEMORY_MB:-4096}"
AUTH_MODE="${AUTH_MODE:-authenticated}"
UPDATE_MODE="${UPDATE_MODE:-auto}"
ENABLE_AOT="${ENABLE_AOT:-true}"
SKIP_UPDATE_CHECK="${SKIP_UPDATE_CHECK:-false}"

CREDENTIALS_FILE="${CREDENTIALS_FILE:-/server/.hytale-downloader-credentials.json}"
SERVER_CREDENTIALS_FILE="${SERVER_CREDENTIALS_FILE:-/server/.hytale-server-credentials.json}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
CURRENT_VERSION_FILE="${CURRENT_VERSION_FILE:-/server/server-files/.current-version}"
CONFIG_DIR="${CONFIG_DIR:-/server/config}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.json}"
SERVER_CONFIG_LINK="${SERVER_CONFIG_LINK:-/server/server-files/config.json}"
AOT_CACHE_DIR="${AOT_CACHE_DIR:-/server/.aot-cache}"
AOT_CACHE_FILE="${AOT_CACHE_FILE:-${AOT_CACHE_DIR}/HytaleServer.aot}"
AOT_VERSION_FILE="${AOT_VERSION_FILE:-${AOT_CACHE_DIR}/.version}"
SERVER_FILES_DIR="${SERVER_FILES_DIR:-/server/server-files}"

UPDATE_MODE="${UPDATE_MODE,,}"
ENABLE_AOT="$(normalize_bool "$ENABLE_AOT")"
SKIP_UPDATE_CHECK="$(normalize_bool "$SKIP_UPDATE_CHECK")"

validate_integer "$MAX_PLAYERS" "MAX_PLAYERS"
validate_integer "$VIEW_DISTANCE" "VIEW_DISTANCE"
validate_integer "$MEMORY_MB" "MEMORY_MB"

case "$UPDATE_MODE" in
    auto|always|never) ;;
    *)
        log_error "UPDATE_MODE must be auto, always, or never (got '$UPDATE_MODE')"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# Signal Handling
# ------------------------------------------------------------------------------
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
        log_info "Stopping Hytale server..."
        kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------------------
# Validate required files and tools
# ------------------------------------------------------------------------------
validate_prerequisites() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        log_error "Credentials file not found at $CREDENTIALS_FILE"
        log_error "Mount .hytale-downloader-credentials.json into /server"
        exit 1
    fi

    if ! jq empty "$CREDENTIALS_FILE" >/dev/null 2>&1; then
        log_error "Credentials file is not valid JSON: $CREDENTIALS_FILE"
        exit 1
    fi

    # Try to set secure permissions (may fail on bind mounts with different ownership)
    chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true

    if ! command -v java >/dev/null 2>&1; then
        log_error "Java is not installed"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is not installed"
        exit 1
    fi

    local java_version
    java_version=$(java -version 2>&1 | head -n 1)
    if ! echo "$java_version" | grep -q '"25'; then
        log_warn "Java 25 is recommended (detected: $java_version)"
    fi
}

# ------------------------------------------------------------------------------
# Configure hytale-downloader authentication
# ------------------------------------------------------------------------------
refresh_token_if_needed() {
    local expires_at
    expires_at=$(jq -r '.expires_at // 0' "$CREDENTIALS_FILE")
    # Ensure expires_at is a valid integer
    if ! [[ "$expires_at" =~ ^[0-9]+$ ]]; then
        expires_at=0
    fi
    local current_time
    current_time=$(date +%s)
    local buffer=300

    if [ "$expires_at" -le "$((current_time + buffer))" ]; then
        log_info "Access token expired or expiring soon, refreshing..."

        local refresh_token
        refresh_token=$(jq -r '.refresh_token // empty' "$CREDENTIALS_FILE")
        if [ -z "$refresh_token" ] || [ "$refresh_token" = "null" ]; then
            log_error "No refresh token available"
            exit 1
        fi

        local response
        response=$(curl -s -X POST "https://oauth.accounts.hytale.com/oauth2/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=refresh_token" \
            -d "client_id=hytale-downloader" \
            -d "refresh_token=$refresh_token")

        local new_access_token
        new_access_token=$(echo "$response" | jq -r '.access_token // empty')
        if [ -z "$new_access_token" ]; then
            log_error "Failed to refresh token: $(echo "$response" | jq -r '.error_description // .error // "Unknown error"')"
            exit 1
        fi

        local new_refresh_token
        new_refresh_token=$(echo "$response" | jq -r '.refresh_token // empty')
        local new_expires_in
        new_expires_in=$(echo "$response" | jq -r '.expires_in // 3600')
        local new_expires_at
        new_expires_at=$((current_time + new_expires_in))
        local branch
        branch=$(jq -r '.branch // "release"' "$CREDENTIALS_FILE")

        jq -n \
            --arg at "$new_access_token" \
            --arg rt "${new_refresh_token:-$refresh_token}" \
            --argjson ea "$new_expires_at" \
            --arg br "$branch" \
            '{access_token: $at, refresh_token: $rt, expires_at: $ea, branch: $br}' \
            > "$CREDENTIALS_FILE"

        chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true
        log_info "Token refreshed successfully (expires at: $(format_epoch "$new_expires_at"))"
    else
        log_info "Access token still valid (expires at: $(format_epoch "$expires_at"))"
    fi
}

# ------------------------------------------------------------------------------
# Server authentication (OAuth device flow for server tokens)
# ------------------------------------------------------------------------------
OAUTH_CLIENT_ID="hytale-server"
OAUTH_SCOPES="openid offline auth:server"
OAUTH_DEVICE_AUTH_URL="https://oauth.accounts.hytale.com/oauth2/device/auth"
OAUTH_TOKEN_URL="https://oauth.accounts.hytale.com/oauth2/token"
PROFILES_URL="https://account-data.hytale.com/my-account/get-profiles"
SESSION_URL="https://sessions.hytale.com/game-session/new"

# ------------------------------------------------------------------------------
# Discord Webhook Notifications
# ------------------------------------------------------------------------------
send_discord_notification() {
    local title="$1"
    local description="$2"
    local color="${3:-3447003}"  # Default blue color
    local url="${4:-}"

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        return
    fi

    local payload
    if [ -n "$url" ]; then
        payload=$(jq -n \
            --arg title "$title" \
            --arg desc "$description" \
            --argjson color "$color" \
            --arg url "$url" \
            '{
                embeds: [{
                    title: $title,
                    description: $desc,
                    color: $color,
                    fields: [{
                        name: "Quick Link",
                        value: $url
                    }],
                    timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
                }]
            }')
    else
        payload=$(jq -n \
            --arg title "$title" \
            --arg desc "$description" \
            --argjson color "$color" \
            '{
                embeds: [{
                    title: $title,
                    description: $desc,
                    color: $color,
                    timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
                }]
            }')
    fi

    curl -s -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1 || log_warn "Failed to send Discord notification"
}

# Check if server credentials exist and are valid
check_server_credentials() {
    if [ ! -f "$SERVER_CREDENTIALS_FILE" ]; then
        return 1
    fi

    if ! jq empty "$SERVER_CREDENTIALS_FILE" >/dev/null 2>&1; then
        return 1
    fi

    # Check if game session tokens exist and are valid
    local session_expires_at
    session_expires_at=$(jq -r '.session_expires_at // 0' "$SERVER_CREDENTIALS_FILE")
    if ! [[ "$session_expires_at" =~ ^[0-9]+$ ]]; then
        session_expires_at=0
    fi

    local current_time
    current_time=$(date +%s)
    local buffer=300  # 5 minute buffer

    if [ "$session_expires_at" -gt "$((current_time + buffer))" ]; then
        # Session tokens still valid
        return 0
    fi

    # Session expired, try to refresh OAuth token and create new session
    local refresh_token
    refresh_token=$(jq -r '.refresh_token // empty' "$SERVER_CREDENTIALS_FILE")
    if [ -n "$refresh_token" ] && [ "$refresh_token" != "null" ]; then
        if refresh_and_create_session "$refresh_token"; then
            return 0
        fi
    fi

    return 1
}

# Refresh OAuth token and create new game session
refresh_and_create_session() {
    local refresh_token="$1"
    log_info "Refreshing server OAuth token..."

    local response
    response=$(curl -s -X POST "$OAUTH_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=refresh_token" \
        -d "client_id=$OAUTH_CLIENT_ID" \
        -d "refresh_token=$refresh_token")

    local access_token
    access_token=$(echo "$response" | jq -r '.access_token // empty')
    if [ -z "$access_token" ]; then
        log_warn "Failed to refresh OAuth token: $(echo "$response" | jq -r '.error_description // .error // "Unknown error"')"
        return 1
    fi

    local new_refresh_token
    new_refresh_token=$(echo "$response" | jq -r '.refresh_token // empty')
    
    # Create new game session with refreshed token
    if create_game_session "$access_token" "${new_refresh_token:-$refresh_token}"; then
        return 0
    fi

    return 1
}

# Get profiles and create game session
create_game_session() {
    local access_token="$1"
    local refresh_token="$2"

    log_info "Fetching game profiles..."
    local profiles_response
    profiles_response=$(curl -s -X GET "$PROFILES_URL" \
        -H "Authorization: Bearer $access_token")

    local profile_uuid
    profile_uuid=$(echo "$profiles_response" | jq -r '.profiles[0].uuid // empty')
    local profile_username
    profile_username=$(echo "$profiles_response" | jq -r '.profiles[0].username // empty')

    if [ -z "$profile_uuid" ]; then
        log_error "No game profiles found: $(echo "$profiles_response" | jq -r '.error // .message // "Unknown error"')"
        return 1
    fi

    log_info "Using profile: $profile_username ($profile_uuid)"

    log_info "Creating game session..."
    local session_response
    session_response=$(curl -s -X POST "$SESSION_URL" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        -d "{\"uuid\": \"$profile_uuid\"}")

    local session_token
    session_token=$(echo "$session_response" | jq -r '.sessionToken // empty')
    local identity_token
    identity_token=$(echo "$session_response" | jq -r '.identityToken // empty')
    local expires_at_str
    expires_at_str=$(echo "$session_response" | jq -r '.expiresAt // empty')

    if [ -z "$session_token" ] || [ -z "$identity_token" ]; then
        log_error "Failed to create game session: $(echo "$session_response" | jq -r '.error // .message // "Unknown error"')"
        return 1
    fi

    # Convert ISO timestamp to epoch
    local session_expires_at
    if [ -n "$expires_at_str" ]; then
        session_expires_at=$(date -d "$expires_at_str" +%s 2>/dev/null || echo $(($(date +%s) + 3600)))
    else
        session_expires_at=$(($(date +%s) + 3600))
    fi

    # Save all credentials
    jq -n \
        --arg at "$access_token" \
        --arg rt "$refresh_token" \
        --arg st "$session_token" \
        --arg it "$identity_token" \
        --arg pu "$profile_uuid" \
        --arg pn "$profile_username" \
        --argjson sea "$session_expires_at" \
        '{
            access_token: $at,
            refresh_token: $rt,
            session_token: $st,
            identity_token: $it,
            profile_uuid: $pu,
            profile_username: $pn,
            session_expires_at: $sea
        }' > "$SERVER_CREDENTIALS_FILE"

    chmod 600 "$SERVER_CREDENTIALS_FILE" 2>/dev/null || true
    log_info "Game session created (expires at: $(format_epoch "$session_expires_at"))"
    return 0
}

# Perform OAuth device flow for server authentication
perform_device_auth() {
    log_info "Starting OAuth device flow for server authentication..."

    # Request device code
    local device_response
    device_response=$(curl -s -X POST "$OAUTH_DEVICE_AUTH_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=$OAUTH_CLIENT_ID" \
        -d "scope=$OAUTH_SCOPES")

    local device_code
    device_code=$(echo "$device_response" | jq -r '.device_code // empty')
    local user_code
    user_code=$(echo "$device_response" | jq -r '.user_code // empty')
    local verification_uri
    verification_uri=$(echo "$device_response" | jq -r '.verification_uri // empty')
    local verification_uri_complete
    verification_uri_complete=$(echo "$device_response" | jq -r '.verification_uri_complete // empty')
    local interval
    interval=$(echo "$device_response" | jq -r '.interval // 5')
    local expires_in
    expires_in=$(echo "$device_response" | jq -r '.expires_in // 900')

    if [ -z "$device_code" ] || [ -z "$user_code" ]; then
        log_error "Failed to start device flow: $(echo "$device_response" | jq -r '.error_description // .error // "Unknown error"')"
        return 1
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    SERVER AUTHENTICATION                         ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  Visit: $verification_uri"
    echo "║  Code:  $user_code"
    echo "║"
    echo "║  Or go directly to:"
    echo "║  $verification_uri_complete"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Waiting for authorization (expires in ${expires_in} seconds)..."

    # Send Discord notification with verification link
    send_discord_notification \
        "🔐 Hytale Server Authentication Required" \
        $'The server needs authentication to start.\n\n**Code:** `'"${user_code}"$'`\n\n**Click the link below or visit:** '"${verification_uri}" \
        "16776960" \
        "$verification_uri_complete"

    # Poll for token
    local start_time
    start_time=$(date +%s)
    local end_time
    end_time=$((start_time + expires_in))

    while [ "$(date +%s)" -lt "$end_time" ]; do
        sleep "$interval"

        local token_response
        token_response=$(curl -s -X POST "$OAUTH_TOKEN_URL" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            -d "client_id=$OAUTH_CLIENT_ID" \
            -d "device_code=$device_code")

        local error
        error=$(echo "$token_response" | jq -r '.error // empty')

        case "$error" in
            "authorization_pending")
                # Still waiting, continue polling
                ;;
            "slow_down")
                # Increase interval
                interval=$((interval + 5))
                ;;
            "")
                # Success - we got OAuth tokens
                local access_token
                access_token=$(echo "$token_response" | jq -r '.access_token // empty')
                local refresh_token
                refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty')

                if [ -n "$access_token" ]; then
                    log_info "OAuth authorization successful!"
                    
                    # Send success notification to Discord
                    send_discord_notification \
                        "✅ Authentication Successful" \
                        "Server authentication completed successfully. The server is now starting." \
                        "5763719"
                    
                    # Now create game session
                    if create_game_session "$access_token" "$refresh_token"; then
                        return 0
                    else
                        return 1
                    fi
                fi
                ;;
            *)
                log_error "Authentication failed: $(echo "$token_response" | jq -r '.error_description // .error')"
                return 1
                ;;
        esac
    done

    log_error "Authentication timed out"
    return 1
}

# Get server token arguments for CLI (or set env vars)
get_server_token_args() {
    SERVER_TOKEN_ARGS=""

    if [ ! -f "$SERVER_CREDENTIALS_FILE" ]; then
        return
    fi

    local session_token
    session_token=$(jq -r '.session_token // empty' "$SERVER_CREDENTIALS_FILE")
    local identity_token
    identity_token=$(jq -r '.identity_token // empty' "$SERVER_CREDENTIALS_FILE")

    if [ -n "$session_token" ] && [ "$session_token" != "null" ]; then
        export HYTALE_SERVER_SESSION_TOKEN="$session_token"
        log_info "Session token loaded"
    fi

    if [ -n "$identity_token" ] && [ "$identity_token" != "null" ]; then
        export HYTALE_SERVER_IDENTITY_TOKEN="$identity_token"
        log_info "Identity token loaded"
    fi
}

# Handle server authentication
handle_server_auth() {
    if [ "$AUTH_MODE" != "authenticated" ]; then
        log_info "Auth mode is '$AUTH_MODE', skipping server authentication"
        return
    fi

    # Check if tokens already provided via environment
    if [ -n "$HYTALE_SERVER_SESSION_TOKEN" ] && [ -n "$HYTALE_SERVER_IDENTITY_TOKEN" ]; then
        log_info "Using server tokens from environment"
        return
    fi

    if check_server_credentials; then
        log_info "Server credentials valid"
        get_server_token_args
        return
    fi

    log_info "No valid server credentials found"
    
    # Check if we're running interactively or have Discord webhook
    if [ -t 0 ] || [ -n "$DISCORD_WEBHOOK_URL" ]; then
        # Interactive mode or Discord webhook available - perform device auth
        if perform_device_auth; then
            get_server_token_args
        else
            log_warn "Server authentication failed - server will start without tokens"
            log_warn "Use '/auth login device' in server console to authenticate"
        fi
    else
        log_warn "Non-interactive mode and no Discord webhook configured"
        log_warn "Run 'docker compose up' (without -d) first to authenticate"
        log_warn "Or set DISCORD_WEBHOOK_URL to receive auth links via Discord"
        log_warn "Or mount existing credentials at $SERVER_CREDENTIALS_FILE"
    fi
}

# ------------------------------------------------------------------------------
# Downloader detection
# ------------------------------------------------------------------------------
setup_downloader() {
    if [ -f "/server/hytale-downloader.exe" ]; then
        DOWNLOADER="/server/hytale-downloader.exe"
    elif [ -f "/server/hytale-downloader" ]; then
        DOWNLOADER="/server/hytale-downloader"
    else
        log_error "hytale-downloader not found"
        exit 1
    fi

    DOWNLOADER_ARGS=()
    # Always specify credentials path explicitly
    DOWNLOADER_ARGS+=("-credentials-path" "$CREDENTIALS_FILE")
    if [ "$SKIP_UPDATE_CHECK" = "true" ]; then
        DOWNLOADER_ARGS+=("-skip-update-check")
    fi

    log_info "Using downloader: $DOWNLOADER"
}

get_recorded_version() {
    if [ -f "$CURRENT_VERSION_FILE" ]; then
        cat "$CURRENT_VERSION_FILE"
    fi
}

get_remote_version() {
    "$DOWNLOADER" "${DOWNLOADER_ARGS[@]}" -print-version 2>/dev/null | head -n 1 | tr -d '\r'
}

get_local_version_fallback() {
    if [ -f "$SERVER_FILES_DIR/HytaleServer.jar" ]; then
        stat -c %Y "$SERVER_FILES_DIR/HytaleServer.jar" 2>/dev/null || date +%s
    else
        date +%s
    fi
}

record_version() {
    local version="$1"
    if [ -n "$version" ]; then
        echo "$version" > "$CURRENT_VERSION_FILE"
    fi
}

ensure_recorded_version() {
    if [ ! -f "$CURRENT_VERSION_FILE" ]; then
        record_version "$(get_local_version_fallback)"
    fi
}

invalidate_aot_cache() {
    rm -f "$AOT_CACHE_FILE" "$AOT_VERSION_FILE"
}

# ------------------------------------------------------------------------------
# Download/update server files
# ------------------------------------------------------------------------------
download_server_files() {
    local remote_version="$1"

    mkdir -p "$SERVER_FILES_DIR"
    cd "$SERVER_FILES_DIR"

    log_info "Downloading server files..."
    "$DOWNLOADER" "${DOWNLOADER_ARGS[@]}" -download-path server-files.zip

    if [ ! -f "server-files.zip" ]; then
        log_error "Failed to download server files"
        exit 1
    fi

    log_info "Unzipping server files..."
    unzip -q -o server-files.zip -d .
    rm -f server-files.zip

    if [ -d "Server" ] && [ -f "Server/HytaleServer.jar" ]; then
        log_info "Detected 'Server' subdirectory, moving files to root..."
        # Use cp + rm to handle hidden files properly
        cp -a Server/. .
        rm -rf Server
    fi

    cd /server

    record_version "${remote_version:-$(get_local_version_fallback)}"
    invalidate_aot_cache
    log_info "Server files downloaded and extracted successfully"
}

handle_updates() {
    mkdir -p "$SERVER_FILES_DIR"

    case "$UPDATE_MODE" in
        always)
            download_server_files "$(get_remote_version)"
            ;;
        never)
            if [ ! -f "$SERVER_FILES_DIR/HytaleServer.jar" ]; then
                log_error "UPDATE_MODE=never but HytaleServer.jar is missing"
                exit 1
            fi
            ensure_recorded_version
            ;;
        auto)
            if [ ! -f "$SERVER_FILES_DIR/HytaleServer.jar" ]; then
                download_server_files "$(get_remote_version)"
                return
            fi

            local recorded_version
            recorded_version=$(get_recorded_version)
            local remote_version
            remote_version=$(get_remote_version)

            if [ -z "$remote_version" ]; then
                log_warn "Unable to determine latest server version, skipping update check"
                ensure_recorded_version
                return
            fi

            if [ -z "$recorded_version" ] || [ "$remote_version" != "$recorded_version" ]; then
                log_info "New server version detected: $remote_version"
                download_server_files "$remote_version"
            else
                log_info "Server files already up to date ($recorded_version)"
            fi
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Verify required files exist
# ------------------------------------------------------------------------------
validate_server_files() {
    if [ ! -f "$SERVER_FILES_DIR/HytaleServer.jar" ]; then
        log_error "HytaleServer.jar not found after download"
        exit 1
    fi

    if [ ! -f "$SERVER_FILES_DIR/Assets.zip" ] && [ ! -d "$SERVER_FILES_DIR/Assets" ]; then
        log_warn "Assets not found - server may not start correctly"
    fi
}

# ------------------------------------------------------------------------------
# Config file management
# ------------------------------------------------------------------------------
write_config_file() {
    mkdir -p "$CONFIG_DIR"

    local tmp_file
    tmp_file="${CONFIG_FILE}.tmp"

    if [ ! -f "$CONFIG_FILE" ]; then
        jq -n \
            --arg server_name "$SERVER_NAME" \
            --arg password "$SERVER_PASSWORD" \
            --argjson max_players "$MAX_PLAYERS" \
            --argjson view_distance "$VIEW_DISTANCE" \
            '{ServerName: $server_name, Password: $password, MaxPlayers: $max_players, ViewDistance: $view_distance}' \
            > "$tmp_file"
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "Generated config.json"
    else
        local jq_filter='(if has("ServerName") then .ServerName = $server_name
              elif has("server_name") then .server_name = $server_name
              elif has("serverName") then .serverName = $server_name
              else .ServerName = $server_name end)
             | (if has("Password") then .Password = $password
                elif has("password") then .password = $password
                else .Password = $password end)
             | (if has("MaxPlayers") then .MaxPlayers = $max_players
                elif has("max_players") then .max_players = $max_players
                elif has("maxPlayers") then .maxPlayers = $max_players
                else .MaxPlayers = $max_players end)
             | (if has("ViewDistance") then .ViewDistance = $view_distance
                elif has("view_distance") then .view_distance = $view_distance
                elif has("viewDistance") then .viewDistance = $view_distance
                else .ViewDistance = $view_distance end)'
        jq --arg server_name "$SERVER_NAME" \
           --arg password "$SERVER_PASSWORD" \
           --argjson max_players "$MAX_PLAYERS" \
           --argjson view_distance "$VIEW_DISTANCE" \
           "$jq_filter" "$CONFIG_FILE" > "$tmp_file"
        mv "$tmp_file" "$CONFIG_FILE"
        log_info "Updated config.json"
    fi

    # Symlink config to expected location if not already present
    if [ ! -L "$SERVER_CONFIG_LINK" ] || [ "$(readlink "$SERVER_CONFIG_LINK")" != "$CONFIG_FILE" ]; then
        ln -sf "$CONFIG_FILE" "$SERVER_CONFIG_LINK"
    fi
}

# ------------------------------------------------------------------------------
# AOT cache handling
# ------------------------------------------------------------------------------
prepare_aot_cache() {
    AOT_JVM_ARGS=""

    if [ "$ENABLE_AOT" != "true" ]; then
        log_info "AOT caching disabled"
        return
    fi

    mkdir -p "$AOT_CACHE_DIR"

    local current_version
    current_version=$(get_recorded_version)
    if [ -z "$current_version" ]; then
        current_version=$(get_local_version_fallback)
    fi

    local cached_version=""
    if [ -f "$AOT_VERSION_FILE" ]; then
        cached_version=$(cat "$AOT_VERSION_FILE")
    fi

    if [ -f "$AOT_CACHE_FILE" ] && [ "$cached_version" = "$current_version" ]; then
        AOT_JVM_ARGS="-XX:AOTCache=${AOT_CACHE_FILE}"
        log_info "Using existing AOT cache"
    else
        rm -f "$AOT_CACHE_FILE"
        echo "$current_version" > "$AOT_VERSION_FILE"
        AOT_JVM_ARGS="-XX:AOTCacheOutput=${AOT_CACHE_FILE}"
        log_info "AOT cache will be generated on this run (training mode)"
    fi
}

# ------------------------------------------------------------------------------
# Start the server
# ------------------------------------------------------------------------------
start_server() {
    cd "$SERVER_FILES_DIR"

    local assets_path=""
    if [ -f "Assets.zip" ]; then
        assets_path="Assets.zip"
    elif [ -d "Assets" ]; then
        assets_path="Assets"
    fi

    log_info "Starting Hytale Server..."
    log_info "Server Name: ${SERVER_NAME}"
    log_info "Max Players: ${MAX_PLAYERS}"
    log_info "View Distance: ${VIEW_DISTANCE}"
    log_info "Memory: ${MEMORY_MB}MB"
    log_info "Auth Mode: ${AUTH_MODE}"
    log_info "Bind: 0.0.0.0:5520"
    log_info "Working Directory: $(pwd)"
    echo ""

    local jvm_args
    jvm_args="-Xms${MEMORY_MB}M -Xmx${MEMORY_MB}M"
    jvm_args="$jvm_args -XX:+UseG1GC"
    jvm_args="$jvm_args -XX:MaxGCPauseMillis=50"
    jvm_args="$jvm_args -XX:+UseStringDeduplication"
    jvm_args="$jvm_args -XX:+UseContainerSupport"

    if [ -n "$AOT_JVM_ARGS" ]; then
        jvm_args="$jvm_args $AOT_JVM_ARGS"
    fi

    local server_args
    server_args="--bind 0.0.0.0:5520"
    server_args="$server_args --auth-mode $AUTH_MODE"
    server_args="$server_args --disable-sentry"

    if [ -n "$assets_path" ]; then
        server_args="$server_args --assets $assets_path"
    fi

    if [ $# -gt 0 ]; then
        server_args="$server_args $*"
    fi

    log_info "Executing: java $jvm_args -jar HytaleServer.jar $server_args"
    java $jvm_args -jar HytaleServer.jar $server_args &
    SERVER_PID=$!
    wait "$SERVER_PID"
}

main() {
    print_banner
    validate_prerequisites
    setup_downloader
    refresh_token_if_needed
    handle_updates
    validate_server_files
    write_config_file
    prepare_aot_cache
    handle_server_auth
    start_server "$@"
}

main "$@"
