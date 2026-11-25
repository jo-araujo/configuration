#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipTerminal,
    [switch]$SkipVSCode,
    [ValidateSet('Local', 'Repo')][string]$OnConflict,
    [switch]$Pull,
    [ValidateSet('Add', 'Mirror')][string]$Mode,
    [switch]$Yes
)

function Get-SettingsEnvironment {
    @{
        Home = $HOME
        Documents = [Environment]::GetFolderPath('MyDocuments')
        AppData = $env:APPDATA
        LocalAppData = $env:LOCALAPPDATA
    }
}

function Read-SettingsJson {
    param(
        [string]$Path,
        [ValidateSet('Object', 'Array')][string]$RootType
    )

    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    # Protect JSON strings while removing JSONC comments and trailing commas.
    $strings = '"(?:\\.|[^"\\])*"'
    $json = [regex]::Replace($json, "$strings|//[^\r\n]*|/\*[\s\S]*?\*/", {
        param($match)
        if ($match.Value.StartsWith('"')) { return $match.Value }
        return ' '
    })
    $json = [regex]::Replace($json, "$strings|,(?=\s*[}\]])", {
        param($match)
        if ($match.Value -eq ',') { return '' }
        return $match.Value
    })
    $opening = if ($RootType -eq 'Object') { '{' } else { '[' }
    if (-not $json.TrimStart().StartsWith($opening)) {
        throw "Expected a JSON $RootType in $Path."
    }
    $options = @{ InputObject = $json; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    try { $value = ConvertFrom-Json @options }
    catch { throw "Invalid JSON/JSONC in $Path. Fix the source file before syncing." }
    if ($RootType -eq 'Array') { return ,@($value) }
    return $value
}

function Read-VSCodeExtensions([string]$Path) {
    $extensions = Read-SettingsJson -Path $Path -RootType Array
    foreach ($extension in $extensions) {
        if ($extension -isnot [string] -or $extension -notmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$') {
            throw 'vscode\extensions.json must contain only publisher.extension ID strings.'
        }
    }
    return ,@($extensions | Select-Object -Unique)
}

function Assert-VSCodeKeybindings($Bindings) {
    foreach ($binding in $Bindings) {
        if ($binding -isnot [pscustomobject] -or $binding.key -isnot [string] -or
            [string]::IsNullOrWhiteSpace($binding.key) -or $binding.command -isnot [string] -or
            ($null -ne $binding.when -and $binding.when -isnot [string])) {
            throw 'Invalid VS Code keybinding: expected a key, a command string, and an optional when string. Values withheld.'
        }
    }
}

function Test-SettingsValueEqual($Left, $Right) {
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Left -is [pscustomobject] -and $Right -is [pscustomobject]) {
        if (@($Left.PSObject.Properties).Count -ne @($Right.PSObject.Properties).Count) { return $false }
        foreach ($property in $Left.PSObject.Properties) {
            $other = $Right.PSObject.Properties[$property.Name]
            if ($null -eq $other -or $other.Name -cne $property.Name -or
                -not (Test-SettingsValueEqual $property.Value $other.Value)) { return $false }
        }
        return $true
    }
    if ($Left -is [array] -and $Right -is [array]) {
        if ($Left.Count -ne $Right.Count) { return $false }
        for ($i = 0; $i -lt $Left.Count; $i++) {
            if (-not (Test-SettingsValueEqual $Left[$i] $Right[$i])) { return $false }
        }
        return $true
    }
    if ($Left -is [string] -and $Right -is [string]) { return $Left -ceq $Right }
    if ($Left -is [bool] -and $Right -is [bool]) { return $Left -eq $Right }
    if ($Left -is [ValueType] -and $Right -is [ValueType] -and
        $Left -isnot [bool] -and $Right -isnot [bool]) { return $Left -eq $Right }
    return $false
}

