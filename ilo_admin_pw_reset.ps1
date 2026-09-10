# ============================================================================
# iLO Administrator Password Change
#
# Requires:
#
# Powershell 7.x
# https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6
#
# Scripting Tools for Windows PowerShell: iLO cmdlets
# https://support.hpe.com/connect/s/softwaredetails?language=en_US&collectionId=MTX-9cb80bdda3824b3d&tab=releaseNotes
# ============================================================================

param(
    [Parameter(Mandatory)]
    [string]$TargetFile,

    [string]$Username = 'Administrator',

    [switch]$TestRun,

    [switch]$DisableCertificateAuthentication
)

# Requires HPE iLO cmdlets
Import-Module "C:\Program Files (x86)\Hewlett Packard Enterprise\PowerShell\Modules\HPEiLOCmdlets" -ErrorAction Stop

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory)]
        [SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-ConfirmedSecureString {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt1,

        [Parameter(Mandatory)]
        [string]$Prompt2
    )

    $First = Read-Host $Prompt1 -AsSecureString
    $Second = Read-Host $Prompt2 -AsSecureString

    $FirstPlain = ConvertTo-PlainText -SecureString $First
    $SecondPlain = ConvertTo-PlainText -SecureString $Second

    if ($FirstPlain -ne $SecondPlain) {
        throw "Passwords do not match."
    }

    return $First
}

if (-not (Test-Path -Path $TargetFile -PathType Leaf)) {
    throw "Target file not found: $TargetFile"
}

$Targets = Get-Content -Path $TargetFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }

if (-not $Targets -or $Targets.Count -eq 0) {
    throw "No targets found in file: $TargetFile"
}

$EnteredUser = Read-Host "User [$Username]"
if ([string]::IsNullOrWhiteSpace($EnteredUser)) {
    $EnteredUser = $Username
}

$Password = Read-Host "Password for user $EnteredUser" -AsSecureString
$Credential = [pscredential]::new($EnteredUser, $Password)

$NewPassword = Read-ConfirmedSecureString `
    -Prompt1 "Enter new iLO password" `
    -Prompt2 "Confirm new iLO password"

$PlainPassword = ConvertTo-PlainText -SecureString $NewPassword
$CredentialPassword = ConvertTo-PlainText -SecureString $Credential.Password

$Results = foreach ($Target in $Targets) {
    $Connection = $null

    try {
        Write-Host "Connecting to $Target ..." -ForegroundColor Cyan

        $Connection = Connect-HPEiLO `
            -Address $Target `
            -Username $Credential.UserName `
            -Password $CredentialPassword `
            -DisableCertificateAuthentication:$DisableCertificateAuthentication `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop

        Write-Host "Login succeeded on $Target" -ForegroundColor Green

        if ($TestRun) {
            [pscustomobject]@{
                Target  = $Target
                Status  = 'TestRun-Success'
                Changed = $false
                Message = 'Connectivity and login verified'
            }
            continue
        }

        $Connection | Set-HPEiLOAdministratorPassword -Password $PlainPassword -Confirm:$false -ErrorAction Stop

        [pscustomobject]@{
            Target  = $Target
            Status  = 'Success'
            Changed = $true
            Message = 'Administrator password updated'
        }
    }
    catch {
        [pscustomobject]@{
            Target  = $Target
            Status  = 'Failed'
            Changed = $false
            Message = $_.Exception.Message
        }
    }
    finally {
        if ($Connection) {
            Disconnect-HPEiLO -Connection $Connection -ErrorAction SilentlyContinue
        }
    }
}

$Results | Format-Table -AutoSize