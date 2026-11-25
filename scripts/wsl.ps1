. "$PSScriptRoot\common.ps1"
Update-SessionPath

if (-not (Test-Admin)) { Write-Warning 'WSL install requires an elevated shell; rerun as administrator if it fails.' }

$env:DEV_WSL_REBOOT_PENDING = $null

# The profile and the wrapper address the distro as exactly "Ubuntu"
$installed = @((wsl --list --quiet 2>$null) -replace "`0", '' | ForEach-Object { ($_ -replace '\(Default\)', '').Trim() }) -contains 'Ubuntu'
$freshInstall = $false
if ($installed) {
    Write-Host 'Ubuntu already installed'
    $ubuntuReady = $true
}
else {
    $ubuntuReady = Invoke-SetupInstall -Name 'Ubuntu (WSL)' -Native -Action {
        wsl --install -d Ubuntu --no-launch
    }
    $freshInstall = $ubuntuReady
}

if (-not $ubuntuReady) {
    Write-Warning 'Skipping WSL dev wrapper because Ubuntu was not installed.'
    return
}

# Right after enabling the WSL features, WSL 2 cannot start until Windows restarts
if ($freshInstall) {
    wsl -d Ubuntu -e true 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $env:DEV_WSL_REBOOT_PENDING = '1'
        Write-Warning 'WSL needs a reboot before Ubuntu and Podman can run.'
        if (-not [Console]::IsInputRedirected) {
            $answer = Read-Host 'Reboot now to finish WSL setup? [y/N]'
            if ($answer -match '^[Yy]') {
                Write-Host 'Restarting. After sign-in, run: dev setup wsl, then dev setup podman'
                Restart-Computer -Force
                return
            }
        }
        Write-Warning 'Skipped the dev wrapper and Podman. After rebooting, run: dev setup wsl, then dev setup podman'
        return
    }
}

# `dev` inside Ubuntu: calls the Windows script through pwsh.exe
$devPs1 = (Resolve-Path "$PSScriptRoot\..\bin\dev.ps1").Path
$wrapper = @"
#!/bin/sh
case "`$PWD" in /mnt/*) ;; *) echo "dev: run from a Windows drive path (/mnt/...)" >&2; exit 1;; esac
exec pwsh.exe -NoProfile -File "$devPs1" "`$@"
"@ -replace "`r`n", "`n"
$wrapperFile = Join-Path $env:TEMP 'dev-wrapper.sh'
[IO.File]::WriteAllText($wrapperFile, $wrapper)
$wslPath = (wsl -d Ubuntu wslpath -u ($wrapperFile -replace '\\', '/')) 2>$null
if ($wslPath) {
    Invoke-SetupInstall -Name 'WSL dev wrapper' -Native -Action {
        wsl -d Ubuntu -u root sh -c "install -m 755 '$wslPath' /usr/local/bin/dev"
    } | Out-Null
}
else { Write-Warning 'Ubuntu not ready yet. Run dev setup wsl afterwards.' }
