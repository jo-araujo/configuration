function Write-Step([string]$Message) {
    Write-Host "`n== $Message ==" -ForegroundColor Cyan
}

# Reload PATH and user/machine variables (e.g. NVM_HOME) so just-installed tools are usable in this session
function Update-SessionPath {
    $paths = foreach ($scope in 'Machine', 'User') {
        [Environment]::GetEnvironmentVariable('Path', $scope) -split ';'
    }
    $env:Path = ($paths | Where-Object { $_ } | Select-Object -Unique) -join ';'
    foreach ($name in 'NVM_HOME', 'NVM_SYMLINK', 'JAVA_HOME', 'DOTNET_ROOT') {
        foreach ($scope in 'User', 'Machine') {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if ($value) { Set-Item "env:$name" $value; break }
        }
    }
}

function Invoke-SetupInstall {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Native,
        [int[]]$SuccessExitCodes = @(0)
    )

    while ($true) {
        $failure = $null
        try {
            & $Action | Out-Host
            if ($Native -and $LASTEXITCODE -notin $SuccessExitCodes) {
                $failure = "exit code $LASTEXITCODE"
            }
        }
        catch { $failure = $_.Exception.Message }

        if (-not $failure) { return $true }
        Write-Warning "$Name failed ($failure)."

        while ($true) {
            try { $answer = Read-Host "$Name failed ($failure). [R]etry or [C]ontinue without installing?" }
            catch { throw "Cannot prompt after $Name failed; rerun from an interactive PowerShell session. $($_.Exception.Message)" }
            if ($answer -match '^[Rr]$') { break }
            if ($answer -match '^[Cc]$') { Write-Warning "Skipping $Name"; return $false }
            Write-Host 'Enter R to retry or C to continue without installing.'
        }
    }
}

function Install-WingetApp([string]$Id) {
    winget list --id $Id -e --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$Id already installed"
        return $true
    }

    $installArgs = @('install', '--id', $Id, '-e', '--silent', '--accept-source-agreements', '--accept-package-agreements')
    $installed = Invoke-SetupInstall -Name $Id -Native -SuccessExitCodes @(0, -1978335189, -1978335135) -Action {
        winget @installArgs
    }
    if ($installed) { Update-SessionPath }
    return $installed
}

# Highest id matching a pattern whose first capture group is the version/year, e.g. latest .NET SDK
function Find-LatestWingetId([string]$Query, [string]$Pattern, [string]$Fallback) {
    $found = winget search $Query --source winget --accept-source-agreements 2>$null |
        Select-String -Pattern $Pattern -AllMatches | ForEach-Object { $_.Matches } |
        Sort-Object { [int]$_.Groups[1].Value } -Descending | Select-Object -First 1
    if ($found) { $found.Value } else { Write-Warning "Could not resolve $Query, using $Fallback"; $Fallback }
}

# One `winget list` call parsed by header column offsets: Id, Version (all installed), Available (newer version or empty)
function Get-WingetInventory {
    $lines = @(winget list --accept-source-agreements 2>$null | ForEach-Object { "$_" })
    $headerIndex = [array]::FindIndex($lines, [Predicate[string]]{ param($l) $l -match '^Name\s+Id\s+Version' })
    if ($headerIndex -lt 0) { return @() }
    $header = $lines[$headerIndex]
    $idStart = $header.IndexOf('Id'); $versionStart = $header.IndexOf('Version')
    $availableStart = $header.IndexOf('Available'); $sourceStart = $header.IndexOf('Source')
    if ($availableStart -lt 0) { $availableStart = $sourceStart }
    if ($sourceStart -lt 0) { $sourceStart = $header.Length }
    $cut = { param($l, $from, $to) if ($l.Length -le $from) { '' } else { $l.Substring($from, [Math]::Min($to, $l.Length) - $from).Trim() } }
    $rows = foreach ($line in $lines[($headerIndex + 2)..($lines.Count - 1)]) {
        if (-not $line.Trim()) { continue }
        [pscustomobject]@{
            Id        = & $cut $line $idStart $versionStart
            Version   = & $cut $line $versionStart $availableStart
            Available = & $cut $line $availableStart $sourceStart
        }
    }
    $rows | Where-Object Id | Group-Object Id | ForEach-Object {
        [pscustomobject]@{
            Id        = $_.Name
            Version   = (($_.Group.Version | Where-Object { $_ } | Select-Object -Unique) -join ', ')
            Available = ($_.Group.Available | Where-Object { $_ } | Select-Object -First 1)
        }
    }
}

# Professional = core + business, Personal = core + personal + addons, plus the latest .NET SDK
function Get-SetupAppIds([string]$InstallType) {
    $apps = Get-Content "$PSScriptRoot\..\apps.json" -Raw | ConvertFrom-Json
    $ids = @($apps.core)
    $ids += if ($InstallType -eq 'Personal') { $apps.personal; $apps.addons } else { $apps.business }
    $ids + (Find-LatestWingetId 'Microsoft.DotNet.SDK' 'Microsoft\.DotNet\.SDK\.(\d+)(?![\w.])' 'Microsoft.DotNet.SDK.9')
}

# Remembered so `dev apps` knows which groups apply to this machine
$script:InstallTypeFile = Join-Path $HOME '.config\dev\install-type'
function Save-InstallType([string]$InstallType) {
    New-Item -ItemType Directory -Force (Split-Path $script:InstallTypeFile) | Out-Null
    Set-Content $script:InstallTypeFile $InstallType
}
function Get-SavedInstallType {
    if (Test-Path $script:InstallTypeFile) { (Get-Content $script:InstallTypeFile -TotalCount 1).Trim() }
}

function Add-PathEntry([string]$Dir, [string]$Scope = 'Machine') {
    $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    $entries = $current -split ';' | Where-Object { $_ }
    if ($entries -contains $Dir) { return }
    [Environment]::SetEnvironmentVariable('Path', (($entries + $Dir) -join ';'), $Scope)
    $env:Path += ";$Dir"
}

function Backup-IfExists([string]$Path) {
    if (Test-Path $Path) { Copy-Item $Path "$Path.bak" -Force }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
