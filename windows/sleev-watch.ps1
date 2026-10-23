# Sleev native-Windows watcher: keep every claude.exe the Desktop app installs
# wrapped with the Sleev launcher, and reconnect sessions that slipped past it.
#
# Started hidden at logon by a Scheduled Task (see install.ps1). One polling
# loop does the job the WSL version splits across a .path unit, a timer and a
# checker; a FileSystemWatcher would add failure modes for no real gain.
#
# Test knobs: SLEEV_WATCH_ONCE=N (N passes, then exit), SLEEV_WATCH_INTERVAL
# (poll seconds), SLEEV_CHECK_DRY_RUN=1 (report, never stop a session),
# SLEEV_PROJECTS_DIR (transcripts folder), plus SLEEV_APPDATA_DIR from
# sleev-common.ps1.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sleev-common.ps1')

$Interval     = if ($env:SLEEV_WATCH_INTERVAL) { [int]$env:SLEEV_WATCH_INTERVAL } else { 5 }
$DryRun       = $env:SLEEV_CHECK_DRY_RUN -eq '1'
$Projects     = if ($env:SLEEV_PROJECTS_DIR) { $env:SLEEV_PROJECTS_DIR } else { Join-Path $env:USERPROFILE '.claude\projects' }
$IdleSecs     = 10    # transcript must be this quiet before a stop
$KillCooldown = 600   # never stop the same session twice within this window
$script:killed = @{}  # resume id (or pid) -> last stop time
$script:failed = @{}  # folder -> error already logged, so a stuck one logs once

$script:skip   = @{}  # folders whose launcher antivirus removed; left unwrapped until restart
$script:missing = @{} # folders whose launcher was missing on the last pass
$script:logged = @{}  # "pid reason" lines already logged, so a waiting session logs once

# Swap the launcher in for a real claude.exe. File.Replace moves the original to
# claude.sleev-real.exe and puts the launcher in place in one call, so a session
# spawning mid-swap never finds claude.exe missing. If Windows refuses that for
# a running image, fall back to rename-then-copy (renaming a running exe is
# allowed), which leaves claude.exe missing for a moment.
function Invoke-Swap([string]$dir) {
    $exe  = Join-Path $dir $LauncherName
    $real = Join-Path $dir $RealName
    $tmp  = Join-Path $dir 'claude.sleev-tmp.exe'
    Copy-Item -LiteralPath $LauncherExe -Destination $tmp -Force
    try {
        [IO.File]::Replace($tmp, $exe, $real)
    } catch {
        Rename-Item -LiteralPath $exe -NewName $RealName
        Move-Item -LiteralPath $tmp -Destination $exe -Force
    }
}

