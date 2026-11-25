#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\settings.ps1"
$source = Join-Path $PSScriptRoot '..\vscode'
$settings = Read-SettingsJson "$source\settings.json" Object
$bindings = Read-SettingsJson "$source\keybindings.json" Array
Assert-VSCodeKeybindings $bindings
$extensions = Read-VSCodeExtensions "$source\extensions.json"
$profileExtensions = @($extensions | ForEach-Object { @{ identifier = @{ id = $_ } } })
$profile = [ordered]@{
    name = 'React'
    settings = ConvertTo-Json -InputObject @{
        settings = [IO.File]::ReadAllText("$source\settings.json")
    } -Compress -Depth 100
    keybindings = ConvertTo-Json -InputObject ([ordered]@{
        keybindings = [IO.File]::ReadAllText("$source\keybindings.json")
        platform = 3 # VS Code's Platform.Windows.
    }) -Compress -Depth 100
    extensions = ConvertTo-Json -InputObject $profileExtensions -Compress -Depth 100
}
$outputs = [ordered]@{
    'default.code-profile' = (ConvertTo-Json -InputObject $profile -Depth 100) + "`n"
}
foreach ($output in $outputs.GetEnumerator()) {
    $destination = Join-Path $source $output.Key
    if (-not (Test-Path -LiteralPath $destination) -or [IO.File]::ReadAllText($destination) -cne $output.Value) {
        [IO.File]::WriteAllText($destination, $output.Value, [Text.UTF8Encoding]::new($false))
    }
    Write-Host "Generated profile: $destination"
}
