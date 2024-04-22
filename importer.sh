#!/bin/bash

set -e

LOG_SEPARATOR=$'\n================================================================================================\n'

# get the session token from the command line
# export SESSION_TOKEN="$1"
# if [ -z "$SESSION_TOKEN" ]; then
#     echo "SESSION_TOKEN is required as the 1st arg"
#     exit 1
# fi

# get the config values from 'config.sh'
. ./config.sh

# output the config variables
echo "$LOG_SEPARATOR"
echo "IMPORT_DIRECTORY           = $IMPORT_DIRECTORY"
echo "  DONE_DIRECTORY           = $DONE_DIRECTORY"
echo "         API_URL           = $API_URL"
echo "   PERSISTENT_ACCESS_TOKEN = ****${PERSISTENT_ACCESS_TOKEN:(-4)}"
echo "   COLUMN_NAMES            = $COLUMN_NAMES"
echo "$LOG_SEPARATOR"

# quit if the import directory is empty
if [ -z "$(ls -A $IMPORT_DIRECTORY)" ]; then
    echo "IMPORT_DIRECTORY is empty. Nothing to import. Exiting now."
    exit 0
fi

response=$(curl -X POST ${curlUrl}/authentication-token --header 'Content-Type: application/json' --data '{"persistentAccessToken": "'$PERSISTENT_ACCESS_TOKEN'"}')

SESSION_TOKEN=$(echo $response | grep -o '"tokenValue":"[^"]*' | sed 's/"tokenValue":"//')

# iterate over the CSVs in the import directory and upload each to the bulk action endpoint
for FILE in $IMPORT_DIRECTORY/*.csv
do 
    ./upload-csv.sh $FILE $API_URL $COLUMN_NAMES

    mv $FILE $DONE_DIRECTORY
    echo "completed: $FILE"
    echo "$LOG_SEPARATOR"
done
