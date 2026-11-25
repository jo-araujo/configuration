#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-HibernateRegistryValue([string]$Path, [string]$Name) {
    if (Test-Path -LiteralPath $Path -ErrorAction Stop) {
        $property = (Get-ItemProperty -LiteralPath $Path -ErrorAction Stop).PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
}

function Invoke-HibernatePowerCfg([string[]]$Arguments) {
    $PSNativeCommandUseErrorActionPreference = $false
    try { $output = @(& $powercfg.Source @Arguments 2>&1) }
    catch { throw "powercfg $($Arguments -join ' ') failed: $($_.Exception.Message)" }
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed (exit $LASTEXITCODE): $($output -join ' ')"
    }
    return $output
}

function Get-HibernateActiveScheme {
    $output = Invoke-HibernatePowerCfg -Arguments @('/getactivescheme')
    $match = [regex]::Match(($output -join ' '), '\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b')
    if (-not $match.Success) { throw 'Could not identify the active power plan.' }
    return [guid]$match.Value
}

$attemptedChanges = $false
try {
    . "$PSScriptRoot\common.ps1"
    if (-not (Test-Admin)) {
        Write-Warning 'Skipping hibernation setup: administrator rights are required. If permitted, rerun scripts\hibernate.ps1 from an elevated shell.'
        return
    }

    $actions = @(
        @{ Alias = 'LIDACTION'; Guid = '5ca83367-6e45-459f-a27b-476b1d01c936' }
        @{ Alias = 'PBUTTONACTION'; Guid = '7648efa3-dd9c-4e3e-b566-50f929386280' }
    )
    $policyPower = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Power'
    $policies = @(
        @{ Path = $policyPower; Name = 'AllowHibernate'; Value = 1; Mdm = $true }
        @{ Path = $policyPower; Name = 'SelectLidCloseActionOnBattery'; Value = 2; Mdm = $true }
        @{ Path = $policyPower; Name = 'SelectLidCloseActionPluggedIn'; Value = 2; Mdm = $true }
        @{ Path = $policyPower; Name = 'SelectPowerButtonActionOnBattery'; Value = 2; Mdm = $true }
        @{ Path = $policyPower; Name = 'SelectPowerButtonActionPluggedIn'; Value = 2; Mdm = $true }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'ShowHibernateOption'; Value = 1 }
    )
    foreach ($action in $actions) {
        foreach ($name in 'ACSettingIndex', 'DCSettingIndex') {
            $policies += @{
                Path = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\$($action.Guid)"
                Name = $name
                Value = 2
            }
        }
    }
    foreach ($policy in $policies) {
        $value = Get-HibernateRegistryValue $policy.Path $policy.Name
        if ($policy.Mdm) {
            $providerSet = Get-HibernateRegistryValue $policy.Path "$($policy.Name)_ProviderSet"
            if ($null -ne $providerSet -and [int]$providerSet -eq 0) { continue }
        }
        if ($null -ne $value -and [int]$value -ne $policy.Value) {
            throw "An enforced $($policy.Name) policy conflicts with hibernation defaults; contact your administrator."
        }
    }

    $powercfg = Get-Command powercfg.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $scheme = Get-HibernateActiveScheme
    if (-not ('DevSetup.Hibernation' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DevSetup {
    public static class Hibernation {
        [StructLayout(LayoutKind.Sequential)]
        private struct BatteryScale {
            public uint Granularity, Capacity;
        }

        // Native BOOLEAN fields occupy one byte in SYSTEM_POWER_CAPABILITIES.
        [StructLayout(LayoutKind.Sequential)]
        private struct Capabilities {
            public byte PowerButtonPresent, SleepButtonPresent, LidPresent;
            public byte SystemS1, SystemS2, SystemS3, SystemS4, SystemS5, HiberFilePresent;
            public byte FullWake, VideoDimPresent, ApmPresent, UpsPresent, ThermalControl;
            public byte ProcessorThrottle, ProcessorMinThrottle, ProcessorMaxThrottle;
            public byte FastSystemS4, Hiberboot, WakeAlarmPresent, AoAc, DiskSpinDown;
            public byte HiberFileType, AoAcConnectivitySupported;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
            public byte[] Spare;
            public byte SystemBatteriesPresent, BatteriesAreShortTerm;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)]
            public BatteryScale[] BatteryScales;
            public uint AcOnLineWake, SoftLidWake, RtcWake, MinDeviceWakeState, DefaultLowLatencyWake;
        }

        [DllImport("powrprof.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        private static extern bool GetPwrCapabilities(out Capabilities capabilities);

        [DllImport("powrprof.dll")]
        private static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);

        [DllImport("powrprof.dll")]
        private static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);

        public static bool IsAvailable() {
            Capabilities capabilities;
            if (!GetPwrCapabilities(out capabilities))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return capabilities.SystemS4 != 0 && capabilities.HiberFilePresent != 0
                && capabilities.HiberFileType == 2; // HIBERFILE_TYPE_FULL.
        }

        public static uint ReadAction(Guid scheme, Guid setting, bool ac) {
            Guid subgroup = new Guid("4f971e89-eebd-4455-a8de-9e59040e7347");
            uint value;
            uint error = ac
                ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value)
                : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value);
            if (error != 0) throw new Win32Exception((int)error);
            return value;
        }
    }
}
'@
    }

    $attemptedChanges = $true
    Invoke-HibernatePowerCfg -Arguments @('/hibernate', 'on') | Out-Null
    Invoke-HibernatePowerCfg -Arguments @('/hibernate', '/type', 'full') | Out-Null
    if (-not [DevSetup.Hibernation]::IsAvailable()) {
        throw 'Full hibernation is unavailable after enabling it. Check hardware/firmware support and device policies.'
    }
    foreach ($action in $actions) {
        Invoke-HibernatePowerCfg -Arguments @('/setacvalueindex', "$scheme", 'SUB_BUTTONS', $action.Alias, '2') | Out-Null
        Invoke-HibernatePowerCfg -Arguments @('/setdcvalueindex', "$scheme", 'SUB_BUTTONS', $action.Alias, '2') | Out-Null
    }
    if ((Get-HibernateActiveScheme) -ne $scheme) { throw 'The active power plan changed during setup; rerun when it is stable.' }
    Invoke-HibernatePowerCfg -Arguments @('/setactive', "$scheme") | Out-Null
    foreach ($action in $actions) {
        foreach ($ac in $true, $false) {
            if ([DevSetup.Hibernation]::ReadAction($scheme, [guid]$action.Guid, $ac) -ne 2) {
                $source = if ($ac) { 'AC' } else { 'battery' }
                throw "Could not verify Hibernate for $($action.Alias) ($source)."
            }
        }
    }
    if ((Get-HibernateActiveScheme) -ne $scheme) { throw 'Could not verify that the configured power plan is still active.' }

    $menu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
    if (-not (Test-Path -LiteralPath $menu -ErrorAction Stop)) {
        New-Item -Path $menu -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -LiteralPath $menu -Name ShowHibernateOption -Value 1 -Type DWord -Force -ErrorAction Stop
    if ((Get-HibernateRegistryValue $menu 'ShowHibernateOption') -ne 1 -or -not [DevSetup.Hibernation]::IsAvailable()) {
        throw 'Could not verify Hibernate availability and its power-menu preference.'
    }
    Write-Host 'Hibernation configured: power-menu entry and lid/power-button Hibernate actions on AC and battery for the active plan.'
}
catch {
    $state = if ($attemptedChanges) { 'Some hibernation settings may already have changed.' } else { 'No hibernation settings were changed.' }
    Write-Warning "Hibernation setup skipped or incomplete: $($_.Exception.Message) $state Continuing setup."
}
