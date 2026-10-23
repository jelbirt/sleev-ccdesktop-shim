# Native Windows (experimental)

For Claude Code Desktop sessions that run natively on Windows rather than in
WSL. Same idea as the WSL setup in the [main README](../README.md): a small
launcher stands in for each CLI binary the app installs, points the session at
the local Sleev gateway, and starts the real binary.

> **Experimental and not yet working end to end.** Every piece below was tested
> on its own, but no native session has yet run through Sleev, because the
> launcher is blocked by antivirus on the only machine tried so far (see
> [Antivirus](#antivirus)). Expect to need an exclusion.

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

On the test machine, McAfee quarantined the launcher the first time it ran
(detection "Real Protect-LS", a machine-learning verdict). Cut-down builds with
no network code at all were flagged too; a test program that starts nothing
was not. The trigger is what a launcher is: an unknown, unsigned exe that
starts another exe with a changed environment. Changing the code won't avoid
it.

- Compiling locally avoids SmartScreen, but not this.
- Windows Defender was not tested (it was passive on that machine).
- Windows 11 Smart App Control, if on, blocks unsigned exes outright.

To try it anyway, add an antivirus exclusion for `%LOCALAPPDATA%\sleev-shim`
and for the app's `claude-code` folder (path above). A code-signed build would
be the real fix.

## Requirements

- Claude Code Desktop running sessions natively on Windows.
- Sleev running and reachable at `http://127.0.0.1:17321` from Windows (Sleev
  inside WSL works under WSL's default localhost forwarding).
- Windows 10 or 11 with .NET Framework 4 (included).

## Install

From a normal PowerShell window (no admin needed), in a clone of this repo:

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```
Compiles the launcher into `%LOCALAPPDATA%\sleev-shim`, wraps the binaries
already installed, registers the `SleevCcdShim` logon task, and starts it. If
you downloaded a ZIP instead of cloning, run `Unblock-File windows\*` first.

Then fully quit Claude Desktop (tray icon, Quit) and reopen it, and check:

```powershell
powershell -ExecutionPolicy Bypass -File windows\sleev-status.ps1
```
Should report all binaries wrapped and 0 direct sessions.

## Uninstall

Fully quit Claude Desktop first, then:

```powershell
powershell -ExecutionPolicy Bypass -File windows\uninstall.ps1
```
Removes the task, puts every original `claude.exe` back, and deletes
`%LOCALAPPDATA%\sleev-shim`. It refuses to run while sessions are open,
because Windows won't delete a running exe.

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
- Logs: `%LOCALAPPDATA%\sleev-shim\shim-fallback.log`.
