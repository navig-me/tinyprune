# Windows end-to-end for `tinyprune update` (ADR 0012), mirroring update-docker.sh. Unreleased dev tooling.
#
#   rust\tests-e2e\update-windows.ps1       (needs TINYPRUNE_E2E_ALLOW_INSTALL=1; see below)
#
# It builds three stamped variants of the daemon + CLI + launcher with a THROWAWAY Ed25519 key generated here
# (never a real secret; the key and everything signed with it die with the work directory):
#   0.1.0 build 1 (old) -> 0.2.0 build 2 (good update) -> 0.3.0 build 3 (its agent dies on start)
# plus a 0.4.0 build 4 whose agent fails `--version`. It installs the OLD build with install-managed.ps1 (a
# per-user Scheduled Task running tinyprune-launcher), serves signed feeds from `tinyprune-feed test-serve`
# (loopback, no Python), and asserts the update, restart through the task, state survival, tamper/replay
# refusal, rollback, pre-swap refusal and the Trash/update interlock on the real agent.
#
# DESTRUCTIVE to the current user's TinyPrune install (task "TinyPrune Agent (dev)" and
# %LOCALAPPDATA%\TinyPrune): it refuses to run unless TINYPRUNE_E2E_ALLOW_INSTALL=1, and it is meant for a
# disposable CI runner. The compiled test binaries use `test-overrides`; released artifacts do not.
$ErrorActionPreference = 'Stop'
if ($env:TINYPRUNE_E2E_ALLOW_INSTALL -ne '1') {
    Write-Error 'refusing to run: this replaces the per-user TinyPrune install and Scheduled Task. Set TINYPRUNE_E2E_ALLOW_INSTALL=1 on a disposable machine.'
    exit 2
}
$rust = Split-Path -Parent $PSScriptRoot
$PORT = 8765
$BASE = "http://127.0.0.1:$PORT"
$TaskName = 'TinyPrune Agent (dev)'
$data = Join-Path $env:LOCALAPPDATA 'TinyPrune'
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $tmp 'tp-update-e2e'
$script:server = $null
$script:checks = 0

