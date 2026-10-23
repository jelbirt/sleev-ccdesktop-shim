# Remove the Sleev native-Windows shim: stop the watcher, put every original
# CLI binary back as claude.exe, and delete the install folder.
#
# Quit Claude Desktop first: a running session holds its launcher open, and
# Windows won't delete a running exe.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sleev-common.ps1')

$open = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and (Test-IsCliPath $_.ExecutablePath) })
if ($open.Count -gt 0) {
    throw "$($open.Count) Claude session process(es) are still running. Fully quit Claude Desktop (tray icon, Quit), then run this again."
}

# 1. Stop and remove the scheduled task, so nothing re-wraps behind us.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
}

# 2. Unwrap: replace each launcher with the original it stood in for.
$restored = 0; $failed = 0
foreach ($r in Get-CliFiles $RealName) {
    $dir = $r.DirectoryName
    try {
        Remove-Item -LiteralPath (Join-Path $dir $LauncherName) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $dir 'claude.sleev-tmp.exe') -Force -ErrorAction SilentlyContinue
        Rename-Item -LiteralPath $r.FullName -NewName $LauncherName
        $restored++
    } catch {
        Write-Host "Could not restore $dir : $($_.Exception.Message)"
        $failed++
    }
}
Write-Host "Restored $restored CLI binary(ies)."
# Originals a re-wrap moved aside and the watcher had not deleted yet.
Get-CliFiles 'claude.sleev-old-*.exe' | Remove-Item -Force -ErrorAction SilentlyContinue

# 3. Remove the launcher, watcher scripts, log and markers. Kept if anything
#    failed above, so the log is still there to look at.
if ($failed -eq 0) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $InstallDir."
}
Write-Host 'Uninstall complete. You can reopen Claude Desktop.'
