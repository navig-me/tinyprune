<#
.SYNOPSIS
  Build the Windows development zip from already-built release binaries.
.EXAMPLE
  package.ps1 -BinDir target\release -OutDir dist [-UiBin ui\target\release\tinyprune-ui.exe]
  Output: tinyprune-dev-<ver>-windows-<arch>.zip and <same>.zip.sha256
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BinDir,
  [Parameter(Mandatory)][string]$OutDir,
  [string]$UiBin = '',
  [string]$Arch = 'x86_64'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $here '..\..\..')).Path
foreach ($b in 'tinyprune.exe', 'tinyprune-agentd.exe') {
  if (-not (Test-Path -LiteralPath (Join-Path $BinDir $b))) { throw "missing $BinDir\$b" }
}
if ($UiBin -and -not (Test-Path -LiteralPath $UiBin)) { throw "missing $UiBin" }

function Get-CrateVersion([string]$crate) {
  $m = Select-String -Path (Join-Path $root "rust\$crate\Cargo.toml") -Pattern '^version\s*=\s*"(.*)"' | Select-Object -First 1
  if (-not $m) { throw "cannot read version of $crate" }
  $m.Matches[0].Groups[1].Value
}
# The stamp describes what was compiled: TINYPRUNE_VERSION (compiled into the binaries) wins over the crate version.
# CI sets it to the daemon crate version, so released archives are unaffected; the update end-to-end uses it to
# build old/new variants with distinct versions.
$daemon = if ($env:TINYPRUNE_VERSION) { $env:TINYPRUNE_VERSION } else { Get-CrateVersion 'tinyprune-daemon' }
$cli = Get-CrateVersion 'tinyprune-cli'
$uiVer = Get-CrateVersion 'ui'
$sha = $env:GITHUB_SHA
if (-not $sha) { $sha = (& git -C $root rev-parse HEAD 2>$null); if (-not $sha) { $sha = 'unknown' } }
$dirty = ''
if (-not $env:GITHUB_SHA -and (& git -C $root status --porcelain -- rust 2>$null)) { $dirty = '-dirty' }
$short = $sha.Substring(0, [Math]::Min(12, $sha.Length))
$version = "$daemon+g$short$dirty"
$name = "tinyprune-dev-$($version -replace '\+', '-')-windows-$Arch"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$stage = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
$pkg = Join-Path $stage $name
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'bin') | Out-Null
try {
  Copy-Item (Join-Path $BinDir 'tinyprune.exe'), (Join-Path $BinDir 'tinyprune-agentd.exe') (Join-Path $pkg 'bin')
  if ($UiBin) { Copy-Item $UiBin (Join-Path $pkg 'bin\tinyprune-ui.exe') }
  # The launcher resolves `current` for the updatable layout (install-managed.ps1); optional for install.ps1.
  $launcher = Join-Path $BinDir 'tinyprune-launcher.exe'
  if (Test-Path -LiteralPath $launcher) { Copy-Item $launcher (Join-Path $pkg 'bin\tinyprune-launcher.exe') }
  Copy-Item (Join-Path $here 'install.ps1'), (Join-Path $here 'uninstall.ps1'), (Join-Path $here 'install-managed.ps1'), (Join-Path $here 'uninstall-managed.ps1') $pkg
  Copy-Item (Join-Path $root 'LICENSE') $pkg
  @(
    'status=unreleased-development-artifact',
    "package_version=$version",
    "build=$(if ($env:TINYPRUNE_BUILD -match '^[0-9]+$') { $env:TINYPRUNE_BUILD } else { '0' })",
    "tinyprune-agentd=$daemon",
    "tinyprune=$cli",
    "tinyprune-ui=$uiVer",
    "git_sha=$sha$dirty",
    "target=windows-$Arch"
  ) | Set-Content -Path (Join-Path $pkg 'VERSION') -Encoding ascii
  @(
    'TinyPrune development build. UNRELEASED engineering artifact: Windows is not a supported',
    'platform; the macOS app is the only released TinyPrune.',
    'Install (no elevation):  powershell -ExecutionPolicy Bypass -File install.ps1 [-Start] [-AddToPath]',
    'Remove:                  powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-Purge]',
    'Updatable layout:        install-managed.ps1 / uninstall-managed.ps1 (needs bin\tinyprune-launcher.exe)',
    'Check:                   tinyprune doctor'
  ) | Set-Content -Path (Join-Path $pkg 'README.txt') -Encoding ascii

  $zip = Join-Path $OutDir "$name.zip"
  if (Test-Path $zip) { Remove-Item $zip }
  # Entry names use '/' on every PowerShell edition: the updater's extractor (ADR 0012) rejects '\' in names,
  # and Compress-Archive in Windows PowerShell 5.1 writes them.
  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
  $zipStream = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
  $archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
  try {
    $prefix = $stage.TrimEnd('\') + '\'
    Get-ChildItem -LiteralPath $pkg -Recurse -File | ForEach-Object {
      $entry = $_.FullName.Substring($prefix.Length).Replace('\', '/')
      [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
    }
  } finally {
    $archive.Dispose()
    $zipStream.Dispose()
  }
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
  # sha256sum format (two spaces), no BOM.
  [IO.File]::WriteAllText("$zip.sha256", "$hash  $name.zip`n", (New-Object Text.UTF8Encoding $false))
  Write-Output $zip
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
