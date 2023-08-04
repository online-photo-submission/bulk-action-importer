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

COLUMN_NAMES="$3"

# to set the column names add the following to the curl command
# --form "columnNames=\"$COLUMN_NAMES\""

# to set the default action add the following to the curl command
# --form "actionDefault=\"$ACTION_DEFAULT\""
curl -i --location "$API_URL/bulk-action" --header "X-Auth-Token: $SESSION_TOKEN" --form "csv=@\"$FILE\""
