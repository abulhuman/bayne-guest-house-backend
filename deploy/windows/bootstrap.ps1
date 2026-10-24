#Requires -Version 5.1
<#
.SYNOPSIS
Converges this Windows machine into the Almis deployment host. Safe to rerun.

.DESCRIPTION
Runs an ordered table of steps. Each step tests its state and converges only when the test fails.
Exits 3010 when Windows must restart before the remaining steps can run. Rerun it after the restart.

.PARAMETER Check
Runs only the tests. Exits 1 if any step is not converged.

.PARAMETER AutostartLogon
Logon type of the Almis WSL scheduled task. S4U starts WSL at boot with no stored password.
Interactive starts it when this user logs on, which needs Windows autologon to survive a reboot.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [ValidateSet('S4U', 'Interactive')]
    [string]$AutostartLogon = 'S4U'
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

$Distro = 'Ubuntu-24.04'
$TaskName = 'Almis WSL'
$WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
$TaskArguments = "-d $Distro -- sleep infinity"
$SshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
$WslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$WslSettings = @(
    @{ Section = 'wsl2'; Key = 'vmIdleTimeout'; Value = '-1' },
    @{ Section = 'general'; Key = 'instanceIdleTimeout'; Value = '-1' }
)
$WindowsFeatures = 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform'
# USERDOMAIN is WORKGROUP in an OpenSSH session, so take the account from the process token.
$Account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Autostart = @{
    S4U         = @{ Trigger = { New-ScheduledTaskTrigger -AtStartup }; TriggerClass = 'MSFT_TaskBootTrigger' }
    Interactive = @{ Trigger = { New-ScheduledTaskTrigger -AtLogOn -User $Account }; TriggerClass = 'MSFT_TaskLogonTrigger' }
}[$AutostartLogon]
# bash -s fails on CR bytes, which appear if the file went through a Windows Git checkout.
$ProvisionScript = [byte[]]@([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'wsl-provision.sh')) | Where-Object { $_ -ne 13 })

# Starts a process with a raw argument string. Windows PowerShell 5.1 mangles quoted native
# arguments, turns redirected native stderr into terminating errors, and adds CRLF to piped stdin.
function Invoke-Native {
    param([string]$File, [string]$Arguments, [byte[]]$Stdin, [switch]$Stream)
    $info = New-Object Diagnostics.ProcessStartInfo $File, $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $null -ne $Stdin
    $info.RedirectStandardOutput = -not $Stream
    $info.RedirectStandardError = -not $Stream
    $process = [Diagnostics.Process]::Start($info)
    if ($null -ne $Stdin) {
        $process.StandardInput.BaseStream.Write($Stdin, 0, $Stdin.Length)
        $process.StandardInput.Close()
    }
    $output = ''
    if (-not $Stream) {
        $errors = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd() + $errors.Result
    }
    $process.WaitForExit()
    # The inbox wsl.exe ignores WSL_UTF8 and writes UTF-16.
    [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output -replace "`0", '' }
}

function Get-PowerIndexes([string]$Subgroup, [string]$Setting) {
    $query = Invoke-Native powercfg.exe "/query SCHEME_CURRENT $Subgroup $Setting"
    # Labels are localized. The current AC and DC indexes are always the last two hex values.
    $values = @([regex]::Matches($query.Output, '0x[0-9a-fA-F]+') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) })
    if ($query.ExitCode -ne 0 -or $values.Count -lt 2) { throw "powercfg cannot read $Subgroup $Setting" }
    $values[-2], $values[-1]
}

function Test-LidSetting {
    # The LIDACTION GUID, since powercfg labels are localized.
    (Invoke-Native powercfg.exe '/query SCHEME_CURRENT SUB_BUTTONS LIDACTION').Output -match '5ca83367-6e45-459f-a27b-476b1d01c936'
}

function Set-PowerIndexes([string]$Subgroup, [string]$Setting) {
    $null = Invoke-Native powercfg.exe "/setacvalueindex SCHEME_CURRENT $Subgroup $Setting 0"
    $null = Invoke-Native powercfg.exe "/setdcvalueindex SCHEME_CURRENT $Subgroup $Setting 0"
    $null = Invoke-Native powercfg.exe '/setactive SCHEME_CURRENT'
}

function Get-ConnectedWlanProfiles {
    $interfaces = Invoke-Native netsh.exe 'wlan show interfaces'
    if ($interfaces.ExitCode -ne 0) { return }
    $lines = $interfaces.Output -split "`r?`n"
    $profiles = @($lines | Where-Object { $_ -match '^\s*Profile\s*:\s*\S' } | ForEach-Object { ($_ -split ':', 2)[1].Trim() })
    if (-not $profiles) {
        $profiles = @($lines | Where-Object { $_ -match '^\s*SSID\s*:\s*\S' } | ForEach-Object { ($_ -split ':', 2)[1].Trim() })
    }
    $profiles
}