function Invoke-WrapPass {
    # Make sure the markers folder exists. A folder created by the launcher
    # would be one the app's package redirects into its private store, where
    # this watcher can't see it; files the launcher adds to an existing real
    # folder are not redirected (tested 2026-10-23).
    New-Item -ItemType Directory -Path $DirectDir -Force | Out-Null
    foreach ($f in Get-CliFiles $LauncherName) {
        $dir  = $f.DirectoryName
        $real = Join-Path $dir $RealName
        if ($script:skip[$dir]) { continue }
        try {
            if (Test-IsLauncher $f) {
                if (Test-Path -LiteralPath $real) { continue }   # wrapped
                # A launcher whose original is gone. The app writes new
                # binaries to a temp name and renames them into place, so a
                # small claude.exe is never a half-finished download. Remove it
                # so the app re-downloads that version cleanly if it needs it.
                Remove-Item -LiteralPath $f.FullName -Force
                Write-ShimLog "removed stray launcher in $dir (original gone)"
            } elseif (Test-IsRealCli $f) {
                if (Test-Path -LiteralPath $real) {
                    # The app re-downloaded a version we had wrapped. The old
                    # original may still be running, so move it aside rather
                    # than delete it; it is cleaned up once nothing uses it.
                    Rename-Item -LiteralPath $real -NewName "claude.sleev-old-$([DateTime]::Now.Ticks).exe"
                }
                Invoke-Swap $dir
                Write-ShimLog "wrapped $dir"
            }   # else a small claude.exe that isn't ours: leave it alone
            $script:failed.Remove($dir)
        } catch {
            if (-not $script:failed[$dir]) { Write-ShimLog "wrap failed for $dir : $($_.Exception.Message)" }
            $script:failed[$dir] = $true
        }
    }
    foreach ($r in Get-CliFiles $RealName) {
        $dir = $r.DirectoryName
        if (Test-Path -LiteralPath (Join-Path $dir $LauncherName)) { $script:missing.Remove($dir); continue }
        # The original with no claude.exe beside it: antivirus removed the
        # launcher, so every session here would fail to start. Put the original
        # back so they run direct, and stop wrapping this folder until the
        # watcher restarts (re-wrapping would just be removed again). Only once
        # it has been missing for two passes in a row, so a claude.exe the app
        # is replacing at that moment isn't taken for antivirus.
        if (-not $script:missing[$dir]) { $script:missing[$dir] = $true; continue }
        $script:missing.Remove($dir)
        try {
            Rename-Item -LiteralPath $r.FullName -NewName $LauncherName
            $script:skip[$dir] = $true
            Write-ShimLog "launcher missing in $dir (antivirus?); restored the original, sessions here run direct"
            Show-Toast 'Sleev: launcher was removed' 'Probably your antivirus. Sessions run direct (not tracked) until you add an exclusion; see the README.'
        } catch {
            if (-not $script:failed[$dir]) { Write-ShimLog "restore failed for $dir : $($_.Exception.Message)" }
            $script:failed[$dir] = $true
        }
    }
    # Originals moved aside by a re-wrap; deleting fails while one still runs.
    foreach ($o in Get-CliFiles 'claude.sleev-old-*.exe') {
        Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-ResumeId($proc) {
    if ($proc.CommandLine -match '--resume[= ]"?([0-9a-f-]+)') { return $Matches[1] }
    return $null
}

# Idle means the transcript's last turn ended (or was interrupted) and nothing
# has been written for IdleSecs, with no child processes (Bash tool shells and
# background commands live there) and no subagent transcript newer than the
# session's own. Anything else, including no --resume or no transcript, counts
# as busy; we never guess. Same rules as the WSL checker.
function Test-SessionIdle($proc) {
    # A console program's conhost.exe shows up as its child; that isn't work.
    $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.ProcessId)" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin 'conhost.exe', 'OpenConsole.exe' }
    if ($kids) { return $false }
    $id = Get-ResumeId $proc
    if (-not $id) { return $false }
    $f = Get-ChildItem -Path (Join-Path $Projects "*\$id.jsonl") -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $f) { return $false }
    # Asked of the file itself: the time in a directory listing can lag behind
    # for a file the CLI still has open.
    $written = [IO.File]::GetLastWriteTime($f.FullName)
    $sub = Get-ChildItem -Path (Join-Path $f.DirectoryName "$id\subagents\*.jsonl") -File -ErrorAction SilentlyContinue |
        Where-Object { [IO.File]::GetLastWriteTime($_.FullName) -gt $written }
    if ($sub) { return $false }
    if (((Get-Date) - $written).TotalSeconds -lt $IdleSecs) { return $false }

    $last = $null
    foreach ($line in (Get-Content -LiteralPath $f.FullName -Tail 50 -Encoding UTF8)) {
        try { $d = $line | ConvertFrom-Json } catch { continue }
        if ($d.type -eq 'user' -or $d.type -eq 'assistant') { $last = $d }
    }
    if (-not $last) { return $false }
    if ($last.type -eq 'assistant') { return $last.message.stop_reason -in 'end_turn', 'stop_sequence' }
    $c = $last.message.content
    $text = if ($c -is [string]) { $c } else { ($c | ForEach-Object { $_.text }) -join ' ' }
    return $text.StartsWith('[Request interrupted by user')
}

# Log a waiting session once per reason, not on every pass.
function Write-WaitLog([string]$key, [string]$msg) {
    if ($script:logged[$key]) { return }
    $script:logged[$key] = $true
    Write-ShimLog $msg
}

