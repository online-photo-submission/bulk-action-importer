# Import the config values from 'config.ps1'
. .\config.ps1

$LOG_SEPARATOR = "==========================================================================================="

# Output the config variables
Write-Host "   IMPORT_DIRECTORY        = $IMPORT_DIRECTORY"
Write-Host "   DONE_DIRECTORY          = $DONE_DIRECTORY"
Write-Host "   API_URL                 = $API_URL"
Write-Host "   PERSISTENT_ACCESS_TOKEN = ****$($PERSISTENT_ACCESS_TOKEN.Substring($PERSISTENT_ACCESS_TOKEN.Length - 4))"
Write-Host "   ACTION_DEFAULT          = $ACTION_DEFAULT"
Write-Host "   COLUMN_NAMES            = $COLUMN_NAMES"
Write-Host $LOG_SEPARATOR

# Quit if the import directory is empty
if (-not (Test-Path -Path "$IMPORT_DIRECTORY\*")) {
    Write-Host "IMPORT_DIRECTORY is empty. Nothing to import. Exiting now."

    Write-Host $LOG_SEPARATOR
    exit
}

# Make the curl request and capture the output
$response = curl.exe --location $API_URL/authentication-token --header "Content-Type: application/json" --data "{`"persistentAccessToken`": `"$PERSISTENT_ACCESS_TOKEN`"}"

$responseObject = $response | ConvertFrom-Json

$SESSION_TOKEN = $responseObject.tokenValue

# Iterate over the CSVs in the import directory and upload each to the bulk action endpoint
Get-ChildItem -Path $IMPORT_DIRECTORY -Filter *.csv | ForEach-Object {
    Write-Host "Sending $_ to CloudCard API"

    .\upload-csv.ps1 $IMPORT_DIRECTORY $_ $API_URL $SESSION_TOKEN $ACTION_DEFAULT #$COLUMN_NAMES

    Move-Item $IMPORT_DIRECTORY\$_ $DONE_DIRECTORY
    Write-Host "`ncompleted: $($_)"
}

# Logout
Invoke-RestMethod -Uri "${API_URL}/person/me/logout" -Method Post -ContentType 'application/json' -Headers @{"X-Auth-Token" = $SESSION_TOKEN} -Body "{`"authenticationToken`": `"$SESSION_TOKEN`"}"

Write-Host $LOG_SEPARATOR

exit