function ConvertTo-SettingsJson($Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 100 -WarningAction Stop
    $options = @{ InputObject = $json; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    $decoded = ConvertFrom-Json @options
    if ($Value -is [array]) { $decoded = @($decoded) }
    if (-not (Test-SettingsValueEqual $Value $decoded)) {
        throw 'Cannot serialize the merged VS Code configuration without changing values. No settings files were written.'
    }
    return $json + "`n"
}

function Merge-VSCodeSettings {
    param($Local, $Repository, [System.Collections.Generic.List[string]]$Conflicts, [string]$Setting)

    $merged = [ordered]@{}
    foreach ($property in $Local.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    foreach ($property in $Repository.PSObject.Properties) {
        $identifier = if ($Setting) { "$Setting.$($property.Name)" } else { $property.Name }
        $existing = $Local.PSObject.Properties[$property.Name]
        if ($null -eq $existing) {
            $merged[$property.Name] = $property.Value
        }
        elseif ($existing.Name -ceq $property.Name -and $existing.Value -is [pscustomobject] -and
            $property.Value -is [pscustomobject]) {
            $merged[$property.Name] = Merge-VSCodeSettings $existing.Value $property.Value $Conflicts $identifier
        }
        elseif ($existing.Name -cne $property.Name -or -not (Test-SettingsValueEqual $existing.Value $property.Value)) {
            $id = "settings.json: $identifier"
            if ($script:ConflictResolutions[$id] -eq 'Repo') {
                $merged.Remove($existing.Name)
                $merged[$property.Name] = $property.Value
            }
            elseif ($script:ConflictResolutions[$id] -ne 'Local') {
                $script:ConflictInfo[$id] = @{
                    Local = ConvertTo-Json -InputObject $existing.Value -Depth 20 -Compress
                    Repo  = ConvertTo-Json -InputObject $property.Value -Depth 20 -Compress
                }
                $Conflicts.Add($id)
            }
        }
    }
    return [pscustomobject]$merged
}

function Get-KeybindingKey($Binding) {
    $aliases = @{ control = 'ctrl'; option = 'alt'; meta = 'win'; windows = 'win'; cmd = 'win'; command = 'win' }
    $chords = foreach ($chord in ($Binding.key.Trim().ToLowerInvariant() -split '\s+')) {
        $key = $chord
        $modifiers = @()
        while ($key -match '^(ctrl|control|shift|alt|option|meta|win|windows|cmd|command)\+') {
            $modifier = $Matches[1]
            if ($aliases.ContainsKey($modifier)) { $modifier = $aliases[$modifier] }
            $modifiers += $modifier
            $key = $key.Substring($Matches[0].Length)
        }
        $prefix = @('ctrl', 'shift', 'alt', 'win' | Where-Object { $modifiers -contains $_ })
        (@($prefix) + $key) -join '+'
    }
    return $chords -join ' '
}

function Merge-VSCodeKeybindings {
    param($Local, $Repository, [System.Collections.Generic.List[string]]$Conflicts)

    $merged = @($Local)
    foreach ($binding in $Repository) {
        $key = Get-KeybindingKey $binding
        $group = @($Repository | Where-Object { (Get-KeybindingKey $_) -ceq $key })
        $localGroup = @($Local | Where-Object { (Get-KeybindingKey $_) -ceq $key })
        $conflict = $false
        foreach ($existing in $localGroup) {
            $matches = @($group | Where-Object { Test-SettingsValueEqual $existing $_ })
            if (-not $matches.Count) { $conflict = $true }
        }
        if ($conflict) {
            $id = "keybindings.json: $key"
            if ($script:ConflictResolutions[$id] -eq 'Repo') {
                $kept = @()
                foreach ($entry in $merged) {
                    $inGroup = @($group | Where-Object { Test-SettingsValueEqual $entry $_ }).Count
                    if ((Get-KeybindingKey $entry) -cne $key -or $inGroup) { $kept += $entry }
                }
                $merged = $kept
                if (-not @($merged | Where-Object { Test-SettingsValueEqual $_ $binding }).Count) { $merged += $binding }
            }
            elseif ($script:ConflictResolutions[$id] -ne 'Local') {
                $script:ConflictInfo[$id] = @{
                    Local = (($localGroup | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 20 -Compress }) -join ' ; ')
                    Repo  = (($group | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 20 -Compress }) -join ' ; ')
                }
                $Conflicts.Add($id)
            }
        }
        elseif (-not @($merged | Where-Object { Test-SettingsValueEqual $_ $binding }).Count) {
            $merged += $binding
        }
    }
    return ,$merged
}

