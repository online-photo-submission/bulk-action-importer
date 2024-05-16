@echo off

set "IMPORT_DIRECTORY=C:\Users\import-directory"
set "DONE_DIRECTORY=C:\Users\done-directory"
set "API_URL=https://api.onlinephotosubmission.com"
set "ACTION_DEFAULT=CREATE_OR_UPDATE"
set "PERSISTENT_ACCESS_TOKEN=insert-token-here"

REM it's best to specify the column names in the first line of the CSV
REM if you use the 'COLUMN_NAMES' option, also add the appropriate '--form' argument in the curl command in 'upload-csv.sh'
REM set "COLUMN_NAMES=email,identifier"
