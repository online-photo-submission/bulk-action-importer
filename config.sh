#!/bin/bash

IMPORT_DIRECTORY="*your csv import directory*"
DONE_DIRECTORY="*your done directory*"
API_URL="*your api url*"
PERSISTENT_ACCESS_TOKEN="*your persistent access token*"
REMOTE_CONFIG_ENABLED=false
INTEGRATION_NAME="*if using the remote_config setting, this will be your integration name as it appears in RemotePhoto*"

# it's best to specify the column names in the first line of the CSV
# if you use the 'COLUMN_NAMES' option, the importer will pass it to the bulk action API as 'columnNames'
# COLUMN_NAMES="email,identifier"

# if you use the 'ACTION_DEFAULT' option, the importer will pass it to the bulk action API as 'actionDefault'
ACTION_DEFAULT="CREATE_OR_UPDATE"

# if you use the 'FIELD_SEPARATOR' option, the importer will pass it to the bulk action API as 'fieldSeparator'
# FIELD_SEPARATOR="|"
