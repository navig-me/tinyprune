# End-to-end smoke for the REAL tinyprune-agentd.exe and tinyprune.exe (Windows PowerShell 5.1 / pwsh 7).
# Unreleased engineering check mirroring smoke.sh. NOT yet executed on Windows by its author: the first
# native run is the CI rust-core job on windows-2022.
#
# Time is the real clock: old fixture items get a 2020 LastWriteTime; the rule is basis=modified with a 1 h lifetime and
# 1 s grace, so old items are due now and new ones are not.
# Trash is the real Recycle Bin (the Windows adapter has no injectable Trash directory); items are checked through the
# Shell.Application Recycle Bin folder.
# Env: TINYPRUNE_BIN_DIR (default rust\target\release), SMOKE_SKIP_BUILD=1, SMOKE_KEEP=1.
# Exit: 0 pass, 1 assertion failure, 2 setup failure.
$ErrorActionPreference = 'Stop'
$rust = Split-Path -Parent $PSScriptRoot
$bin = if ($env:TINYPRUNE_BIN_DIR) { $env:TINYPRUNE_BIN_DIR } else { Join-Path $rust 'target\release' }
if ($env:SMOKE_SKIP_BUILD -ne '1') {
    Push-Location $rust
    cargo build --release --locked -p tinyprune-daemon -p tinyprune-cli
    if ($LASTEXITCODE -ne 0) { Write-Error 'build failed'; exit 2 }
    Pop-Location
}
$agentd = Join-Path $bin 'tinyprune-agentd.exe'
$cli = Join-Path $bin 'tinyprune.exe'
if (-not ((Test-Path $agentd) -and (Test-Path $cli))) { Write-Error "missing binaries in $bin"; exit 2 }

$name = 'tpsmoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$T = Join-Path ([System.IO.Path]::GetTempPath()) $name
$Root = Join-Path $T 'root'
$Data = Join-Path $T 'data'
$Home_ = Join-Path $T 'home'
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'docs'), (Join-Path $Root 'stale'), $Data, $Home_ | Out-Null
$Root = (Get-Item $Root).FullName
$env:TINYPRUNE_ENDPOINT = "\\.\pipe\tinyprune-$name"
$env:USERPROFILE = $Home_ # keep the agent's notion of "home" away from the real profile
$Rule = '11111111-1111-4111-8111-111111111111'
$script:proc = $null
$script:checks = 0
$old = [datetime]'2020-01-01T00:00:00'

function Cleanup {
    if ($script:proc -and -not $script:proc.HasExited) { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue }
    if ($env:SMOKE_KEEP -eq '1') { Write-Host "kept $T" } else { Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue }
}
function Fail($message) {
    Write-Host "FAIL: $message" -ForegroundColor Red
    Write-Host '--- root ---'; Get-ChildItem -Recurse $Root -ErrorAction SilentlyContinue | ForEach-Object FullName
    Cleanup
    exit 1
}
function Ok($message) { $script:checks++; Write-Host "ok   $message" }
function Tp {
    # Native stdout as one string; exit code in $global:TpExit.
    $out = & $cli @args 2>&1 | Out-String
    $global:TpExit = $LASTEXITCODE
    return $out
}
function WaitFor($seconds, $what, [scriptblock]$test) {
    $end = (Get-Date).AddSeconds($seconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $test) } catch { $ok = $false }
        if ($ok) { return }
        if ((Get-Date) -gt $end) { Fail "timeout (${seconds}s) waiting for: $what" }
        Start-Sleep -Milliseconds 250
    }
}
function MovedCount {
    $json = (Tp activity --json) | ConvertFrom-Json
    return @($json.events | Where-Object { $_.kind -eq 'movedToTrash' }).Count
}
function BinPaths {
    $shell = New-Object -ComObject Shell.Application
    try {
        $folder = $shell.Namespace(0xA)
        foreach ($item in $folder.Items()) {
            # Scope assertions to this unique fixture, not unrelated user/runner Bin entries.
            $from = [string]$item.ExtendedProperty('System.Recycle.DeletedFrom')
            if ($from -eq $Root -or $from.StartsWith("$Root\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $name = [string]$item.ExtendedProperty('System.ItemNameDisplay')
                Join-Path $from $name
            }
        }
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}
function StartAgent {
    $script:proc = Start-Process -FilePath $agentd -ArgumentList '--data-dir', "`"$Data`"", '--reconcile-seconds', '1' -PassThru -WindowStyle Hidden
    WaitFor 30 'agent to answer status' { (Tp status) | Out-Null; $global:TpExit -eq 0 }
}
Add-Type -Namespace Smoke -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint group);
'@
function StopAgent {
    # Clean shutdown = Ctrl-C delivered to the agent's own hidden console (the agent handles Ctrl-C only).
    $id = $script:proc.Id
    $helper = "Add-Type -Namespace Smoke -Name Console -MemberDefinition '[DllImport(\`"kernel32.dll\`")] public static extern bool AttachConsole(uint pid); [DllImport(\`"kernel32.dll\`")] public static extern bool FreeConsole(); [DllImport(\`"kernel32.dll\`")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool a); [DllImport(\`"kernel32.dll\`")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);'; [void][Smoke.Console]::FreeConsole(); if ([Smoke.Console]::AttachConsole($id)) { [void][Smoke.Console]::SetConsoleCtrlHandler([IntPtr]::Zero, `$true); [void][Smoke.Console]::GenerateConsoleCtrlEvent(0, 0); Start-Sleep -Milliseconds 500; [void][Smoke.Console]::FreeConsole() }"
    Start-Process -FilePath powershell -ArgumentList '-NoProfile', '-Command', $helper -Wait -WindowStyle Hidden
    if (-not $script:proc.WaitForExit(15000)) { Fail 'agent did not exit after Ctrl-C' }
    if ($script:proc.ExitCode -ne 0) { Fail "agent exit code $($script:proc.ExitCode) after Ctrl-C" }
    $script:proc = $null
    Ok 'agent exited 0 on Ctrl-C'
    (Tp status) | Out-Null
    if ($global:TpExit -ne 69) { Fail "CLI exit code for unreachable agent is $($global:TpExit), expected 69" }
    Ok 'CLI reports unavailable (69) when agent is down'
}

