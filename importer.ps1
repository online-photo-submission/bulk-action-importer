$ErrorActionPreference = "Stop"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$LOG_SEPARATOR = "==========================================================================================="
$SESSION_TOKEN = $null
$FORM_FIELDS = [ordered]@{}

# Import the config values from 'config.ps1'
. (Join-Path $SCRIPT_DIR "config.ps1")

function ConvertTo-BooleanSetting {
    param (
        [AllowNull()] $Value,
        [Parameter(Mandatory=$true)] [string] $Name
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return $Value
    }

    switch ($Value.ToString().Trim().ToLowerInvariant()) {
        "true" { return $true }
        "1" { return $true }
        "yes" { return $true }
        "y" { return $true }
        "false" { return $false }
        "0" { return $false }
        "no" { return $false }
        "n" { return $false }
        "" { return $false }
        default {
            throw "$Name must be true or false."
        }
    }
}

function Assert-RequiredValue {
    param (
        [Parameter(Mandatory=$true)] [string] $Name,
        [AllowNull()] $Value
    )

    if ([string]::IsNullOrWhiteSpace([string] $Value)) {
        throw "$Name is required."
    }
}

function Get-MaskedToken {
    param (
        [AllowNull()] [string] $Token
    )

    if ([string]::IsNullOrEmpty($Token)) {
        return ""
    }

    if ($Token.Length -le 4) {
        return "****"
    }

    return "****$($Token.Substring($Token.Length - 4))"
}

function Set-FormField {
    param (
        [Parameter(Mandatory=$true)] [string] $Name,
        [AllowNull()] [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    $FORM_FIELDS[$Name] = $Value
}

function Add-LocalFormFieldDefaults {
    Set-FormField "actionDefault" $ACTION_DEFAULT
    Set-FormField "columnNames" $COLUMN_NAMES
    Set-FormField "fieldSeparator" $FIELD_SEPARATOR
}

function Test-SafeConfigKey {
    param (
        [Parameter(Mandatory=$true)] [string] $Name
    )

    return $Name -match '^[A-Za-z_][A-Za-z0-9_.-]*$'
}

function Apply-RemoteConfig {
    param (
        [Parameter(Mandatory=$true)] [string] $Name,
        [AllowNull()] [string] $Value
    )

    if ($Name -match '(?i)(token|password)') {
        throw "Cloud config key '$Name' is not allowed because tokens and passwords must remain local."
    }

    if (-not (Test-SafeConfigKey $Name)) {
        throw "Cloud config key '$Name' is not a safe property or form-field name."
    }

    switch ($Name) {
        { $_ -in @("IMPORT_DIRECTORY", "importDirectory") } {
            Set-Variable -Name IMPORT_DIRECTORY -Value $Value -Scope Script
            break
        }
        { $_ -in @("DONE_DIRECTORY", "doneDirectory") } {
            Set-Variable -Name DONE_DIRECTORY -Value $Value -Scope Script
            break
        }
        { $_ -in @("API_URL", "apiUrl") } {
            Write-Host "Ignoring cloud config key '$Name'; API_URL must remain local."
            break
        }
        { $_ -in @("REMOTE_CONFIG_ENABLED", "remoteConfigEnabled", "INTEGRATION_NAME", "integrationName") } {
            Write-Host "Ignoring cloud config key '$Name'; bootstrap settings must remain local."
            break
        }
        { $_ -in @("ACTION_DEFAULT", "actionDefault") } {
            Set-Variable -Name ACTION_DEFAULT -Value $Value -Scope Script
            Set-FormField "actionDefault" $Value
            break
        }
        { $_ -in @("COLUMN_NAMES", "columnNames") } {
            Set-Variable -Name COLUMN_NAMES -Value $Value -Scope Script
            Set-FormField "columnNames" $Value
            break
        }
        { $_ -in @("FIELD_SEPARATOR", "fieldSeparator") } {
            Set-Variable -Name FIELD_SEPARATOR -Value $Value -Scope Script
            Set-FormField "fieldSeparator" $Value
            break
        }
        default {
            Set-FormField $Name $Value
        }
    }
}

function Parse-RemoteConfigText {
    param (
        [Parameter(Mandatory=$true)] [string] $ConfigText
    )

    $lines = $ConfigText -split "`r?`n"

    foreach ($line in $lines) {
        $trimmedLine = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith("#")) {
            continue
        }

        $equalsIndex = $line.IndexOf("=")

        if ($equalsIndex -lt 1) {
            throw "Cloud config line is not in key=value format: $line"
        }

        $name = $line.Substring(0, $equalsIndex).Trim()
        $value = $line.Substring($equalsIndex + 1)

        Apply-RemoteConfig $name $value
    }
}

function Parse-RemoteConfigJson {
    param (
        [Parameter(Mandatory=$true)] $ConfigObject
    )

    if ($null -ne $ConfigObject.integrationType -and $ConfigObject.integrationType -ne "IMPORTER") {
        throw "Cloud config integrationType must be IMPORTER."
    }

    if ($null -eq $ConfigObject.integrationConfigs) {
        return
    }

    foreach ($config in $ConfigObject.integrationConfigs) {
        if ($null -eq $config.propertyName) {
            continue
        }

        $name = [string] $config.propertyName
        $value = if ($null -eq $config.propertyValue) { "" } else { [string] $config.propertyValue }

        if ($name -match "[`r`n]" -or $value -match "[`r`n]") {
            throw "Cloud config JSON cannot contain newline characters in names or values."
        }

        Apply-RemoteConfig $name $value
    }
}

function Authenticate {
    $body = @{
        persistentAccessToken = $PERSISTENT_ACCESS_TOKEN
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Uri "$($API_URL.TrimEnd('/'))/authentication-token" -Method Post -ContentType "application/json" -Body $body
    } catch {
        throw "Authentication request failed. Exiting before upload. $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace([string] $response.tokenValue)) {
        throw "Authentication response did not contain tokenValue. Exiting before upload."
    }

    return [string] $response.tokenValue
}

function Fetch-RemoteConfig {
    param (
        [Parameter(Mandatory=$true)] [string] $SessionToken
    )

    Assert-RequiredValue "INTEGRATION_NAME" $INTEGRATION_NAME

    $encodedIntegrationName = [System.Uri]::EscapeDataString($INTEGRATION_NAME)
    $remoteConfigUrl = "$($API_URL.TrimEnd('/'))/integration/${encodedIntegrationName}?findBy=name&format=env"

    try {
        $response = Invoke-RestMethod -Uri $remoteConfigUrl -Method Get -Headers @{"X-Auth-Token" = $SessionToken; "Accept" = "text/plain"}
    } catch {
        throw "Cloud config request failed. Exiting before upload. $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        return
    }

    if ($response -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($response)) {
            Parse-RemoteConfigText $response
        }
    } else {
        Parse-RemoteConfigJson $response
    }
}