function Dump {
    Write-Host '--- diagnostics ---'
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Format-List TaskName, State
    Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue | Format-List LastRunTime, LastTaskResult, NumberOfMissedRuns
    Get-CimInstance Win32_Process -Filter "Name like 'tinyprune%'" -ErrorAction SilentlyContinue |
        Format-Table ProcessId, ParentProcessId, Name, ExecutablePath -AutoSize -Wrap | Out-String -Width 250 | Write-Host
    if (Test-Path -LiteralPath $data) {
        Get-ChildItem -LiteralPath $data -Recurse -Depth 2 -ErrorAction SilentlyContinue | ForEach-Object FullName
        if (Test-Path -LiteralPath (Join-Path $data 'current')) { Write-Host "current -> $([IO.File]::ReadAllText((Join-Path $data 'current')).Trim())" }
        Get-ChildItem -LiteralPath $data -Recurse -Include '*.log', '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "--- $($_.FullName)"; Get-Content -LiteralPath $_.FullName -Tail 40
        }
        $shimPath = Join-Path $data 'bin\tinyprune.cmd'
        if (Test-Path -LiteralPath $shimPath) {
            Write-Host '--- tinyprune status via the shim'
            (& $shimPath status 2>&1 | Out-String) | Write-Host
            Write-Host "exit $LASTEXITCODE"
        }
        if (Test-Path -LiteralPath (Join-Path $data 'current')) {
            $exe = Join-Path $data "versions\$([IO.File]::ReadAllText((Join-Path $data 'current')).Trim())\bin\tinyprune.exe"
            Write-Host '--- tinyprune.exe status directly'
            (& $exe status 2>&1 | Out-String) | Write-Host
            Write-Host "exit $LASTEXITCODE"
        }
        $state = Join-Path $data 'update\state.json'
        if (Test-Path -LiteralPath $state) { Write-Host '--- update state'; Get-Content -LiteralPath $state }
        if ($script:procLog -and (Test-Path -LiteralPath $script:procLog)) {
            Write-Host '--- tinyprune process timeline'; Get-Content -LiteralPath $script:procLog -Tail 120
        }
    }
}
$script:procLog = $null
$script:poller = $null
function Cleanup {
    if ($script:server -and -not $script:server.HasExited) { Stop-Process -Id $script:server.Id -Force -ErrorAction SilentlyContinue }
    if ($script:poller) { Stop-Job $script:poller -ErrorAction SilentlyContinue; Remove-Job $script:poller -Force -ErrorAction SilentlyContinue }
    if ($script:oldPkg -and (Test-Path -LiteralPath (Join-Path $script:oldPkg 'uninstall-managed.ps1'))) {
        $uninstall = Join-Path $script:oldPkg 'uninstall-managed.ps1'
        try { & $uninstall -Purge | Out-Null } catch { Write-Host "cleanup uninstall: $_" }
    }
    Get-Process -Name tinyprune-agentd, tinyprune-launcher -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
function Fail($message) {
    Write-Host "FAIL: $message" -ForegroundColor Red
    Dump
    Cleanup
    exit 1
}
function Ok($message) { $script:checks++; Write-Host "ok   $message" }
function WaitFor($seconds, $what, [scriptblock]$test) {
    $end = (Get-Date).AddSeconds($seconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $test) } catch { $ok = $false; $lastError = "$_" }
        if ($ok) { return }
        if ((Get-Date) -gt $end) { Fail "timeout (${seconds}s) waiting for: $what (last error: $lastError)" }
        Start-Sleep -Milliseconds 250
    }
}
function Native([scriptblock]$command) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw "native command failed ($LASTEXITCODE): $command" }
}

$script:oldPkg = $null
try {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    # ---------------------------------------------------------------------------------------------
    # Phase 1: build + package + sign fixtures
    # ---------------------------------------------------------------------------------------------
    Push-Location $rust
    $env:CARGO_INCREMENTAL = '0'
    Native { cargo build --release --locked -p tinyprune-update --bin tinyprune-feed --features test-overrides }
    $feed = Join-Path $work 'tinyprune-feed.exe'
    Copy-Item -LiteralPath 'target\release\tinyprune-feed.exe' -Destination $feed
    $seed = Join-Path $work 'seed.bin'
    $pub = (& $feed test-keygen --seed-file $seed | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $pub) { throw 'test-keygen failed' }

    $pkgDir = Join-Path $work 'pkg'
    New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
    function Build-Variant($version, $build, $name) {
        $env:TINYPRUNE_UPDATE_PUBLIC_KEY = $pub
        $env:TINYPRUNE_VERSION = $version
        $env:TINYPRUNE_BUILD = "$build"
        # Separate invocations: the agent must not be compiled with the HTTP/TLS client features.
        Native { cargo build --release --locked -p tinyprune-daemon }
        Native { cargo build --release --locked -p tinyprune-cli --features update-test-overrides }
        Native { cargo build --release --locked -p tinyprune-update --bin tinyprune-launcher }
        $out = Join-Path $pkgDir $name
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        & packaging\windows\package.ps1 -BinDir 'target\release' -OutDir $out | Out-Null
        $zip = Get-ChildItem $out -Filter *.zip | Select-Object -First 1
        Move-Item -LiteralPath $zip.FullName -Destination (Join-Path $out 'pkg.zip')
        Remove-Item (Join-Path $out '*.sha256') -Force
        # Keep this variant's binaries for the repackaged bad builds.
        $bins = Join-Path $out 'bin'
        New-Item -ItemType Directory -Force -Path $bins | Out-Null
        Copy-Item 'target\release\tinyprune.exe', 'target\release\tinyprune-agentd.exe', 'target\release\tinyprune-launcher.exe' $bins
    }
    Build-Variant '0.1.0' 1 'v1'
    Build-Variant '0.2.0' 2 'v2'
    Build-Variant '0.3.0' 3 'v3'
    Remove-Item Env:TINYPRUNE_UPDATE_PUBLIC_KEY, Env:TINYPRUNE_VERSION, Env:TINYPRUNE_BUILD

    # Fake agents. b3's passes the staged self-check (`--version` works) but dies on start; b4's fails
    # `--version`, so the updater must refuse it before anything points at it.
    $fakeDir = Join-Path $work 'fake'
    New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeDir 'dies.rs') -Encoding ascii -Value @'
