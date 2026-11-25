$ErrorActionPreference = 'Stop'

# User preferences are per-user; the hibernation helper below requires elevation.
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$settings = @(
    @{ Path = 'HKCU:\Software\Microsoft\Clipboard';                        Name = 'EnableClipboardHistory';   Value = 1 }
    @{ Path = $advanced;                                                    Name = 'Hidden';                   Value = 1 }
    @{ Path = $advanced;                                                    Name = 'HideFileExt';              Value = 0 }
    @{ Path = $advanced;                                                    Name = 'LaunchTo';                 Value = 1 }
    @{ Path = $advanced;                                                    Name = 'MultiTaskingAltTabFilter'; Value = 3 }
    # Start menu: hide the Recommended section content
    @{ Path = $advanced;                                                    Name = 'Start_TrackDocs';          Value = 0 }
    @{ Path = $advanced;                                                    Name = 'Start_IrisRecommendations'; Value = 0 }
    @{ Path = $advanced;                                                    Name = 'Start_AccountNotifications'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';     Name = 'SearchBoxTaskbarMode';     Value = 0 }
    @{ Path = $personalize;                                                 Name = 'AppsUseLightTheme';        Value = 0 }
    @{ Path = $personalize;                                                 Name = 'SystemUsesLightTheme';     Value = 0 }
)

foreach ($s in $settings) {
    try {
        if (-not (Test-Path $s.Path)) { New-Item -Path $s.Path -Force | Out-Null }
        Set-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -Type DWord -Force
    }
    catch { Write-Warning "Could not set $($s.Name): $($_.Exception.Message)" }
}

# Explorer restarts itself after being stopped
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

# Applies to the active power plan; may be overridden by policy
powercfg -x -monitor-timeout-ac 30
powercfg -x -monitor-timeout-dc 10

& "$PSScriptRoot\hibernate.ps1"
