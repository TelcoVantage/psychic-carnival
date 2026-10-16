<#
.SYNOPSIS
    Creates or updates the "Check Caller Recent Activity" data action draft from the JSON
    export, tests it with a live 30-minute window, and optionally publishes it.

.DESCRIPTION
    Uses the integrations actions endpoints:
      POST  /api/v2/integrations/actions/drafts              create a new action (draft)
      GET   /api/v2/integrations/actions/{id}/draft          read draft (for its version)
      PATCH /api/v2/integrations/actions/{id}/draft          update an existing draft
      POST  /api/v2/integrations/actions/{id}/draft/test     run the draft with test inputs
      POST  /api/v2/integrations/actions/{id}/draft/publish  publish the draft

    CLM-safe (Windows PowerShell 5.1, Constrained Language Mode). The OAuth client needs
    integrations:action:add, integrations:action:edit, integrations:action:test and
    integrations:integration:view.

.EXAMPLE
    .\Publish-GcDataAction.ps1 -Region mypurecloud.com -ClientId $id -ClientSecret $secret `
        -IntegrationId 'a1b2c3...' -TestAni 'tel:+15551234567'

.EXAMPLE
    .\Publish-GcDataAction.ps1 -Region mypurecloud.com -ClientId $id -ClientSecret $secret `
        -IntegrationId 'a1b2c3...' -ActionId 'custom_-_abc123' -TestAni 'tel:+15551234567' -Publish
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Region,
    [Parameter(Mandatory = $true)][string]$ClientId,
    [Parameter(Mandatory = $true)][string]$ClientSecret,
    [Parameter(Mandatory = $true)][string]$IntegrationId,
    [string]$ActionId = '',
    [string]$ExportPath = '',
    [string]$TestAni = 'tel:+15551234567',
    [int]$LookbackMinutes = 30,
    [switch]$SkipTest,
    [switch]$Publish,
    [string]$ApiBaseUri = '',
    [string]$LoginBaseUri = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GcCommon.ps1')

if ($ApiBaseUri -eq '') { $ApiBaseUri = 'https://api.' + $Region }
if ($ExportPath -eq '') { $ExportPath = Join-Path $PSScriptRoot '..\data-actions\Check-Caller-Recent-Activity.json' }
if (-not (Test-Path -Path $ExportPath)) { throw "Export file not found: $ExportPath" }

# --- load and validate the export -------------------------------------------------
$definition = Get-Content -Path $ExportPath -Raw | ConvertFrom-Json
if ($null -eq $definition -or -not $definition.name -or $null -eq $definition.config -or $null -eq $definition.contract) {
    throw "Export at $ExportPath is missing name/config/contract."
}
if ($definition.integrationType -ne 'purecloud-data-actions') {
    throw "Export integrationType is '$($definition.integrationType)'; expected purecloud-data-actions."
}
Add-Member -InputObject $definition -NotePropertyName 'integrationId' -NotePropertyValue $IntegrationId -Force

$token = Get-GcAccessToken -Region $Region -ClientId $ClientId -ClientSecret $ClientSecret -LoginBaseUri $LoginBaseUri

# --- confirm the integration exists and is a data actions integration --------------
$integration = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'GET' -Path ('/api/v2/integrations/' + $IntegrationId)
if ($null -eq $integration -or -not $integration.id) { throw "Integration $IntegrationId was not returned by the API." }
Write-Host ("Integration: {0} ({1})" -f $integration.name, $integration.integrationType.id)

# --- create or update the draft ---------------------------------------------------
if ($ActionId -eq '') {
    $created = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'POST' `
        -Path '/api/v2/integrations/actions/drafts' -Body ($definition | ConvertTo-Json -Depth 25)
    if ($null -eq $created -or -not $created.id) { throw 'Create draft response did not contain an action id.' }
    $ActionId = [string]$created.id
    Write-Host "Created draft action $ActionId"
}
else {
    $draft = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'GET' -Path ('/api/v2/integrations/actions/' + $ActionId + '/draft')
    if ($null -eq $draft -or $null -eq $draft.version) { throw "Draft for action $ActionId did not return a version." }
    $update = @{
        name     = $definition.name
        category = $(if ($draft.category) { $draft.category } else { 'Caller Activity' })
        version  = [int]$draft.version
        secure   = [bool]$definition.secure
        config   = $definition.config
        contract = $definition.contract
    }
    $updated = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'PATCH' `
        -Path ('/api/v2/integrations/actions/' + $ActionId + '/draft') -Body ($update | ConvertTo-Json -Depth 25)
    if ($null -eq $updated -or -not $updated.id) { throw 'Update draft response did not contain an action id.' }
    Write-Host ("Updated draft action {0} (now version {1})" -f $ActionId, $updated.version)
}

# --- test with a live window ------------------------------------------------------
if (-not $SkipTest) {
    $testInput = @{
        ani           = $TestAni
        intervalStart = (Get-GcUtcStamp -OffsetMinutes (0 - $LookbackMinutes))
        intervalEnd   = (Get-GcUtcStamp -OffsetMinutes 0)
    }
    Write-Host ("Testing draft with ani={0} interval={1}/{2}" -f $testInput.ani, $testInput.intervalStart, $testInput.intervalEnd)
    $test = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'POST' `
        -Path ('/api/v2/integrations/actions/' + $ActionId + '/draft/test') -Body $testInput
    if ($null -eq $test) { throw 'Draft test returned an empty response.' }

    if ($null -ne $test.operations) {
        foreach ($op in @($test.operations)) {
            $state = $(if ($op.success) { 'OK  ' } else { 'FAIL' })
            Write-Host ("  [{0}] {1}" -f $state, $op.name)
        }
    }
    if (-not $test.success) {
        throw ("Draft test FAILED for action {0}. Details: {1}" -f $ActionId, ($test | ConvertTo-Json -Depth 10))
    }
    Write-Host 'Draft test succeeded. Final result:'
    $test.finalResult | ConvertTo-Json -Depth 10 | Write-Host
}

# --- publish -----------------------------------------------------------------------
if ($Publish) {
    $draft = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'GET' -Path ('/api/v2/integrations/actions/' + $ActionId + '/draft')
    if ($null -eq $draft -or $null -eq $draft.version) { throw "Draft for action $ActionId did not return a version; cannot publish." }
    $published = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'POST' `
        -Path ('/api/v2/integrations/actions/' + $ActionId + '/draft/publish') -Body @{ version = [int]$draft.version }
    if ($null -eq $published -or -not $published.id) { throw 'Publish response did not contain an action id.' }
    Write-Host ("Published action {0} version {1}" -f $published.id, $published.version)
}
else {
    Write-Host "Draft left unpublished. Re-run with -ActionId $ActionId -Publish, or press Publish in Admin > Integrations > Actions."
}

New-Object PSObject -Property @{ ActionId = $ActionId; Published = [bool]$Publish } | Select-Object ActionId, Published