# ---- fixture ---------------------------------------------------------------------------------
Set-Content (Join-Path $Root 'old.txt') 'old'
Set-Content (Join-Path $Root 'keep.txt') 'keep'
Set-Content (Join-Path $Root 'recent.txt') 'recent'
Set-Content (Join-Path $Root 'docs\protected.txt') 'prot'
foreach ($p in 'old.txt', 'keep.txt', 'docs\protected.txt', 'docs', 'stale') { (Get-Item (Join-Path $Root $p)).LastWriteTime = $old }

StartAgent
Ok 'agent started, CLI status answers'
if ((Tp status) -notmatch 'available') { Fail 'status output' }

(Tp roots add smoke-root $Root Fixture) | Out-Null
if ($global:TpExit -ne 0) { Fail 'roots add' }
$rootsText = ((Tp roots list) -join "`n").Replace('\', '/')
if ($rootsText -notmatch [regex]::Escape($Root.Replace('\', '/').TrimStart('/'))) { Write-Host "roots list output: $rootsText"; Fail 'managed root not listed' }
Ok 'managed root added'

(Tp keep (Join-Path $Root 'keep.txt')) | Out-Null; if ($global:TpExit -ne 0) { Fail 'keep file' }
(Tp keep (Join-Path $Root 'docs\protected.txt')) | Out-Null; if ($global:TpExit -ne 0) { Fail 'keep descendant' }
Ok 'Keep set on keep.txt and docs\protected.txt'

$ruleJson = @{
    id = $Rule; name = 'Old items'
    scope = @{ path = $Root; recursive = $true }
    matcher = @{ itemKind = 'fileOrDirectory'; exactNames = @(); globPatterns = @('*') }
    expiryBasis = 'modified'; lifetime = 3600; gracePeriod = 1; action = 'trashItem'; state = 'preview'; matchMode = 'scoped'
} | ConvertTo-Json -Depth 5
$ruleFile = Join-Path $T 'rule.json'
[System.IO.File]::WriteAllText($ruleFile, $ruleJson, (New-Object System.Text.UTF8Encoding($false)))
(Tp rules add $ruleFile) | Out-Null; if ($global:TpExit -ne 0) { Fail 'rules add' }
Ok 'Preview rule added (modified + 1h lifetime, 1s grace)'

# ---- Preview moves nothing -------------------------------------------------------------------
WaitFor 30 'index to list old.txt as eligible' { (Tp upcoming) -match 'old\.txt' }
$prev = Tp rules preview $Rule
if ($global:TpExit -ne 0) { Fail 'rules preview' }
if ($prev -notmatch 'Nothing was changed or moved to Trash') { Fail 'preview did not state nothing changed' }
Start-Sleep 4
foreach ($p in 'old.txt', 'keep.txt', 'recent.txt', 'docs\protected.txt', 'docs', 'stale') { if (-not (Test-Path (Join-Path $Root $p))) { Fail "Preview moved $p" } }
if ((MovedCount) -ne 0) { Fail 'movedToTrash audit event under Preview' }
Ok 'Preview + 4 s of reconcile moved nothing; no movedToTrash audit'

# ---- explanations ----------------------------------------------------------------------------
$e = Tp explain (Join-Path $Root 'old.txt')
foreach ($field in 'Scheduled:', 'Eligible:', 'Rule:', 'Basis:', 'Basis date:', 'Project context:', 'Override:', 'Suppression:', 'Disposition:', 'Globally paused:', 'Identity:', 'Overrides:') {
    if (-not $e.Contains($field)) { Fail "explain old.txt is missing field $field" }
}
if ($e -notmatch 'Disposition: "preview"') { Fail 'old.txt should be a Preview decision' }
Ok 'explain old.txt has every explanation field; disposition preview'
if ((Tp explain (Join-Path $Root 'keep.txt')) -notmatch 'Suppression: "protected"') { Fail 'keep.txt not suppressed as protected' }
if ($prev -notmatch '(?s)docs\r?\n(?:.*?\r?\n){0,12}?Suppression: "protectedDescendant"') { Fail 'Preview does not show docs as protectedDescendant' }
$sched = [regex]::Match((Tp explain (Join-Path $Root 'recent.txt')), 'Scheduled: (\d+)').Groups[1].Value
$now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (-not $sched -or [int64]$sched -le $now + 1800) { Fail "recent.txt deadline is not ~1 h away (got '$sched')" }
Ok 'Keep, protected folder and recent-item deadlines explained'

# ---- pause blocks Active ---------------------------------------------------------------------
(Tp pause) | Out-Null; if ($global:TpExit -ne 0) { Fail 'pause' }
(Tp rules activate $Rule) | Out-Null; if ($global:TpExit -ne 0) { Fail 'rules activate' }
if ((Tp rules) -notmatch 'paused') { Fail 'rules list does not show global pause' }
Start-Sleep 4
foreach ($p in 'old.txt', 'stale') { if (-not (Test-Path (Join-Path $Root $p))) { Fail "Active rule moved $p while globally paused" } }
if ((Tp explain (Join-Path $Root 'old.txt')) -notmatch 'Globally paused: true') { Fail 'explain does not report global pause' }
Ok 'Active rule + global pause moved nothing in 4 s'

StopAgent
StartAgent
if ((Tp rules) -notmatch 'paused') { Fail 'pause did not persist across restart' }
Start-Sleep 3
if (-not (Test-Path (Join-Path $Root 'old.txt'))) { Fail 'old.txt moved after restart although paused' }
Ok 'pause persisted across restart and still blocks'

# ---- Active moves exactly the expected items -------------------------------------------------
(Tp resume) | Out-Null; if ($global:TpExit -ne 0) { Fail 'resume' }
WaitFor 30 'old.txt and stale to leave the root' { -not (Test-Path (Join-Path $Root 'old.txt')) -and -not (Test-Path (Join-Path $Root 'stale')) }
Start-Sleep 3
$survivors = (Get-ChildItem -Recurse $Root | ForEach-Object { $_.FullName.Substring($Root.Length + 1) } | Sort-Object) -join ' '
if ($survivors -ne 'docs docs\protected.txt keep.txt recent.txt') { Fail "unexpected survivors: $survivors" }
Ok 'survivors are exactly docs, docs\protected.txt, keep.txt, recent.txt'
WaitFor 30 'Recycle Bin entries for old.txt and stale' {
    $bin_ = @(BinPaths)
    # Shell display names may hide known extensions. Original directories still isolate our fixture.
    ($bin_ -contains (Join-Path $Root 'old.txt') -or $bin_ -contains (Join-Path $Root 'old')) -and
        $bin_ -contains (Join-Path $Root 'stale')
}
$bin_ = @(BinPaths)
if ($bin_.Count -ne 2) { Fail "unexpected fixture Recycle Bin entries: $($bin_ -join ', ')" }
Ok 'Recycle Bin holds only old.txt and stale from this fixture'

# ---- audit / explain completeness ------------------------------------------------------------
$moved = MovedCount
if ($moved -lt 2) { Fail "expected >=2 movedToTrash audit events, got $moved" }
$events = ((Tp activity --json) | ConvertFrom-Json).events | Where-Object { $_.kind -eq 'movedToTrash' }
foreach ($ev in $events) { if (-not $ev.explanation) { Fail 'movedToTrash audit event lacks a full explanation' } }
if ((Tp activity) -notmatch 'movedToTrash') { Fail 'human activity output lacks movedToTrash' }
Ok "activity: $moved movedToTrash events, each with an explanation"

# ---- restart persistence ---------------------------------------------------------------------
StopAgent
StartAgent
if ((Tp rules) -notmatch "$Rule.*active") { Fail 'Active rule not persisted' }
if ((((Tp roots list) -join "`n").Replace('\', '/')) -notmatch [regex]::Escape($Root.Replace('\', '/').TrimStart('/'))) { Fail 'root not persisted' }
if ((Tp explain (Join-Path $Root 'keep.txt')) -notmatch 'Suppression: "protected"') { Fail 'Keep not persisted' }
if ((MovedCount) -ne $moved) { Fail 'audit history changed across restart' }
Ok 'rule, root, Keep and audit history persisted across restart'

Set-Content (Join-Path $Root 'old2.txt') 'old2'
(Get-Item (Join-Path $Root 'old2.txt')).LastWriteTime = $old
WaitFor 30 'post-restart old2.txt to be trashed' { -not (Test-Path (Join-Path $Root 'old2.txt')) }
foreach ($p in 'keep.txt', 'recent.txt', 'docs\protected.txt') { if (-not (Test-Path (Join-Path $Root $p))) { Fail "survivor $p lost after restart" } }
Ok 'restarted agent keeps enforcing (old2.txt trashed; Keep/recent/protected survive)'

StopAgent
Write-Host "SMOKE PASS ($($script:checks) checks)"
Cleanup
exit 0
