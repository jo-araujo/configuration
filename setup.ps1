#Requires -Version 7
<#
.SYNOPSIS
Work laptop setup. Run from PowerShell 7: .\setup.ps1
.PARAMETER InstallType
Personal (Visual Studio Community + addons) or Professional (Visual Studio Professional). Prompted when omitted.
.PARAMETER SkipWsl
Skip the Ubuntu/WSL step.
.PARAMETER SkipPodman
Skip creating/starting the Podman machine (the Linux VM the Podman CLI needs).
.PARAMETER SkipSystem / SkipApps / SkipTerminal / SkipVSCode / SkipGit
Skip individual steps.
#>
[CmdletBinding()]
param(
    [ValidateSet('Personal', 'Professional')][string]$InstallType,
    [switch]$SkipWsl,
    [switch]$SkipPodman,
    [switch]$SkipSystem,
    [switch]$SkipApps,
    [switch]$SkipTerminal,
    [switch]$SkipVSCode,
    [switch]$SkipGit
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. "$root\scripts\common.ps1"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store (or via Company Portal) and retry.'
}

if (-not $InstallType -and -not $SkipApps) {
    $choice = $Host.UI.PromptForChoice('Install type', 'Is this a personal or professional install?',
        @('&Personal', '&Professional'), 1)
    $InstallType = @('Personal', 'Professional')[$choice]
}

$steps = @(
    @{ Skip = $SkipSystem;   Name = 'System';   Script = 'system.ps1';   Args = @{} }
    @{ Skip = $SkipApps;     Name = 'Apps';     Script = 'apps.ps1';     Args = @{ InstallType = $InstallType } }
    @{ Skip = $SkipVSCode;   Name = 'VS Code settings'; Script = 'settings.ps1'; Args = @{ SkipTerminal = $true } }
    @{ Skip = $SkipTerminal; Name = 'Terminal'; Script = 'terminal.ps1'; Args = @{} }
    @{ Skip = $SkipTerminal; Name = 'Copilot CLI'; Script = 'copilot.ps1'; Args = @{} }
    @{ Skip = $SkipGit;      Name = 'Git';      Script = 'git.ps1';      Args = @{} }
    @{ Skip = $SkipWsl;      Name = 'WSL';      Script = 'wsl.ps1';      Args = @{} }
    @{ Skip = $SkipPodman;   Name = 'Podman machine'; Script = 'podman.ps1'; Args = @{} }
)

foreach ($step in $steps) {
    if ($step.Skip) { Write-Step "Skipping $($step.Name)"; continue }
    Write-Step $step.Name
    $stepArgs = $step.Args
    try { & "$root\scripts\$($step.Script)" @stepArgs }
    catch { Write-Warning "$($step.Name) failed: $($_.Exception.Message)" }
}

Write-Step 'Done. Restart the terminal (and the machine if WSL was installed).'
