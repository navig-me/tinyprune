# Start the REAL tinyprune-agentd.exe with isolated data and a unique named pipe, then run the shared
# rust/ui/docker/smoke.py through tauri-driver + msedgedriver against the real Tauri/WebView2 window.
# Env in: TINYPRUNE_BIN_DIR (agent+CLI), TINYPRUNE_UI_APP, TINYPRUNE_UI_AXE, TINYPRUNE_UI_OUT.
$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:RUNNER_TEMP ('tpui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$data = Join-Path $temp 'data'
$fixture = Join-Path $temp 'tinyprune-ui-fixture'
New-Item -ItemType Directory -Force -Path $data, $fixture, $env:TINYPRUNE_UI_OUT | Out-Null
$env:TINYPRUNE_ENDPOINT = "\\.\pipe\tinyprune-ui-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$env:TINYPRUNE_UI_CLI = Join-Path $env:TINYPRUNE_BIN_DIR 'tinyprune.exe'
$env:TINYPRUNE_UI_FIXTURE = $fixture
$env:PYTHONUTF8 = '1'
$agent = Start-Process -FilePath (Join-Path $env:TINYPRUNE_BIN_DIR 'tinyprune-agentd.exe') -ArgumentList '--data-dir', "`"$data`"" `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $env:TINYPRUNE_UI_OUT 'agent.log') -RedirectStandardError (Join-Path $env:TINYPRUNE_UI_OUT 'agent.err.log')
$env:TINYPRUNE_UI_AGENT_PID = $agent.Id
try {
    python rust/ui/docker/fixture.py
    if ($LASTEXITCODE -ne 0) { throw 'fixture failed' }
    python rust/ui/docker/smoke.py
    if ($LASTEXITCODE -ne 0) { throw "smoke failed ($LASTEXITCODE)" }
} finally {
    if (-not $agent.HasExited) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
    Get-Process tinyprune-ui, msedgedriver, tauri-driver -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
