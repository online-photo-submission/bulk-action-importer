#!/bin/bash

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

>&2 echo "Sending $FILE to $API_URL"

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

# to set a custom field seperator (i.e. pipe, slash, etc) add the following to the curl command.
# --form "fieldSeparator=|"

# to set the column names add the following to the curl command
# --form "columnNames=$COLUMN_NAMES"

# to set the default action add the following to the curl command
# --form "actionDefault=\"$ACTION_DEFAULT\""

curl_args=(
    --location "$API_URL/bulk-action"
    --header "X-Auth-Token: $SESSION_TOKEN"
    --form "csv=@$FILE"
)

for FORM_FIELD in "${FORM_FIELDS[@]}"
do
    if [ -z "$FORM_FIELD" ]; then
        continue
    fi

    if [[ "$FORM_FIELD" != *=* ]]; then
        echo "Bulk action form field must be key=value: $FORM_FIELD"
        exit 1
    fi

    curl_args+=(--form-string "$FORM_FIELD")
done

curl "${curl_args[@]}"