function Test-WlanAutoConnect([string]$Name) {
    $wlanProfile = Invoke-Native netsh.exe "wlan show profile name=`"$Name`""
    $wlanProfile.ExitCode -eq 0 -and $wlanProfile.Output -match '(?m)^\s*Connection mode\s*:\s*Connect automatically'
}

function Test-KeyOnlySshd {
    if (-not (Test-Path $SshdConfig)) { return $false }
    # sshd takes the first value it sees, and settings after a Match line only apply to that match.
    $values = @(foreach ($line in Get-Content $SshdConfig) {
            if ($line -match '^\s*Match\s') { 'match' }
            elseif ($line -match '^\s*PasswordAuthentication\s+(\S+)') { $Matches[1] }
        })
    $values.Count -gt 0 -and $values[0] -eq 'no' -and $values -notcontains 'yes'
}

function Set-KeyOnlySshd {
    $lines = New-Object Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in Get-Content $SshdConfig) {
        if ($line -match '^\s*PasswordAuthentication\s') { continue }
        if (-not $inserted -and $line -match '^\s*Match\s') {
            $lines.Add('PasswordAuthentication no')
            $inserted = $true
        }
        $lines.Add($line)
    }
    if (-not $inserted) { $lines.Add('PasswordAuthentication no') }
    $staged = "$SshdConfig.almis"
    [IO.File]::WriteAllLines($staged, $lines, [Text.Encoding]::ASCII)
    # A broken config would stop sshd and lock out the remote operator, so validate first.
    $test = Invoke-Native (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe') "-t -f `"$staged`""
    if ($test.ExitCode -ne 0) { throw "sshd rejected the new config: $($test.Output)" }
    # Replace keeps the original file's ACL, which sshd requires.
    [IO.File]::Replace($staged, $SshdConfig, $null)
    Restart-Service sshd
}

function Test-TailscaleSshRule {
    $rule = Get-NetFirewallRule -Name sshd-tailscale -ErrorAction SilentlyContinue
    if (-not $rule) { return $false }
    $port = $rule | Get-NetFirewallPortFilter
    $address = (@(($rule | Get-NetFirewallAddressFilter).RemoteAddress) -join ',')
    "$($rule.Enabled)" -eq 'True' -and "$($rule.Direction)" -eq 'Inbound' -and "$($rule.Action)" -eq 'Allow' -and
    $port.Protocol -eq 'TCP' -and "$($port.LocalPort)" -eq '22' -and
    ($address -in '100.64.0.0/10', '100.64.0.0/255.192.0.0')
}

function Get-IniValue([string[]]$Lines, [string]$Section, [string]$Key) {
    $current = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $current = $Matches[1] }
        elseif ($current -eq $Section -and $line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*?)\s*$") { return $Matches[1] }
    }
}

function Set-IniValue([Collections.Generic.List[string]]$Lines, [string]$Section, [string]$Key, [string]$Value) {
    $sectionAt = -1
    $end = $Lines.Count
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[(.+?)\]\s*$') {
            if ($sectionAt -ge 0) { $end = $i; break }
            if ($Matches[1] -eq $Section) { $sectionAt = $i }
        }
        elseif ($sectionAt -ge 0 -and $Lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $Lines[$i] = "$Key=$Value"
            return
        }
    }
    if ($sectionAt -lt 0) {
        $Lines.Add("[$Section]")
        $Lines.Add("$Key=$Value")
    }
    else { $Lines.Insert($end, "$Key=$Value") }
}

function Get-WslConfigLines {
    if (Test-Path $WslConfig) { @(Get-Content $WslConfig) } else { @() }
}

function Get-DistroVersion {
    $list = Invoke-Native wsl.exe '--list --verbose'
    if ($list.ExitCode -ne 0) { return $null }
    foreach ($line in $list.Output -split "`r?`n") {
        $fields = -split ($line -replace '^\s*\*', '')
        if ($fields.Count -ge 3 -and $fields[0] -eq $Distro) { return $fields[-1] }
    }
}

function Get-DistroInit {
    (Invoke-Native wsl.exe "-d $Distro -u root -- cat /proc/1/comm").Output.Trim()
}

