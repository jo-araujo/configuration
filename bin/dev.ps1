#Requires -Version 5.1
# Interface to the configs this repo provides. Usage: dev <command>
$repo = (Resolve-Path "$PSScriptRoot\..").Path

function Show-DevCommands {
	Write-Host 'Usage: dev <command>' -ForegroundColor Cyan
	$commands.GetEnumerator() | ForEach-Object {
		[pscustomobject]@{ Command = "dev $($_.Key)"; Description = $_.Value.Description }
	} | Format-Table -AutoSize
}

function Remove-DevGoneBranches {
	git fetch --prune
	$current = git branch --show-current
	$gone = git for-each-ref --format '%(refname:short)|%(upstream:track)' refs/heads |
		Where-Object { $_ -like '*|`[gone`]' } | ForEach-Object { ($_ -split '\|')[0] } |
		Where-Object { $_ -ne $current }
	if (-not $gone) { Write-Host 'No gone branches.'; return }
	$gone | ForEach-Object { git branch -D $_ }
}

function Remove-DevAllBranches {
	$current = git branch --show-current
	git branch --format '%(refname:short)' |
		Where-Object { $_ -ne 'main' -and $_ -ne $current } | ForEach-Object { git branch -D $_ }
}

function Remove-DevProjectArtifacts {
	Get-ChildItem -Path . -Recurse -Force -Directory -Include bin, obj, .vs -ErrorAction SilentlyContinue |
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Resolve-DevInstallType([string]$Requested) {
	. "$repo\scripts\common.ps1"
	foreach ($candidate in $Requested, (Get-SavedInstallType)) {
		if ($candidate -in 'Personal', 'Professional') { return $candidate }
		if ($candidate -in 'personal', 'professional') { return (Get-Culture).TextInfo.ToTitleCase($candidate) }
	}
	$choice = $Host.UI.PromptForChoice('Install type', 'Is this a personal or professional install?', @('&Personal', '&Professional'), 1)
	@('Personal', 'Professional')[$choice]
}

function Invoke-DevApps([string]$Action, [string]$Options) {
	$tokens = @("$Options" -split '\s+' | Where-Object { $_ })
	$confirmed = $tokens -contains 'yes'
	$type = Resolve-DevInstallType ($tokens | Where-Object { $_ -ne 'yes' } | Select-Object -First 1)
	switch ($Action) {
		'install' { & "$repo\scripts\apps.ps1" -InstallType $type }
		'update' {
			. "$repo\scripts\common.ps1"
			winget source update
			$inventory = @{}
			Get-WingetInventory | ForEach-Object { $inventory[$_.Id] = $_ }
			$pending = @(Get-SetupAppIds $type | Where-Object { $inventory[$_] -and $inventory[$_].Available } |
				ForEach-Object { [pscustomobject]@{ Id = $_; Installed = $inventory[$_].Version; UpgradeTo = $inventory[$_].Available } })
			if (-not $pending) { Write-Host 'All apps from apps.json are up to date.'; return }
			$pending | Format-Table -AutoSize
			if ($confirmed) { }
			elseif ([Console]::IsInputRedirected) { throw 'Interactive confirmation is required; rerun with: dev apps update yes' }
			elseif ($Host.UI.PromptForChoice('Update apps', "Upgrade $($pending.Count) app(s)?", @('&Yes', '&No'), 1) -ne 0) { Write-Host 'Skipped.'; return }
			foreach ($app in $pending) {
				Write-Host "Updating $($app.Id) $($app.Installed) -> $($app.UpgradeTo)" -ForegroundColor Cyan
				winget upgrade --id $app.Id -e --silent --accept-source-agreements --accept-package-agreements
			}
			Update-SessionPath
		}
		'list' {
			. "$repo\scripts\common.ps1"
			$inventory = @{}
			Get-WingetInventory | ForEach-Object { $inventory[$_.Id] = $_ }
			Get-SetupAppIds $type | ForEach-Object {
				$entry = $inventory[$_]
				[pscustomobject]@{ Id = $_; Installed = [bool]$entry; Version = $entry.Version; Available = $entry.Available }
			} | Format-Table -AutoSize -Wrap
		}
	}
}

function Invoke-DevSettingsPull([string]$Options) {
	$pullArgs = @{}
	foreach ($token in @("$Options" -split '\s+' | Where-Object { $_ -and $_ -ne '-mode' })) {
		switch -regex ($token) {
			'^-?add$'    { $pullArgs.Mode = 'Add' }
			'^-?mirror$' { $pullArgs.Mode = 'Mirror' }
			'^-?(yes|y)$' { $pullArgs.Yes = $true }
			default      { Write-Warning "Ignoring unknown option: $token" }
		}
	}
	& "$repo\scripts\settings.ps1" -Pull @pullArgs
}

function Invoke-DevSetup([string]$Step, [string]$Type) {
	$script = @{ system = 'system.ps1'; terminal = 'terminal.ps1'; copilot = 'copilot.ps1'; git = 'git.ps1'; wsl = 'wsl.ps1'; podman = 'podman.ps1' }
	switch ($Step) {
		'apps'   { Invoke-DevApps 'install' $Type }
		'vscode' { & "$repo\scripts\settings.ps1" -SkipTerminal }
		'all'    {
			if ($Type -in 'personal', 'professional') { & "$repo\setup.ps1" -InstallType (Get-Culture).TextInfo.ToTitleCase($Type) }
			else { & "$repo\setup.ps1" }
		}
		default  { & "$repo\scripts\$($script[$Step])" }
	}
}

function Show-DevSetupSteps {
	$commands.GetEnumerator() | Where-Object { $_.Key -like 'setup*' } | ForEach-Object {
		[pscustomobject]@{ Command = "dev $($_.Key)"; Description = $_.Value.Description }
	} | Format-Table -AutoSize -Wrap
}

function Invoke-DevCopilot([string]$Path) {
	if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { Write-Warning 'copilot not found on PATH.'; return }
	if (-not $Path) {
		$folders = @(Get-ChildItem -LiteralPath 'C:\dev' -Directory -ErrorAction SilentlyContinue)
		if (-not $folders) { Write-Warning 'No folders under C:\dev.'; return }
		for ($i = 0; $i -lt $folders.Count; $i++) { Write-Host ('{0,3}) {1}' -f ($i + 1), $folders[$i].Name) }
		if ([Console]::IsInputRedirected) { Write-Warning 'Pass a path: dev copilot <path>'; return }
		$answer = Read-Host 'Folder number (Enter to cancel)'
		$number = 0
		if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $folders.Count) { return }
		$Path = $folders[$number - 1].FullName
	}
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Warning "Folder not found: $Path"; return }
	Push-Location -LiteralPath $Path
	try { copilot } finally { Pop-Location }
}

