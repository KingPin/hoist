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

Global webhooks fire for any container with `update` or `notify` enabled that has no per-container webhook label. Per-container labels always take precedence.

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
| `--dry-run` | Show what would be updated without pulling, recreating, or notifying |
| `--parallel <N>` | Process containers concurrently with `N` workers |

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
