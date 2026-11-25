. "$PSScriptRoot\common.ps1"

$source = Join-Path (Split-Path $PSScriptRoot) 'copilot\settings.json'
$targetDir = Join-Path $env:USERPROFILE '.copilot'
$target = Join-Path $targetDir 'settings.json'

New-Item -ItemType Directory -Force $targetDir | Out-Null
$current = if (Test-Path $target) { Get-Content $target -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
foreach ($property in (Get-Content $source -Raw | ConvertFrom-Json).PSObject.Properties) { $current[$property.Name] = $property.Value }
$current | ConvertTo-Json -Depth 10 | Set-Content $target -Encoding utf8
Write-Host "Copilot settings merged: $target"
