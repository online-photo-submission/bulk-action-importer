#!/bin/bash

set -e

LOG_SEPARATOR='================================================================================================'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_TOKEN=""
FORM_FIELD_KEYS=()
FORM_FIELD_VALUES=()
LOG_FILE=""

# get the config values from 'config.sh'
. "$SCRIPT_DIR/config.sh"

# ------------------------------------------------------------------------------
# Logging
#
# Every message is written to the console AND appended to a dated log file so a
# scheduled run leaves a trail support can review. Secrets are redacted, and
# DEBUG-level lines are only emitted when DEBUG is enabled in config.
# ------------------------------------------------------------------------------
is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|y) return 0 ;;
        *) return 1 ;;
    esac
}

debug_enabled() {
    is_truthy "${DEBUG:-false}"
}

# Replace any occurrence of the access token or session token with **** so a
# secret can never end up in a log line (e.g. inside an error response body).
redact_secrets() {
    local msg="$1"

    if [ -n "${PERSISTENT_ACCESS_TOKEN:-}" ]; then
        msg="${msg//${PERSISTENT_ACCESS_TOKEN}/****}"
    fi
    if [ -n "${SESSION_TOKEN:-}" ]; then
        msg="${msg//${SESSION_TOKEN}/****}"
    fi

    printf '%s' "$msg"
}

init_logging() {
    local dir="${LOG_DIRECTORY:-$SCRIPT_DIR/logs}"

    if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
        LOG_FILE="$dir/importer-$(date '+%Y-%m-%d').log"
    else
        LOG_FILE=""
        printf 'WARNING: log directory is not writable: %s (logging to console only)\n' "$dir" >&2
    fi
}

emit_log() {
    local level="$1" console_prefix="$2" msg
    msg="$(redact_secrets "$3")"

    # Console: clean text (errors/warnings prefixed, errors to stderr).
    if [ "$level" = "ERROR" ]; then
        printf '%s%s\n' "$console_prefix" "$msg" >&2
    else
        printf '%s%s\n' "$console_prefix" "$msg"
    fi

    # File: timestamped and leveled for support review.
    if [ -n "$LOG_FILE" ]; then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE"
    fi
}

log_info()  { emit_log "INFO"  ""          "$*"; }
log_warn()  { emit_log "WARN"  "WARNING: " "$*"; }
log_error() { emit_log "ERROR" "ERROR: "   "$*"; }
log_debug() { if debug_enabled; then emit_log "DEBUG" "DEBUG: " "$*"; fi; }

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

mask_token() {
    local token="$1"

    if [ -z "$token" ]; then
        printf ''
    elif [ "${#token}" -le 4 ]; then
        printf '****'
    else
        printf '****%s' "${token: -4}"
    fi
}

urlencode() {
    local value="$1"
    local encoded=""
    local pos char hex

    for ((pos = 0; pos < ${#value}; pos++)); do
        char="${value:$pos:1}"
        case "$char" in
            [a-zA-Z0-9.~_-])
                encoded+="$char"
                ;;
            *)
                printf -v hex '%%%02X' "'$char"
                encoded+="$hex"
                ;;
        esac
    done

    printf '%s' "$encoded"
}

remote_config_enabled() {
    local value
    value="$(printf '%s' "${REMOTE_CONFIG_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
        true|1|yes|y)
            return 0
            ;;
        false|0|no|n|'')
            return 1
            ;;
        *)
            log_error "REMOTE_CONFIG_ENABLED must be true or false."
            exit 1
            ;;
    esac
}

set_form_field() {
    local key="$1"
    local value="${2-}"
    local index

    if [ -z "$key" ]; then
        return
    fi

    for index in "${!FORM_FIELD_KEYS[@]}"; do
        if [ "${FORM_FIELD_KEYS[$index]}" = "$key" ]; then
            FORM_FIELD_VALUES[$index]="$value"
            return
        fi
    done

    FORM_FIELD_KEYS+=("$key")
    FORM_FIELD_VALUES+=("$value")
}

add_local_form_field_defaults() {
    set_form_field "actionDefault" "${ACTION_DEFAULT:-}"
    set_form_field "columnNames" "${COLUMN_NAMES:-}"
    set_form_field "fieldSeparator" "${FIELD_SEPARATOR:-}"
}

is_safe_config_key() {
    local key="$1"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]
}

