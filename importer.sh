#!/bin/bash

set -e

LOG_SEPARATOR=$'\n================================================================================================\n'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_TOKEN=""
FORM_FIELD_KEYS=()
FORM_FIELD_VALUES=()

# get the config values from 'config.sh'
. "$SCRIPT_DIR/config.sh"

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
            echo "REMOTE_CONFIG_ENABLED must be true or false."
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
            echo "Cloud config key '$key' is not allowed because tokens and passwords must remain local."
            return 1
            ;;
    esac

    if ! is_safe_config_key "$key"; then
        echo "Cloud config key '$key' is not a safe property or form-field name."
        return 1
    fi

    case "$key" in
        IMPORT_DIRECTORY|importDirectory)
            IMPORT_DIRECTORY="$value"
            ;;
        DONE_DIRECTORY|doneDirectory)
            DONE_DIRECTORY="$value"
            ;;
        API_URL|apiUrl)
            echo "Ignoring cloud config key '$key'; API_URL must remain local."
            ;;
        REMOTE_CONFIG_ENABLED|remoteConfigEnabled|INTEGRATION_NAME|integrationName)
            echo "Ignoring cloud config key '$key'; bootstrap settings must remain local."
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
            echo "Cloud config line is not in key=value format: $line"
            invalid_config=1
            continue
        fi

        key="$(trim "${line%%=*}")"
        value="${line#*=}"

        if [ -z "$key" ]; then
            echo "Cloud config contains a blank property name."
            invalid_config=1
            continue
        fi

        if ! apply_remote_config "$key" "$value"; then
            invalid_config=1
        fi
    done <<< "$remote_config"

    if [ "$invalid_config" -ne 0 ]; then
        echo "Cloud config contains invalid entries. Exiting before upload."
        exit 1
    fi
}

parse_remote_config_json() {
    local remote_config="$1"
    local env_config

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Cloud config returned JSON, but python3 is not installed. Install python3 or update the API to return key=value lines for format=env."
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
        echo "Cloud config JSON could not be converted to key=value entries. Exiting before upload."
        exit 1
    fi

    if [ -n "$(trim "$env_config")" ]; then
        parse_remote_config "$env_config"
    fi
}

authenticate() {
    local response payload escaped_pat

    escaped_pat="$(json_escape "$PERSISTENT_ACCESS_TOKEN")"
    payload="{\"persistentAccessToken\": \"$escaped_pat\"}"

    if ! response="$(curl --fail --silent --show-error --location -X POST "${API_URL%/}/authentication-token" --header 'Content-Type: application/json' --data "$payload")"; then
        echo "Authentication request failed. Exiting before upload."
        exit 1
    fi

    SESSION_TOKEN="$(printf '%s' "$response" | sed -n 's/.*"tokenValue"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    if [ -z "$SESSION_TOKEN" ]; then
        echo "Authentication response did not contain tokenValue. Exiting before upload."
        exit 1
    fi
}

logout() {
    if [ -n "$SESSION_TOKEN" ]; then
        curl --silent --show-error --location "${API_URL%/}/person/me/logout" \
            --header "X-Auth-Token: $SESSION_TOKEN" \
            --header 'Accept: application/json' \
            --header 'Content-Type: application/json' \
            --data "{\"authenticationToken\": \"$(json_escape "$SESSION_TOKEN")\"}" >/dev/null 2>&1 || true
    fi
}

fetch_remote_config() {
    local encoded_integration_name remote_config_url remote_config

    if [ -z "${INTEGRATION_NAME:-}" ]; then
        echo "INTEGRATION_NAME is required when REMOTE_CONFIG_ENABLED=true."
        exit 1
    fi

    encoded_integration_name="$(urlencode "$INTEGRATION_NAME")"
    remote_config_url="${API_URL%/}/integration/${encoded_integration_name}?findBy=name&format=env"

    if ! remote_config="$(curl --fail --silent --show-error --location "$remote_config_url" --header "X-Auth-Token: $SESSION_TOKEN" --header 'Accept: text/plain')"; then
        echo "Cloud config request failed. Exiting before upload."
        exit 1
    fi

    if [ -n "$(trim "$remote_config")" ]; then
        parse_remote_config "$remote_config"
    fi
}

require_config_value() {
    local key="$1"
    local value="$2"

    if [ -z "$value" ]; then
        echo "$key is required."
        exit 1
    fi
}

validate_directories() {
    require_config_value "IMPORT_DIRECTORY" "$IMPORT_DIRECTORY"
    require_config_value "DONE_DIRECTORY" "$DONE_DIRECTORY"

    if [ ! -d "$IMPORT_DIRECTORY" ]; then
        echo "IMPORT_DIRECTORY does not exist or is not a directory: $IMPORT_DIRECTORY"
        exit 1
    fi

    if [ ! -d "$DONE_DIRECTORY" ]; then
        echo "DONE_DIRECTORY does not exist or is not a directory: $DONE_DIRECTORY"
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
    echo "$LOG_SEPARATOR"
    echo "IMPORT_DIRECTORY           = $IMPORT_DIRECTORY"
    echo "  DONE_DIRECTORY           = $DONE_DIRECTORY"
    echo "         API_URL           = $API_URL"
    echo "   PERSISTENT_ACCESS_TOKEN = $(mask_token "$PERSISTENT_ACCESS_TOKEN")"
    echo "REMOTE_CONFIG_ENABLED      = ${REMOTE_CONFIG_ENABLED:-false}"
    echo "   INTEGRATION_NAME        = ${INTEGRATION_NAME:-}"
    echo "BULK_ACTION_FORM_FIELDS    = $(format_form_fields_for_log)"
    echo "$LOG_SEPARATOR"
}

require_config_value "API_URL" "${API_URL:-}"
require_config_value "PERSISTENT_ACCESS_TOKEN" "${PERSISTENT_ACCESS_TOKEN:-}"

add_local_form_field_defaults

if remote_config_enabled; then
    authenticate
    trap logout EXIT
    fetch_remote_config
fi

print_config
validate_directories

shopt -s nullglob
csv_files=("$IMPORT_DIRECTORY"/*.csv)

if [ "${#csv_files[@]}" -eq 0 ]; then
    echo "IMPORT_DIRECTORY contains no CSV files. Nothing to import. Exiting now."
    exit 0
fi

if [ -z "$SESSION_TOKEN" ]; then
    authenticate
    trap logout EXIT
fi

build_form_field_args

# iterate over the CSVs in the import directory and upload each to the bulk action endpoint
for FILE in "${csv_files[@]}"
do
    "$SCRIPT_DIR/upload-csv.sh" "$FILE" "$API_URL" "$SESSION_TOKEN" "${FORM_FIELD_ARGS[@]}"

    mv "$FILE" "$DONE_DIRECTORY"
    echo "completed: $FILE"
    echo "$LOG_SEPARATOR"
done
