<#
.SYNOPSIS
    Shared Genesys Cloud helpers that are safe in PowerShell Constrained Language Mode.

.DESCRIPTION
    Dot-source this file from a script:  . (Join-Path $PSScriptRoot 'GcCommon.ps1')

    Written for Windows PowerShell 5.1 under AppLocker/WDAC Constrained Language Mode:
      - no .NET static method calls, no ::new(), no [pscustomobject] casts
      - Base64 for the OAuth Basic header is implemented with bit operators
      - HTTP status is read via [int]$_.Exception.Response.StatusCode in try/catch,
        with a fallback regex on the exception message
      - every API response is validated before it is used
#>

function ConvertTo-GcUtf8Bytes {
    <# Returns an [int[]] of UTF-8 byte values for a string, pure PowerShell. #>
    param([string]$Text)

    $bytes = @()
    $chars = $Text.ToCharArray()
    $i = 0
    while ($i -lt $chars.Length) {
        $cp = [int]$chars[$i]
        # Combine a UTF-16 surrogate pair into one code point
        if ($cp -ge 55296 -and $cp -le 56319 -and ($i + 1) -lt $chars.Length) {
            $low = [int]$chars[$i + 1]
            if ($low -ge 56320 -and $low -le 57343) {
                $cp = 65536 + (($cp - 55296) -shl 10) + ($low - 56320)
                $i++
            }
        }
        if ($cp -lt 128) {
            $bytes += $cp
        }
        elseif ($cp -lt 2048) {
            $bytes += (192 -bor ($cp -shr 6))
            $bytes += (128 -bor ($cp -band 63))
        }
        elseif ($cp -lt 65536) {
            $bytes += (224 -bor ($cp -shr 12))
            $bytes += (128 -bor (($cp -shr 6) -band 63))
            $bytes += (128 -bor ($cp -band 63))
        }
        else {
            $bytes += (240 -bor ($cp -shr 18))
            $bytes += (128 -bor (($cp -shr 12) -band 63))
            $bytes += (128 -bor (($cp -shr 6) -band 63))
            $bytes += (128 -bor ($cp -band 63))
        }
        $i++
    }
    return ,$bytes
}

function ConvertTo-GcBase64 {
    <# Base64-encodes a string (UTF-8) without [Convert]:: - CLM safe. #>
    param([string]$Text)

    $table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $bytes = ConvertTo-GcUtf8Bytes -Text $Text
    $count = $bytes.Length
    $out = ''
    $i = 0
    while ($i -lt $count) {
        $b0 = [int]$bytes[$i]
        $b1 = 0
        $b2 = 0
        $have = 1
        if (($i + 1) -lt $count) { $b1 = [int]$bytes[$i + 1]; $have = 2 }
        if (($i + 2) -lt $count) { $b2 = [int]$bytes[$i + 2]; $have = 3 }

        $n = ($b0 -shl 16) -bor ($b1 -shl 8) -bor $b2

        $out += $table.Substring((($n -shr 18) -band 63), 1)
        $out += $table.Substring((($n -shr 12) -band 63), 1)
        if ($have -ge 2) { $out += $table.Substring((($n -shr 6) -band 63), 1) } else { $out += '=' }
        if ($have -ge 3) { $out += $table.Substring(($n -band 63), 1) }         else { $out += '=' }

        $i += 3
    }
    return $out
}

function ConvertTo-GcFormValue {
    <# Minimal application/x-www-form-urlencoded escaping without [uri]:: #>
    param([string]$Value)
    return $Value.Replace('%', '%25').Replace('+', '%2B').Replace('/', '%2F').Replace('=', '%3D').Replace('&', '%26').Replace(' ', '+')
}

function Get-GcUtcStamp {
    <# ISO-8601 UTC timestamp (yyyy-MM-ddTHH:mm:ss.fffZ) offset by N minutes from now. #>
    param([int]$OffsetMinutes = 0)
    $t = (Get-Date).ToUniversalTime().AddMinutes($OffsetMinutes)
    # Quote every literal so culture-specific date/time separators cannot leak in
    return $t.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
}