function Copy-SettingsFile {
    param([string]$Source, [string]$Destination, [AllowEmptyString()][string]$Content)

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $same = if ($PSBoundParameters.ContainsKey('Content')) {
            [IO.File]::ReadAllText($Destination) -ceq $Content
        } else {
            (Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Destination).Hash
        }
        if ($same) {
            Write-Host "Unchanged: $Destination"
            return
        }
        $backup = '{0}.{1}.{2}.bak' -f $Destination, (Get-Date -Format 'yyyyMMdd-HHmmssfff'), [guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $Destination -Destination $backup -ErrorAction Stop
        Write-Host "Backup: $backup"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force -ErrorAction Stop | Out-Null
    if ($PSBoundParameters.ContainsKey('Content')) {
        [IO.File]::WriteAllText($Destination, $Content, [Text.UTF8Encoding]::new($false))
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
    Write-Host "Applied: $Destination"
}

function Test-SensitiveSettingText([string]$Name, $Value) {
    $text = if ($Value -is [string]) { $Value } else { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
    $homePattern = [regex]::Escape($HOME)
    return ($Name -match '(?i)token|password|secret|api[-_.]?key|credential') -or
        ($text -match '(?i)token|password|secret|api[-_.]?key|credential') -or
        ($text -match '(?<![A-Za-z])[A-Za-z]:[\\/]') -or ($text -match '\\\\') -or
        ($text -match "(?i)$homePattern|/users/|/home/") -or ($text -match '://[^/\s:@]+:[^/\s@]+@')
}

function Format-SettingPreview($Value) {
    $text = if ($Value -is [string]) { $Value } else { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
    if ($text.Length -gt 60) { $text = $text.Substring(0, 57) + '...' }
    return $text
}

function Confirm-PullSection([string]$Name, [string[]]$Lines, [bool]$Yes) {
    if (-not $Lines.Count) { Write-Host "${Name}: no changes"; return $false }
    Write-Host "${Name}:" -ForegroundColor Cyan
    $Lines | ForEach-Object { Write-Host "  $_" }
    if ($Yes) { return $true }
    if ([Console]::IsInputRedirected) { throw 'Interactive confirmation is required; rerun with -Yes to accept.' }
    return ($Host.UI.PromptForChoice($Name, "Update repo $Name?", @('&Apply', '&Skip'), 0) -eq 0)
}

function Test-InsideVSCode {
    $id = $PID
    for ($depth = 0; $depth -lt 12 -and $id; $depth++) {
        $info = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $info) { return $false }
        $id = $info.ParentProcessId
        if ((Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName -eq 'Code') { return $true }
    }
    return $false
}

# Returns $true when VS Code is closed (or the user chose to continue anyway), $false when the user chose to skip.
function Confirm-VSCodeClosed([string]$Reason, [string]$SkipLabel) {
    if ([Console]::IsInputRedirected) {
        if (Get-Process -Name Code -ErrorAction SilentlyContinue) { throw "Close all VS Code windows $Reason. Run this command from an external terminal." }
        return $true
    }
    while (Get-Process -Name Code -ErrorAction SilentlyContinue) {
        $inside = Test-InsideVSCode
        $options = @('&Retry', "&Skip ($SkipLabel)")
        $message = "Close all VS Code windows $Reason."
        if ($inside) {
            $message += ' This terminal is inside VS Code, so it cannot close it; use an external terminal.'
        } else {
            $options = @('&Close VS Code now') + $options
        }
        $choice = $Host.UI.PromptForChoice('VS Code is running', $message, $options, 0)
        if (-not $inside -and $choice -eq 0) {
            Get-Process -Name Code -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | ForEach-Object { $null = $_.CloseMainWindow() }
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Process -Name Code -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
            if (Get-Process -Name Code -ErrorAction SilentlyContinue) {
                Write-Warning 'VS Code did not close in time (it may be asking to save). Stopping remaining processes.'
                Get-Process -Name Code -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
        } elseif ($choice -eq ($options.Count - 1)) {
            return $false
        }
    }
    return $true
}

function Pull-DevSettings {
    [CmdletBinding()]
    param([ValidateSet('Add', 'Mirror')][string]$Mode, [switch]$Yes)

    $ErrorActionPreference = 'Stop'
    # Closing flushes unsaved state to disk; pull only reads, so skipping continues with what is on disk.
    if (-not $Yes) { $null = Confirm-VSCodeClosed 'so the latest changes are saved before pulling' 'pull with VS Code open' }
    $root = (Resolve-Path "$PSScriptRoot\..").Path
    $environment = Get-SettingsEnvironment
    $liveUser = Join-Path $environment.AppData 'Code\User'
    $repoDir = Join-Path $root 'vscode'

    if (-not $Mode) {
        if ([Console]::IsInputRedirected) { throw 'Pass -Mode Add or -Mode Mirror when not running interactively.' }
        $choice = $Host.UI.PromptForChoice('Pull VS Code settings into the repo',
            'Add: add and update, never remove. Mirror: repo becomes an exact copy of VS Code (removed extensions/settings disappear).',
            @('&Add', '&Mirror'), 0)
        $Mode = @('Add', 'Mirror')[$choice]
    }

    $code = Get-Command code -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $code) { throw 'VS Code CLI (code) was not found. Install VS Code Stable and reopen the terminal.' }
    $liveExtensions = @(& $code.Source --user-data-dir (Join-Path $environment.AppData 'Code') --profile Default --list-extensions 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "VS Code extension inventory failed (exit code $LASTEXITCODE)." }

    $outputs = @()

    # settings.json
    $repoSettings = Read-SettingsJson "$repoDir\settings.json" Object
    $liveSettingsPath = Join-Path $liveUser 'settings.json'
    $liveSettings = if (Test-Path -LiteralPath $liveSettingsPath) { Read-SettingsJson $liveSettingsPath Object } else { [pscustomobject]@{} }
    $skipped = @()
    $merged = [ordered]@{}
    $lines = @()
    foreach ($property in $repoSettings.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    foreach ($property in $liveSettings.PSObject.Properties) {
        if (Test-SensitiveSettingText $property.Name $property.Value) { $skipped += $property.Name; continue }
        $existing = $repoSettings.PSObject.Properties[$property.Name]
        if ($null -eq $existing) {
            $merged[$property.Name] = $property.Value
            $lines += "+ $($property.Name) = $(Format-SettingPreview $property.Value)"
        }
        elseif (-not (Test-SettingsValueEqual $existing.Value $property.Value)) {
            $merged[$property.Name] = $property.Value
            $lines += "~ $($property.Name): $(Format-SettingPreview $existing.Value) -> $(Format-SettingPreview $property.Value)"
        }
    }
    if ($Mode -eq 'Mirror') {
        foreach ($property in @($repoSettings.PSObject.Properties)) {
            if (-not $liveSettings.PSObject.Properties[$property.Name]) {
                $merged.Remove($property.Name)
                $lines += "- $($property.Name)"
            }
        }
    }
    if ($skipped.Count) { Write-Host "Skipped settings that look like paths or secrets (values withheld): $($skipped -join ', ')" -ForegroundColor Yellow }
    if (Confirm-PullSection 'settings' $lines $Yes.IsPresent) {
        $outputs += @{ Path = "$repoDir\settings.json"; Content = ConvertTo-SettingsJson ([pscustomobject]$merged) }
    }

    # keybindings.json
    $repoBindings = Read-SettingsJson "$repoDir\keybindings.json" Array
    $liveBindingsPath = Join-Path $liveUser 'keybindings.json'
    $liveBindings = if (Test-Path -LiteralPath $liveBindingsPath) { Read-SettingsJson $liveBindingsPath Array } else { @() }
    Assert-VSCodeKeybindings $liveBindings
    $bindingSkipped = 0
    $bindingResult = @($repoBindings)
    $lines = @()
    foreach ($binding in $liveBindings) {
        if (Test-SensitiveSettingText '' $binding) { $bindingSkipped++; continue }
        if (-not @($repoBindings | Where-Object { Test-SettingsValueEqual $_ $binding }).Count) {
            $bindingResult += $binding
            $lines += "+ $($binding.key) -> $($binding.command)"
        }
    }
    if ($Mode -eq 'Mirror') {
        foreach ($binding in $repoBindings) {
            if (-not @($liveBindings | Where-Object { Test-SettingsValueEqual $_ $binding }).Count) {
                $bindingResult = @($bindingResult | Where-Object { -not (Test-SettingsValueEqual $_ $binding) })
                $lines += "- $($binding.key) -> $($binding.command)"
            }
        }
    }
    if ($bindingSkipped) { Write-Host "Skipped $bindingSkipped keybinding(s) that look like paths or secrets." -ForegroundColor Yellow }
    if (Confirm-PullSection 'keybindings' $lines $Yes.IsPresent) {
        $outputs += @{ Path = "$repoDir\keybindings.json"; Content = ConvertTo-SettingsJson $bindingResult }
    }

    # extensions.json
    $repoExtensions = Read-VSCodeExtensions "$repoDir\extensions.json"
    $liveExtensions = @($liveExtensions | Where-Object { $_ -match '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$' })
    $extensionResult = @($repoExtensions)
    $lines = @()
    foreach ($extension in ($liveExtensions | Sort-Object)) {
        if ($repoExtensions -inotcontains $extension) { $extensionResult += $extension; $lines += "+ $extension" }
    }
    if ($Mode -eq 'Mirror') {
        foreach ($extension in $repoExtensions) {
            if ($liveExtensions -inotcontains $extension) {
                $extensionResult = @($extensionResult | Where-Object { $_ -ine $extension })
                $lines += "- $extension"
            }
        }
    }
    if (Confirm-PullSection 'extensions' $lines $Yes.IsPresent) {
        $outputs += @{ Path = "$repoDir\extensions.json"; Content = ConvertTo-SettingsJson $extensionResult }
    }

    # The repo is under git, so no .bak copies are made here
    foreach ($output in $outputs) {
        [IO.File]::WriteAllText($output.Path, $output.Content, [Text.UTF8Encoding]::new($false))
        Write-Host "Updated: $($output.Path)"
    }
    if (-not $outputs.Count) { Write-Host 'Nothing was changed.'; return }
    Write-Host 'Review the changes with git diff and commit when ready.'
    $refresh = $Yes.IsPresent -or ([Console]::IsInputRedirected -eq $false -and
        $Host.UI.PromptForChoice('default.code-profile', 'Regenerate vscode\default.code-profile now?', @('&Yes', '&No'), 0) -eq 0)
    if ($refresh) { & "$root\scripts\export-vscode-profile.ps1" }
}

function Sync-DevSettings {
    [CmdletBinding()]
    param(
        [switch]$SkipTerminal,
        [switch]$SkipVSCode,
        [ValidateSet('Local', 'Repo')][string]$OnConflict
    )

    $ErrorActionPreference = 'Stop'
    $root = (Resolve-Path "$PSScriptRoot\..").Path
    $environment = Get-SettingsEnvironment
    $files = @()
    $unchanged = @()
    $extensions = @()
    $installed = @()

    # VS Code overwrites its settings on exit, so offer to close it, or skip just this part
    if (-not $SkipVSCode -and -not (Confirm-VSCodeClosed 'to sync its settings' 'Skip VS Code settings')) {
        Write-Warning 'Skipped VS Code settings.'; $SkipVSCode = [switch]$true
    }

    if (-not $SkipTerminal) {
        Read-SettingsJson -Path "$root\terminal\settings.json" -RootType Object | Out-Null
        foreach ($directory in 'PowerShell', 'WindowsPowerShell') {
            $files += @{
                Source = "$root\terminal\Microsoft.PowerShell_profile.ps1"
                Destination = Join-Path $environment.Documents "$directory\Microsoft.PowerShell_profile.ps1"
            }
        }
        $images = @(Get-ChildItem -LiteralPath "$root\terminal" -Filter '*.png' -File)
        if (-not $images.Count) { throw 'Terminal image assets are missing from the repository.' }
        foreach ($image in $images) {
            $files += @{
                Source = $image.FullName
                Destination = Join-Path $environment.Home ".config\terminal\$($image.Name)"
            }
        }
        $terminalDirs = @()
        $packages = Join-Path $environment.LocalAppData 'Packages'
        if (Test-Path -LiteralPath $packages -PathType Container) {
            foreach ($package in Get-ChildItem -LiteralPath $packages -Filter 'Microsoft.WindowsTerminal*' -Directory) {
                $localState = Join-Path $package.FullName 'LocalState'
                if (Test-Path -LiteralPath $localState -PathType Container) { $terminalDirs += $localState }
            }
        }
        $unpackaged = Join-Path $environment.LocalAppData 'Microsoft\Windows Terminal'
        if (Test-Path -LiteralPath $unpackaged -PathType Container) { $terminalDirs += $unpackaged }
        if (-not $terminalDirs.Count) {
            Write-Warning 'Windows Terminal settings folder not found; open Windows Terminal once and rerun. PowerShell profiles will still be applied.'
        }
        foreach ($directory in $terminalDirs) {
            $files += @{
                Source = "$root\terminal\settings.json"
                Destination = Join-Path $directory 'settings.json'
            }
        }
    }

    if (-not $SkipVSCode) {
        $repoSettings = Read-SettingsJson -Path "$root\vscode\settings.json" -RootType Object
        $repoBindings = Read-SettingsJson -Path "$root\vscode\keybindings.json" -RootType Array
        Assert-VSCodeKeybindings $repoBindings
        $extensions = Read-VSCodeExtensions "$root\vscode\extensions.json"
        $codeUser = Join-Path $environment.AppData 'Code\User'
        $script:ConflictResolutions = @{}
        $stickyChoice = if ($OnConflict) { $OnConflict } else { $null }
        while ($true) {
            $script:ConflictInfo = @{}
            $conflicts = [System.Collections.Generic.List[string]]::new()
            $vsFiles = @(); $vsUnchanged = @()
            foreach ($name in 'settings.json', 'keybindings.json') {
                $destination = Join-Path $codeUser $name
                $exists = Test-Path -LiteralPath $destination -PathType Leaf
                if ($name -eq 'settings.json') {
                    $local = if ($exists) { Read-SettingsJson $destination Object } else { [pscustomobject]@{} }
                    $merged = Merge-VSCodeSettings $local $repoSettings $conflicts
                } else {
                    $local = @()
                    if ($exists) { $local = Read-SettingsJson $destination Array }
                    Assert-VSCodeKeybindings $local
                    $merged = Merge-VSCodeKeybindings $local $repoBindings $conflicts
                }
                if ($exists -and (Test-SettingsValueEqual $local $merged)) {
                    $vsUnchanged += $destination
                } else {
                    $vsFiles += @{
                        Destination = $destination
                        Content = ConvertTo-SettingsJson $merged
                    }
                }
            }
            if (-not $conflicts.Count) { break }
            $pending = @($conflicts | Sort-Object -Unique)
            if (-not $stickyChoice -and [Console]::IsInputRedirected) {
                throw ("VS Code configuration conflicts: {0}. No settings files or extensions were changed. Rerun with -OnConflict Local or -OnConflict Repo, or resolve these entries manually." -f ($pending -join '; '))
            }
            foreach ($id in $pending) {
                if ($stickyChoice) { $script:ConflictResolutions[$id] = $stickyChoice; continue }
                Write-Host "Conflict in $id" -ForegroundColor Yellow
                Write-Host "  this PC: $($script:ConflictInfo[$id].Local)"
                Write-Host "  repo:    $($script:ConflictInfo[$id].Repo)"
                $choice = $Host.UI.PromptForChoice('Resolve conflict', 'Which value should be used?',
                    @('Keep &local', 'Use &repo', 'Keep local for &all', 'Use repo for a&ll', '&Cancel'), 0)
                switch ($choice) {
                    0 { $script:ConflictResolutions[$id] = 'Local' }
                    1 { $script:ConflictResolutions[$id] = 'Repo' }
                    2 { $stickyChoice = 'Local'; $script:ConflictResolutions[$id] = 'Local' }
                    3 { $stickyChoice = 'Repo'; $script:ConflictResolutions[$id] = 'Repo' }
                    4 { throw 'Cancelled. No settings files or extensions were changed.' }
                }
            }
        }
        $files += $vsFiles
        $unchanged += $vsUnchanged
        if (Get-Process -Name Code -ErrorAction SilentlyContinue) {
            throw 'Close all VS Code windows before syncing its settings. Run this command from an external terminal.'
        }
        $code = Get-Command code -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $code) { throw 'VS Code CLI (code) was not found. Install VS Code Stable and reopen the terminal, or skip VS Code.' }
        $installRoot = Split-Path -Parent (Split-Path -Parent $code.Source)
        if ($env:VSCODE_PORTABLE -or (Test-Path -LiteralPath (Join-Path $installRoot 'data') -PathType Container)) {
            throw 'Portable VS Code is not supported by this sync. Use a standard VS Code Stable installation.'
        }
    }

    foreach ($file in $files) {
        if ($file.ContainsKey('Source') -and -not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
            throw "Required settings source is missing: $($file.Source)"
        }
    }

    if (-not $SkipVSCode) {
        # Match extension installation to the Default profile whose settings we merge.
        $codeArgs = @('--user-data-dir', (Join-Path $environment.AppData 'Code'), '--profile', 'Default')
        $installed = @(& $code.Source @codeArgs --list-extensions)
        if ($LASTEXITCODE -ne 0) { throw "VS Code extension inventory failed (exit code $LASTEXITCODE). No settings files were replaced." }
        $missing = @($extensions | Where-Object { $installed -notcontains $_ })
        # Corporate TLS inspection makes the CLI reject the Marketplace certificate; trust the Windows store instead
        $oldNodeOptions = $env:NODE_OPTIONS
        $env:NODE_OPTIONS = "$oldNodeOptions --use-system-ca".Trim()
        $failedExtensions = @()
        try {
            foreach ($extension in $missing) {
                & $code.Source @codeArgs --install-extension $extension | Out-Host
                if ($LASTEXITCODE -ne 0) { $failedExtensions += $extension }
            }
        }
        finally { $env:NODE_OPTIONS = $oldNodeOptions }
        if ($failedExtensions.Count) {
            Write-Warning "Could not install VS Code extensions: $($failedExtensions -join ', '). Settings are still applied; rerun 'dev setup vscode' to retry (check network/proxy access to the Marketplace)."
        }
    }
    foreach ($file in $files) {
        Copy-SettingsFile @file
    }
    foreach ($path in $unchanged) { Write-Host "Unchanged: $path" }
    if (-not $SkipTerminal) { Write-Host 'Restart the shell to load the updated PowerShell profile.' }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Pull) {
        $pullArgs = @{ Yes = $Yes }
        if ($Mode) { $pullArgs.Mode = $Mode }
        Pull-DevSettings @pullArgs
    }
    else {
        $syncArgs = @{ SkipTerminal = $SkipTerminal; SkipVSCode = $SkipVSCode }
        if ($OnConflict) { $syncArgs.OnConflict = $OnConflict }
        Sync-DevSettings @syncArgs
    }
}
