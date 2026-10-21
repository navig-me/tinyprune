<#
.SYNOPSIS
  Remove a TinyPrune development install made by install.ps1.
  Leaves user data (agent database/logs) unless -Purge. Never touches the Recycle Bin or managed files.
.PARAMETER Prefix Install root used at install time (default: %LOCALAPPDATA%\Programs\TinyPrune)
.PARAMETER Purge  Also delete %LOCALAPPDATA%\TinyPrune (database, audit log). Recycled items are not touched.
#>
[CmdletBinding()]
param(
  [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\TinyPrune'),
  [switch]$Purge
)
$ErrorActionPreference = 'Stop'
$TaskName = 'TinyPrune Agent (dev)'
if (-not [IO.Path]::IsPathRooted($Prefix)) { throw '-Prefix must be an absolute path' }
$bin = Join-Path $Prefix 'bin'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "removed Scheduled Task '$TaskName'"
}
# The agent holds its executable open (Stop-ScheduledTask terminates it, not a graceful shutdown).
Get-Process -Name 'tinyprune-agentd', 'tinyprune-ui' -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and $_.Path.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase) } |
  Stop-Process -Force

foreach ($f in 'tinyprune.exe', 'tinyprune-agentd.exe', 'tinyprune-ui.exe') {
  $p = Join-Path $bin $f
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host "removed $p" }
}
# Remove bin and Prefix only if now empty; never recurse.
foreach ($d in $bin, $Prefix) {
  if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d }
}
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'TinyPrune (development).lnk'
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host "removed $lnk" }

$current = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($current) {
  $parts = $current -split ';' | Where-Object { $_ }
  $kept = @($parts | Where-Object { $_ -ne $bin })
  if ($kept.Count -ne @($parts).Count) {
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    Write-Host "removed $bin from the user PATH"
  }
}

$data = Join-Path $env:LOCALAPPDATA 'TinyPrune'
if (Test-Path -LiteralPath $data) {
  if ($Purge) {
    if ((Get-Item -LiteralPath $data -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "refusing to purge: $data is a reparse point"
    }
    Remove-Item -LiteralPath $data -Recurse -Force
    Write-Host "purged $data"
  } else {
    Write-Host "kept user data in $data (use -Purge to delete it)"
  }
}
Write-Host 'uninstall complete'
