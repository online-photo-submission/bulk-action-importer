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

COLUMN_NAMES="$4"

# to set a custom field seperator (i.e. pipe, slash, etc) add the following to the curl command.
# --form "fieldSeparator=|"

# to set the column names add the following to the curl command
# --form "columnNames=\"$COLUMN_NAMES\""

# to set the default action add the following to the curl command
# --form "actionDefault=\"$ACTION_DEFAULT\""

curl --location "$API_URL/bulk-action" --header "X-Auth-Token: $SESSION_TOKEN" --form "csv=@\"$FILE\""
