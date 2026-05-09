# Scheduling hoist

Hoist is meant to run periodically. The recommended way to set that up is the
built-in subcommand:

```bash
hoist --cron install
```

This auto-detects the available scheduler and walks you through the prompts.
The rest of this document is a reference for what `--cron install` actually
writes, plus a manual setup recipe for macOS (which `--cron` does not install
automatically).

---

## `hoist --cron` cheat sheet

| Command | What it does |
|---|---|
| `hoist --cron` | Interactive menu (install / remove / print / status / cancel) |
| `hoist --cron install` | Detect scheduler, prompt, write files, enable |
| `hoist --cron install --schedule hourly --user root --backend cron` | Fully non-interactive install |
| `hoist --cron remove` | Uninstall hoist-managed schedule (idempotent) |
| `hoist --cron print` | Print files that *would* be written (no changes) |
| `hoist --cron status` | Show what's currently installed; exit 1 if nothing |
| `hoist --cron install --dry-run` | Show planned writes without touching disk |

### Schedule presets

| Preset | cron expression | systemd `OnCalendar` |
|---|---|---|
| `30min` | `*/30 * * * *` | `*:0/30` |
| `hourly` | `0 * * * *` | `hourly` |
| `6hourly` | `0 */6 * * *` | `0/6:00:00` |
| `daily` | `0 3 * * *` | `*-*-* 03:00:00` |
| `weekly` | `0 3 * * 0` | `Sun *-*-* 03:00:00` |

You can also pass any raw cron expression (5 fields) or systemd `OnCalendar`
value via `--schedule`.

### Safety guarantees

- All managed files start with a `# Managed by hoist --cron install` marker.
  Hoist refuses to overwrite a file at the same path without it.
- Re-running `--cron install` silently replaces the previous managed file.
- Writes are gated by `sudo` only when the target isn't writable as the current
  user.
- `--user` is validated via `getent passwd`; non-root users not in the `docker`
  group get a warning (still installs — useful for rootless docker setups).

---

## Linux: cron

`hoist --cron install --backend cron` writes `/etc/cron.d/hoist`:

```
# Managed by hoist --cron install — do not edit; re-run `hoist --cron install` to change.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 * * * * root /usr/local/bin/hoist >> /var/log/hoist.log 2>&1
```

Logs go to `/var/log/hoist.log`. Tail it with:

```bash
sudo tail -f /var/log/hoist.log
```

---

## Linux: systemd timer

`hoist --cron install --backend systemd` writes two units in
`/etc/systemd/system/`, runs `daemon-reload`, then `enable --now hoist.timer`.

`hoist.service`:

```ini
# Managed by hoist --cron install — do not edit; re-run `hoist --cron install` to change.
[Unit]
Description=Hoist — auto-update Docker containers via labels
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/hoist
```

`hoist.timer`:

```ini
# Managed by hoist --cron install — do not edit; re-run `hoist --cron install` to change.
[Unit]
Description=Run hoist on schedule

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

Inspect with:

```bash
systemctl list-timers hoist.timer
systemctl status hoist.service
journalctl -u hoist.service
```

---

## macOS: launchd

`hoist --cron` does not install on macOS — Apple plist conventions vary across
OS versions and the resulting file is too easy to get subtly wrong from a
generator. Drop a plist in place yourself:

`~/Library/LaunchAgents/com.sumguy.hoist.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sumguy.hoist</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/bash</string>
        <string>/usr/local/bin/hoist</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <key>StandardOutPath</key>
    <string>/tmp/hoist.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/hoist.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
```

Adjust paths for your install (Apple Silicon: `/opt/homebrew/bin/bash`;
Intel: `/usr/local/bin/bash`). Hoist requires bash 4+ — the system bash 3.2 will
not work, so install one with `brew install bash` and point the plist at it.

Load and enable:

```bash
launchctl load -w ~/Library/LaunchAgents/com.sumguy.hoist.plist
```

Check it ran:

```bash
launchctl list | grep hoist
tail -f /tmp/hoist.log
```

Remove:

```bash
launchctl unload -w ~/Library/LaunchAgents/com.sumguy.hoist.plist
rm ~/Library/LaunchAgents/com.sumguy.hoist.plist
```