function Logout {
    param (
        [AllowNull()] [string] $SessionToken
    )

    if ([string]::IsNullOrWhiteSpace($SessionToken)) {
        return
    }

    $body = @{
        authenticationToken = $SessionToken
    } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Uri "$($API_URL.TrimEnd('/'))/person/me/logout" -Method Post -ContentType "application/json" -Headers @{"X-Auth-Token" = $SessionToken} -Body $body | Out-Null
    } catch {
        Write-Host "Logout failed: $($_.Exception.Message)"
    }
}

function Assert-Directories {
    Assert-RequiredValue "IMPORT_DIRECTORY" $IMPORT_DIRECTORY
    Assert-RequiredValue "DONE_DIRECTORY" $DONE_DIRECTORY

    if (-not (Test-Path -Path $IMPORT_DIRECTORY -PathType Container)) {
        throw "IMPORT_DIRECTORY does not exist or is not a directory: $IMPORT_DIRECTORY"
    }

    if (-not (Test-Path -Path $DONE_DIRECTORY -PathType Container)) {
        throw "DONE_DIRECTORY does not exist or is not a directory: $DONE_DIRECTORY"
    }
}

function Get-FormFieldArgs {
    $formFieldArgs = @()

    foreach ($key in $FORM_FIELDS.Keys) {
        $value = $FORM_FIELDS[$key]

        if (-not [string]::IsNullOrEmpty($value)) {
            $formFieldArgs += "$key=$value"
        }
    }

    return $formFieldArgs
}

function Get-FormFieldsForLog {
    $values = @()

    foreach ($key in $FORM_FIELDS.Keys) {
        $value = $FORM_FIELDS[$key]

        if (-not [string]::IsNullOrEmpty($value)) {
            $values += "$key=$value"
        }
    }

    return ($values -join ", ")
}

function Print-Config {
    Write-Host "   IMPORT_DIRECTORY        = $IMPORT_DIRECTORY"
    Write-Host "   DONE_DIRECTORY          = $DONE_DIRECTORY"
    Write-Host "   API_URL                 = $API_URL"
    Write-Host "   PERSISTENT_ACCESS_TOKEN = $(Get-MaskedToken $PERSISTENT_ACCESS_TOKEN)"
    Write-Host "   REMOTE_CONFIG_ENABLED   = $REMOTE_CONFIG_ENABLED"
    Write-Host "   INTEGRATION_NAME        = $INTEGRATION_NAME"
    Write-Host "   BULK_ACTION_FORM_FIELDS = $(Get-FormFieldsForLog)"
    Write-Host $LOG_SEPARATOR
}

try {
    Assert-RequiredValue "API_URL" $API_URL
    Assert-RequiredValue "PERSISTENT_ACCESS_TOKEN" $PERSISTENT_ACCESS_TOKEN

    Add-LocalFormFieldDefaults

    if (ConvertTo-BooleanSetting $REMOTE_CONFIG_ENABLED "REMOTE_CONFIG_ENABLED") {
        $SESSION_TOKEN = Authenticate
        Fetch-RemoteConfig $SESSION_TOKEN
    }

    Print-Config
    Assert-Directories

    $csvFiles = @(Get-ChildItem -Path $IMPORT_DIRECTORY -Filter *.csv -File)

    if ($csvFiles.Count -eq 0) {
        Write-Host "IMPORT_DIRECTORY contains no CSV files. Nothing to import. Exiting now."
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($SESSION_TOKEN)) {
        $SESSION_TOKEN = Authenticate
    }

    $formFieldArgs = @(Get-FormFieldArgs)

    foreach ($csvFile in $csvFiles) {
        Write-Host "Sending $($csvFile.FullName) to CloudCard API"

        & (Join-Path $SCRIPT_DIR "upload-csv.ps1") $IMPORT_DIRECTORY $csvFile.Name $API_URL $SESSION_TOKEN "" @formFieldArgs

        Move-Item -Path $csvFile.FullName -Destination $DONE_DIRECTORY
        Write-Host "`ncompleted: $($csvFile.Name)"
    }
} finally {
    Logout $SESSION_TOKEN
    Write-Host $LOG_SEPARATOR
}

exit
