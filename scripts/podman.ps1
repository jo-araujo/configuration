. "$PSScriptRoot\common.ps1"
Update-SessionPath

if ($env:DEV_WSL_REBOOT_PENDING) {
    Write-Warning 'Skipping Podman machine: reboot first, then run dev setup podman'
    return
}

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    Write-Host 'podman not installed on this machine; skipping.'
    return
}

# The CLI alone has no Linux VM to talk to; create and start the default machine (WSL2-based)
$machines = podman machine list --format '{{.Name}}|{{.Running}}' 2>$null | Where-Object { $_ }
if (-not $machines) {
    if (-not (Invoke-SetupInstall -Name 'podman machine init' -Native -Action { podman machine init })) { return }
    $machines = podman machine list --format '{{.Name}}|{{.Running}}' 2>$null | Where-Object { $_ }
}

if ($machines -notmatch '\|true') {
    Invoke-SetupInstall -Name 'podman machine start' -Native -Action { podman machine start } | Out-Null
}
else { Write-Host 'podman machine already running' }
