<#
.SYNOPSIS
  Remove an install made by install-managed.ps1. Keeps %LOCALAPPDATA%\TinyPrune data unless -Purge.
  Never touches the Recycle Bin. Verified on a windows-2022 runner by rust/tests-e2e/update-windows.ps1.
#>
[CmdletBinding()]
param([switch]$Purge)
$ErrorActionPreference = 'Stop'
$TaskName = 'TinyPrune Agent (dev)'
$root = Join-Path $env:LOCALAPPDATA 'TinyPrune'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
# Ending the task kills the launcher and (through its job object) the agent, but not instantly. Wait for
# any TinyPrune process running from this install to exit; stop stragglers (an agent started by hand).
function Get-InstallProcesses {
  Get-Process -Name tinyprune, tinyprune-agentd, tinyprune-launcher, tinyprune-ui -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) }
}
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline -and @(Get-InstallProcesses).Count -gt 0) { Start-Sleep -Milliseconds 200 }
Get-InstallProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
function Remove-WithRetry([string]$path) {
  $attempt = 0
  while ($true) {
    try { Remove-Item -LiteralPath $path -Recurse -Force; return }
    catch {
      $attempt++
      if ($attempt -ge 20) { throw }
      Start-Sleep -Milliseconds 250
    }
  }
}
foreach ($p in 'versions', 'launcher', 'bin', 'update') {
  $path = Join-Path $root $p
  if (Test-Path -LiteralPath $path) { Remove-WithRetry $path }
}
foreach ($f in 'current', 'current.new') {
  $path = Join-Path $root $f
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
if ($Purge) {
  if ((Get-Item -LiteralPath $root -ErrorAction SilentlyContinue).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "refusing to purge: $root is a reparse point"
  }
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "purged $root"
} else {
  Write-Host "kept agent data in $root (use -Purge to remove)"
}
