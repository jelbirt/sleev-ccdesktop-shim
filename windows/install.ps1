# Install the Sleev native-Windows shim: compile the launcher, wrap the CLI
# binaries now, and register a Scheduled Task that starts the watcher at logon.
# Run from a normal (non-admin) PowerShell.
#
# Re-runnable: it rebuilds the launcher, restarts the watcher, and refreshes
# the launcher in every wrapped folder that isn't in use.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sleev-common.ps1')

Write-Host "Installing the Sleev shim into $InstallDir"
# The markers folder is created here, not only by the launcher, in case the
# app's package would redirect a folder its child creates.
New-Item -ItemType Directory -Path $DirectDir -Force | Out-Null

# 1. Compile the launcher with the csc.exe that ships with .NET Framework 4
#    (present on every Windows 10/11; no toolchain to install).
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "csc.exe not found; install the .NET Framework 4 runtime." }
& $csc /nologo /optimize /target:exe "/out:$LauncherExe" (Join-Path $PSScriptRoot 'sleev-launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "launcher compile failed (exit $LASTEXITCODE)" }
Write-Host "Compiled $LauncherExe"

# 2. Stop a watcher left by an earlier install, so the new scripts take over.
#    Done after the compile, so a failed build leaves the old watcher running.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName }

# 3. Copy the watcher next to the launcher so the task runs from a stable
#    place, not this checkout.
foreach ($f in 'sleev-watch.ps1', 'sleev-common.ps1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $InstallDir -Force
}

# 4. Put the new launcher into folders wrapped by an earlier install. One that
#    a running session holds open is left as is; quitting Claude and re-running
#    this updates it.
# Replaced via a temp copy, never rewritten in place, so a session starting
# mid-update gets the old launcher or the new one, not a partial file.
$busy = 0
foreach ($dir in Get-WrappedDirs) {
    $tmp = Join-Path $dir 'claude.sleev-tmp.exe'
    try {
        Copy-Item -LiteralPath $LauncherExe -Destination $tmp -Force
        # [NullString]::Value, not $null: PowerShell passes $null to a string
        # parameter as "", which File.Replace rejects as a backup path.
        [IO.File]::Replace($tmp, (Join-Path $dir $LauncherName), [NullString]::Value)
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $busy++
    }
}
if ($busy) { Write-Host "$busy wrapped folder(s) are in use and keep the old launcher until you quit Claude and re-run this." }

# 5. Register (or refresh) the logon task. No time limit: by default a task is
#    stopped after 72 hours, which would silently end the watcher.
$watch = Join-Path $InstallDir 'sleev-watch.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watch`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Keeps Claude Desktop sessions routed through the local Sleev gateway.' -Force | Out-Null
Write-Host "Registered scheduled task '$TaskName' (starts at logon)."

# 6. Wrap what is installed now, then start the watcher for this login.
$env:SLEEV_WATCH_ONCE = '1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watch
Remove-Item Env:\SLEEV_WATCH_ONCE
Start-ScheduledTask -TaskName $TaskName

Write-Host ''
Write-Host 'Done. Fully quit Claude Desktop (tray icon, Quit) and reopen it, then check with:'
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'sleev-status.ps1')`""