$commands = [ordered]@{
	'alias list'    = @{ Description = 'List every dev command';                                         Action = { Show-DevCommands } }
	'branch prune'  = @{ Description = 'Fetch --prune and delete local branches whose upstream is gone'; Action = { Remove-DevGoneBranches } }
	'branch clean'  = @{ Description = 'Delete all local branches except main and the current one';      Action = { Remove-DevAllBranches } }
	'project clean' = @{ Description = 'Delete bin, obj and .vs folders under the current directory';    Action = { Remove-DevProjectArtifacts } }
	'copilot'       = @{ Description = 'Start Copilot CLI in a folder (dev copilot [path]; no path lists C:\dev folders)'; Action = { Invoke-DevCopilot $rest } }
	'setup'         = @{ Description = 'List the setup steps you can run separately';                     Action = { Show-DevSetupSteps } }
	'setup system'  = @{ Description = 'Windows tweaks (dark mode, file extensions, Explorer, ...)';       Action = { Invoke-DevSetup 'system' } }
	'setup apps'    = @{ Description = 'Install apps from apps.json (dev setup apps [personal|professional])'; Action = { Invoke-DevSetup 'apps' $rest } }
	'setup vscode'  = @{ Description = 'Merge repo VS Code settings, keybindings and extensions';         Action = { Invoke-DevSetup 'vscode' } }
	'setup terminal' = @{ Description = 'PowerShell modules, profile, Windows Terminal settings, dev on PATH'; Action = { Invoke-DevSetup 'terminal' } }
	'setup copilot' = @{ Description = 'Copilot CLI settings (hide startup banner)';                       Action = { Invoke-DevSetup 'copilot' } }
	'setup git'     = @{ Description = 'Git name, email and defaults';                                    Action = { Invoke-DevSetup 'git' } }
	'setup wsl'     = @{ Description = 'Ubuntu on WSL and the dev wrapper';                               Action = { Invoke-DevSetup 'wsl' } }
	'setup podman'  = @{ Description = 'Create and start the Podman machine';                             Action = { Invoke-DevSetup 'podman' } }
	'setup all'     = @{ Description = 'Run every step (dev setup all [personal|professional])';          Action = { Invoke-DevSetup 'all' $rest } }
	'apps install'  = @{ Description = 'Install missing apps from apps.json (dev apps install [personal|professional])'; Action = { Invoke-DevApps 'install' $rest } }
	'apps update'   = @{ Description = 'Show installed -> new versions from apps.json, confirm, then upgrade (dev apps update [yes])'; Action = { Invoke-DevApps 'update' $rest } }
	'apps list'     = @{ Description = 'Show apps.json ids with installed and available versions';       Action = { Invoke-DevApps 'list' $rest } }
	'settings pull' = @{ Description = 'Copy live VS Code settings, keybindings and extensions into the repo (dev settings pull [add|mirror] [yes])'; Action = { Invoke-DevSettingsPull $rest } }
	'settings sync' = @{ Description = 'Apply local repo settings for VS Code, PowerShell and Windows Terminal'; Action = { & "$repo\scripts\settings.ps1" -ErrorAction Stop; & "$repo\scripts\copilot.ps1" } }
}

if ($args.Count -and $args[0] -eq 'complete') {
	# Used by the profile's tab completer: next word of every command that starts with the typed prefix
	$prefix = ("$($args[1])").TrimStart().ToLower()
	$skip = if ($prefix.Contains(' ')) { $prefix.LastIndexOf(' ') + 1 } else { 0 }
	$commands.Keys | Where-Object { $_ -like "$prefix*" } |
		ForEach-Object { ($_.Substring($skip) -split ' ')[0] } | Select-Object -Unique
	return
}

$name = ($args -join ' ').Trim().ToLower()
if (-not $name -or $name -eq 'help') { Show-DevCommands; return }
$rest = ''
if ($name -match '^copilot(?: |$)') { $rest = (($args -join ' ').Trim() -replace '^(?i)copilot\s*', '').Trim('"'); $name = 'copilot' }
if ($name -match '^apps (install|update|list)(?: (.+))?$') { $rest = $Matches[2]; $name = "apps $($Matches[1])" }
if ($name -match '^setup (apps|all)(?: (\S+))?$') { $rest = $Matches[2]; $name = "setup $($Matches[1])" }
if ($name -match '^settings pull(?: (.+))?$') { $rest = $Matches[1]; $name = 'settings pull' }
if ($commands.Contains($name)) { & $commands[$name].Action; return }
Write-Warning "Unknown command: dev $name"
Show-DevCommands
