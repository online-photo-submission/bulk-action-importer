#!/bin/bash

# Uploads a single CSV file to the RemotePhoto bulk action endpoint.
# Called by importer.sh once per CSV. This script is pure transport: it performs
# the request and reports the result back to the importer, which does the logging.
#
# Contract with the caller:
#   - stdout: the HTTP status code on the first line, then the response body.
#   - exit code: 0 when the API returns 2xx, non-zero otherwise.

set -e

FILE="$1"

if [ -z "$1" ]; then
    echo "FILE is required as the 1st arg"
    exit 1
fi

API_URL="$2"

if [ -z "$API_URL" ]; then
    echo "API_URL is required as the 2nd arg"
    exit 1
fi

SESSION_TOKEN="$3"

if [ -z "$SESSION_TOKEN" ]; then
    echo "SESSION_TOKEN is required as the 3rd arg"
    exit 1
fi

shift 3
FORM_FIELDS=("$@")

# Backwards compatibility: older callers passed COLUMN_NAMES as the 4th arg.
if [ "${#FORM_FIELDS[@]}" -eq 1 ] && [ -n "${FORM_FIELDS[0]}" ] && [[ "${FORM_FIELDS[0]}" != *=* ]]; then
    FORM_FIELDS=("columnNames=${FORM_FIELDS[0]}")
fi

curl_args=(
    --location "${API_URL%/}/bulk-action"
    --header "X-Auth-Token: $SESSION_TOKEN"
    --form "csv=@$FILE"
)

for FORM_FIELD in "${FORM_FIELDS[@]}"
do
    if [ -z "$FORM_FIELD" ]; then
        continue
    fi

    if [[ "$FORM_FIELD" != *=* ]]; then
        # Signal a config problem to the caller (status 0 = "no HTTP call made").
        printf '0\nBulk action form field must be key=value: %s' "$FORM_FIELD"
        exit 1
    fi

    # --form-string keeps the value literal so spaces in column names and
    # special characters (@, <) are not misinterpreted by curl.
    curl_args+=(--form-string "$FORM_FIELD")
done

# Capture the response body and HTTP status. No --fail: curl returns 0 even on a
# 4xx/5xx, so we inspect the status ourselves and let the caller decide.
set +e
response="$(curl --silent --show-error -w $'\n%{http_code}' "${curl_args[@]}" 2>&1)"
curl_rc=$?
set -e

http_code="${response##*$'\n'}"
body="${response%$'\n'*}"

printf '%s\n%s' "$http_code" "$body"

# A transport-level failure (DNS, TLS, connection refused) has no HTTP status.
if [ "$curl_rc" -ne 0 ]; then
    exit 1
fi

case "$http_code" in
    2*) exit 0 ;;
    *)  exit 1 ;;
esac
