#!/bin/bash

IMPORT_DIRECTORY="/Users/terskine/git/cloudcard/bulk-action-importer/new"
DONE_DIRECTORY="/Users/terskine/git/cloudcard/bulk-action-importer/done"
API_URL="https://api.onlinephotosubmission.com"
PERSISTENT_ACCESS_TOKEN=""

# it's best to specify the column names in the first line of the CSV
# if you use the 'COLUMN_NAMES' option, also add the appropriate '--form' argument in the curl command in 'upload-csv.sh'
# COLUMN_NAMES="email,identifier"

# if you use the 'ACTION_DEFAULT' option, also add the appropriate '--form' argument in the curl command in 'upload-csv.sh'
# ACTION_DEFAULT="ARCHIVE"
