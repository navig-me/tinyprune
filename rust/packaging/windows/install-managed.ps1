<#
.SYNOPSIS
  Install the TinyPrune development build for the current user in the UPDATABLE layout (no elevation).
  UNRELEASED engineering artifact: Windows is not a supported or released platform. NEVER RUN ON WINDOWS
  by the authors: this script has not been parsed or executed there (ADR 0012).
.DESCRIPTION
  Layout (ADR 0012):
    %LOCALAPPDATA%\TinyPrune\versions\<package_version>-b<build>\bin\*.exe
    %LOCALAPPDATA%\TinyPrune\current            text file naming the active version directory
    %LOCALAPPDATA%\TinyPrune\launcher\tinyprune-launcher.exe   resolves `current` at start
    %LOCALAPPDATA%\TinyPrune\bin\tinyprune.cmd  PATH shim -> launcher
  A running .exe cannot be overwritten on Windows, so updates stage side by side and only the `current`
  file is replaced; the per-user Scheduled Task runs the launcher, never a versioned binary.
#>
[CmdletBinding()]
param(
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

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in 'bin\tinyprune.exe', 'bin\tinyprune-agentd.exe', 'bin\tinyprune-launcher.exe', 'VERSION') {
  if (-not (Test-Path -LiteralPath (Join-Path $here $f))) { throw "incomplete package: missing $f" }
}
$meta = @{}
Get-Content -LiteralPath (Join-Path $here 'VERSION') | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { $meta[$Matches[1]] = $Matches[2] } }
$build = if ($meta['build']) { $meta['build'] } else { '0' }
$name = "$($meta['package_version'])-b$build"
if ($name -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]*$') { throw "VERSION has an unusable package_version/build: '$name'" }
if ($build -eq '0') { Write-Warning 'This package has no build number (build=0): it installs, but updates stay disabled.' }

$root = Join-Path $env:LOCALAPPDATA 'TinyPrune'
$versions = Join-Path $root 'versions'
$launcherDir = Join-Path $root 'launcher'
$shimDir = Join-Path $root 'bin'
$target = Join-Path $versions $name
if (Test-Path -LiteralPath $target) { throw "version $name is already installed at $target" }
New-Item -ItemType Directory -Force -Path $versions, $launcherDir, $shimDir | Out-Null

# The launcher is the parent of the running agent; stop the task before replacing it.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
$stage = Join-Path $versions ".stage-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
  Copy-Item -Recurse -LiteralPath (Join-Path $here 'bin') -Destination (Join-Path $stage 'bin')
  Remove-Item -LiteralPath (Join-Path $stage 'bin\tinyprune-launcher.exe') -Force
  Copy-Item -LiteralPath (Join-Path $here 'VERSION') -Destination (Join-Path $stage 'VERSION')
  $license = Join-Path $here 'LICENSE'
  if (Test-Path -LiteralPath $license) { Copy-Item -LiteralPath $license -Destination (Join-Path $stage 'LICENSE') }
  Move-Item -LiteralPath $stage -Destination $target
} catch {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  throw
}
Copy-Item -LiteralPath (Join-Path $here 'bin\tinyprune-launcher.exe') -Destination (Join-Path $launcherDir 'tinyprune-launcher.exe') -Force

# Replace the pointer file in one step. [IO.File]::Replace is MoveFileEx/ReplaceFile based.
$pointer = Join-Path $root 'current'
$pending = Join-Path $root 'current.new'
[IO.File]::WriteAllText($pending, "$name`n", (New-Object Text.UTF8Encoding $false))
if (Test-Path -LiteralPath $pointer) { [IO.File]::Replace($pending, $pointer, $null) } else { Move-Item -LiteralPath $pending -Destination $pointer }
Write-Host "installed $target and pointed $pointer at it"

$launcher = Join-Path $launcherDir 'tinyprune-launcher.exe'
$shim = Join-Path $shimDir 'tinyprune.cmd'
Set-Content -LiteralPath $shim -Encoding ascii -Value "@echo off`r`n`"$launcher`" tinyprune %*"
Write-Host "installed $shim"

if (-not $NoTask) {
  $user = "$($identity.Name)"
  $action = New-ScheduledTaskAction -Execute $launcher -Argument 'tinyprune-agentd'
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'TinyPrune development agent (unreleased).' -Force | Out-Null
  Write-Host "registered Scheduled Task '$TaskName' (runs the launcher at logon, limited rights)"
  if ($Start) { Start-ScheduledTask -TaskName $TaskName; Write-Host 'task started' }
}
if ($AddToPath) {
  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @(); if ($current) { $parts = $current -split ';' | Where-Object { $_ } }
  if ($parts -notcontains $shimDir) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $shimDir) -join ';'), 'User')
    Write-Host "added $shimDir to the user PATH (open a new terminal)"
  }
}
Write-Host "next: tinyprune doctor   (agent data lives in $root)"