function Test-AutostartTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $false }
    $triggers = @($task.Triggers)
    $actions = @($task.Actions)
    $settings = $task.Settings
    "$($task.State)" -ne 'Disabled' -and
    $triggers.Count -eq 1 -and $triggers[0].CimClass.CimClassName -eq $Autostart.TriggerClass -and $triggers[0].Enabled -and
    $actions.Count -eq 1 -and (Split-Path $actions[0].Execute -Leaf) -eq 'wsl.exe' -and $actions[0].Arguments -eq $TaskArguments -and
    ($task.Principal.UserId -split '\\')[-1] -eq $env:USERNAME -and "$($task.Principal.LogonType)" -eq $AutostartLogon -and
    $settings.ExecutionTimeLimit -eq 'PT0S' -and $settings.RestartCount -gt 0 -and
    -not $settings.DisallowStartIfOnBatteries -and -not $settings.StopIfGoingOnBatteries
}

function Register-AutostartTask {
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $Account -LogonType $AutostartLogon
    $action = New-ScheduledTaskAction -Execute $WslExe -Argument $TaskArguments
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (& $Autostart.Trigger) `
        -Principal $principal -Settings $settings -Force
}

$Steps = @(
    @{
        Name   = 'Running elevated'
        Test   = { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        Set    = { throw 'Run this script from an elevated PowerShell.' }
        Reboot = $false
    },
    @{
        Name   = 'Firmware virtualization on'
        # A running hypervisor makes Win32_Processor report virtualization as off.
        Test   = { [bool]((Get-CimInstance Win32_ComputerSystem).HypervisorPresent -or @(Get-CimInstance Win32_Processor)[0].VirtualizationFirmwareEnabled) }
        Set    = { throw 'Enable Intel VT-x or AMD-V (SVM) in the BIOS or UEFI setup, then rerun.' }
        Reboot = $false
    },
    @{
        Name   = 'Never sleep on AC or battery'
        Test   = { @(Get-PowerIndexes SUB_SLEEP STANDBYIDLE | Where-Object { $_ -ne 0 }).Count -eq 0 }
        Set    = { Set-PowerIndexes SUB_SLEEP STANDBYIDLE }
        Reboot = $false
    },
    @{
        Name   = 'Closing the lid does nothing'
        # Machines without a lid have no LIDACTION setting, and powercfg prints only the scheme header.
        Test   = { -not (Test-LidSetting) -or @(Get-PowerIndexes SUB_BUTTONS LIDACTION | Where-Object { $_ -ne 0 }).Count -eq 0 }
        Set    = { Set-PowerIndexes SUB_BUTTONS LIDACTION }
        Reboot = $false
    },
    @{
        Name   = 'Connected Wi-Fi profile connects automatically'
        Test   = { @(Get-ConnectedWlanProfiles | Where-Object { -not (Test-WlanAutoConnect $_) }).Count -eq 0 }
        Set    = {
            Get-ConnectedWlanProfiles | Where-Object { -not (Test-WlanAutoConnect $_) } | ForEach-Object {
                Invoke-Native netsh.exe "wlan set profileparameter name=`"$_`" connectionmode=auto"
            }
        }
        Reboot = $false
    },
    @{
        Name   = 'OpenSSH Server running and automatic'
        Test   = {
            $service = Get-Service sshd -ErrorAction SilentlyContinue
            [bool]$service -and "$($service.StartType)" -eq 'Automatic' -and "$($service.Status)" -eq 'Running'
        }
        Set    = {
            if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
                Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
            }
            Set-Service sshd -StartupType Automatic
            Start-Service sshd
        }
        Reboot = $false
    },
    @{
        Name   = 'sshd allows key logins only'
        Test   = { Test-KeyOnlySshd }
        Set    = { Set-KeyOnlySshd }
        Reboot = $false
    },
    @{
        Name   = 'Firewall allows SSH from Tailscale'
        Test   = { Test-TailscaleSshRule }
        Set    = {
            if (-not (Get-NetFirewallRule -Name sshd-tailscale -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name sshd-tailscale -DisplayName 'OpenSSH Server (Tailscale)' -Enabled False
            }
            Set-NetFirewallRule -Name sshd-tailscale -Enabled True -Direction Inbound -Action Allow -Profile Any `
                -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10
        }
        Reboot = $false
    },
    @{
        Name   = 'Default OpenSSH firewall rule disabled'
        Test   = {
            $rule = Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue
            -not $rule -or "$($rule.Enabled)" -eq 'False'
        }
        Set    = { Disable-NetFirewallRule -Name OpenSSH-Server-In-TCP }
        Reboot = $false
    },
    @{
        Name   = 'Tailscale installed and automatic'
        Test   = {
            $service = Get-Service Tailscale -ErrorAction SilentlyContinue
            [bool]$service -and "$($service.StartType)" -eq 'Automatic'
        }
        Set    = { throw 'Install Tailscale and log in, then rerun.' }
        Reboot = $false
    },
    @{
        Name   = 'WSL and Virtual Machine Platform features enabled'
        Test   = { @($WindowsFeatures | Where-Object { "$((Get-WindowsOptionalFeature -Online -FeatureName $_).State)" -ne 'Enabled' }).Count -eq 0 }
        Set    = {
            foreach ($feature in $WindowsFeatures) {
                Invoke-Native dism.exe "/online /enable-feature /featurename:$feature /all /norestart" -Stream
            }
        }
        Reboot = $true
    },
    @{
        Name   = 'WSL package installed'
        Test   = { (Invoke-Native wsl.exe '--version').ExitCode -eq 0 }
        Set    = { Invoke-Native wsl.exe '--update --web-download' -Stream }
        Reboot = $false
    },
    @{
        Name   = '.wslconfig keeps the VM and distro running'
        Test   = {
            $lines = Get-WslConfigLines
            @($WslSettings | Where-Object { (Get-IniValue $lines $_.Section $_.Key) -ne $_.Value }).Count -eq 0
        }
        Set    = {
            $lines = New-Object Collections.Generic.List[string]
            Get-WslConfigLines | ForEach-Object { $lines.Add($_) }
            foreach ($setting in $WslSettings) { Set-IniValue $lines $setting.Section $setting.Key $setting.Value }
            [IO.File]::WriteAllLines("$WslConfig.almis", $lines, [Text.Encoding]::ASCII)
            Move-Item -Force "$WslConfig.almis" $WslConfig
            Write-Host 'WSL reads .wslconfig at VM start. A running VM keeps the old values until wsl --shutdown or a reboot.'
        }
        Reboot = $false
    },
    @{
        Name   = "$Distro registered as WSL 2"
        Test   = { (Get-DistroVersion) -eq '2' }
        Set    = {
            Invoke-Native wsl.exe '--set-default-version 2'
            if (Get-DistroVersion) { Invoke-Native wsl.exe "--set-version $Distro 2" -Stream }
            else { Invoke-Native wsl.exe "--install -d $Distro --web-download --no-launch" -Stream }
        }
        Reboot = $false
    },
    @{
        Name   = "$Distro provisioned and booted with systemd"
        Test   = {
            $check = Invoke-Native wsl.exe "-d $Distro -u root -- bash -s -- --check" -Stdin $ProvisionScript
            if ($check.ExitCode -ne 0) { Write-Host $check.Output.TrimEnd() }
            $check.ExitCode -eq 0 -and (Get-DistroInit) -eq 'systemd'
        }
        Set    = {
            $run = Invoke-Native wsl.exe "-d $Distro -u root -- bash -s" -Stdin $ProvisionScript -Stream
            if ($run.ExitCode -ne 0) { throw "wsl-provision.sh exited $($run.ExitCode)" }
            # wsl.conf only takes effect when the distro starts. The next Test starts it again.
            if ((Get-DistroInit) -ne 'systemd') { Invoke-Native wsl.exe "--terminate $Distro" }
        }
        Reboot = $false
    },
    @{
        Name   = "Scheduled task '$TaskName' keeps WSL running ($AutostartLogon)"
        Test   = { Test-AutostartTask }
        Set    = { Register-AutostartTask }
        Reboot = $false
    }
)

function Test-Step($Step) {
    try { $result = @(& $Step.Test) }
    catch {
        Write-Warning "$($Step.Name): $_"
        return $false
    }
    # Stray pipeline output would make the step look converged.
    if ($result.Count -ne 1 -or $result[0] -isnot [bool]) { throw "Test for '$($Step.Name)' returned '$result', not one boolean" }
    $result[0]
}

Add-Type -AssemblyName System.Windows.Forms
if ([Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Offline') {
    Write-Warning 'Running on battery. The deployment stack stops when the battery runs out. Plug in AC power.'
}

$pending = 0
foreach ($step in $Steps) {
    if (Test-Step $step) {
        Write-Host "ok   $($step.Name)"
        continue
    }
    if ($Check) {
        Write-Host "todo $($step.Name)"
        $pending++
        continue
    }
    $null = & $step.Set
    if ($step.Reboot) {
        Write-Host "set  $($step.Name)"
        Write-Host 'Restart Windows, then rerun this script.'
        exit 3010
    }
    if (-not (Test-Step $step)) { throw "failed $($step.Name)" }
    Write-Host "set  $($step.Name)"
}
if ($pending) { exit 1 }