function ConvertTo-GcIsoString {
    <#
    Normalises an API date value to an ISO-8601 UTC string. PowerShell 7's ConvertFrom-Json
    turns ISO strings into [datetime]; Windows PowerShell 5.1 leaves them as strings.
    #>
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
    }
    return [string]$Value
}

function Get-GcHttpStatus {
    <# Extracts an HTTP status code from an ErrorRecord, 0 when unknown. #>
    param($ErrorRecord)

    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { $status = 0 }
    if ($status -eq 0) {
        $msg = [string]$ErrorRecord.Exception.Message
        if ($msg -match '\b([45][0-9][0-9])\b') { $status = [int]$matches[1] }
    }
    return $status
}

function Get-GcErrorDetail {
    <# Best-effort response body text from an Invoke-RestMethod failure. #>
    param($ErrorRecord)
    $detail = ''
    try {
        if ($null -ne $ErrorRecord.ErrorDetails) { $detail = [string]$ErrorRecord.ErrorDetails.Message }
    } catch { $detail = '' }
    if ($detail -eq '') { $detail = [string]$ErrorRecord.Exception.Message }
    return $detail
}

function Get-GcAccessToken {
    <#
    .SYNOPSIS  OAuth client-credentials token from login.<region>.
    .OUTPUTS   The access token string. Throws when the response has no access_token.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
        [string]$LoginBaseUri = ''
    )

    if ($LoginBaseUri -eq '') { $LoginBaseUri = 'https://login.' + $Region }
    $basic = ConvertTo-GcBase64 -Text ($ClientId + ':' + $ClientSecret)
    $headers = @{ Authorization = ('Basic ' + $basic) }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri ($LoginBaseUri + '/oauth/token') `
            -Headers $headers -ContentType 'application/x-www-form-urlencoded' `
            -Body 'grant_type=client_credentials'
    }
    catch {
        $status = Get-GcHttpStatus -ErrorRecord $_
        $detail = Get-GcErrorDetail -ErrorRecord $_
        if ($status -eq 401) { throw "Token request rejected (HTTP 401): check client id/secret and region. $detail" }
        throw "Token request failed (HTTP $status): $detail"
    }

    if ($null -eq $resp -or -not $resp.access_token) {
        throw 'Token response did not contain access_token; aborting.'
    }
    return [string]$resp.access_token
}

function Invoke-GcApi {
    <#
    .SYNOPSIS  Calls the Genesys Cloud Platform API with bearer auth, JSON body and 429 retry.
    .PARAMETER Body  A hashtable/object (serialised with ConvertTo-Json) or a pre-built JSON string.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ApiBaseUri,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Body = $null,
        [int]$MaxRetries = 3
    )

    $headers = @{ Authorization = ('Bearer ' + $Token) }
    $uri = $ApiBaseUri + $Path
    $json = $null
    if ($null -ne $Body) {
        if ($Body -is [string]) { $json = $Body } else { $json = $Body | ConvertTo-Json -Depth 25 -Compress }
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($null -ne $json) {
                return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
                    -ContentType 'application/json; charset=utf-8' -Body $json
            }
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        }
        catch {
            $status = Get-GcHttpStatus -ErrorRecord $_
            if ($status -eq 429 -and $attempt -le $MaxRetries) {
                $wait = 5 * $attempt
                Write-Warning "Rate limited (429) on $Method $Path - retrying in $wait s (attempt $attempt of $MaxRetries)"
                Start-Sleep -Seconds $wait
                continue
            }
            $detail = Get-GcErrorDetail -ErrorRecord $_
            if ($status -eq 401) { throw "HTTP 401 on $Method $Path - token expired or invalid. $detail" }
            if ($status -eq 403) { throw "HTTP 403 on $Method $Path - OAuth client lacks the required permission. $detail" }
            throw "HTTP $status on $Method $Path - $detail"
        }
    }
}
