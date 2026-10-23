# Quick check: is Claude Desktop actually routing native sessions through
# Sleev right now?

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'sleev-common.ps1')

$unwrapped = @(Get-UnwrappedFiles |
    ForEach-Object { $_.DirectoryName })
$wrapped = @(Get-WrappedDirs).Count
if ($wrapped + $unwrapped.Count -eq 0) {
    Write-Host 'BINARIES: none found (does Claude Desktop run sessions natively on this PC?)'
} elseif ($unwrapped.Count -eq 0) {
    Write-Host "BINARIES: all wrapped ($wrapped)"
} else {
    Write-Host ('BINARIES: UNWRAPPED: ' + ($unwrapped -join '; '))
}

$s = @(Get-Sessions)
$routed = @($s | Where-Object { $_.Kind -eq 'routed' }).Count
$direct = $s.Count - $routed
$note = if ($direct -gt 0) { '  <-- QUIT AND RELAUNCH THE APP' } else { '' }
Write-Host "SESSIONS: $routed via gateway, $direct direct$note"

Write-Host ('GATEWAY: ' + $(if (Test-GatewayUp) { "up at $GatewayUrl" } else { "UNREACHABLE at $GatewayUrl" }))

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Host ('WATCHER: ' + $(if ($task) { "scheduled task $($task.State)" } else { 'not installed' }))
