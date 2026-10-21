# Ensure the WebView2 runtime exists and put a matching Microsoft Edge WebDriver on PATH (GITHUB_PATH).
# Unreleased engineering harness; used by the rust-ui-windows CI job.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$clientKey = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' # Evergreen WebView2 Runtime
function RuntimeVersion {
    foreach ($path in "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$clientKey", "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$clientKey", "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$clientKey") {
        $pv = (Get-ItemProperty -Path $path -ErrorAction SilentlyContinue).pv
        if ($pv -and $pv -ne '0.0.0.0') { return $pv }
    }
    return $null
}
$version = RuntimeVersion
if ($version) {
    Write-Host "WebView2 runtime already installed: $version"
} else {
    Write-Host 'WebView2 runtime not found; installing the Evergreen bootstrapper from Microsoft.'
    $setup = Join-Path $env:RUNNER_TEMP 'MicrosoftEdgeWebview2Setup.exe'
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $setup
    $sig = Get-AuthenticodeSignature $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "bootstrapper signature: $($sig.Status) $($sig.SignerCertificate.Subject)" }
    $p = Start-Process -FilePath $setup -ArgumentList '/silent', '/install' -Wait -PassThru
    Write-Host "bootstrapper exit code $($p.ExitCode)"
    $version = RuntimeVersion
    if (-not $version) { throw 'WebView2 runtime is still missing after install' }
    Write-Host "WebView2 runtime installed: $version"
}
"WEBVIEW2_VERSION=$version" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8

# msedgedriver must match the WebView2 runtime version. Microsoft publishes no checksum, so the download is
# accepted only if the extracted executable has a valid Microsoft Authenticode signature.
$dir = Join-Path $env:RUNNER_TEMP 'edgedriver'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$zip = Join-Path $dir 'edgedriver_win64.zip'
$base = 'https://msedgedriver.microsoft.com'
try {
    Invoke-WebRequest -Uri "$base/$version/edgedriver_win64.zip" -OutFile $zip
} catch {
    $major = $version.Split('.')[0]
    Write-Host "No driver for exactly $version ($($_.Exception.Message)); using LATEST_RELEASE_${major}_WINDOWS."
    $marker = Join-Path $dir 'latest.txt'
    Invoke-WebRequest -Uri "$base/LATEST_RELEASE_${major}_WINDOWS" -OutFile $marker
    $latest = [regex]::Match(([System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($marker)) + [System.IO.File]::ReadAllText($marker)), '\d+\.\d+\.\d+\.\d+').Value
    if (-not $latest) { throw 'cannot parse latest driver version' }
    Write-Host "driver version $latest"
    Invoke-WebRequest -Uri "$base/$latest/edgedriver_win64.zip" -OutFile $zip
}
Expand-Archive -Path $zip -DestinationPath $dir -Force
$exe = Join-Path $dir 'msedgedriver.exe'
$sig = Get-AuthenticodeSignature $exe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "msedgedriver signature: $($sig.Status) $($sig.SignerCertificate.Subject)" }
Write-Host ("msedgedriver: " + (& $exe --version))
$dir | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
