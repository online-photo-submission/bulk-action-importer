<#
    RemotePhoto Bulk Action Importer (Windows / PowerShell)

    Mirrors importer.sh so the Windows and Mac/Linux importers behave identically.
    Reads bootstrap settings from config.ps1, optionally pulls the rest of the
    configuration from RemotePhoto (remote config), then uploads every CSV in the
    import directory to the bulk action API and moves it to the done directory.

    The file is organized top-to-bottom as:
        1. Globals
        2. Small helpers        (masking, form-field storage)
        3. Remote config        (fetch + parse + safety guards)
        4. API calls            (authenticate / logout)
        5. Validation + logging
        6. Entry point (Invoke-Main)
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

# Ordered map of bulk-action form fields (preserves insertion order, like the
# parallel arrays in importer.sh). Populated from local config first, then
# overridden/extended by remote config.
$script:FormFields = [ordered]@{}

# ------------------------------------------------------------------------------
# 2. Small helpers
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
# 3. Remote config
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
        Write-Host "Cloud config key '$Key' is not allowed because tokens and passwords must remain local."
        return $false
    }

    if (-not (Test-SafeConfigKey $Key)) {
        Write-Host "Cloud config key '$Key' is not a safe property or form-field name."
        return $false
    }

    switch -CaseSensitive ($Key) {
        { 'IMPORT_DIRECTORY', 'importDirectory' -ccontains $_ } {
            $script:IMPORT_DIRECTORY = $Value; break
        }
        { 'DONE_DIRECTORY', 'doneDirectory' -ccontains $_ } {
            $script:DONE_DIRECTORY = $Value; break
        }
        { 'API_URL', 'apiUrl' -ccontains $_ } {
            Write-Host "Ignoring cloud config key '$Key'; API_URL must remain local."; break
        }
        { 'REMOTE_CONFIG_ENABLED', 'remoteConfigEnabled', 'INTEGRATION_NAME', 'integrationName' -ccontains $_ } {
            Write-Host "Ignoring cloud config key '$Key'; bootstrap settings must remain local."; break
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
            Write-Host "Cloud config line is not in key=value format: $line"
            $invalid = $true
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        $key            = $line.Substring(0, $separatorIndex).Trim()
        $value          = $line.Substring($separatorIndex + 1)

        if (-not $key) {
            Write-Host "Cloud config contains a blank property name."
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

    try {
        $response = Invoke-WebRequest -Uri $url -Headers @{
            'X-Auth-Token' = $script:SESSION_TOKEN
            'Accept'       = 'text/plain'
        } -UseBasicParsing
    } catch {
        throw "Cloud config request failed. Exiting before upload."
    }

    $text = [string] $response.Content
    if ($text.Trim()) {
        ConvertFrom-RemoteConfig $text
    }
}

# ------------------------------------------------------------------------------
# 4. API calls
# ------------------------------------------------------------------------------
function Invoke-Authentication {
    $body = @{ persistentAccessToken = $PERSISTENT_ACCESS_TOKEN } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$(Get-ApiBase)/authentication-token" `
            -ContentType 'application/json' -Body $body
    } catch {
        throw "Authentication request failed. Exiting before upload."
    }

    $token = $response.tokenValue
    if (-not $token) {
        throw "Authentication response did not contain tokenValue. Exiting before upload."
    }

    $script:SESSION_TOKEN = $token
}

function Confirm-Authenticated {
    # No-op once we already hold a session token, so the remote-config path and
    # the upload path can both call it without authenticating twice.
    if ($script:SESSION_TOKEN) { return }
    Invoke-Authentication
}

function Invoke-Logout {
    if (-not $script:SESSION_TOKEN) { return }

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
# 5. Validation + logging
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
    Write-Host $LOG_SEPARATOR
    Write-Host "IMPORT_DIRECTORY           = $IMPORT_DIRECTORY"
    Write-Host "  DONE_DIRECTORY           = $DONE_DIRECTORY"
    Write-Host "         API_URL           = $API_URL"
    Write-Host "   PERSISTENT_ACCESS_TOKEN = $(Get-MaskedToken $PERSISTENT_ACCESS_TOKEN)"
    Write-Host "REMOTE_CONFIG_ENABLED      = $(if ("$REMOTE_CONFIG_ENABLED") { ("$REMOTE_CONFIG_ENABLED").ToLower() } else { 'false' })"
    Write-Host "   INTEGRATION_NAME        = $INTEGRATION_NAME"
    Write-Host "BULK_ACTION_FORM_FIELDS    = $(Format-FormFieldsForLog)"
    Write-Host $LOG_SEPARATOR
}

# ------------------------------------------------------------------------------
# 6. Entry point
# ------------------------------------------------------------------------------
function Invoke-Main {
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

    Write-ConfigSummary
    Assert-Directories

    $csvFiles = @(Get-ChildItem -LiteralPath $IMPORT_DIRECTORY -Filter *.csv -File)

    if ($csvFiles.Count -eq 0) {
        Write-Host "IMPORT_DIRECTORY contains no CSV files. Nothing to import. Exiting now."
        return
    }

    # Authenticate now if remote config was disabled (no session yet).
    Confirm-Authenticated

    $fieldArgs = Get-FormFieldArgs

    foreach ($file in $csvFiles) {
        Write-Host "Sending $($file.Name) to RemotePhoto API"

        & "$SCRIPT_DIR\upload-csv.ps1" -File $file.FullName -ApiUrl $API_URL `
            -SessionToken $script:SESSION_TOKEN -FormFields $fieldArgs

        Move-Item -LiteralPath $file.FullName -Destination $DONE_DIRECTORY
        Write-Host "completed: $($file.Name)"
        Write-Host $LOG_SEPARATOR
    }
}

# Run everything inside try/finally so we always attempt to log out, exactly
# like `trap logout EXIT` in importer.sh.
try {
    Invoke-Main
} catch {
    Write-Host $_.Exception.Message
    $script:ExitCode = 1
} finally {
    Invoke-Logout
}

exit $script:ExitCode
