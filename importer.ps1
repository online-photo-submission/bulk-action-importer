<#
    RemotePhoto Bulk Action Importer (Windows / PowerShell)

    Mirrors importer.sh so the Windows and Mac/Linux importers behave identically.
    Reads bootstrap settings from config.ps1, optionally pulls the rest of the
    configuration from RemotePhoto (remote config), then uploads every CSV in the
    import directory to the bulk action API and moves it to the done directory.

    The file is organized top-to-bottom as:
        1. Globals
        2. Logging              (dated log file + console, redaction, DEBUG)
        3. Small helpers        (masking, form-field storage)
        4. Remote config        (fetch + parse + safety guards)
        5. API calls            (authenticate / logout)
        6. Validation
        7. Entry point (Invoke-Main)
#>

# Fail fast: any cmdlet error becomes a terminating error we can catch and
# clean up after (the same intent as `set -e` in importer.sh).
$ErrorActionPreference = 'Stop'

# Prefer TLS 1.2+ so authentication does not fail on older Windows PowerShell
# hosts that still default to TLS 1.0.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ------------------------------------------------------------------------------
# 1. Globals
# ------------------------------------------------------------------------------
$SCRIPT_DIR    = $PSScriptRoot
$LOG_SEPARATOR = '==========================================================================================='

# Load the customer's bootstrap settings (API_URL, PERSISTENT_ACCESS_TOKEN,
# REMOTE_CONFIG_ENABLED, INTEGRATION_NAME, and any local form-field defaults).
. "$SCRIPT_DIR\config.ps1"

$script:SESSION_TOKEN = ''
$script:ExitCode      = 0
$script:LogFile       = $null

# Ordered map of bulk-action form fields (preserves insertion order, like the
# parallel arrays in importer.sh). Populated from local config first, then
# overridden/extended by remote config.
$script:FormFields = [ordered]@{}

# ------------------------------------------------------------------------------
# 2. Logging
#
# Every message is written to the console AND appended to a dated log file so a
# scheduled run leaves a trail support can review. Secrets are redacted, and
# DEBUG-level lines are only emitted when DEBUG is enabled in config.
# ------------------------------------------------------------------------------
function Test-Truthy {
    param([string] $Value)
    return (@('true', '1', 'yes', 'y') -contains ("$Value").Trim().ToLower())
}

function Test-DebugEnabled {
    return (Test-Truthy "$DEBUG")
}

# Replace any occurrence of the access token or session token with **** so a
# secret can never end up in a log line (e.g. inside an error response body).
function Protect-Secret {
    param([string] $Message)

    if ($PERSISTENT_ACCESS_TOKEN) { $Message = $Message.Replace($PERSISTENT_ACCESS_TOKEN, '****') }
    if ($script:SESSION_TOKEN)    { $Message = $Message.Replace($script:SESSION_TOKEN, '****') }

    return $Message
}

function Initialize-Logging {
    $dir = if ($LOG_DIRECTORY) { $LOG_DIRECTORY } else { Join-Path $SCRIPT_DIR 'logs' }

    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $script:LogFile = Join-Path $dir ("importer-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    } catch {
        $script:LogFile = $null
        Write-Host "WARNING: log directory is not writable: $dir (logging to console only)"
    }
}

function Write-Log {
    param(
        [string] $Level,
        [string] $ConsolePrefix,
        [string] $Message
    )

    $msg = Protect-Secret $Message

    # Console: clean text (warnings/errors are prefixed).
    Write-Host ($ConsolePrefix + $msg)

    # File: timestamped and leveled for support review.
    if ($script:LogFile) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        try {
            Add-Content -LiteralPath $script:LogFile -Value ("{0} [{1}] {2}" -f $timestamp, $Level, $msg)
        } catch { }
    }
}

function Log-Info  { param([string] $Message) Write-Log 'INFO'  ''          $Message }
function Log-Warn  { param([string] $Message) Write-Log 'WARN'  'WARNING: ' $Message }
function Log-Error { param([string] $Message) Write-Log 'ERROR' 'ERROR: '   $Message }
function Log-Debug { param([string] $Message) if (Test-DebugEnabled) { Write-Log 'DEBUG' 'DEBUG: ' $Message } }

