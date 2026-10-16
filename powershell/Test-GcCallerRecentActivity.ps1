<#
.SYNOPSIS
    Checks whether an ANI has made a completed inbound voice call in the last N minutes
    (default 30) using POST /api/v2/analytics/conversations/details/query.

.DESCRIPTION
    Same query the "Check Caller Recent Activity" data action runs, callable from
    PowerShell for testing, reporting or batch checks. The look-back window is computed
    from the clock at run time, so every execution is relative to "now".

    CLM-safe (Windows PowerShell 5.1, Constrained Language Mode). Requires an OAuth
    client-credentials client with permission analytics:conversationDetail:view.

.EXAMPLE
    .\Test-GcCallerRecentActivity.ps1 -Region mypurecloud.ie -ClientId $id -ClientSecret $secret -Ani 'tel:+447700900123'

.EXAMPLE
    .\Test-GcCallerRecentActivity.ps1 -Region usw2.pure.cloud -ClientId $id -ClientSecret $secret `
        -Ani '+15551234567' -LookbackMinutes 60 -OutCsv .\recent-calls.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Region,
    [Parameter(Mandatory = $true)][string]$ClientId,
    [Parameter(Mandatory = $true)][string]$ClientSecret,
    [Parameter(Mandatory = $true)][string]$Ani,
    [int]$LookbackMinutes = 30,
    [switch]$IncludeInProgress,
    [string]$OutCsv = '',
    [string]$ApiBaseUri = '',
    [string]$LoginBaseUri = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GcCommon.ps1')

if ($ApiBaseUri -eq '') { $ApiBaseUri = 'https://api.' + $Region }

# --- normalise ANI exactly like the data action does -------------------------
$aniValue = $Ani.Trim()
if ($aniValue.IndexOf(':') -lt 0) { $aniValue = 'tel:' + $aniValue }

# --- dynamic window, computed at run time ------------------------------------
$intervalStart = Get-GcUtcStamp -OffsetMinutes (0 - $LookbackMinutes)
$intervalEnd   = Get-GcUtcStamp -OffsetMinutes 0
$interval      = $intervalStart + '/' + $intervalEnd
Write-Verbose "ANI $aniValue, interval $interval"

# --- token --------------------------------------------------------------------
$token = Get-GcAccessToken -Region $Region -ClientId $ClientId -ClientSecret $ClientSecret -LoginBaseUri $LoginBaseUri

# --- query body ---------------------------------------------------------------
$segmentPredicates = @(
    @{ type = 'dimension'; dimension = 'direction'; operator = 'matches'; value = 'inbound' },
    @{ type = 'dimension'; dimension = 'mediaType'; operator = 'matches'; value = 'voice' },
    @{ type = 'dimension'; dimension = 'ani';       operator = 'matches'; value = $aniValue }
)
$conversationFilters = @()
if (-not $IncludeInProgress) {
    $conversationFilters += @{
        type = 'and'
        predicates = @(
            @{ type = 'dimension'; dimension = 'conversationEnd'; operator = 'exists' }
        )
    }
}

$pageSize = 100
$pageNumber = 0
$rows = @()
$totalHits = 0

do {
    $pageNumber++
    $body = @{
        interval = $interval
        order    = 'desc'
        orderBy  = 'conversationStart'
        paging   = @{ pageSize = $pageSize; pageNumber = $pageNumber }
        segmentFilters = @(
            @{ type = 'and'; predicates = $segmentPredicates }
        )
    }
    if ($conversationFilters.Count -gt 0) { $body['conversationFilters'] = $conversationFilters }

    $resp = Invoke-GcApi -ApiBaseUri $ApiBaseUri -Token $token -Method 'POST' `
        -Path '/api/v2/analytics/conversations/details/query' -Body $body

    if ($null -eq $resp) { throw 'Empty response from analytics query.' }
    if ($null -ne $resp.totalHits) { $totalHits = [int]$resp.totalHits }

    $pageConversations = @()
    if ($null -ne $resp.conversations) { $pageConversations = @($resp.conversations) }

    foreach ($c in $pageConversations) {
        $custAni = ''
        $custDnis = ''
        if ($null -ne $c.participants) {
            foreach ($p in @($c.participants)) {
                if (($p.purpose -eq 'customer' -or $p.purpose -eq 'external') -and $null -ne $p.sessions) {
                    $s = @($p.sessions)[0]
                    if ($null -ne $s) {
                        if ($null -ne $s.ani)  { $custAni  = [string]$s.ani }
                        if ($null -ne $s.dnis) { $custDnis = [string]$s.dnis }
                    }
                    break
                }
            }
        }
        $rows += New-Object PSObject -Property @{
            ConversationId      = [string]$c.conversationId
            ConversationStart   = ConvertTo-GcIsoString -Value $c.conversationStart
            ConversationEnd     = ConvertTo-GcIsoString -Value $c.conversationEnd
            OriginatingDirection = [string]$c.originatingDirection
            Ani                 = $custAni
            Dnis                = $custDnis
        }
    }
} while ($pageConversations.Count -eq $pageSize -and $rows.Count -lt $totalHits)

# --- result ---------------------------------------------------------------------
$hasCalledRecently = ($rows.Count -gt 0)
$last = $null
if ($hasCalledRecently) { $last = $rows[0] }

$result = New-Object PSObject -Property @{
    Ani                    = $aniValue
    IntervalStart          = $intervalStart
    IntervalEnd            = $intervalEnd
    LookbackMinutes        = $LookbackMinutes
    HasCalledRecently      = $hasCalledRecently
    PriorCallCount         = $rows.Count
    LastCallConversationId = $(if ($null -ne $last) { $last.ConversationId } else { '' })
    LastCallStart          = $(if ($null -ne $last) { $last.ConversationStart } else { '' })
    LastCallEnd            = $(if ($null -ne $last) { $last.ConversationEnd } else { '' })
}

if ($OutCsv -ne '') {
    $rows | Select-Object ConversationId, ConversationStart, ConversationEnd, OriginatingDirection, Ani, Dnis |
        Export-Csv -Path $OutCsv -NoTypeInformation
    Write-Host ("Wrote {0} row(s) to {1}" -f $rows.Count, $OutCsv)
}

$result | Select-Object Ani, LookbackMinutes, IntervalStart, IntervalEnd, HasCalledRecently, PriorCallCount, LastCallConversationId, LastCallStart, LastCallEnd
