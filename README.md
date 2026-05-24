# hoist

Automatically update or notify about Docker Compose container image updates.

Hoist runs against all running containers, checks for newer images, and either recreates the container or fires a notification — all controlled by Docker labels.

Inspired by [pullio](https://github.com/hotio/pullio). Existing `org.hotio.pullio.*` labels are supported as-is — no migration required. The `com.sumguy.hoist.*` prefix takes precedence if both are present.

## Configuration

Copy `hoist.conf.example` to one of the following locations (first found wins):

1. `$HOIST_CONFIG` — explicit path via environment variable
2. Same directory as `hoist.sh` — portable/dev installs
3. `/etc/hoist/hoist.conf` — system installs

CLI flags always override config file values.

| Setting | Default | Description |
|---|---|---|
| `PARALLEL` | `1` | Containers to process concurrently |
| `CACHE_LOCATION` | `/tmp` | Directory for notification dedup cache files |
| `DOCKER_BINARY` | `$(which docker)` | Path to docker binary |
| `PRUNE_IMAGES` | `true` | Prune dangling images after each run |
| `LOG_FILE` | _(none)_ | Append log output to this file (in addition to stdout) |
| `TAG` | _(none)_ | Default tag filter (same as `--tag`) |
| `GLOBAL_DISCORD_WEBHOOK` | _(none)_ | Fallback Discord webhook for containers without a per-container label |
| `GLOBAL_SLACK_WEBHOOK` | _(none)_ | Fallback Slack webhook |
| `GLOBAL_GENERIC_WEBHOOK` | _(none)_ | Fallback generic webhook |
| `GLOBAL_TELEGRAM_BOT_TOKEN` / `GLOBAL_TELEGRAM_CHAT_ID` | _(none)_ | Fallback Telegram bot credentials |
| `GLOBAL_GOTIFY_URL` | _(none)_ | Fallback Gotify message URL (`?token=` in URL) |
| `GLOBAL_NTFY_URL` / `GLOBAL_NTFY_TOKEN` | _(none)_ | Fallback ntfy.sh topic URL and optional bearer token |
| `GLOBAL_TEAMS_WEBHOOK` | _(none)_ | Fallback Microsoft Teams incoming webhook |
| `GLOBAL_MATRIX_HOMESERVER` / `GLOBAL_MATRIX_ROOM_ID` / `GLOBAL_MATRIX_TOKEN` | _(none)_ | Fallback Matrix room credentials |
| `HEALTHCHECKS_PING_URL` | _(none)_ | Healthchecks.io heartbeat URL — pinged at start (`/start`), end (success), or `/fail` if any update failed |
| `WEBHOOK_ROLLUP` | `false` | Send one summary webhook per run instead of per-container, for listed channels |
| `WEBHOOK_ROLLUP_CHANNELS` | `discord,slack,generic` | Comma list of channels to roll up. Per-container labels are ignored for rolled-up channels. |
| `HEALTHCHECK_TIMEOUT` | `120` | Default seconds to wait when `healthcheck.wait` is enabled (per-container override via `healthcheck.timeout`). |
| `HEALTHCHECK_INTERVAL` | `2` | Poll interval in seconds while waiting for healthy. |
| `ROLLBACK_DEFAULT` | `false` | When `true`, rollback applies to every container even without the `rollback` label. |
| `MAINTENANCE_WINDOW` | _(none)_ | Only run during this time window (e.g. `02:00-06:00`). Midnight-spanning works: `22:00-04:00`. Dry-run bypasses this. |
| `VERBOSE` | `false` | Log containers skipped due to missing hoist labels. Auto-enabled by `--dry-run`. |
| `CURL_TIMEOUT` | `30` | Maximum time in seconds for webhook HTTP requests. |
| `UPDATE_CHECK` | `notify` | Self-update behavior on every run: `notify` (log + webhook alert), `update` (auto-apply new releases), or `off`. See [Self-update](#self-update). |

Global webhooks fire for any container with `update` or `notify` enabled that has no per-container webhook label. Per-container labels always take precedence.

## Installation

**One-line install** (latest release):

```bash
curl -fsSL https://raw.githubusercontent.com/KingPin/hoist/master/install.sh | bash
```

> ⚠️ **Always inspect scripts before piping to a shell.** Review first:
> `curl -fsSL https://raw.githubusercontent.com/KingPin/hoist/master/install.sh | less`

Pin a specific version:

```bash
HOIST_VERSION=v1.2.0 curl -fsSL https://raw.githubusercontent.com/KingPin/hoist/master/install.sh | bash
```

Override paths (e.g. install per-user without sudo):

```bash
INSTALL_DIR=$HOME/.local/bin CONFIG_DIR=$HOME/.config/hoist \
  curl -fsSL https://raw.githubusercontent.com/KingPin/hoist/master/install.sh | bash
```

The installer downloads `hoist.sh` and `hoist.conf.example` from the GitHub release, verifies SHA256 checksums, installs the binary to `INSTALL_DIR/hoist`, and seeds `CONFIG_DIR/hoist.conf` from the example only if it doesn't already exist.

**Manual install:**

```bash
sudo cp hoist.sh /usr/local/bin/hoist
sudo chmod +x /usr/local/bin/hoist
```

For system-wide config, place `hoist.conf` at `/etc/hoist/hoist.conf`.

## Requirements

- Docker with the `compose` subcommand (`docker compose`)
- `jq`
- Bash 4.3+ (macOS ships 3.2 by default — `brew install bash`)

## Usage

```bash
bash hoist.sh [options]
```

| Flag | Description |
|---|---|
| `--tag <value>` | Use a label subset (e.g. `--tag nightly` reads `com.sumguy.hoist.nightly.*` labels) |
| `--dry-run` | Show what would be updated without pulling, recreating, or notifying (implies `--verbose`) |
| `--verbose` | Log containers skipped because they have no hoist labels |
| `--parallel <N>` | Process containers concurrently with `N` workers |
| `--only <names>` | Comma-separated list of container names to include (others ignored). Names not currently running emit a warning. |
| `--exclude <names>` | Comma-separated list of container names to skip. Highest precedence — wins over `--only`. |
| `--list`, `--status` | Print a table of all running containers with their label config and last-cached digest, then exit. No pulls or updates are performed. |
| `--update` | Self-update hoist to the latest GitHub release (interactive — prompts before replacing) |
| `--force` | With `--update`, skip the confirmation prompt and reinstall even if already up to date |
| `--version` | Print version and exit |
| `-h`, `--help`, `-?` | Show help and exit |

After every run, hoist prints a one-line summary:

```
[HH:MM:SS] Run complete: 3 updated (1 failed), 2 notified, 5 no-change, 12 skipped
```

In `--dry-run` mode this becomes `Run complete (dry-run): N would update, N would notify, ...`.

## Labels

Add labels to your Docker Compose services to opt containers in:

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      com.sumguy.hoist.update: "true"          # pull + recreate on new image
      com.sumguy.hoist.notify: "true"          # notify without recreating
      com.sumguy.hoist.discord.webhook: "https://discord.com/api/webhooks/..."
      com.sumguy.hoist.slack.webhook: "https://hooks.slack.com/services/..."
      com.sumguy.hoist.generic.webhook: "https://example.com/webhook"
      com.sumguy.hoist.telegram.bot_token: "123456:ABC..."
      com.sumguy.hoist.telegram.chat_id: "-1001234567890"
      com.sumguy.hoist.gotify.url: "https://gotify.example.com/message?token=XXX"
      com.sumguy.hoist.ntfy.url: "https://ntfy.sh/your-topic"
      com.sumguy.hoist.ntfy.token: "tk_..."    # optional bearer token
      com.sumguy.hoist.teams.webhook: "https://outlook.office.com/webhook/..."
      com.sumguy.hoist.matrix.homeserver: "https://matrix.org"
      com.sumguy.hoist.matrix.room_id: "!abc123:matrix.org"
      com.sumguy.hoist.matrix.token: "syt_..."
      com.sumguy.hoist.script.update: "/opt/scripts/pre-update.sh"
      com.sumguy.hoist.script.notify: "/opt/scripts/on-notify.sh"
      com.sumguy.hoist.registry.authfile: "/run/secrets/registry.json"
      com.sumguy.hoist.pause_until: "2026-06-01"          # skip until this date/datetime
      com.sumguy.hoist.constraint: "^1.2"                 # semver pin (^, ~, >=, <=, >, <, =)
      com.sumguy.hoist.group: "db"                        # any group member's pull failure aborts the rest
      com.sumguy.hoist.healthcheck.wait: "true"           # poll for healthy after recreate
      com.sumguy.hoist.healthcheck.timeout: "180"         # seconds to wait (overrides config)
      com.sumguy.hoist.rollback: "true"                   # re-tag prior SHA on update or healthcheck failure
```

`update` and `notify` can both be set on the same container — it will update and then notify.

### Tag-scoped labels

Use `--tag` to target a subset of containers without affecting others:

```yaml
labels:
  com.sumguy.hoist.nightly.update: "true"   # only updated when run with --tag nightly
```

### Registry auth

The `registry.authfile` label points to a JSON file:

```json
{
  "registry": "ghcr.io",
  "username": "myuser",
  "password": "mytoken"
}
```

### Policy labels

Three labels gate whether an update is applied (notifications still fire so you know what was held back):

- **`pause_until`** — ISO date (`2026-06-01`) or datetime (`2026-06-01T15:00:00Z`). Hoist skips the container entirely until current time ≥ value. Emits the `paused` summary token. Unparseable values fail open with a warning, so a typo never silently pauses forever.
- **`constraint`** — semver-style pin against the new image's `org.opencontainers.image.version` label. Supported operators: `^1.2`, `~1.2.3`, `>=1.0`, `<=2.0`, `>1.0`, `<2.0`, `=1.2.3`, or an exact `1.2.3`. If the candidate version violates, hoist skips the update, still notifies, and emits `constraint_blocked`. Images without an OCI version label fail open (cannot enforce). **Caveat — caret on 0.x:** hoist treats `^0.1.2` as "any `0.x` ≥ `0.1.2`" (same major). This differs from npm's "no minor bumps when major is 0" semantics. If you want npm-style behavior at major 0, use `~0.1.2` or an explicit range like `>=0.1.2,<0.2`.
- **`group`** — free-form group name. If any container in the group has a pull failure, the others' updates are aborted (`group_aborted` token). Group atomicity is "soft" under `--parallel N`: a sibling may finish updating before its peer fails — accepted limitation. Group flags reset at the start of each run.

### Container filters

`--only foo,bar` and `--exclude baz,qux` filter which running containers hoist processes. `--exclude` wins over `--only`. Names that aren't currently running emit a warning but don't fail the run. Filters apply before label inspection — useful for ad-hoc maintenance without editing labels.

### Healthcheck wait + rollback

Two opt-in safety nets stack on top of the normal `compose up` flow:

- **`healthcheck.wait`** — after `compose up` succeeds, hoist polls `docker inspect --format '{{.State.Health.Status}}'`. Reaches `healthy`: success. `unhealthy`/`exited`/timeout: emits the `unhealthy` token. Per-container `healthcheck.timeout` overrides the global `HEALTHCHECK_TIMEOUT` (default 120s, polled every `HEALTHCHECK_INTERVAL` seconds — default 2). **Images without a `HEALTHCHECK` directive** fall back to `.State.Status`, which only distinguishes `running` from `exited`. A warning is logged and the wait succeeds the moment the container is `running` — add a real `HEALTHCHECK` to the image if you need stronger guarantees.
- **`rollback`** — on update failure OR unhealthy outcome, hoist re-aliases the prior image SHA back onto the original tag and re-runs `compose up --no-pull`. Emits `rolled_back` on success, `rollback_failed` on failure. **Caveat:** the old image must still be present locally. If `PRUNE_IMAGES=true` removed it between runs, rollback fails clearly with `rollback_failed` rather than silently. Set `ROLLBACK_DEFAULT=true` in config to enable rollback for every container without per-container labels.

## Custom scripts

When `script.update` or `script.notify` fires, these environment variables are available:

| Variable | Value |
|---|---|
| `HOIST_CONTAINER` | Container name |
| `HOIST_IMAGE` | Image name |
| `HOIST_OLD_IMAGE_ID` | Previous image digest |
| `HOIST_NEW_IMAGE_ID` | New image digest |
| `HOIST_OLD_VERSION` | Previous `org.opencontainers.image.version` label |
| `HOIST_NEW_VERSION` | New `org.opencontainers.image.version` label |
| `HOIST_OLD_REVISION` | Previous `org.opencontainers.image.revision` label |
| `HOIST_NEW_REVISION` | New `org.opencontainers.image.revision` label |
| `HOIST_COMPOSE_SERVICE` | Compose service name |
| `HOIST_COMPOSE_WORKDIR` | Compose project working directory |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker: command not found` | `DOCKER_BINARY` not set or docker not in PATH | Set `DOCKER_BINARY=/usr/bin/docker` in config |
| `jq: command not found` | jq not installed | Install jq (`apt install jq`, `brew install jq`, etc.) |
| `compose workdir missing` / container skipped silently | Container has no `com.docker.compose.project.working_dir` label | Container wasn't started via `docker compose` — hoist only manages Compose-managed containers |
| Container never updates despite new image | Label typo or wrong tag | Check label spelling; if using `--tag nightly`, labels must be `com.sumguy.hoist.nightly.*` |
| Notifications fire every run | `CACHE_LOCATION` is cleaned between runs (e.g. tmpfs) | Set `CACHE_LOCATION` to a persistent path |
| Script runs but exits immediately | `MAINTENANCE_WINDOW` set and current time is outside it | Expected behavior — adjust window or run with `--dry-run` to bypass |

## Self-update

On every run, hoist checks the GitHub releases API for a newer version. Behavior is controlled by `UPDATE_CHECK`:

- **`notify`** (default) — logs a message and fires global webhooks (Discord/Slack/generic) once per new version, then continues normal operation. A sentinel file in `CACHE_LOCATION` suppresses repeat notifications for the same version.
- **`update`** — automatically downloads, SHA256-verifies, and replaces the script on disk. Webhooks still fire before the update is applied. **Avoid this on cron** — a breaking release will affect every subsequent unattended run.
- **`off`** — skips the check entirely.

To trigger an interactive update manually:

```bash
hoist --update            # prompts before replacing
hoist --update --force    # skip prompt, reinstall even if up to date
hoist --update --dry-run  # show what would be downloaded, then exit
```

Updates require write access to the running script path. The downloaded asset is verified against `hoist.sh.sha256` from the same release before any replacement happens.

## Running on a schedule

Hoist can install its own scheduled run on Linux:

```bash
hoist --cron install                     # interactive: prompts for schedule, user, backend
hoist --cron install --schedule hourly --user root --backend cron   # non-interactive
hoist --cron install --scope user --schedule hourly \
  --docker-host unix:///run/user/1000/docker.sock     # rootless docker, non-interactive
hoist --cron status                      # show what's currently installed
hoist --cron print                       # preview the file(s) that would be written
hoist --cron remove                      # uninstall the hoist-managed schedule
hoist --cron                             # interactive menu
```

For user-scope installs, hoist auto-pins `DOCKER_HOST` into the generated unit
when rootless docker is detected. Pass `--docker-host <uri>` to override
auto-detect (useful for non-interactive automation where `DOCKER_HOST` isn't
set in the calling shell).

`--cron install` auto-detects systemd vs. cron and writes either `/etc/cron.d/hoist`
or a `hoist.service` + `hoist.timer` pair in `/etc/systemd/system/`. Files carry a
`# Managed by hoist --cron install` marker; hoist refuses to overwrite a file at
the same path that lacks it.

Schedule presets: `30min`, `hourly`, `6hourly`, `daily` (03:00), `weekly` (Sun 03:00),
or pass any cron expression / systemd `OnCalendar` value.

On macOS, hoist points you at a launchd plist example. See
[`docs/scheduling.md`](docs/scheduling.md) for the full reference (cron, systemd, launchd).

## Notifications

**Discord** — sends a rich embed with image name, digest diff, and version/revision if the image exposes `org.opencontainers.image.version` and `org.opencontainers.image.revision` labels.

**Slack** — sends a plain text message: `[container] Update available: image:tag`

**Telegram** — sends a plain text message via the Bot API. Requires `bot_token` (from BotFather) and `chat_id` (negative for groups, positive for users).

**Gotify** — sends a `{title, message, priority}` payload. Token goes in the URL: `https://gotify.example.com/message?token=XXX`.

**ntfy** — POSTs the message body to your ntfy topic URL. Title goes in the `Title:` header. Optional `token` adds bearer auth for protected topics.

**Microsoft Teams** — sends an `MessageCard` (Office 365 connector format). Use the incoming-webhook URL for your channel.

**Matrix** — PUTs an `m.text` message into a room. Requires `homeserver` (e.g. `https://matrix.org`), `room_id`, and an `access_token`.

**Healthchecks.io** — set `HEALTHCHECKS_PING_URL` to a check URL. Hoist pings `/start` at run start, the bare URL on success, and `/fail` if any container's update failed. Best-effort — failed pings don't block the run.

### Webhook rollup

Set `WEBHOOK_ROLLUP=true` (and adjust `WEBHOOK_ROLLUP_CHANNELS`) to receive one summary message per run instead of one per container. The rolled-up message is sent to the corresponding `GLOBAL_*` webhook for each listed channel. Per-container webhook labels are ignored for rolled-up channels; channels not in the rollup list keep their normal per-container behavior.

**Generic webhook** — POST with JSON body:

```json
{
  "type": "update_success",
  "container": "myapp",
  "image": "myapp:latest",
  "old_image_id": "abc123",
  "new_image_id": "def456",
  "old_version": "1.0.0",
  "new_version": "1.1.0",
  "old_revision": "aabbcc",
  "new_revision": "ddeeff",
  "timestamp": "2026-05-04T04:00:00.000Z"
}
```

`type` is one of: `update_available`, `update_success`, `update_failure`
