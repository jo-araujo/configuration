. "$PSScriptRoot\common.ps1"
Update-SessionPath

New-Item -ItemType Directory -Force 'C:\dev' | Out-Null

# `dev` command (dev.cmd / dev.ps1) available from any shell
Add-PathEntry (Resolve-Path "$PSScriptRoot\..\bin").Path 'User'

if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    $nugetReady = Invoke-SetupInstall -Name 'NuGet package provider' -Action {
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }
}
else {
    $nugetReady = $true
}

if ($nugetReady) {
    foreach ($module in 'posh-git', 'PSReadLine', 'CompletionPredictor') {
        if (Get-Module -ListAvailable $module) { continue }
        $moduleName = $module
        Invoke-SetupInstall -Name "PowerShell module $moduleName" -Action {
            Install-Module $moduleName -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
        } | Out-Null
    }
}
else {
    Write-Warning 'Skipping PowerShell module installs because the NuGet provider was skipped.'
}

& "$PSScriptRoot\settings.ps1" -SkipVSCode
