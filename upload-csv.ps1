<#
    Uploads a single CSV file to the RemotePhoto bulk action endpoint.
    Called by importer.ps1 once per CSV. Mirrors upload-csv.sh.

    Form fields are passed as an array of "key=value" strings so that any
    bulk-action field (actionDefault, columnNames, fieldSeparator, or a custom
    one from remote config) can be forwarded without changing this script.
#>
param (
    [Parameter(Mandatory = $true)]  [string]   $File,
    [Parameter(Mandatory = $true)]  [string]   $ApiUrl,
    [Parameter(Mandatory = $true)]  [string]   $SessionToken,
    [Parameter(Mandatory = $false)] [string[]] $FormFields = @()
)

$ErrorActionPreference = 'Stop'

$url = $ApiUrl.TrimEnd('/') + "/bulk-action"

Write-Host "Sending $File to $url"

# curl.exe (bundled with Windows 10+) handles multipart uploads cleanly.
$curlArgs = @(
    '--location', $url
    '--header',   "X-Auth-Token: $SessionToken"
    '--form',     "csv=@$File"
)

foreach ($field in $FormFields) {
    if (-not $field) { continue }

    if ($field -notmatch '=') {
        Write-Host "Bulk action form field must be key=value: $field"
        exit 1
    }

    # --form-string keeps the value literal so leading '@'/'<' characters and
    # spaces in column names are not misinterpreted by curl.
    $curlArgs += @('--form-string', $field)
}

curl.exe @curlArgs