# Pull an HTTP status code / response body out of a failed web-request error so
# we can log a specific message instead of a generic failure.
function Get-HttpStatus {
    param($ErrorRecord)
    try {
        $response = $ErrorRecord.Exception.Response
        if ($response -and $null -ne $response.StatusCode) {
            return [int] $response.StatusCode
        }
    } catch { }
    return 'none'
}

function Get-HttpErrorBody {
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return [string] $ErrorRecord.ErrorDetails.Message
    }
    return ''
}

# ------------------------------------------------------------------------------
# 3. Small helpers
# ------------------------------------------------------------------------------
function Get-ApiBase {
    # Trailing-slash-safe base URL, e.g. "https://api...." (no trailing "/").
    return ("$API_URL").TrimEnd('/')
}

function Get-MaskedToken {
    param([string] $Token)

    if (-not $Token)            { return '' }
    if ($Token.Length -le 4)    { return '****' }
    return '****' + $Token.Substring($Token.Length - 4)
}

function Set-FormField {
    param(
        [string] $Key,
        [string] $Value = ''
    )

    if (-not $Key) { return }
    if ($null -eq $Value) { $Value = '' }

    # Assigning an existing key updates it in place and keeps its position;
    # a new key is appended. This matches set_form_field() in importer.sh.
    $script:FormFields[$Key] = $Value
}

function Add-LocalFormFieldDefaults {
    Set-FormField 'actionDefault'  $ACTION_DEFAULT
    Set-FormField 'columnNames'    $COLUMN_NAMES
    Set-FormField 'fieldSeparator' $FIELD_SEPARATOR
}

function Test-SafeConfigKey {
    param([string] $Key)
    return $Key -cmatch '^[A-Za-z_][A-Za-z0-9_.-]*$'
}

# ------------------------------------------------------------------------------
# 4. Remote config
# ------------------------------------------------------------------------------
function Test-RemoteConfigEnabled {
    $value = ("$REMOTE_CONFIG_ENABLED").Trim().ToLower()

    switch ($value) {
        { 'true', '1', 'yes', 'y'      -contains $_ } { return $true }
        { '', 'false', '0', 'no', 'n'  -contains $_ } { return $false }
        default { throw "REMOTE_CONFIG_ENABLED must be true or false." }
    }
}

function Add-RemoteConfigEntry {
    # Apply a single key/value coming from RemotePhoto. Returns $true when the
    # entry is valid (applied or safely ignored) and $false when it is rejected.
    param(
        [string] $Key,
        [string] $Value
    )

    $upper = $Key.ToUpper()

    # Secrets must never be delivered from the cloud.
    if ($upper -like '*TOKEN*' -or $upper -like '*PASSWORD*') {
        Log-Error "Cloud config key '$Key' is not allowed because tokens and passwords must remain local."
        return $false
    }

    if (-not (Test-SafeConfigKey $Key)) {
        Log-Error "Cloud config key '$Key' is not a safe property or form-field name."
        return $false
    }

    switch -CaseSensitive ($Key) {
        { 'IMPORT_DIRECTORY', 'importDirectory' -ccontains $_ } {
            $script:IMPORT_DIRECTORY = $Value; break
        }
        { 'DONE_DIRECTORY', 'doneDirectory' -ccontains $_ } {
            $script:DONE_DIRECTORY = $Value; break
        }
        { 'FAILED_DIRECTORY', 'failedDirectory' -ccontains $_ } {
            $script:FAILED_DIRECTORY = $Value; break
        }
        { 'API_URL', 'apiUrl' -ccontains $_ } {
            Log-Warn "Ignoring cloud config key '$Key'; API_URL must remain local."; break
        }
        { 'REMOTE_CONFIG_ENABLED', 'remoteConfigEnabled', 'INTEGRATION_NAME', 'integrationName', 'LOG_DIRECTORY', 'logDirectory', 'DEBUG', 'debug' -ccontains $_ } {
            Log-Warn "Ignoring cloud config key '$Key'; bootstrap settings must remain local."; break
        }
        { 'ACTION_DEFAULT', 'actionDefault' -ccontains $_ } {
            $script:ACTION_DEFAULT = $Value; Set-FormField 'actionDefault' $Value; break
        }
        { 'COLUMN_NAMES', 'columnNames' -ccontains $_ } {
            $script:COLUMN_NAMES = $Value; Set-FormField 'columnNames' $Value; break
        }
        { 'FIELD_SEPARATOR', 'fieldSeparator' -ccontains $_ } {
            $script:FIELD_SEPARATOR = $Value; Set-FormField 'fieldSeparator' $Value; break
        }
        default {
            # Anything else is treated as an extra bulk-action form field.
            Set-FormField $Key $Value
        }
    }

    return $true
}

