. "$PSScriptRoot\common.ps1"
Update-SessionPath

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning 'git not found. Open a new terminal and run: dev setup git'
    return
}

function Read-GitValue([string]$Key, [string]$Prompt) {
    $current = git config --global $Key
    if ($current) { Write-Host "$Key already set: $current"; return }
    $value = Read-Host $Prompt
    if ($value) { git config --global $Key $value }
}

Read-GitValue 'user.name'  'Git user name'
Read-GitValue 'user.email' 'Git work email'

git config --global core.editor 'code --wait'
git config --global init.defaultBranch main
git config --global core.autocrlf true
git config --global push.autoSetupRemote true
