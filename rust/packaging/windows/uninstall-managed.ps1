<#
.SYNOPSIS
  Remove an install made by install-managed.ps1. Keeps %LOCALAPPDATA%\TinyPrune data unless -Purge.
  Never touches the Recycle Bin. Not parsed or executed on Windows by the authors (ADR 0012).
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
foreach ($p in 'versions', 'launcher', 'bin', 'update') {
  $path = Join-Path $root $p
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
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