# Still the same process we listed (guards against pid reuse), still unrouted.
function Test-SameSession($p, [string]$kind) {
    $q = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)" -ErrorAction SilentlyContinue
    if (-not $q -or $q.CreationDate -ne $p.CreationDate -or $q.Name -ne $p.Name -or $q.ExecutablePath -ne $p.ExecutablePath) { return $false }
    if ($kind -eq 'bypassed') {
        $real = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.ProcessId)" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $RealName }
        if ($real) { return $false }
    }
    return $true
}

function Invoke-CheckPass {
    Remove-StaleMarkers
    $now = Get-Date
    foreach ($k in @($script:killed.Keys)) {
        if (($now - $script:killed[$k]).TotalSeconds -ge $KillCooldown) { $script:killed.Remove($k) }
    }
    $missed = @(Get-Sessions | Where-Object { $_.Kind -ne 'routed' })
    if ($missed.Count -eq 0) { $script:logged = @{}; return }
    # A stopped session respawns on whatever version the app picks; only stop
    # when the gateway is up and every binary is wrapped, so it comes back routed.
    $unwrapped = @(Get-UnwrappedFiles)
    $canStop = (Test-GatewayUp) -and $unwrapped.Count -eq 0
    $stopped = 0
    foreach ($s in $missed) {
        $p = $s.Process
        $key = Get-ResumeId $p; if (-not $key) { $key = "pid $($p.ProcessId)" }
        $what = "pid $($p.ProcessId) $($s.Kind)"
        if (-not $canStop) { Write-WaitLog "$($p.ProcessId) down" "${what}: gateway down or unwrapped version, waiting"; continue }
        if ($script:killed.ContainsKey($key)) { Write-WaitLog "$($p.ProcessId) cooldown" "${what}: already restarted once recently, waiting"; continue }
        if (-not (Test-SessionIdle $p)) { continue }
        if (-not (Test-SameSession $p $s.Kind)) { continue }   # exited or replaced since we listed it
        if ($DryRun) { Write-ShimLog "${what}: idle, would stop"; $stopped++; continue }
        try {
            # For a fallback this stops claude.sleev-real.exe; its launcher then
            # exits too, and the app respawns the session through a fresh one.
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $script:killed[$key] = $now
            Write-ShimLog "${what}: idle, stopped (the app respawns it through the launcher)"
            $stopped++
        } catch {
            Write-ShimLog "${what}: stop failed: $($_.Exception.Message)"
        }
    }
    if ($stopped -gt 0 -and -not $DryRun) {
        $n = if ($stopped -eq 1) { '1 Claude session' } else { "$stopped Claude sessions" }
        Show-Toast "Sleev: reconnected $n" 'Ignore the Session was interrupted note and keep typing; your next message goes through Sleev.'
    }
}

function Show-Toast([string]$title, [string]$body) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $x.GetElementsByTagName('text')
        $t.Item(0).AppendChild($x.CreateTextNode($title)) | Out-Null
        $t.Item(1).AppendChild($x.CreateTextNode($body)) | Out-Null
        $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($x))
    } catch { }
}

# One instance at a time: a manual run and the scheduled task could overlap,
# and two wrap passes racing on the same binary could lose the original.
$mutex = New-Object System.Threading.Mutex($false, 'Local\SleevCcdShimWatch')
if (-not $mutex.WaitOne(0)) { Write-ShimLog 'another watcher holds the lock; exiting'; return }
try {
    if ($env:SLEEV_WATCH_ONCE) {
        for ($n = [int]$env:SLEEV_WATCH_ONCE; $n -gt 0; $n--) { Invoke-WrapPass; Invoke-CheckPass }
    } else {
        Write-ShimLog "watcher started (interval ${Interval}s)"
        while ($true) {
            try { Invoke-WrapPass; Invoke-CheckPass } catch { Write-ShimLog "pass failed: $($_.Exception.Message)" }
            Start-Sleep -Seconds $Interval
        }
    }
} finally {
    $mutex.ReleaseMutex()
}
