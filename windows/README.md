# Native Windows (experimental)

For Claude Code Desktop sessions that run natively on Windows rather than in
WSL. Same idea as the WSL setup in the [main README](../README.md): a small
launcher stands in for each CLI binary the app installs, points the session at
the local Sleev gateway, and starts the real binary.

> **Experimental.** Verified end to end on one machine (Windows Defender,
> 2026-10-23): a native Desktop session ran through Sleev. McAfee blocks the
> launcher, so third-party antivirus may need an exclusion (see
> [Antivirus](#antivirus)).

## Why a shim is needed

The app sets `ANTHROPIC_BASE_URL=https://api.anthropic.com` in every session's
environment, and that wins over the `env` block in
`%USERPROFILE%\.claude\settings.json` (tested October 2026: a native session
set to the gateway in `settings.json` still reported the Anthropic URL). A
Windows user environment variable would be overwritten the same way. So, as in
WSL, the only place to change it is the process the app launches.

## How it works

Native 1P sessions run
`%LOCALAPPDATA%\Claude-Data\<package>\claude-code\<version>\<build>\claude.exe`
(3P installs use `%LOCALAPPDATA%\Claude-3p\claude-code\<version>\claude.exe`).

- `sleev-launcher.cs`: a ~10KB C# program, compiled on your PC by the installer
  with the `csc.exe` that ships with Windows. It probes the gateway, sets
  `ANTHROPIC_BASE_URL` and the Sleev headers, adds `[1m]` to `--model` (except
  Haiku), and runs `claude.sleev-real.exe` beside it with the same stdio. The
  real binary runs in a Job Object, so it dies with the launcher, and its exit
  code is passed back. If the gateway is down it runs direct, logs it, and
  leaves a marker so the watcher can reconnect the session later.
- `sleev-watch.ps1`: a hidden PowerShell loop that a Scheduled Task starts at
  logon. Every 5s it wraps any new `claude.exe` (moving the original to
  `claude.sleev-real.exe` in one `File.Replace` call, so the app never finds
  the file missing), and finds sessions that run outside Sleev. Windows can't
  read another process's environment, so those are spotted by parentage: the
  real binary started by the app itself, or a gateway-down fallback. Once one is
  idle (same transcript rules as the WSL checker), it stops it and shows a
  toast; your next message respawns it through the launcher.
- `sleev-status.ps1`: one-shot check of binaries, sessions, gateway and watcher.
- `install.ps1`, `uninstall.ps1`.

The app doesn't hash `claude.exe` before starting it (it checks only that the
file exists and that a `.verified` marker matches its manifest), so swapping
the file doesn't trigger a re-download.

## Antivirus

With McAfee active, it quarantined the launcher the first time it ran
(detection "Real Protect-LS", a machine-learning verdict). Cut-down builds with
no network code at all were flagged too; a test program that starts nothing
was not. The trigger is what a launcher is: an unknown, unsigned exe that
starts another exe with a changed environment. Changing the code won't avoid
it.

- Compiling locally avoids SmartScreen, but not this.
- Windows Defender allowed it (tested 2026-10-23, real-time protection on).
- Windows 11 Smart App Control, if on, blocks unsigned exes outright.

If your antivirus blocks it, add an exclusion for `%LOCALAPPDATA%\sleev-shim`
and for the app's `claude-code` folder (path above), then run
`windows\install.ps1` again so the launcher is rebuilt and put back. A
code-signed build would be the real fix.

## Requirements

- Claude Code Desktop running sessions natively on Windows.
- Sleev running and reachable at `http://127.0.0.1:17321` from Windows (Sleev
  inside WSL works under WSL's default localhost forwarding). If Sleev runs in
  WSL, the distro has to be running: after a reboot, sessions run direct until
  you open WSL and Sleev starts. They are reconnected once idle after that.
- Windows 10 or 11 with .NET Framework 4 (included).

## Install

From a normal PowerShell window (no admin needed), in a clone of this repo:

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```
Compiles the launcher into `%LOCALAPPDATA%\sleev-shim`, wraps the binaries
already installed, registers the `SleevCcdShim` logon task, and starts it. If
you downloaded a ZIP instead of cloning, run `Unblock-File windows\*` first.

Sessions you start from then on go through Sleev. Sessions already open keep
running direct until the watcher reconnects them once idle; to switch them at
once, fully quit Claude Desktop (tray icon, Quit) and reopen it. Then check:

```powershell
powershell -ExecutionPolicy Bypass -File windows\sleev-status.ps1
```
With one session open, a healthy setup looks like:

```
BINARIES: all wrapped (3)
SESSIONS: 1 via gateway, 0 direct
GATEWAY: up at http://127.0.0.1:17321
WATCHER: scheduled task Running
```

## Updating the shim

Fully quit Claude Desktop, `git pull`, then run `windows\install.ps1` again.
It recompiles the launcher and replaces it in every wrapped folder. A folder
still in use keeps the old launcher (the installer says how many); quit Claude
and re-run it to finish.

## Uninstall

Fully quit Claude Desktop first, then:

```powershell
powershell -ExecutionPolicy Bypass -File windows\uninstall.ps1
```
Removes the task, puts every original `claude.exe` back, and deletes
`%LOCALAPPDATA%\sleev-shim`. It refuses to run while sessions are open,
because Windows won't delete a running exe. Keep your clone (or unzipped folder):
the uninstaller lives there, not in the install folder. If you deleted it,
download the repo again and run this.

## Notes

- Different gateway port: change `GatewayUrl` in `sleev-launcher.cs` and
  `$GatewayPort` in `sleev-common.ps1`, then fully quit Claude Desktop and run
  `install.ps1` again (see Updating the shim).
- Don't want the 1M context tag? In `sleev-launcher.cs`, replace
  `TagModel(ArgsAfterProgramName(Environment.CommandLine))` with
  `ArgsAfterProgramName(Environment.CommandLine)`, then fully quit Claude
  Desktop and run `install.ps1` again.
- App updates need nothing from you: the watcher wraps a new version within
  5s and reconnects any session that started before that once it is idle.
- The launcher treats anything that answers on the gateway port as Sleev.
  Don't run anything else on that port: it would receive your Claude
  credentials.

## Troubleshooting

Run `windows\sleev-status.ps1` first.

- `GATEWAY: UNREACHABLE`: Sleev isn't running, or (if it lives in WSL) WSL
  isn't. Start it; direct sessions are reconnected once idle.
- `BINARIES: UNWRAPPED`: the watcher isn't running or can't replace the file.
  If `WATCHER` isn't `Running`, run `install.ps1` again. Otherwise check the
  log for `wrap failed` or `launcher missing` (see
  [Antivirus](#antivirus)).
- `SESSIONS: ... N direct` for more than a minute with the gateway up and
  `BINARIES: all wrapped`: those
  sessions are busy or can't be restarted (see Limits). Fully quit and reopen
  Claude Desktop to switch them.

The log is `%LOCALAPPDATA%\sleev-shim\shim-fallback.log`. Lines to look for:
`gateway unreachable ... running DIRECT` (a session started while Sleev was
down), `launcher missing ... (antivirus?)` (see [Antivirus](#antivirus)),
`wrap failed` and `could not start`.

To report a problem, open a GitHub issue with your Windows, Claude Desktop and
Sleev versions, your antivirus, the `sleev-status.ps1` output, and the last 50
log lines:

```powershell
Get-Content "$env:LOCALAPPDATA\sleev-shim\shim-fallback.log" -Tail 50
```
Look it over before posting; it includes your username in paths.

## Limits

- Sessions that start before a new version is wrapped (up to 5s after an app
  update) run direct until the watcher restarts them once idle.
- The watcher restarts a session only if its command line carries `--resume`,
  its transcript shows an ended turn, and it has no child processes (a running
  shell, background command or stdio MCP server keeps it alive). Otherwise it
  leaves it alone and `sleev-status.ps1` reports it as direct.
- The `[1m]` tag is added only at spawn; switching models from the app's menu
  drops it.
- If antivirus removes a launcher, the watcher puts the original back so
  sessions in that folder still start (direct, untracked), shows a toast, and
  leaves that folder alone until the next logon or install. Until then it
  also stops reconnecting any session outside Sleev (bypassed or
  gateway-down), since a restarted
  session could land on that unwrapped version.
- Untested: wrapping a version while a session is running from it. The
  watcher tries `File.Replace` first and falls back to rename-then-copy.
- 3P installs (`Claude-3p`) are wrapped too but untested. The launcher sets
  its own gateway URL, so it replaces any custom gateway URL and headers the 3P setup uses.
- Untested on Windows 10 and on ARM PCs.

Tested on Windows 11 with Claude Desktop 3.6556.2.0 (CLI 2.1.304 and 2.1.308),
Windows PowerShell 5.1 and Windows Defender, October 2026.
