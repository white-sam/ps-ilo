<#
.SYNOPSIS
    Power control for HPE ProLiant servers (iLO 5 / iLO 6) using Redfish API

.EXAMPLE
    .\Set-HPEServerPower.ps1 -IPAddress 10.0.0.50 -Action On -User admin -Password 'P@ss'
.EXAMPLE
    .\Set-HPEServerPower.ps1 -ListFile .\servers.txt -Action Off -Force -User admin -Password 'P@ss'
.EXAMPLE
    .\Set-HPEServerPower.ps1 -ListFile .\servers.txt -Action ColdBoot      # prompts for credentials
#>
[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    # Parameter list for single IP address - Default
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [string[]]$IPAddress,

    # Parameter list for IP addresses supplied in a file
    [Parameter(Mandatory, ParameterSetName = 'List')]
    [ValidateScript({ Test-Path $_ })]
    [string]$ListFile,

    [Parameter(Mandatory)]
    [ValidateSet('On', 'Off', 'Restart', 'ColdBoot', 'Status')]
    [string]$Action,

    # Off -> ForceOff, Restart -> ForceRestart (no graceful OS shutdown)
    [switch]$Force,

    [string]$User,
    [string]$Password,
    [PSCredential]$Credential,

    # Parallel jobs (only works with PS7)
    [int]$ThrottleLimit = 10,
    [string]$LogFile = ".\HPEPower_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
)

# ---- Credentials: -User/-Password > -Credential > prompt ----
if ($User -and $Password) {
    $pass = $Password
}
elseif ($Credential) {
    $User = $Credential.UserName
    $pass = $Credential.GetNetworkCredential().Password
}
else {
    $c = Get-Credential -UserName $User -Message 'iLO credentials'
    if (-not $c) { throw 'No credentials supplied.' }
    $User = $c.UserName
    $pass = $c.GetNetworkCredential().Password
}

# ---- Resolve Redfish reset type ----
switch ($Action) {
    # Switch On
    'On'       { $resetType = 'On' }
    # Gracefull off unless -Force then it's a simple power off
    'Off'      { $resetType = if ($Force) { 'ForceOff' }     else { 'GracefulShutdown' } }
    # Gracefull restart unless -Force then it's a simple power off restart
    'Restart'  { $resetType = if ($Force) { 'ForceRestart' } else { 'GracefulRestart' } }
    # Same as pulling power cords for 10 seconds
    'ColdBoot' { $resetType = 'ColdBoot' }
    # Display's the current power status
    'Status'   { $resetType = $null }
}

# ---- Build target list (ignore blanks and # comments) ----
if ($PSCmdlet.ParameterSetName -eq 'List') {
    # Loop through file collating all IP addresses excluding comments
    $targets = Get-Content $ListFile | ForEach-Object { $_.Trim() } |
               Where-Object { $_ -and $_ -notmatch '^#' } | Select-Object -Unique
} else {
    $targets = $IPAddress
}
# Display a summary of the IP addresses found
Write-Host "Targets: $($targets.Count)  Action: $Action  ResetType: $resetType" -ForegroundColor Cyan

# ---- Per-server worker (self-contained for parallel use) ----
$worker = {
    param($ip, $Action, $resetType, $user, $pass)

    # Check if running in PS7
    $isPS7 = $PSVersionTable.PSVersion.Major -ge 7
    if (-not $isPS7) {
        if (-not ('TrustAll' -as [type])) {
            Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }

    $auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:${pass}"))
    $headers = @{ Authorization = "Basic $auth"; 'Content-Type' = 'application/json' }
    $common  = @{ Headers = $headers; TimeoutSec = 30; ErrorAction = 'Stop' }
    if ($isPS7) { $common.SkipCertificateCheck = $true }

    $base   = "https://$ip/redfish/v1/Systems/1"
    $result = [ordered]@{ IP = $ip; Model = ''; Before = ''; Action = $Action; ResetType = $resetType; Result = ''; Message = '' }

    try {
        $sys = Invoke-RestMethod -Uri "$base/" -Method Get @common
        $result.Model  = $sys.Model
        $result.Before = $sys.PowerState
        $state = $sys.PowerState

        $skip = switch ($Action) {
            'Status'   { 'Status only' }
            'On'       { if ($state -eq 'On')  { 'Already on' } }
            'Off'      { if ($state -eq 'Off') { 'Already off' } }
            'Restart'  { if ($state -eq 'Off') { 'Server is off - use On' } }
            'ColdBoot' { if ($state -eq 'Off') { 'Server is off - use On' } }
        }

        if ($skip) {
            $result.Result  = if ($Action -eq 'Status') { 'OK' } else { 'Skipped' }
            $result.Message = $skip
        }
        else {
            if ($resetType -eq 'ColdBoot') {
                $uri = "$base/Actions/Oem/Hpe/HpeComputerSystemExt.SystemReset/"
            } else {
                $uri = "$base/Actions/ComputerSystem.Reset/"
            }
            $body = @{ ResetType = $resetType } | ConvertTo-Json
            Invoke-RestMethod -Uri $uri -Method Post -Body $body @common | Out-Null
            $result.Result  = 'Success'
            $result.Message = "Sent ResetType=$resetType"
        }
    }
    catch {
        $result.Result  = 'Failed'
        $result.Message = $_.Exception.Message
    }
    [pscustomobject]$result
}

# ---- Execute ----
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $workerText = $worker.ToString()
    $results = $targets | ForEach-Object -Parallel {
        $sb = [scriptblock]::Create($using:workerText)
        & $sb $_ $using:Action $using:resetType $using:User $using:pass
    } -ThrottleLimit $ThrottleLimit
} else {
    $results = foreach ($ip in $targets) {
        Write-Host "Processing $ip ..." -NoNewline
        $r = & $worker $ip $Action $resetType $User $pass
        Write-Host " $($r.Result)"
        $r
    }
}

$results | Sort-Object IP | Format-Table -AutoSize