apply_remote_config() {
    local key="$1"
    local value="$2"
    local uppercase_key

    uppercase_key="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"

    case "$uppercase_key" in
        *TOKEN*|*PASSWORD*)
            log_error "Cloud config key '$key' is not allowed because tokens and passwords must remain local."
            return 1
            ;;
    esac

    if ! is_safe_config_key "$key"; then
        log_error "Cloud config key '$key' is not a safe property or form-field name."
        return 1
    fi

    case "$key" in
        IMPORT_DIRECTORY|importDirectory)
            IMPORT_DIRECTORY="$value"
            ;;
        DONE_DIRECTORY|doneDirectory)
            DONE_DIRECTORY="$value"
            ;;
        FAILED_DIRECTORY|failedDirectory)
            FAILED_DIRECTORY="$value"
            ;;
        API_URL|apiUrl)
            log_warn "Ignoring cloud config key '$key'; API_URL must remain local."
            ;;
        REMOTE_CONFIG_ENABLED|remoteConfigEnabled|INTEGRATION_NAME|integrationName|LOG_DIRECTORY|logDirectory|DEBUG|debug)
            log_warn "Ignoring cloud config key '$key'; bootstrap settings must remain local."
            ;;
        ACTION_DEFAULT|actionDefault)
            ACTION_DEFAULT="$value"
            set_form_field "actionDefault" "$value"
            ;;
        COLUMN_NAMES|columnNames)
            COLUMN_NAMES="$value"
            set_form_field "columnNames" "$value"
            ;;
        FIELD_SEPARATOR|fieldSeparator)
            FIELD_SEPARATOR="$value"
            set_form_field "fieldSeparator" "$value"
            ;;
        *)
            set_form_field "$key" "$value"
            ;;
    esac
}

parse_remote_config() {
    local remote_config="$1"
    local line key value
    local invalid_config=0

    if [[ "$(trim "$remote_config")" == \{* ]]; then
        parse_remote_config_json "$remote_config"
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"

        if [ -z "$(trim "$line")" ]; then
            continue
        fi

        case "$(trim "$line")" in
            \#*)
                continue
                ;;
        esac

        if [[ "$line" != *=* ]]; then
            log_error "Cloud config line is not in key=value format: $line"
            invalid_config=1
            continue
        fi

        key="$(trim "${line%%=*}")"
        value="${line#*=}"

        if [ -z "$key" ]; then
            log_error "Cloud config contains a blank property name."
            invalid_config=1
            continue
        fi

        if ! apply_remote_config "$key" "$value"; then
            invalid_config=1
        fi
    done <<< "$remote_config"

    if [ "$invalid_config" -ne 0 ]; then
        log_error "Cloud config contains invalid entries. Exiting before upload."
        exit 1
    fi
}

parse_remote_config_json() {
    local remote_config="$1"
    local env_config

    if ! command -v python3 >/dev/null 2>&1; then
        log_error "Cloud config returned JSON, but python3 is not installed. Install python3 or update the API to return key=value lines for format=env."
        exit 1
    fi

    if ! env_config="$(REMOTE_CONFIG_JSON="$remote_config" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["REMOTE_CONFIG_JSON"])
except Exception as error:
    print(f"Could not parse cloud config JSON: {error}", file=sys.stderr)
    sys.exit(1)

if payload.get("integrationType") not in (None, "IMPORTER"):
    print("Cloud config integrationType must be IMPORTER.", file=sys.stderr)
    sys.exit(1)

configs = payload.get("integrationConfigs")
if configs is None:
    sys.exit(0)

if not isinstance(configs, list):
    print("Cloud config JSON integrationConfigs must be a list.", file=sys.stderr)
    sys.exit(1)

for item in configs:
    if not isinstance(item, dict):
        print("Cloud config JSON contains a non-object integration config.", file=sys.stderr)
        sys.exit(1)

    key = item.get("propertyName")
    value = item.get("propertyValue", "")

    if key is None:
        continue

    if not isinstance(key, str):
        print("Cloud config propertyName must be a string.", file=sys.stderr)
        sys.exit(1)

    if value is None:
        value = ""
    elif not isinstance(value, str):
        value = str(value)

    if "\n" in key or "\r" in key or "\n" in value or "\r" in value:
        print("Cloud config JSON cannot contain newline characters in names or values.", file=sys.stderr)
        sys.exit(1)

    print(f"{key}={value}")
PY
)"; then
        log_error "Cloud config JSON could not be converted to key=value entries. Exiting before upload."
        exit 1
    fi

    if [ -n "$(trim "$env_config")" ]; then
        parse_remote_config "$env_config"
    fi
}

