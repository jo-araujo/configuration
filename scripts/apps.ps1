param([ValidateSet('Personal', 'Professional')][string]$InstallType = 'Professional')

. "$PSScriptRoot\common.ps1"

winget source update
Update-SessionPath
Save-InstallType $InstallType

foreach ($id in Get-SetupAppIds $InstallType) { Install-WingetApp $id | Out-Null }

# Node LTS via nvm-windows
Update-SessionPath
if (Get-Command nvm -ErrorAction SilentlyContinue) {
    if (-not (nvm list | Select-String -SimpleMatch 'Currently using')) {
        if (Invoke-SetupInstall -Name 'Node.js LTS install' -Native -Action { nvm install lts }) {
            if (Invoke-SetupInstall -Name 'Node.js LTS activation' -Native -Action { nvm use lts }) {
                Update-SessionPath
            }
        }
    }
}
else { Write-Warning 'nvm not found. Open a new terminal and run: nvm install lts; nvm use lts' }

# The Store python.exe stubs (per-user App Execution Aliases) shadow the real install and cannot be outranked on PATH
if (Get-Command python -ErrorAction SilentlyContinue | Where-Object Source -like '*\WindowsApps\*') {
    $apps = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    Remove-Item "$apps\python.exe", "$apps\python3.exe" -ErrorAction SilentlyContinue
}
