# Sleev for Claude Code Desktop, without 3P mode

Routes Claude Code Desktop sessions through a local Sleev gateway while the app
stays in normal (1P) mode, so Artifacts, Remote Control, cloud sessions and
claude.ai connectors keep working.

> **Unofficial.** A community setup, not an official Sleev product. It relies
> on undocumented Claude Desktop internals (the `ccd-cli` folder and how the
> app launches sessions), so any app update can break it.

**WSL first.** The setup below works when Claude Code Desktop runs its
sessions inside WSL. To check, run `ls ~/.claude/remote/ccd-cli` inside WSL: it
should list version-numbered files. If the folder doesn't exist, your sessions
run natively on Windows; see [windows/](windows/README.md) for an experimental
native version (antivirus currently blocks it on at least one setup).

**1M context is on by default.** The shim adds `[1m]` to every non-Haiku model
the app picks, which asks for the 1M-token context window instead of 200K. If
your plan doesn't include it, requests may fail, and on API billing long
prompts can cost more. To turn it off, see Notes.

## How it works

The Desktop app runs each session by exec'ing a CLI binary in
`~/.claude/remote/ccd-cli/`. `sleev-wrap-ccd-cli.sh` moves each binary to
`<name>.sleev-real` and puts a small bash shim in its place. The shim checks
that the gateway is up, sets `ANTHROPIC_BASE_URL` and the Sleev headers, adds
`[1m]` to the `--model` flag, then execs the real binary.

- `sleev-wrap-ccd.path` + `.timer`: re-wrap new binaries when the app updates
  (inotify, with a 45s timer as backstop).
- `sleev-check-sessions.timer`: every 20s, finds sessions that started before
  the wrap or while the gateway was down. Once a session is idle it kills it
  (the app respawns it through the shim on your next message) and shows a
  Windows toast.
- `sleev-status`: optional one-shot check (binaries wrapped? sessions routed?).

## App updates

When the app updates, it drops a new binary into `ccd-cli/` and restarts open
sessions on it within about 1 to 2.5 seconds. Any session that starts before
that binary is wrapped bypasses Sleev for its whole life. The setup handles
this in two layers.

**Wrap fast, so the race is rarely lost.**
- The `.path` watcher runs the wrapper as soon as the folder changes, with no
  polling delay. Its start rate limit is off, because an update fires a burst
  of file events that would otherwise trip the limit and stop the watcher.
- The "is the download finished" size check polls every 0.2s.
- The swap has no gap: the binary is hard-linked to `.sleev-real` first, then
  the shim is renamed over the original name. A session that spawns mid-swap
  gets either the binary or the shim, never a missing file.
- Binaries are found by what they are (ELF files), not by name, so a change
  in the app's version naming doesn't stop wrapping.
- The 45s timer re-runs the wrapper in case the watcher misses an event.

**Fix the sessions that lose anyway, without restarting the app.**
Every 20s the checker looks for sessions whose environment doesn't point at
the gateway. Once one is idle (last turn ended, nothing written for 10s, no
child processes or running subagents), and the gateway is up and every binary
is wrapped, it terminates that session and shows a Windows notification. The
app shows "Session was interrupted", and your next message respawns the
session through the shim; Sleev continues the same session. A session is
restarted at most once per 10 minutes, so it can't loop.

**Limits.** A session that loses the race runs direct until it next goes idle,
usually seconds, but a long busy turn stays unrouted until it finishes. The
`[1m]` tag is only added at spawn, so switching models mid-session from the
app's menu drops it.

## Requirements

- Claude Code Desktop running its sessions in **WSL** (or Linux). For native
  Windows sessions, see [windows/](windows/README.md).
- systemd enabled in WSL (`[boot] systemd=true` in `/etc/wsl.conf`), plus
  `loginctl enable-linger $USER`.
- Sleev installed and signed in **inside the same WSL distro**, gateway on
  `127.0.0.1:17321`. Under WSL's default networking, `127.0.0.1` inside WSL
  can't reach a gateway running on the Windows side, so every session would
  run direct.