authenticate() {
    local auth_url payload escaped_pat response http_code body

    auth_url="${API_URL%/}/authentication-token"
    escaped_pat="$(json_escape "$PERSISTENT_ACCESS_TOKEN")"
    payload="{\"persistentAccessToken\": \"$escaped_pat\"}"

    log_debug "POST $auth_url"

    # Capture the body and the HTTP status so we can report a useful error
    # instead of a generic failure (2>&1 folds any curl transport error in too).
    response="$(curl --silent --show-error --location -X POST "$auth_url" \
        --header 'Content-Type: application/json' --data "$payload" \
        -w $'\n%{http_code}' 2>&1)" || true

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    log_debug "authentication HTTP status: $http_code"

    case "$http_code" in
        2*) ;;
        *)
            log_error "Authentication request failed (HTTP ${http_code:-none}). Verify API_URL has no extra path (e.g. no trailing /api) and that the token is valid."
            log_error "server response: $body"
            exit 1
            ;;
    esac

    SESSION_TOKEN="$(printf '%s' "$body" | sed -n 's/.*"tokenValue"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    if [ -z "$SESSION_TOKEN" ]; then
        log_error "Authentication response did not contain tokenValue. Exiting before upload."
        log_debug "server response: $body"
        exit 1
    fi

    log_debug "authenticated; received session token $(mask_token "$SESSION_TOKEN")"
}

logout() {
    if [ -n "$SESSION_TOKEN" ]; then
        log_debug "logging out session $(mask_token "$SESSION_TOKEN")"
        curl --silent --show-error --location "${API_URL%/}/person/me/logout" \
            --header "X-Auth-Token: $SESSION_TOKEN" \
            --header 'Accept: application/json' \
            --header 'Content-Type: application/json' \
            --data "{\"authenticationToken\": \"$(json_escape "$SESSION_TOKEN")\"}" >/dev/null 2>&1 || true
    fi
}

# Authenticate once and guarantee we log out on exit. Safe to call repeatedly:
# it is a no-op once a session token already exists, so both the remote-config
# path and the upload path can call it without authenticating twice.
ensure_authenticated() {
    if [ -n "$SESSION_TOKEN" ]; then
        return
    fi

    authenticate
    trap logout EXIT
}

fetch_remote_config() {
    local encoded_integration_name remote_config_url response http_code body

    if [ -z "${INTEGRATION_NAME:-}" ]; then
        log_error "INTEGRATION_NAME is required when REMOTE_CONFIG_ENABLED=true."
        exit 1
    fi

    encoded_integration_name="$(urlencode "$INTEGRATION_NAME")"
    remote_config_url="${API_URL%/}/integration/${encoded_integration_name}?findBy=name&format=env"

    log_debug "GET $remote_config_url"

    response="$(curl --silent --show-error --location "$remote_config_url" \
        --header "X-Auth-Token: $SESSION_TOKEN" --header 'Accept: text/plain' \
        -w $'\n%{http_code}' 2>&1)" || true

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    log_debug "cloud config HTTP status: $http_code"

    case "$http_code" in
        2*) ;;
        *)
            log_error "Cloud config request failed (HTTP ${http_code:-none}). Check that INTEGRATION_NAME matches the integration name in RemotePhoto exactly."
            log_error "server response: $body"
            exit 1
            ;;
    esac

    if [ -n "$(trim "$body")" ]; then
        parse_remote_config "$body"
    fi
}

require_config_value() {
    local key="$1"
    local value="$2"

    if [ -z "$value" ]; then
        log_error "$key is required."
        exit 1
    fi
}

validate_directories() {
    require_config_value "IMPORT_DIRECTORY" "$IMPORT_DIRECTORY"
    require_config_value "DONE_DIRECTORY" "$DONE_DIRECTORY"

    if [ ! -d "$IMPORT_DIRECTORY" ]; then
        log_error "IMPORT_DIRECTORY does not exist or is not a directory: $IMPORT_DIRECTORY"
        exit 1
    fi

    if [ ! -d "$DONE_DIRECTORY" ]; then
        log_error "DONE_DIRECTORY does not exist or is not a directory: $DONE_DIRECTORY"
        exit 1
    fi
}

# The failed directory is created automatically (it is an error sink, not
# something the customer must pre-create). It can be overridden locally or via
# remote config; otherwise it defaults to a "failed" folder next to the script.
ensure_failed_directory() {
    FAILED_DIRECTORY="${FAILED_DIRECTORY:-$SCRIPT_DIR/failed}"

    if ! mkdir -p "$FAILED_DIRECTORY" 2>/dev/null || [ ! -d "$FAILED_DIRECTORY" ]; then
        log_error "FAILED_DIRECTORY does not exist and could not be created: $FAILED_DIRECTORY"
        exit 1
    fi
}

