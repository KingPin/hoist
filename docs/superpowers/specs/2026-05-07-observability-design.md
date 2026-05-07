# Hoist Observability: --list and Run Summary

## Overview

Add two observability features to `hoist.sh`:

1. `--list` / `--status` — read-only flag that shows all managed containers and their current state
2. End-of-run summary — prints outcome counts after every run

## `--list` / `--status` Flag

### Behaviour

New boolean `DO_LIST=false`, set by either `--list` or `--status`. When true:

1. Run `docker ps` to get container names (same as normal run)
2. Per container: `docker inspect` to read labels using the existing label extraction logic
3. Read `${CACHE_LOCATION}/hoist-${safe_name}.notified` if present to get last-notified digest
4. Print formatted table, then exit — no pulls, no updates, no webhook calls
5. Respects `--tag` filter
6. Does not require or trigger `setup_environment` (no parallel subshells needed)

### Output Format

```
CONTAINER         IMAGE                    UPDATE  NOTIFY  CACHED DIGEST
myapp             myapp:latest             yes     yes     abc12345678901
db                postgres:16              no      yes     -
proxy             nginx:alpine             yes     no      def67890abcdef
other             redis:7                  -       -       (no hoist labels)
```

- `UPDATE` / `NOTIFY` show `yes` / `no` when the container has hoist labels, `-` when it has none
- `CACHED DIGEST` shows the first 13 chars of the digest stored in the `.notified` file, or `-` if absent
- Columns formatted with `printf` fixed-width fields

### New function: `list_containers()`

Standalone function, not exported (never called in a subshell). Calls `docker inspect` per container (same one-at-a-time pattern as `process_container`), extracts only the fields needed for display.

## End-of-Run Summary

### Mechanism

**Result files:** one file per container at `${CACHE_LOCATION}/hoist-${safe_name}.run-result`, containing one outcome token per line. Written by `process_container`. Read by `print_summary` after the main loop.

File-based approach is used (rather than global variables) so that it works correctly under `xargs -P N` parallel mode, where subshells cannot write back to parent variables. This is the same pattern already used by `.notified` files.

**Cleanup:** stale `hoist-*.run-result` files are deleted from `CACHE_LOCATION` before the main loop starts, so orphaned files from previous runs don't pollute the count.

### Outcome Tokens

| Token | Meaning |
|---|---|
| `updated` | `compose up` succeeded |
| `update_failed` | `compose up` failed |
| `notified` | a webhook or script notification was sent |
| `no_change` | image pulled, digest matched running container — nothing to do |
| `skipped` | container has no hoist labels |

A single container can emit multiple tokens (e.g. `updated` + `notified`).

In dry-run mode `process_container` writes `would_update` and `would_notify` instead of `updated` and `notified`.

### New function: `print_summary()`

Reads all `hoist-*.run-result` files in `CACHE_LOCATION`, counts tokens, formats output. Called in the parent process after `xargs` completes — does NOT need to be exported.

### Output

Normal run:
```
[HH:MM:SS] Run complete: 3 updated (1 failed), 2 notified, 5 no-change, 12 skipped
```

Zero failures omit the parenthetical:
```
[HH:MM:SS] Run complete: 3 updated, 2 notified, 5 no-change, 12 skipped
```

Dry-run:
```
[HH:MM:SS] Run complete (dry-run): 3 would update, 2 would notify, 5 no-change, 12 skipped
```

## Code Changes (all in `hoist.sh`)

| Change | Location |
|---|---|
| Add `DO_LIST=false` | defaults block |
| Add `--list` / `--status` to arg parsing | `while` arg loop |
| New `list_containers()` function | after `check_maintenance_window` |
| New `print_summary()` function | after `list_containers` |
| Write result tokens in `process_container` | at each outcome branch |
| Delete stale `.run-result` files | before `setup_environment` call |
| Call `print_summary` | after main loop (before image prune) |
| If `DO_LIST=true`: call `list_containers` and exit | after arg parsing / docker binary check |

## Out of Scope

- Machine-readable output (JSON) from `--list` — can be added later via `--json` flag
- Persisting run history across invocations
- Per-container timing information
