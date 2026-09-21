<#
    Uploads a single CSV file to the RemotePhoto bulk action endpoint.
    Called by importer.ps1 once per CSV. Mirrors upload-csv.sh.

    This script is pure transport: it performs the request and returns the
    result to importer.ps1, which does all logging and file routing.

    Returns a result object:
        .HttpCode  - the HTTP status code (or 'none' if the call never connected)
        .Body      - the response body
        .Success   - $true when the API returned 2xx

    Form fields are passed as an array of "key=value" strings so any bulk-action
    field (actionDefault, columnNames, fieldSeparator, or a custom one from
    remote config) can be forwarded without changing this script.
#>
param (
    [Parameter(Mandatory = $true)]  [string]   $File,
    [Parameter(Mandatory = $true)]  [string]   $ApiUrl,
    [Parameter(Mandatory = $true)]  [string]   $SessionToken,
    [Parameter(Mandatory = $false)] [string[]] $FormFields = @()
)

$ErrorActionPreference = 'Stop'

$url = $ApiUrl.TrimEnd('/') + "/bulk-action"

# curl.exe (bundled with Windows 10+) handles multipart uploads cleanly.
# -w writes the HTTP status code after the body so we can inspect it; no --fail,
# so curl still returns the error body on a 4xx/5xx.
$curlArgs = @(
    '--location', $url
    '--silent', '--show-error'
    '--header', "X-Auth-Token: $SessionToken"
    '--form',   "csv=@$File"
    '-w', "`n%{http_code}"
)

foreach ($field in $FormFields) {
    if (-not $field) { continue }

    if ($field -notmatch '=') {
        # Signal a config problem to the caller (HTTP 'none' = no call made).
        return [pscustomobject]@{
            HttpCode = 'none'
            Body     = "Bulk action form field must be key=value: $field"
            Success  = $false
        }
    }

    # --form-string keeps the value literal so leading '@'/'<' characters and
    # spaces in column names are not misinterpreted by curl.
    $curlArgs += @('--form-string', $field)
}

$raw     = (& curl.exe @curlArgs 2>&1 | Out-String)
$curlRc  = $LASTEXITCODE
$text    = $raw.TrimEnd("`r", "`n")

# The status code is the last line; everything before it is the response body.
$lastBreak = $text.LastIndexOf("`n")
if ($lastBreak -ge 0) {
    $httpCode = $text.Substring($lastBreak + 1).Trim()
    $body     = $text.Substring(0, $lastBreak)
} else {
    $httpCode = $text.Trim()
    $body     = ''
}

return [pscustomobject]@{
    HttpCode = if ($httpCode) { $httpCode } else { 'none' }
    Body     = $body
    Success  = ($curlRc -eq 0 -and $httpCode -match '^2\d\d$')
}