build_form_field_args() {
    local index
    FORM_FIELD_ARGS=()

    for index in "${!FORM_FIELD_KEYS[@]}"; do
        if [ -n "${FORM_FIELD_VALUES[$index]}" ]; then
            FORM_FIELD_ARGS+=("${FORM_FIELD_KEYS[$index]}=${FORM_FIELD_VALUES[$index]}")
        fi
    done
}

format_form_fields_for_log() {
    local index
    local output=""

    for index in "${!FORM_FIELD_KEYS[@]}"; do
        if [ -z "${FORM_FIELD_VALUES[$index]}" ]; then
            continue
        fi

        if [ -n "$output" ]; then
            output+=", "
        fi

        output+="${FORM_FIELD_KEYS[$index]}=${FORM_FIELD_VALUES[$index]}"
    done

    printf '%s' "$output"
}

print_config() {
    log_info "$LOG_SEPARATOR"
    log_info "IMPORT_DIRECTORY           = $IMPORT_DIRECTORY"
    log_info "  DONE_DIRECTORY           = $DONE_DIRECTORY"
    log_info "FAILED_DIRECTORY           = $FAILED_DIRECTORY"
    log_info "         API_URL           = $API_URL"
    log_info "   PERSISTENT_ACCESS_TOKEN = $(mask_token "$PERSISTENT_ACCESS_TOKEN")"
    log_info "REMOTE_CONFIG_ENABLED      = ${REMOTE_CONFIG_ENABLED:-false}"
    log_info "   INTEGRATION_NAME        = ${INTEGRATION_NAME:-}"
    log_info "BULK_ACTION_FORM_FIELDS    = $(format_form_fields_for_log)"
    log_info "                   DEBUG   = ${DEBUG:-false}"
    log_info "                LOG_FILE   = ${LOG_FILE:-<console only>}"
    log_info "$LOG_SEPARATOR"
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------
main() {
    local csv_files FILE total success failed response rc http_code body

    # Start logging first so even the earliest error lands in the log file.
    init_logging

    # These two settings must always be present locally; everything else can
    # come from the cloud when remote config is enabled.
    require_config_value "API_URL" "${API_URL:-}"
    require_config_value "PERSISTENT_ACCESS_TOKEN" "${PERSISTENT_ACCESS_TOKEN:-}"

    # Seed the form fields from local config first so remote config can override.
    add_local_form_field_defaults

    # When remote config is on we must authenticate before we can fetch it.
    if remote_config_enabled; then
        ensure_authenticated
        fetch_remote_config
    fi

    # Resolve the failed directory default now so it appears in the summary.
    FAILED_DIRECTORY="${FAILED_DIRECTORY:-$SCRIPT_DIR/failed}"

    print_config
    validate_directories
    ensure_failed_directory

    shopt -s nullglob
    csv_files=("$IMPORT_DIRECTORY"/*.csv)

    if [ "${#csv_files[@]}" -eq 0 ]; then
        log_info "IMPORT_DIRECTORY contains no CSV files. Nothing to import. Exiting now."
        exit 0
    fi

    # Authenticate now if remote config was disabled (no session yet).
    ensure_authenticated

    build_form_field_args

    total="${#csv_files[@]}"
    success=0
    failed=0

    # Upload each CSV. Successful files move to the done directory; failed files
    # move to the failed directory (never silently lost) and are logged.
    for FILE in "${csv_files[@]}"
    do
        log_info "uploading: $FILE"

        # upload-csv.sh prints "<http_code>\n<body>" and exits non-zero on any
        # non-2xx response. Guard set -e so we can react to a failed upload.
        set +e
        response="$("$SCRIPT_DIR/upload-csv.sh" "$FILE" "$API_URL" "$SESSION_TOKEN" "${FORM_FIELD_ARGS[@]}")"
        rc=$?
        set -e

        http_code="${response%%$'\n'*}"
        body="${response#*$'\n'}"

        if [ "$rc" -eq 0 ]; then
            log_info "completed: $FILE (HTTP $http_code)"
            log_debug "server response: $body"
            mv "$FILE" "$DONE_DIRECTORY"
            success=$((success + 1))
        else
            log_error "upload failed: $FILE (HTTP ${http_code:-none})"
            log_error "server response: $body"
            mv "$FILE" "$FAILED_DIRECTORY"
            failed=$((failed + 1))
        fi

        log_info "$LOG_SEPARATOR"
    done

    log_info "Run summary: ${total} file(s) processed — ${success} succeeded, ${failed} failed."
    log_info "Log file: ${LOG_FILE:-<console only>}"

    # Non-zero exit so a scheduler (cron/Task Scheduler) can alarm on failures.
    if [ "$failed" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
