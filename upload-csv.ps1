param (
    [Parameter(Mandatory=$true, Position=0)] [string] $IMPORT_DIRECTORY,
    [Parameter(Mandatory=$true, Position=1)] [string] $FILE,
    [Parameter(Mandatory=$true, Position=2)] [string] $API_URL,
    [Parameter(Mandatory=$true, Position=3)] [string] $SESSION_TOKEN,
    [Parameter(Mandatory=$false, Position=4)] [string] $ACTION_DEFAULT,
    [Parameter(Mandatory=$false, Position=5, ValueFromRemainingArguments=$true)] [string[]] $FORM_FIELDS
)

$ErrorActionPreference = "Stop"

if ([System.IO.Path]::IsPathRooted($FILE)) {
    $ABSOLUTE_PATH = $FILE
} else {
    $ABSOLUTE_PATH = Join-Path $IMPORT_DIRECTORY $FILE
}

$URL = $API_URL.TrimEnd("/") + "/bulk-action"
$curlCommand = Get-Command curl.exe -ErrorAction SilentlyContinue

if ($null -eq $curlCommand) {
    $curlCommand = Get-Command curl -ErrorAction SilentlyContinue
}

if ($null -eq $curlCommand) {
    throw "curl or curl.exe is required."
}

$curlArgs = @(
    "--location",
    $URL,
    "--header",
    "X-Auth-Token: $SESSION_TOKEN",
    "--form",
    "csv=@$ABSOLUTE_PATH"
)

if (-not [string]::IsNullOrWhiteSpace($ACTION_DEFAULT)) {
    $curlArgs += @("--form-string", "actionDefault=$ACTION_DEFAULT")
}

foreach ($formField in $FORM_FIELDS) {
    if ([string]::IsNullOrWhiteSpace($formField)) {
        continue
    }

    if (-not $formField.Contains("=")) {
        throw "Bulk action form field must be key=value: $formField"
    }

    $curlArgs += @("--form-string", $formField)
}

& $curlCommand.Source @curlArgs

if ($LASTEXITCODE -ne 0) {
    throw "$($curlCommand.Name) failed with exit code $LASTEXITCODE"
}