- `curl` and `python3`.

Tested on Windows 11 with WSL2 Ubuntu 24.04, Claude Desktop 2.42304.0 and
Sleev 1.8.9.

## Install

Run these inside WSL:

```bash
git clone https://github.com/jelbirt/sleev-ccdesktop-shim && cd sleev-ccdesktop-shim
```
Downloads this repo and moves into it. The rest run from here.

```bash
install -D -m 755 -t ~/.local/bin sleev-wrap-ccd-cli.sh sleev-check-sessions.sh sleev-status
```
Copies the three scripts into `~/.local/bin` (creating it if needed) and makes
them executable. The systemd units expect them there.

```bash
install -D -m 644 -t ~/.config/systemd/user systemd/*
```
Puts the five unit files where systemd looks for your user's services, as
plain read-only files (systemd warns about unit files marked executable).

```bash
systemctl --user daemon-reload
```
Tells systemd to re-read that folder so it sees the new units.

```bash
systemctl --user enable --now sleev-wrap-ccd.path sleev-wrap-ccd.timer sleev-check-sessions.timer
```
Turns on the folder watcher and both timers. `enable` starts them at every
boot; `--now` also starts them right away. The two `.service` units are not
listed because the watcher and timers trigger them.

```bash
systemctl --user start sleev-wrap-ccd.service
```
Runs the wrapper now and waits for it to finish, so the binaries already on
disk are wrapped before you restart the app. If the timer already started it,
this just waits for that run.

Then fully quit Claude Desktop (tray icon, Quit) and reopen it, so every
session restarts through the shim. If you skip this, the checker restarts your
idle sessions within about 20s instead and shows a "missed a Claude update"
notification; that is expected the first time.

```bash
~/.local/bin/sleev-status
```
Should report all binaries wrapped and 0 direct sessions. (After your next
login, plain `sleev-status` works too.)

## Notes

- Edit the shim in `sleev-wrap-ccd-cli.sh` (the `SHIM_TEXT` block), never the
  files in `ccd-cli/`: the wrapper overwrites those within seconds.
- Different gateway port: change `GATEWAY_PORT` in the wrapper and `SLEEV_URL`
  in the checker.
- Don't want the 1M context tag? Delete the `tag_1m` block in `SHIM_TEXT` and
  end it with `exec "$0.sleev-real" "$@"`.
- The shim treats anything that answers on the gateway port as Sleev. Don't
  run anything else on that port: it would receive your Claude credentials.

## Uninstall

```bash
systemctl --user disable --now sleev-wrap-ccd.path sleev-wrap-ccd.timer sleev-check-sessions.timer
systemctl --user stop sleev-wrap-ccd.service sleev-check-sessions.service
```
Stops the watcher and timers, keeps them off after a reboot, and stops any run
already in progress. Do this first: anything still running re-wraps
everything within 45s.

```bash
cd ~/.claude/remote/ccd-cli && for r in *.sleev-real; do mv -f -- "$r" "${r%.sleev-real}"; done
```
Moves each original binary back over its shim.

```bash
rm ~/.local/bin/sleev-wrap-ccd-cli.sh ~/.local/bin/sleev-check-sessions.sh ~/.local/bin/sleev-status
rm ~/.config/systemd/user/sleev-wrap-ccd.* ~/.config/systemd/user/sleev-check-sessions.*
rm -f ~/.local/state/sleev/{wrap.lock,bypass-notified,bypass-killed,shim-fallback.log}
systemctl --user daemon-reload
```
Removes the scripts, unit files and this setup's state files. The rest of
`~/.local/state/sleev/` belongs to Sleev itself; leave it.

Then fully quit Claude Desktop and reopen it.

## Reporting problems

Open a GitHub issue with your Claude Desktop and Sleev versions, the output of
`~/.local/bin/sleev-status`, and the recent log:

```bash
journalctl --user -u sleev-wrap-ccd -u sleev-check-sessions --since "1 hour ago"
```

Look over the log before posting; it can include your username and paths.

## License

MIT. See [LICENSE](LICENSE).