function ConvertFrom-RemoteConfig {
    # Accepts either a JSON payload or plain key=value lines (format=env).
    param([string] $Text)

    if ($Text.TrimStart().StartsWith('{')) {
        ConvertFrom-RemoteConfigJson $Text
        return
    }

    $invalid = $false

    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = $rawLine.TrimEnd("`r")

        if (-not $line.Trim())              { continue }
        if ($line.Trim().StartsWith('#'))   { continue }

        if ($line -notmatch '=') {
            Log-Error "Cloud config line is not in key=value format: $line"
            $invalid = $true
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        $key            = $line.Substring(0, $separatorIndex).Trim()
        $value          = $line.Substring($separatorIndex + 1)

        if (-not $key) {
            Log-Error "Cloud config contains a blank property name."
            $invalid = $true
            continue
        }

        if (-not (Add-RemoteConfigEntry $key $value)) {
            $invalid = $true
        }
    }

    if ($invalid) {
        throw "Cloud config contains invalid entries. Exiting before upload."
    }
}

function ConvertFrom-RemoteConfigJson {
    param([string] $Text)

    try {
        $payload = $Text | ConvertFrom-Json
    } catch {
        throw "Could not parse cloud config JSON: $($_.Exception.Message)"
    }

    if ($payload.integrationType -and $payload.integrationType -ne 'IMPORTER') {
        throw "Cloud config integrationType must be IMPORTER."
    }

    $configs = $payload.integrationConfigs
    if ($null -eq $configs) { return }

    $invalid = $false

    foreach ($item in @($configs)) {
        $key = $item.propertyName
        if ($null -eq $key) { continue }

        if ($key -isnot [string]) {
            throw "Cloud config propertyName must be a string."
        }

        $value = $item.propertyValue
        if ($null -eq $value) { $value = '' } else { $value = [string]$value }

        if ($key -match "[`r`n]" -or $value -match "[`r`n]") {
            throw "Cloud config JSON cannot contain newline characters in names or values."
        }

        if (-not (Add-RemoteConfigEntry $key $value)) {
            $invalid = $true
        }
    }

    if ($invalid) {
        throw "Cloud config contains invalid entries. Exiting before upload."
    }
}

function Get-RemoteConfig {
    if (-not $INTEGRATION_NAME) {
        throw "INTEGRATION_NAME is required when REMOTE_CONFIG_ENABLED=true."
    }

    $encodedName = [uri]::EscapeDataString($INTEGRATION_NAME)
    $url         = "$(Get-ApiBase)/integration/$encodedName`?findBy=name&format=env"

    Log-Debug "GET $url"

    try {
        $response = Invoke-WebRequest -Uri $url -Headers @{
            'X-Auth-Token' = $script:SESSION_TOKEN
            'Accept'       = 'text/plain'
        } -UseBasicParsing
    } catch {
        $status = Get-HttpStatus $_
        Log-Error "Cloud config request failed (HTTP $status). Check that INTEGRATION_NAME matches the integration name in RemotePhoto exactly."
        $errorBody = Get-HttpErrorBody $_
        if ($errorBody) { Log-Error "server response: $errorBody" }
        throw "Cloud config request failed. Exiting before upload."
    }

    Log-Debug "cloud config HTTP status: $($response.StatusCode)"

    $text = [string] $response.Content
    if ($text.Trim()) {
        ConvertFrom-RemoteConfig $text
    }
}

