# Deploying hoist with Ansible

A worked example for installing [hoist](https://github.com/KingPin/hoist) on one or more hosts and (optionally) wiring up its scheduled run via `hoist --cron install`.

This is a single self-contained playbook, not a role — copy it into your own Ansible tree and adapt as needed. See [Converting to a role](#converting-to-a-role) below if you'd rather have a role layout.

## What it does

1. Ensures `jq` and `curl` are installed on the target.
2. Downloads `hoist.sh` from a GitHub release and installs it to `/usr/local/bin/hoist`.
3. Renders `/etc/hoist/hoist.conf` from a Jinja2 template (with `UPDATE_CHECK=off` and a non-`/tmp` cache directory).
4. Creates `/var/cache/hoist`.
5. Runs `hoist --cron install --schedule … --user … --backend …` to install a cron entry or systemd timer.
6. Runs `hoist --cron status` as a smoke test.

## Prerequisites

- Ansible 2.12+ on the control node.
- Targets running Linux (macOS uses `launchd`, which hoist's `--cron` does not manage; see `docs/scheduling.md` in the main repo).
- Bash 4+ on targets (the Linux distros you'd plausibly run docker on already satisfy this).
- Docker (with the `compose` subcommand) already installed and running on the targets — hoist is meaningless without it. The playbook does **not** install docker.
- `become: true` (root) — required to write to `/usr/local/bin`, `/etc/hoist`, `/etc/cron.d`, and `/etc/systemd/system`.

## Quick start

```bash
ansible-playbook -i inventory.example.ini playbook.yml --become
```

That installs the latest release, drops a managed config, and sets up a daily systemd timer running as root.

## Variables

| Variable | Default | Description |
|---|---|---|
| `hoist_version` | `latest` | Release tag to install (e.g. `v1.3.0`). `latest` tracks the newest release and re-downloads on every run. |
| `hoist_sha256` | _(unset)_ | Optional `sha256:<hex>` of `hoist.sh` for `get_url` checksum verification. Strongly recommended when pinning a version. |
| `hoist_install_dir` | `/usr/local/bin` | Where the binary lands. |
| `hoist_config_dir` | `/etc/hoist` | Where `hoist.conf` is rendered. |
| `hoist_cache_dir` | `/var/cache/hoist` | `CACHE_LOCATION` for notification dedupe. |
| `hoist_install_schedule` | `true` | Set `false` to deploy the binary + config only, without scheduling. |
| `hoist_schedule` | `daily` | Preset (`30min`, `hourly`, `6hourly`, `daily`, `weekly`) or a raw cron expression / systemd `OnCalendar` string. |
| `hoist_user` | `root` | User the scheduled run executes as. Non-root must be in the `docker` group. |
| `hoist_backend` | `systemd` | `systemd` or `cron`. **Required when both schedulers are present** — otherwise hoist refuses to guess in non-interactive mode. |
| `hoist_log_file` | _(unset)_ | If set, hoist appends all log output to this file in addition to stdout. |
| `hoist_parallel` | _(unset)_ | Containers to process concurrently (default 1). |
| `hoist_tag` | _(unset)_ | Default `--tag` filter. |
| `hoist_maintenance_window` | _(unset)_ | E.g. `02:00-06:00`. Hoist exits cleanly outside this window. |
| `hoist_global_discord_webhook` | _(unset)_ | Fallback Discord webhook for containers without a per-container label. |
| `hoist_global_slack_webhook` | _(unset)_ | Fallback Slack webhook. |
| `hoist_global_generic_webhook` | _(unset)_ | Fallback generic webhook. |

## Pinning a version

Pin both the tag and the checksum to lock the binary fully:

```yaml
hoist_version: v1.3.0
hoist_sha256: "sha256:<copy from hoist.sh.sha256 release asset>"
```

Grab the hash with:

```bash
curl -fsSL https://github.com/KingPin/hoist/releases/download/v1.3.0/hoist.sh.sha256 | awk '{print $1}'
```

Then prefix it with `sha256:` in your variable.

When `hoist_version` is `latest`, the playbook passes `force: true` to `get_url` so each run re-downloads and replaces the binary if upstream changed. With a pinned tag, `force` is `false` — the file is fetched once and only re-checked against the checksum.

## Removing the schedule

Ad-hoc, without re-running the playbook:

```bash
ansible -i inventory.example.ini docker_hosts -b -m command -a '/usr/local/bin/hoist --cron remove'
```

`hoist --cron remove` only deletes files marked with the `# Managed by hoist --cron install` header on line 1, so it's safe even if someone hand-edited the unit afterwards (it'll refuse instead of clobbering).

## A note on the "always changed" task

Ansible will report the `Install scheduled run` task as **changed** on every run, because `hoist --cron install` always rewrites its unit/cron file and emits `Installed …` to stdout. The on-disk effect is fully idempotent — re-running produces identical content. We accept the cosmetic `changed` flag rather than wrap it in a brittle stat-based comparison.

If you really need accurate change reporting, register the file's hash before/after with `stat` and gate the install task on diff. It's not worth it for most cases.

## Known caveats

- **macOS targets aren't supported.** `hoist --cron install` returns exit 2 on Darwin with a pointer to the launchd docs.
- **Hosts with both cron and systemd present** — the auto-detect picks `both`, which forces `--backend` to be specified explicitly (the playbook does this; just be sure you set `hoist_backend` correctly).
- **systemd backend with a custom `OnCalendar` expression** requires `systemd-analyze` on the target. The presets (`hourly`, `daily`, etc.) skip validation. If you pass a raw expression and your distro doesn't ship `systemd-analyze`, either install the `systemd` package or switch to `hoist_backend: cron`.
- **Non-root `hoist_user`** must already be in the `docker` group. The playbook doesn't manage user/group membership — add a task or pre-existing role for that if needed.
- **The `command` module is used for `--cron install` rather than a dedicated systemd/cron module.** This is deliberate: hoist's marker-driven idempotency and dual-backend logic live inside the script itself, and reimplementing it in Ansible would duplicate that logic.

## Converting to a role

Drop these files into a standard role layout:

```
roles/hoist/
├── defaults/main.yml         # the vars block from playbook.yml
├── tasks/main.yml            # the tasks: list (drop the play wrapper)
└── templates/hoist.conf.j2   # unchanged
```

Then call it from a play with `roles: [hoist]` and override variables in inventory or group_vars as usual.

## See also

- [`docs/scheduling.md`](../../docs/scheduling.md) in the main repo — backend details and macOS guidance.
- [`hoist.conf.example`](../../hoist.conf.example) — full list of available config knobs (the template here only renders a subset).
- [`install.sh`](../../install.sh) — reference for the install steps this playbook automates.