fn main() {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("tinyprune-agentd 0.1.0");
        return;
    }
    eprintln!("simulated broken agent");
    std::process::exit(1);
}
'@
    Set-Content -LiteralPath (Join-Path $fakeDir 'badversion.rs') -Encoding ascii -Value @'
fn main() {
    eprintln!("simulated broken --version");
    std::process::exit(3);
}
'@
    Native { rustc -O --edition 2021 (Join-Path $fakeDir 'dies.rs') -o (Join-Path $fakeDir 'dies.exe') }
    Native { rustc -O --edition 2021 (Join-Path $fakeDir 'badversion.rs') -o (Join-Path $fakeDir 'badversion.exe') }
    function Repack($baseVariant, $fake, $name, $build) {
        $bin = Join-Path $pkgDir "$name\bin"
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        Copy-Item (Join-Path $pkgDir "$baseVariant\bin\tinyprune.exe"), (Join-Path $pkgDir "$baseVariant\bin\tinyprune-launcher.exe") $bin
        Copy-Item (Join-Path $fakeDir "$fake.exe") (Join-Path $bin 'tinyprune-agentd.exe')
        $env:TINYPRUNE_BUILD = "$build"
        & packaging\windows\package.ps1 -BinDir $bin -OutDir (Join-Path $pkgDir $name) | Out-Null
        Remove-Item Env:TINYPRUNE_BUILD
        $zip = Get-ChildItem (Join-Path $pkgDir $name) -Filter *.zip | Select-Object -First 1
        Move-Item -LiteralPath $zip.FullName -Destination (Join-Path $pkgDir "$name\pkg.zip")
    }
    Repack 'v3' 'dies' 'bad3' 3
    Repack 'v3' 'badversion' 'bad4' 4
    Pop-Location

    $serve = Join-Path $work 'serve'
    $a1 = 'tinyprune-0.1.0-b1-windows-x86_64.zip'
    $a2 = 'tinyprune-0.2.0-b2-windows-x86_64.zip'
    $a3 = 'tinyprune-0.3.0-b3-windows-x86_64.zip'
    $a4 = 'tinyprune-0.4.0-b4-windows-x86_64.zip'
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $utf8 = New-Object Text.UTF8Encoding($false)
    function Sign($file) {
        $sig = (& $feed test-sign --seed-file $seed --file $file | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $sig) { throw "test-sign failed for $file" }
        [IO.File]::WriteAllText("$file.sig", "$sig`n", $utf8)
    }
    function Gen($scenario, $version, $build, $artifact, $existing) {
        $dir = Join-Path $serve $scenario
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $new = Join-Path $dir 'rust-update-feed.json.new'
        $args_ = @('generate', '--out', $new, '--version', $version, '--build', "$build", '--base-url', "$BASE/$scenario/", '--published', $now, '--artifact', "windows-x86_64=$artifact")
        if ($existing) { $args_ += @('--existing', $existing) }
        & $feed @args_ | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "feed generate failed for $scenario" }
        Move-Item -LiteralPath $new -Destination (Join-Path $dir 'rust-update-feed.json') -Force
        Sign (Join-Path $dir 'rust-update-feed.json')
    }
    function Stage($scenario, $from, $name) {
        New-Item -ItemType Directory -Force -Path (Join-Path $serve $scenario) | Out-Null
        Copy-Item -LiteralPath $from -Destination (Join-Path $serve "$scenario\$name")
    }
    Stage 'good' (Join-Path $pkgDir 'v2\pkg.zip') $a2
    Gen 'good' '0.2.0' 2 (Join-Path $serve "good\$a2")
    Stage 'tamper-artifact' (Join-Path $pkgDir 'v2\pkg.zip') $a2
    Gen 'tamper-artifact' '0.2.0' 2 (Join-Path $serve "tamper-artifact\$a2")
    # Flip one byte AFTER the feed recorded the hash: same length, different content.
    $victim = Join-Path $serve "tamper-artifact\$a2"
    $bytes = [IO.File]::ReadAllBytes($victim)
    $bytes[200] = $bytes[200] -bxor 0xFF
    [IO.File]::WriteAllBytes($victim, $bytes)
    New-Item -ItemType Directory -Force -Path (Join-Path $serve 'tamper-feed') | Out-Null
    Copy-Item (Join-Path $serve 'good\rust-update-feed.json'), (Join-Path $serve 'good\rust-update-feed.json.sig') (Join-Path $serve 'tamper-feed')
    $tampered = Join-Path $serve 'tamper-feed\rust-update-feed.json'
    $text = [IO.File]::ReadAllText($tampered)
    if ($text -notmatch '"build": 2') { throw 'unexpected feed layout' }
    [IO.File]::WriteAllText($tampered, $text.Replace('"build": 2', '"build": 99'), $utf8)
    Stage 'stale' (Join-Path $pkgDir 'v1\pkg.zip') $a1
    Gen 'stale' '0.1.0' 1 (Join-Path $serve "stale\$a1")
    Stage 'bad' (Join-Path $pkgDir 'v2\pkg.zip') $a2
    Gen 'bad' '0.2.0' 2 (Join-Path $serve "bad\$a2")
    Copy-Item (Join-Path $pkgDir 'bad3\pkg.zip') (Join-Path $serve "bad\$a3")
    Gen 'bad' '0.3.0' 3 (Join-Path $serve "bad\$a3") (Join-Path $serve 'bad\rust-update-feed.json')
    Stage 'badversion' (Join-Path $pkgDir 'bad4\pkg.zip') $a4
    Gen 'badversion' '0.4.0' 4 (Join-Path $serve "badversion\$a4") (Join-Path $serve 'bad\rust-update-feed.json')
    Write-Host 'fixtures ready'

    # ---------------------------------------------------------------------------------------------
    # Phase 2: the scenario, as the current user, against the real Scheduled Task
    # ---------------------------------------------------------------------------------------------
    $shim = Join-Path $data 'bin\tinyprune.cmd'
    function Tp { # native output as one string; exit code in $script:rc (and $global:rc); `cli` is a Clear-Item alias
        $out = & $shim @args 2>&1 | Out-String
        $global:rc = $LASTEXITCODE
        $script:rc = $global:rc
        return $out.Trim()
    }
    function Upd($scenario) {
        $env:TINYPRUNE_UPDATE_FEED_URL = "$BASE/$scenario/rust-update-feed.json"
        try { return (Tp update @args) } finally { Remove-Item Env:TINYPRUNE_UPDATE_FEED_URL -ErrorAction SilentlyContinue }
    }
    function Cur { [IO.File]::ReadAllText((Join-Path $data 'current')).Trim() }
    function AgentProcs { @(Get-CimInstance Win32_Process -Filter "Name='tinyprune-agentd.exe'") }
    function Healthy {
        $null = & $shim status 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    function DirNames($path) { @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object) }
    function RunsFrom($version) {
        # Exactly one agent, started by the launcher, whose image is in this version directory.
        $procs = AgentProcs
        if ($procs.Count -ne 1) { return $false }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($procs[0].ParentProcessId)" -ErrorAction SilentlyContinue
        return ($procs[0].ExecutablePath -like "*\versions\$version\bin\tinyprune-agentd.exe") -and $parent -and ($parent.Name -eq 'tinyprune-launcher.exe')
    }

    # --- install the OLD build in the updatable layout, started by the real Scheduled Task ---
    # (TINYPRUNE_E2E_ALLOW_INSTALL stays set for the scripts below.)
    $old = Join-Path $work 'old'
    Expand-Archive -LiteralPath (Join-Path $pkgDir 'v1\pkg.zip') -DestinationPath $old
    $script:oldPkg = (Get-ChildItem $old -Directory | Select-Object -First 1).FullName
    # The hosted runner user is an administrator; -AllowElevated still registers a Limited-token task.
    # Timestamped timeline of every tinyprune process (pid <- parent), for diagnosing restarts on failure.
    $script:procLog = Join-Path $work 'procs.log'
    $script:poller = Start-Job -ArgumentList $script:procLog -ScriptBlock {
        param($log)
        $last = ''
        while ($true) {
            $lines = @(Get-CimInstance Win32_Process -Filter "Name like 'tinyprune%'" -ErrorAction SilentlyContinue |
                Sort-Object ProcessId | ForEach-Object { "  $($_.ProcessId)<-$($_.ParentProcessId) $($_.Name) $($_.ExecutablePath)" })
            $text = $lines -join "`n"
            if ($text -ne $last) {
                Add-Content -LiteralPath $log -Value ("[{0} utc]`n{1}" -f [DateTime]::UtcNow.ToString('HH:mm:ss.fff'), $text)
                $last = $text
            }
            Start-Sleep -Milliseconds 100
        }
    }
    & (Join-Path $script:oldPkg 'install-managed.ps1') -AllowElevated -Start
    WaitFor 90 'old agent answers' { Healthy }
    if ((Cur) -notmatch '^0\.1\.0.*-b1$') { Fail "unexpected current: $(Cur)" }
    WaitFor 30 'old agent runs from the old version dir via the launcher' { RunsFrom '0.1.0*-b1' }
    $status = (Tp update status --json) | ConvertFrom-Json
    if ($status.installedBuild -ne 1) { Fail 'old build is not build 1' }
    if ($status.updatesEnabled -ne $true) { Fail "managed old build has updates disabled: $($status.disabledReason)" }
    if ($status.managedInstall -ne $true) { Fail 'CLI does not consider itself managed' }
    Ok 'old build 1 installed in the managed layout; the Scheduled Task runs it through tinyprune-launcher'

    # --- state that must survive: a root, a Preview rule and a Keep item ---
    $root = Join-Path $tmp 'tp-update-root'
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $root = (Get-Item $root).FullName
    $rule = '11111111-1111-4111-8111-111111111111'
    Set-Content (Join-Path $root 'keep.txt') 'keep'
    Set-Content (Join-Path $root 'old.txt') 'old'
    $longAgo = [datetime]'2020-01-01T00:00:00'
    foreach ($f in 'keep.txt', 'old.txt') { (Get-Item (Join-Path $root $f)).LastWriteTime = $longAgo }
    Tp roots add e2e-root $root E2E | Out-Null
    if ($script:rc -ne 0) { Fail 'roots add' }
    $ruleJson = @{
        id = $rule; name = 'Update e2e'
        scope = @{ path = $root; recursive = $true }
        matcher = @{ itemKind = 'file'; exactNames = @(); globPatterns = @('*.txt') }
        expiryBasis = 'modified'; lifetime = 3600; gracePeriod = 1; action = 'trashItem'; state = 'preview'; matchMode = 'scoped'
    } | ConvertTo-Json -Depth 5
    $ruleFile = Join-Path $work 'rule.json'
    [IO.File]::WriteAllText($ruleFile, $ruleJson, $utf8)
    Tp rules add $ruleFile | Out-Null
    if ($script:rc -ne 0) { Fail 'rules add' }
    Tp keep (Join-Path $root 'keep.txt') | Out-Null
    if ($script:rc -ne 0) { Fail 'keep' }
    Start-Sleep -Seconds 3
    if (-not ((Test-Path (Join-Path $root 'old.txt')) -and (Test-Path (Join-Path $root 'keep.txt')))) { Fail 'Preview must not trash' }
    if ((Tp explain (Join-Path $root 'keep.txt')) -notmatch '(?i)keep') { Fail 'Keep not recorded before the update' }
    Ok 'root, Preview rule and Keep recorded'

    # --- the feed server (tinyprune-feed test-serve: loopback only, test-overrides build) ---
    $script:server = Start-Process -FilePath $feed -ArgumentList 'test-serve', '--dir', "`"$serve`"", '--port', "$PORT" -PassThru -WindowStyle Hidden
    WaitFor 30 'feed server' { (Invoke-WebRequest -UseBasicParsing "$BASE/good/rust-update-feed.json").StatusCode -eq 200 }

    # --- checks never install ---
    $out = Upd good check --json
    $offer = $out | ConvertFrom-Json
    if ($offer.status -ne 'available' -or $offer.build -ne 2) { Fail "check: $out" }
    $token = $offer.confirmationToken
    if ((Cur) -notmatch '-b1$') { Fail 'check changed current' }
    $out = Upd good install --json
    if (($out | ConvertFrom-Json).status -ne 'confirmationRequired') { Fail "install without --confirm: $out" }
    if ((Cur) -notmatch '-b1$') { Fail 'install without --confirm changed current' }
    $out = Upd good install --confirm 00000000000000000000000000000000 --json
    if ($script:rc -ne 65) { Fail "wrong confirmation exit $($script:rc): $out" }
    if ((Cur) -notmatch '-b1$') { Fail 'wrong confirmation changed current' }
    Tp update settings --check-for-new-versions off | Out-Null
    $out = Upd good check --auto --json
    if (($out | ConvertFrom-Json).reason -ne 'disabled') { Fail "--auto ignored checkForNewVersions=off: $out" }
    Tp update settings --check-for-new-versions on | Out-Null
    Ok 'check is read-only; install needs the exact confirmation token; the setting gates --auto'

    # --- tampering is rejected and changes nothing ---
    $pidBefore = (AgentProcs)[0].ProcessId
    $out = Upd tamper-feed check --json
    if ($script:rc -ne 65 -or ($out | ConvertFrom-Json).code -ne 'feedRejected') { Fail "tampered feed accepted (rc=$($script:rc)): $out" }
    $out = Upd tamper-artifact check --json
    $token = ($out | ConvertFrom-Json).confirmationToken
    $out = Upd tamper-artifact install --confirm $token --json
    if ($script:rc -ne 65 -or ($out | ConvertFrom-Json).code -ne 'packageRejected') { Fail "tampered artifact accepted (rc=$($script:rc)): $out" }
    if ((Cur) -notmatch '-b1$' -or (AgentProcs)[0].ProcessId -ne $pidBefore) { Fail 'tampering disturbed the install or the agent' }
    $leftovers = @(DirNames (Join-Path $data 'update') | Where-Object { $_ -ne 'state.json' })
    if ($leftovers.Count -ne 0) { Fail "download leftovers: $($leftovers -join ', ')" }
    Ok 'tampered feed (signature) and tampered artifact (SHA-256) rejected; agent untouched'

    # --- the real update, with a real Scheduled Task restart ---
    $out = Upd good check --json
    $token = ($out | ConvertFrom-Json).confirmationToken
    $out = Upd good install --confirm $token --json
    if ($script:rc -ne 0) { Fail "install failed (rc=$($script:rc)): $out" }
    $done = $out | ConvertFrom-Json
    if ($done.status -ne 'installed' -or $done.agent -ne 'restarted') { Fail "install result: $out" }
    if ((Cur) -ne '0.2.0-b2') { Fail "current after update: $(Cur)" }
    $names = DirNames (Join-Path $data 'versions')
    if (-not (Test-Path (Join-Path $data 'versions\0.2.0-b2')) -or $names.Count -ne 2) { Fail "expected new + previous kept: $($names -join ', ')" }
    WaitFor 60 'the Scheduled Task runs the NEW build through the launcher' { RunsFrom '0.2.0-b2' }
    if ((AgentProcs)[0].ProcessId -eq $pidBefore) { Fail 'agent was not restarted' }
    if (Get-Process -Id $pidBefore -ErrorAction SilentlyContinue) { Fail 'the old agent process is still alive' }
    WaitFor 60 'new agent answers' { Healthy }
    if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { Fail 'the Scheduled Task is not running after the update' }
    $status = (Tp update status --json) | ConvertFrom-Json
    if ($status.installedBuild -ne 2 -or $status.installedVersion -ne '0.2.0') { Fail 'CLI is not 0.2.0 build 2 after the update' }
    Ok 'updated 0.1.0 build 1 -> 0.2.0 build 2; the task restarted the agent from versions\0.2.0-b2 via the launcher; previous kept'

    # --- state survived: Keep still wins, the Preview rule activates, pruning resumes ---
    if ((Tp explain (Join-Path $root 'keep.txt')) -notmatch '(?i)keep') { Fail 'Keep lost across the update' }
    if ((Tp rules list) -notmatch [regex]::Escape($rule)) { Fail 'rule lost across the update' }
    $rootsText = (Tp roots list).Replace('\', '/')
    if ($rootsText -notmatch [regex]::Escape($root.Replace('\', '/').TrimStart('/'))) { Fail "root lost across the update: $rootsText" }
    Tp rules activate $rule | Out-Null
    if ($script:rc -ne 0) { Fail 'rules activate' }
    WaitFor 60 'expired file trashed by the NEW agent' { -not (Test-Path (Join-Path $root 'old.txt')) }
    Start-Sleep -Seconds 2
    if (-not (Test-Path (Join-Path $root 'keep.txt'))) { Fail 'Keep item was trashed after the update' }
    Ok 'root, rule and Keep survived; the new agent prunes old.txt and still protects keep.txt'

    # --- Trash is blocked while an update holds the quiesce lease, and resumes after release ---
    # Control first: how long an unblocked due file takes to be trashed on this machine.
    $control = Join-Path $root 'control.txt'
    Set-Content $control 'control'
    (Get-Item $control).LastWriteTime = $longAgo
    $t0 = Get-Date
    WaitFor 90 'control file trashed (agent prunes new due files)' { -not (Test-Path $control) }
    $controlSeconds = [math]::Ceiling(((Get-Date) - $t0).TotalSeconds)
    $hold = [math]::Max(10, 3 * $controlSeconds)
    $q = (Tp update test-quiesce --token e2e-hold --seconds 120 --json) | ConvertFrom-Json
    if ($script:rc -ne 0 -or $q.phase -ne 'Quiesced') { Fail "agent did not quiesce: $($q | ConvertTo-Json -Compress)" }
    $held = Join-Path $root 'held.txt'
    Set-Content $held 'held'
    (Get-Item $held).LastWriteTime = $longAgo
    Start-Sleep -Seconds $hold
    if (-not (Test-Path $held)) { Fail "a due file was trashed while the agent was quiesced (waited ${hold}s; unblocked control took ${controlSeconds}s)" }
    $r = (Tp update test-release --token e2e-hold --json) | ConvertFrom-Json
    if ($script:rc -ne 0 -or $r.phase -ne 'Idle') { Fail "release: $($r | ConvertTo-Json -Compress)" }
    WaitFor 90 'held file trashed after the lease was released' { -not (Test-Path $held) }
    Ok "Trash blocked for ${hold}s while quiesced (unblocked control: ${controlSeconds}s), resumed after release"

    # --- replay / downgrade ---
    $out = Upd stale check --json
    if ($script:rc -ne 65 -or ($out | ConvertFrom-Json).code -ne 'feedRejected') { Fail "older signed feed accepted (rc=$($script:rc)): $out" }
    Ok 'replayed older (validly signed) feed refused'

    # --- a bad update (agent dies on start) must roll back ---
    $out = Upd bad check --json
    if (($out | ConvertFrom-Json).build -ne 3) { Fail "bad scenario check: $out" }
    $token = ($out | ConvertFrom-Json).confirmationToken
    $out = Upd bad install --confirm $token --json
    if ($script:rc -ne 70 -or ($out | ConvertFrom-Json).code -ne 'rolledBack') { Fail "bad update not rolled back (rc=$($script:rc)): $out" }
    if ((Cur) -ne '0.2.0-b2') { Fail "current after rollback: $(Cur)" }
    WaitFor 60 'rolled-back agent answers' { Healthy }
    WaitFor 30 'the rolled-back agent runs the good build via the launcher' { RunsFrom '0.2.0-b2' }
    if (Test-Path (Join-Path $data 'versions\0.3.0-b3')) { Fail 'failed build directory left behind' }
    $stages = @(DirNames (Join-Path $data 'versions') | Where-Object { $_ -like '.stage*' })
    if ($stages.Count -ne 0) { Fail "staging leftovers: $($stages -join ', ')" }
    if (((Tp update status --json) | ConvertFrom-Json).installedBuild -ne 2) { Fail 'installed build after rollback' }
    Ok 'bad build rolled back automatically; the build 2 agent runs again'

    # --- a build whose `--version` fails is refused before anything is touched ---
    $pidBefore = (AgentProcs)[0].ProcessId
    $out = Upd badversion check --json
    if (($out | ConvertFrom-Json).build -ne 4) { Fail "badversion check: $out" }
    $token = ($out | ConvertFrom-Json).confirmationToken
    $out = Upd badversion install --confirm $token --json
    if ($script:rc -ne 65 -or ($out | ConvertFrom-Json).code -ne 'packageRejected') { Fail "failing --version accepted (rc=$($script:rc)): $out" }
    if ((Cur) -ne '0.2.0-b2' -or (AgentProcs)[0].ProcessId -ne $pidBefore) { Fail 'a build with a failing --version disturbed the install' }
    if (Test-Path (Join-Path $data 'versions\0.4.0-b4')) { Fail 'rejected build placed in versions' }
    $stages = @(DirNames (Join-Path $data 'versions') | Where-Object { $_ -like '.stage*' })
    if ($stages.Count -ne 0) { Fail "staging leftovers: $($stages -join ', ')" }
    Ok 'a build with a failing --version is refused before the pointer or the agent is touched'

    # --- uninstall removes the task and the processes, even with the agent running ---
    & (Join-Path $script:oldPkg 'uninstall-managed.ps1') -Purge | Out-Null
    if ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { Fail 'task not removed by uninstall-managed' }
    WaitFor 30 'agent and launcher stopped' { -not (Get-Process -Name tinyprune-agentd, tinyprune-launcher -ErrorAction SilentlyContinue) }
    if (Test-Path -LiteralPath $data) { Fail 'purge left agent data behind' }
    if (-not (Test-Path -LiteralPath $root)) { Fail 'managed folder was touched by uninstall' }
    Ok 'uninstall-managed -Purge stopped the task, the launcher and the agent and removed the data'

    Cleanup
    Write-Host "UPDATE E2E PASSED ($script:checks checks)"
    exit 0
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Dump
    Cleanup
    exit 1
}
