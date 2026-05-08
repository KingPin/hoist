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
| `MAINTENANCE_WINDOW` | _(none)_ | Only run during this time window (e.g. `02:00-06:00`). Midnight-spanning works: `22:00-04:00`. Dry-run bypasses this. |
| `VERBOSE` | `false` | Log containers skipped due to missing hoist labels. Auto-enabled by `--dry-run`. |
| `CURL_TIMEOUT` | `30` | Maximum time in seconds for webhook HTTP requests. |
| `UPDATE_CHECK` | `notify` | Self-update behavior on every run: `notify` (log + webhook alert), `update` (auto-apply new releases), or `off`. See [Self-update](#self-update). |

Global webhooks fire for any container with `update` or `notify` enabled that has no per-container webhook label. Per-container labels always take precedence.

## Installation

```bash
sudo cp hoist.sh /usr/local/bin/hoist
sudo chmod +x /usr/local/bin/hoist
```

For system-wide config, place `hoist.conf` at `/etc/hoist/hoist.conf`.

## Requirements

- Docker with the `compose` subcommand (`docker compose`)
- `jq`

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
      com.sumguy.hoist.script.update: "/opt/scripts/pre-update.sh"
      com.sumguy.hoist.script.notify: "/opt/scripts/on-notify.sh"
      com.sumguy.hoist.registry.authfile: "/run/secrets/registry.json"
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

Example cron entry to check for updates every day at 4 AM:

```cron
0 4 * * * hoist --parallel 4 >> /var/log/hoist.log 2>&1
```

## Notifications

**Discord** — sends a rich embed with image name, digest diff, and version/revision if the image exposes `org.opencontainers.image.version` and `org.opencontainers.image.revision` labels.

**Slack** — sends a plain text message: `[container] Update available: image:tag`

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