# ------------------------------------------------------------------------------
# 5. API calls
# ------------------------------------------------------------------------------
function Invoke-Authentication {
    $authUrl = "$(Get-ApiBase)/authentication-token"
    $body    = @{ persistentAccessToken = $PERSISTENT_ACCESS_TOKEN } | ConvertTo-Json -Compress

    Log-Debug "POST $authUrl"

    try {
        $response = Invoke-RestMethod -Method Post -Uri $authUrl `
            -ContentType 'application/json' -Body $body
    } catch {
        $status = Get-HttpStatus $_
        Log-Error "Authentication request failed (HTTP $status). Verify API_URL has no extra path (e.g. no trailing /api) and that the token is valid."
        $errorBody = Get-HttpErrorBody $_
        if ($errorBody) { Log-Error "server response: $errorBody" }
        throw "Authentication request failed. Exiting before upload."
    }

    $token = $response.tokenValue
    if (-not $token) {
        throw "Authentication response did not contain tokenValue. Exiting before upload."
    }

    $script:SESSION_TOKEN = $token
    Log-Debug "authenticated; received session token $(Get-MaskedToken $token)"
}

function Confirm-Authenticated {
    # No-op once we already hold a session token, so the remote-config path and
    # the upload path can both call it without authenticating twice.
    if ($script:SESSION_TOKEN) { return }
    Invoke-Authentication
}

function Invoke-Logout {
    if (-not $script:SESSION_TOKEN) { return }

    Log-Debug "logging out session $(Get-MaskedToken $script:SESSION_TOKEN)"

    try {
        $body = @{ authenticationToken = $script:SESSION_TOKEN } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$(Get-ApiBase)/person/me/logout" `
            -ContentType 'application/json' `
            -Headers @{ 'X-Auth-Token' = $script:SESSION_TOKEN; 'Accept' = 'application/json' } `
            -Body $body | Out-Null
    } catch {
        # Logout is best-effort; never let it mask the real exit status.
    }
}

# ------------------------------------------------------------------------------
# 6. Validation
# ------------------------------------------------------------------------------
function Assert-ConfigValue {
    param(
        [string] $Name,
        [string] $Value
    )

    if (-not $Value) {
        throw "$Name is required."
    }
}

function Assert-Directories {
    Assert-ConfigValue 'IMPORT_DIRECTORY' $IMPORT_DIRECTORY
    Assert-ConfigValue 'DONE_DIRECTORY'   $DONE_DIRECTORY

    if (-not (Test-Path -LiteralPath $IMPORT_DIRECTORY -PathType Container)) {
        throw "IMPORT_DIRECTORY does not exist or is not a directory: $IMPORT_DIRECTORY"
    }

    if (-not (Test-Path -LiteralPath $DONE_DIRECTORY -PathType Container)) {
        throw "DONE_DIRECTORY does not exist or is not a directory: $DONE_DIRECTORY"
    }
}

# The failed directory is created automatically (it is an error sink, not
# something the customer must pre-create).
function Confirm-FailedDirectory {
    try {
        if (-not (Test-Path -LiteralPath $script:FAILED_DIRECTORY)) {
            New-Item -ItemType Directory -Path $script:FAILED_DIRECTORY -Force | Out-Null
        }
    } catch { }

    if (-not (Test-Path -LiteralPath $script:FAILED_DIRECTORY -PathType Container)) {
        throw "FAILED_DIRECTORY does not exist and could not be created: $($script:FAILED_DIRECTORY)"
    }
}

function Get-FormFieldArgs {
    # Build the "key=value" list passed to upload-csv.ps1, skipping empty values.
    $fieldArgs = @()

    foreach ($key in $script:FormFields.Keys) {
        $value = $script:FormFields[$key]
        if ($value) {
            $fieldArgs += "$key=$value"
        }
    }

    return , $fieldArgs
}

function Format-FormFieldsForLog {
    $parts = foreach ($key in $script:FormFields.Keys) {
        $value = $script:FormFields[$key]
        if ($value) { "$key=$value" }
    }

    return ($parts -join ', ')
}

