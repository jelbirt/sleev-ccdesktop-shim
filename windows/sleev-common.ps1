# Shared settings and helpers for the Sleev native-Windows shim.
# Dot-sourced by sleev-watch.ps1, sleev-status.ps1, install.ps1, uninstall.ps1.
#
# Test knobs: SLEEV_APPDATA_DIR stands in for %LOCALAPPDATA% when looking for
# the app's CLI binaries, and SLEEV_INSTALL_DIR for the install folder, so the
# scripts can run against a scratch tree.

$GatewayPort = 17321
$GatewayUrl  = "http://127.0.0.1:$GatewayPort"

# Where the shim keeps the compiled launcher, its log, and the per-pid "direct"
# markers the launcher drops when it had to run without the gateway. The
# launcher hardcodes the same folder; keep the two in sync.
$InstallDir  = if ($env:SLEEV_INSTALL_DIR) { $env:SLEEV_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'sleev-shim' }
$LauncherExe = Join-Path $InstallDir 'sleev-launcher.exe'
$LogFile     = Join-Path $InstallDir 'shim-fallback.log'
$DirectDir   = Join-Path $InstallDir 'direct'
$TaskName    = 'SleevCcdShim'

$AppDataDir   = if ($env:SLEEV_APPDATA_DIR) { $env:SLEEV_APPDATA_DIR } else { $env:LOCALAPPDATA }
$RealName     = 'claude.sleev-real.exe'  # the renamed original CLI binary
$LauncherName = 'claude.exe'             # what the app launches; we replace it
$RealMinBytes = 50MB                     # the real CLI is ~260MB
$LauncherMaxAge = 15                     # secs; longer than the launcher's worst-case gateway probe

# The app's CLI folders: Claude-3p\claude-code (3P) and
# Claude-Data\<package>\claude-code (1P, MSIX). Only these are searched, never
# the whole data folder, which holds large browser caches.
function Get-ClaudeCodeDirs {
    Get-ChildItem -LiteralPath $AppDataDir -Directory -Filter 'Claude*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Join-Path $_.FullName 'claude-code'
            Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'claude-code' }
        } | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
}

# Every file with the given name under those folders, at any depth (the 1P
# layout adds a build folder under each version). Matched by location, never
# by version name, so an app rename can't blind this the way it once blinded
# the WSL port.
function Get-CliFiles([string]$name) {
    foreach ($d in Get-ClaudeCodeDirs) {
        Get-ChildItem -LiteralPath $d -Recurse -File -Filter $name -ErrorAction SilentlyContinue
    }
}

function Test-IsCliPath([string]$path) { return $path -match '\\claude-code\\' }

# Our launcher is recognised by its product name, never by size alone, so a
# small file the app might ship is left alone rather than deleted. The real
# CLI is any other claude.exe big enough to be one.
function Test-IsLauncher($file) { return $file.VersionInfo.ProductName -eq 'sleev-launcher' }
function Test-IsRealCli($file) { return -not (Test-IsLauncher $file) -and $file.Length -gt $RealMinBytes }
function Get-UnwrappedFiles { Get-CliFiles $LauncherName | Where-Object { Test-IsRealCli $_ } }
# Wrapped means the folder has the original aside and a launcher in its place.
function Get-WrappedDirs {
    foreach ($r in Get-CliFiles $RealName) {
        $l = Get-Item -LiteralPath (Join-Path $r.DirectoryName $LauncherName) -ErrorAction SilentlyContinue
        if ($l -and (Test-IsLauncher $l)) { $r.DirectoryName }
    }
}

function Test-GatewayUp {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Invoke-WebRequest -Uri "$GatewayUrl/" -TimeoutSec 3 -UseBasicParsing | Out-Null
            return $true
        } catch {
            # Any HTTP answer, even an error status, means it is listening.
            if ($_.Exception.Response) { return $true }
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Write-ShimLog([string]$msg) {
    try {
        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format s) + ' ' + $msg)
    } catch { }
}

# Session processes, classified. Another process's environment can't be read
# on Windows, so routing is judged by image name and parentage instead:
#   routed   : claude.sleev-real.exe started by our launcher, with no "direct"
#              marker (the launcher writes one when the gateway was down)
#   fallback : claude.sleev-real.exe with a "direct" marker written after it
#              started (an older marker belongs to an earlier owner of the pid)
#   bypassed : the real CLI as claude.exe, started by the app itself: it began
#              before its version was wrapped
# Our launcher is also a claude.exe started by the app; it is told apart by
# having a claude.sleev-real.exe child, or by being younger than
# LauncherMaxAge (still probing the gateway, no child yet). The app is
# identified by its path, which is outside claude-code, so its own exe name
# doesn't matter.
function Get-Sessions {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $byPid = @{}; foreach ($p in $procs) { $byPid[[int]$p.ProcessId] = $p }
    $all = @($procs | Where-Object { $_.Name -eq $LauncherName -or $_.Name -eq $RealName })
    $hasRealChild = @{}
    foreach ($p in $all) { if ($p.Name -eq $RealName) { $hasRealChild[[int]$p.ParentProcessId] = $true } }
    $markers = @{}
    Get-ChildItem -LiteralPath $DirectDir -File -ErrorAction SilentlyContinue | ForEach-Object { $markers[$_.Name] = $_ }
    $now = Get-Date

    foreach ($p in $all) {
        if (-not (Test-IsCliPath $p.ExecutablePath)) { continue }
        $parent = $byPid[[int]$p.ParentProcessId]
        # A parent newer than its child is a reused pid, not the real parent.
        if ($parent -and $parent.CreationDate -gt $p.CreationDate) { $parent = $null }
        if ($p.Name -eq $RealName) {
            $m = $markers[[string]$p.ProcessId]
            $kind = if ($m -and $m.LastWriteTime -ge $p.CreationDate) { 'fallback' } else { 'routed' }
        } elseif ($parent -and -not (Test-IsCliPath $parent.ExecutablePath) -and -not $hasRealChild[[int]$p.ProcessId] `
                -and ($now - $p.CreationDate).TotalSeconds -gt $LauncherMaxAge) {
            $kind = 'bypassed'
        } else {
            continue   # our launcher, or a session's own helper process
        }
        [pscustomobject]@{ Kind = $kind; Process = $p }
    }
}

# Markers whose pid is gone, or now belongs to a process started after the
# marker was written. The launcher deletes its own marker when the session
# ends; this catches a launcher that was killed first.
function Remove-StaleMarkers {
    Get-ChildItem -LiteralPath $DirectDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$_.Name)" -ErrorAction SilentlyContinue
        if (-not $p -or $p.CreationDate -gt $_.LastWriteTime) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
