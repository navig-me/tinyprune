<#
.SYNOPSIS
  Install the TinyPrune development build for the current user (no elevation).
  UNRELEASED engineering artifact: Windows is not a supported or released platform.
.DESCRIPTION
  Copies tinyprune.exe / tinyprune-agentd.exe (and tinyprune-ui.exe if bundled) into
  -Prefix\bin and registers a per-user Scheduled Task "TinyPrune Agent (dev)" that runs
  the agent at logon with limited rights and restarts it on failure. The task is NOT
  started unless -Start is given. Check afterwards with: tinyprune doctor
.PARAMETER Prefix    Install root (default: %LOCALAPPDATA%\Programs\TinyPrune)
.PARAMETER Start     Start the task now (default: register only; it runs at next logon)
.PARAMETER NoTask    Do not register the Scheduled Task
.PARAMETER AddToPath Append <Prefix>\bin to the user PATH (HKCU only)
.PARAMETER AllowElevated Permit running from an elevated shell (for CI runners, whose default user is an administrator). The task is still registered with a limited token.
#>
[CmdletBinding()]
param(
  [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\TinyPrune'),
  [switch]$Start,
  [switch]$NoTask,
  [switch]$AddToPath,
  [switch]$AllowElevated
)
$ErrorActionPreference = 'Stop'
$TaskName = 'TinyPrune Agent (dev)'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $AllowElevated -and (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Refusing to run elevated: this installs per-user files only. Run from a normal (non-admin) PowerShell.'
}
if ($Start -and $NoTask) { throw '-Start conflicts with -NoTask' }
if (-not [IO.Path]::IsPathRooted($Prefix)) { throw '-Prefix must be an absolute path' }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in 'bin\tinyprune.exe', 'bin\tinyprune-agentd.exe') {
  if (-not (Test-Path -LiteralPath (Join-Path $here $f))) { throw "incomplete package: missing $f" }
}

$bin = Join-Path $Prefix 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# A running agent holds its executable open; stop the task first so the copy can replace it.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Get-Process -Name 'tinyprune-agentd' -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq (Join-Path $bin 'tinyprune-agentd.exe') } | Stop-Process -Force

$ui = Join-Path $here 'bin\tinyprune-ui.exe'
$files = @('tinyprune.exe', 'tinyprune-agentd.exe')
if (Test-Path -LiteralPath $ui) { $files += 'tinyprune-ui.exe' }
foreach ($f in $files) {
  Copy-Item -LiteralPath (Join-Path $here "bin\$f") -Destination (Join-Path $bin $f) -Force
  Write-Host "installed $(Join-Path $bin $f)"
}

if (Test-Path -LiteralPath $ui) {
  $programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'TinyPrune (development).lnk'
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($programs)
  $link.TargetPath = Join-Path $bin 'tinyprune-ui.exe'
  $link.Save()
  Write-Host "installed Start Menu shortcut $programs"
}

if (-not $NoTask) {
  $user = "$($identity.Name)"
  $action = New-ScheduledTaskAction -Execute (Join-Path $bin 'tinyprune-agentd.exe')
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  # Interactive token, limited run level: never elevated.
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'TinyPrune development agent (unreleased).' -Force | Out-Null
  Write-Host "registered Scheduled Task '$TaskName' (at logon, limited rights, restart on failure)"
  if ($Start) { Start-ScheduledTask -TaskName $TaskName; Write-Host 'task started' }
  else { Write-Host "task not started; it runs at next logon, or: Start-ScheduledTask -TaskName '$TaskName'" }
}

if ($AddToPath) {
  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @(); if ($current) { $parts = $current -split ';' | Where-Object { $_ } }
  if ($parts -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $bin) -join ';'), 'User')
    Write-Host "added $bin to the user PATH (open a new terminal)"
  }
}
Write-Host "next: $(Join-Path $bin 'tinyprune.exe') doctor   (agent data lives in $env:LOCALAPPDATA\TinyPrune)"