function Write-ConfigSummary {
    Log-Info $LOG_SEPARATOR
    Log-Info "IMPORT_DIRECTORY           = $IMPORT_DIRECTORY"
    Log-Info "  DONE_DIRECTORY           = $DONE_DIRECTORY"
    Log-Info "FAILED_DIRECTORY           = $($script:FAILED_DIRECTORY)"
    Log-Info "         API_URL           = $API_URL"
    Log-Info "   PERSISTENT_ACCESS_TOKEN = $(Get-MaskedToken $PERSISTENT_ACCESS_TOKEN)"
    Log-Info "REMOTE_CONFIG_ENABLED      = $(if ("$REMOTE_CONFIG_ENABLED") { ("$REMOTE_CONFIG_ENABLED").ToLower() } else { 'false' })"
    Log-Info "   INTEGRATION_NAME        = $INTEGRATION_NAME"
    Log-Info "BULK_ACTION_FORM_FIELDS    = $(Format-FormFieldsForLog)"
    Log-Info "                   DEBUG   = $(if ("$DEBUG") { ("$DEBUG").ToLower() } else { 'false' })"
    Log-Info "                LOG_FILE   = $(if ($script:LogFile) { $script:LogFile } else { '<console only>' })"
    Log-Info $LOG_SEPARATOR
}

# ------------------------------------------------------------------------------
# 7. Entry point
# ------------------------------------------------------------------------------
function Invoke-Main {
    # Start logging first so even the earliest error lands in the log file.
    Initialize-Logging

    # These two settings must always be present locally; everything else can
    # come from the cloud when remote config is enabled.
    Assert-ConfigValue 'API_URL'                 $API_URL
    Assert-ConfigValue 'PERSISTENT_ACCESS_TOKEN' $PERSISTENT_ACCESS_TOKEN

    # Seed form fields from local config first so remote config can override.
    Add-LocalFormFieldDefaults

    # When remote config is on we must authenticate before we can fetch it.
    if (Test-RemoteConfigEnabled) {
        Confirm-Authenticated
        Get-RemoteConfig
    }

    # Resolve the failed directory default now so it appears in the summary.
    $script:FAILED_DIRECTORY = if ($FAILED_DIRECTORY) { $FAILED_DIRECTORY } else { Join-Path $SCRIPT_DIR 'failed' }

    Write-ConfigSummary
    Assert-Directories
    Confirm-FailedDirectory

    $csvFiles = @(Get-ChildItem -LiteralPath $IMPORT_DIRECTORY -Filter *.csv -File)

    if ($csvFiles.Count -eq 0) {
        Log-Info "IMPORT_DIRECTORY contains no CSV files. Nothing to import. Exiting now."
        return
    }

    # Authenticate now if remote config was disabled (no session yet).
    Confirm-Authenticated

    $fieldArgs = Get-FormFieldArgs
    $total     = $csvFiles.Count
    $success   = 0
    $failed    = 0

    # Upload each CSV. Successful files move to the done directory; failed files
    # move to the failed directory (never silently lost) and are logged.
    foreach ($file in $csvFiles) {
        Log-Info "uploading: $($file.Name)"

        # Isolate each file: an unexpected error on one CSV must not abort the
        # whole batch. A thrown error is treated as a failed upload.
        try {
            $result = & "$SCRIPT_DIR\upload-csv.ps1" -File $file.FullName -ApiUrl $API_URL `
                -SessionToken $script:SESSION_TOKEN -FormFields $fieldArgs
        } catch {
            $result = [pscustomobject]@{ HttpCode = 'none'; Body = $_.Exception.Message; Success = $false }
        }

        if ($result.Success) {
            Log-Info "completed: $($file.Name) (HTTP $($result.HttpCode))"
            Log-Debug "server response: $($result.Body)"
            Move-Item -LiteralPath $file.FullName -Destination $DONE_DIRECTORY
            $success++
        } else {
            Log-Error "upload failed: $($file.Name) (HTTP $($result.HttpCode))"
            Log-Error "server response: $($result.Body)"
            Move-Item -LiteralPath $file.FullName -Destination $script:FAILED_DIRECTORY
            $failed++
        }

        Log-Info $LOG_SEPARATOR
    }

    Log-Info "Run summary: $total file(s) processed - $success succeeded, $failed failed."
    Log-Info "Log file: $(if ($script:LogFile) { $script:LogFile } else { '<console only>' })"

    # Non-zero exit so a scheduler (cron/Task Scheduler) can alarm on failures.
    if ($failed -gt 0) { $script:ExitCode = 1 }
}

# Run everything inside try/finally so we always attempt to log out, exactly
# like `trap logout EXIT` in importer.sh.
try {
    Invoke-Main
} catch {
    Log-Error $_.Exception.Message
    $script:ExitCode = 1
} finally {
    Invoke-Logout
}

exit $script:ExitCode
