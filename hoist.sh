#!/usr/bin/env bash
HOIST_VERSION="1.7.1"
HOIST_REPO="KingPin/hoist"

DOCKER_BINARY="${DOCKER_BINARY:-$(which docker)}"
CACHE_LOCATION=/tmp
TAG=""
DRY_RUN=false
PARALLEL=1
PRUNE_IMAGES=true
LOG_FILE=""
GLOBAL_DISCORD_WEBHOOK=""
GLOBAL_SLACK_WEBHOOK=""
GLOBAL_GENERIC_WEBHOOK=""
GLOBAL_TELEGRAM_BOT_TOKEN=""
GLOBAL_TELEGRAM_CHAT_ID=""
GLOBAL_GOTIFY_URL=""
GLOBAL_NTFY_URL=""
GLOBAL_NTFY_TOKEN=""
GLOBAL_TEAMS_WEBHOOK=""
GLOBAL_MATRIX_HOMESERVER=""
GLOBAL_MATRIX_ROOM_ID=""
GLOBAL_MATRIX_TOKEN=""
HEALTHCHECKS_PING_URL=""
WEBHOOK_ROLLUP="false"
WEBHOOK_ROLLUP_CHANNELS="discord,slack,generic"
HEALTHCHECK_TIMEOUT=120
HEALTHCHECK_INTERVAL=2
ROLLBACK_DEFAULT="false"
MAINTENANCE_WINDOW=""
HOIST_HOSTNAME=""
VERBOSE=false
CURL_TIMEOUT="${CURL_TIMEOUT:-30}"
UPDATE_CHECK="${UPDATE_CHECK:-notify}"
DO_SELF_UPDATE=false
FORCE=false
DO_LIST=false
DO_CRON=false
CRON_ACTION=""
CRON_SCHEDULE_FLAG=""
CRON_USER_FLAG=""
CRON_BACKEND_FLAG=""
CRON_SCOPE_FLAG=""
CRON_DOCKER_HOST_FLAG=""
ONLY_LIST=""
EXCLUDE_LIST=""

log() {
    local msg="[$(date +%T)] $*"
    echo "$msg"
    [[ -n $LOG_FILE ]] && echo "$msg" >> "$LOG_FILE"
}

# _is_true <value>  -> 0 if the value is an affirmative boolean, else 1.
# Case-insensitive; accepts true/1/yes/on. Used for user-supplied label and
# config gates so "True", "YES", "1" behave the same as "true".
_is_true() {
    case "${1,,}" in
        true|1|yes|on) return 0 ;;
        *)             return 1 ;;
    esac
}

# _normalize_tag <tag>  -> echoes the tag with a guaranteed leading dot (or
# empty for empty input). Labels are read as com.sumguy.hoist<TAG>.<key>.
_normalize_tag() {
    local t="$1"
    [[ -n $t && $t != .* ]] && t=".$t"
    printf '%s' "$t"
}

_load_config() {
    local cfg=""
    if   [[ -n $HOIST_CONFIG && -f $HOIST_CONFIG ]];   then cfg="$HOIST_CONFIG"
    elif [[ -f "$(dirname "$0")/hoist.conf" ]];         then cfg="$(dirname "$0")/hoist.conf"
    elif [[ -f /etc/hoist/hoist.conf ]];                then cfg=/etc/hoist/hoist.conf
    fi
    [[ -n $cfg ]] && { log "Loading config: $cfg"; source "$cfg"; }
}

# All startup side effects (config load, arg parsing, environment validation,
# trap install) live in _init so the script can be sourced by tests without
# executing anything. _init is invoked from the entry-point guard at the bottom.
_init() {
_load_config

while [[ "$1" != "" ]]; do
    case "$1" in
    --dry-run)    DRY_RUN=true; VERBOSE=true ;;
    --verbose)    VERBOSE=true ;;
    --tag=*)      TAG="${1#*=}"
                  [[ -n $TAG ]] || { echo "Error: --tag requires a value" >&2; exit 2; } ;;
    --tag)        [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --tag requires a value" >&2; exit 2; }
                  TAG="$2"; shift ;;
    --parallel=*) PARALLEL="${1#*=}"
                  [[ $PARALLEL =~ ^[0-9]+$ ]] || { echo "Error: --parallel requires a non-negative integer" >&2; exit 2; } ;;
    --parallel)   [[ -n ${2:-} && $2 =~ ^[0-9]+$ ]] || { echo "Error: --parallel requires a non-negative integer" >&2; exit 2; }
                  PARALLEL="$2"; shift ;;
    --update)     DO_SELF_UPDATE=true ;;
    --version)    echo "hoist v${HOIST_VERSION}"; exit 0 ;;
    --force)      FORCE=true ;;
    --list|--status) DO_LIST=true ;;
    --only=*)     ONLY_LIST="${1#*=}"
                  [[ -n $ONLY_LIST ]] || { echo "Error: --only requires a value" >&2; exit 2; } ;;
    --only)       [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --only requires a value" >&2; exit 2; }
                  ONLY_LIST="$2"; shift ;;
    --exclude=*)  EXCLUDE_LIST="${1#*=}"
                  [[ -n $EXCLUDE_LIST ]] || { echo "Error: --exclude requires a value" >&2; exit 2; } ;;
    --exclude)    [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --exclude requires a value" >&2; exit 2; }
                  EXCLUDE_LIST="$2"; shift ;;
    --cron=*)
        echo "Error: --cron does not take a value with '='; use: hoist --cron <action>" >&2
        exit 2 ;;
    --cron)
        DO_CRON=true
        if [[ -n "${2:-}" && "$2" != --* ]]; then
            CRON_ACTION="$2"
            shift
        fi ;;
    --schedule=*) CRON_SCHEDULE_FLAG="${1#*=}"
                  [[ -n $CRON_SCHEDULE_FLAG ]] || { echo "Error: --schedule requires a value" >&2; exit 2; } ;;
    --schedule)   [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --schedule requires a value" >&2; exit 2; }
                  CRON_SCHEDULE_FLAG="$2"; shift ;;
    --user=*)     CRON_USER_FLAG="${1#*=}"
                  [[ -n $CRON_USER_FLAG ]] || { echo "Error: --user requires a value" >&2; exit 2; } ;;
    --user)       [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --user requires a value" >&2; exit 2; }
                  CRON_USER_FLAG="$2"; shift ;;
    --backend=*)  CRON_BACKEND_FLAG="${1#*=}"
                  [[ -n $CRON_BACKEND_FLAG ]] || { echo "Error: --backend requires a value" >&2; exit 2; } ;;
    --backend)    [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --backend requires a value" >&2; exit 2; }
                  CRON_BACKEND_FLAG="$2"; shift ;;
    --scope=*)    CRON_SCOPE_FLAG="${1#*=}"
                  [[ -n $CRON_SCOPE_FLAG ]] || { echo "Error: --scope requires a value" >&2; exit 2; } ;;
    --scope)      [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --scope requires a value" >&2; exit 2; }
                  CRON_SCOPE_FLAG="$2"; shift ;;
    --docker-host=*) CRON_DOCKER_HOST_FLAG="${1#*=}"
                     [[ -n $CRON_DOCKER_HOST_FLAG ]] || { echo "Error: --docker-host requires a value" >&2; exit 2; } ;;
    --docker-host)   [[ -n ${2:-} && $2 != --* ]] || { echo "Error: --docker-host requires a value" >&2; exit 2; }
                     CRON_DOCKER_HOST_FLAG="$2"; shift ;;
    -h|--help|-\?)
        cat <<EOF
hoist v${HOIST_VERSION} — auto-update or notify on Docker containers via labels

Usage: hoist [options]

Options:
  --tag <value>      Use a label subset (e.g. --tag nightly reads
                     com.sumguy.hoist.nightly.* labels)
  --dry-run          Show what would be pulled/updated without making
                     changes or sending notifications (implies --verbose)
  --verbose          Log skipped containers (no hoist labels)
  --parallel <N>     Process containers concurrently with N workers
  --list, --status   Print a table of running containers and their label
                     config, then exit (no pulls or updates)
  --only <names>     Comma-separated container names to include (others skipped)
  --exclude <names>  Comma-separated container names to exclude
  --update           Self-update hoist to the latest GitHub release
  --force            With --update, reinstall even if already up to date
  --version          Print version and exit
  -h, --help, -?     Show this help and exit

Scheduling:
  --cron [action]    Manage hoist's scheduled run. Bare --cron opens an
                     interactive menu. Actions:
                       install   Install a cron entry or systemd timer
                       remove    Remove the hoist-managed schedule
                       print     Print the file(s) hoist would install
                       status    Show what's currently installed
  --schedule <expr>  Schedule for --cron install/print. Presets:
                       30min, hourly, 6hourly, daily, weekly
                     or a raw cron / OnCalendar expression.
  --scope <scope>    Install scope for --cron install: user | system.
                     user: systemd --user units, no sudo needed.
                     system: /etc/cron.d or /etc/systemd/system/ (default for root).
  --user <name>      User to run hoist as (--cron install, system scope). Default: root.
  --backend <name>   Force backend: cron | systemd. Default: auto-detect.
                     cron backend is only available with --scope system.
  --docker-host <uri> Pin DOCKER_HOST in the generated user unit
                     (--cron install, --scope user only). Overrides
                     auto-detect. Use this for rootless docker on a
                     non-default socket, or in non-interactive automation
                     where DOCKER_HOST isn't set in the calling shell.

Config file (sourced before CLI flag parsing):
  \$HOIST_CONFIG, ./hoist.conf, or /etc/hoist/hoist.conf

Repo: https://github.com/${HOIST_REPO}
EOF
        exit 0 ;;
    *)  echo "Error: unknown option: $1" >&2
        echo "Run 'hoist --help' for usage." >&2
        exit 2 ;;
    esac
    shift
done

# Normalize TAG: labels are read as com.sumguy.hoist<TAG>.<key>, so a non-empty
# TAG must carry its leading dot. Accepts both `--tag nightly` (CLI) and
# `TAG=nightly` (config / Ansible).
TAG="$(_normalize_tag "$TAG")"

# Bash 4.3+ check runs after arg parse so --version/--help still work on macOS
# system bash 3.2 — users need a way to diagnose what they have installed.
# 4.3 is required for `wait -n` used by the parallel worker pool.
if [[ -z ${BASH_VERSINFO+x} ]] || (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Error: hoist requires bash 4.3+ (current: ${BASH_VERSION:-unknown})." >&2
    echo "  macOS: brew install bash, then ensure the Homebrew bash is first in PATH" >&2
    echo "         (e.g. /opt/homebrew/bin or /usr/local/bin), or invoke hoist with that bash explicitly." >&2
    echo "  Verify with: bash --version" >&2
    exit 1
fi

# Tear down only the background workers we spawned, not the entire process
# group — `kill 0` would also signal shell siblings (e.g. the cron parent).
trap '_jobs=$(jobs -p); [[ -n "$_jobs" ]] && kill $_jobs 2>/dev/null; exit 130' INT TERM

if [[ $DO_CRON != true ]]; then
    [[ -x "$DOCKER_BINARY" ]] || { echo "Error: docker binary not found: ${DOCKER_BINARY:-docker}"; exit 1; }
fi

for _wh_var in GLOBAL_DISCORD_WEBHOOK GLOBAL_SLACK_WEBHOOK GLOBAL_GENERIC_WEBHOOK \
               GLOBAL_GOTIFY_URL GLOBAL_NTFY_URL GLOBAL_TEAMS_WEBHOOK \
               GLOBAL_MATRIX_HOMESERVER HEALTHCHECKS_PING_URL; do
    _wh_val="${!_wh_var}"
    if [[ -n "$_wh_val" ]]; then
        [[ "$_wh_val" =~ ^https?:// ]] || { echo "Error: $_wh_var is not a valid http(s) URL: $_wh_val"; exit 1; }
    fi
done

_validate_maintenance_window "$MAINTENANCE_WINDOW" || exit 2

log "TAG=${TAG} | DRY_RUN=${DRY_RUN} | PARALLEL=${PARALLEL} | VERBOSE=${VERBOSE}"
}

setup_environment() {
    # Exported so external child processes (user script.update / script.notify hooks,
    # docker, curl) see them. Bash functions are inherited automatically by `&`-spawned
    # subshells in the same process, so no `export -f` is needed for the parallel pool.
    export DOCKER_BINARY CACHE_LOCATION TAG DRY_RUN VERBOSE CURL_TIMEOUT
    export PRUNE_IMAGES LOG_FILE MAINTENANCE_WINDOW
    export GLOBAL_DISCORD_WEBHOOK GLOBAL_SLACK_WEBHOOK GLOBAL_GENERIC_WEBHOOK
    export GLOBAL_TELEGRAM_BOT_TOKEN GLOBAL_TELEGRAM_CHAT_ID
    export GLOBAL_GOTIFY_URL GLOBAL_NTFY_URL GLOBAL_NTFY_TOKEN GLOBAL_TEAMS_WEBHOOK
    export GLOBAL_MATRIX_HOMESERVER GLOBAL_MATRIX_ROOM_ID GLOBAL_MATRIX_TOKEN
    export HEALTHCHECKS_PING_URL WEBHOOK_ROLLUP WEBHOOK_ROLLUP_CHANNELS
    export HEALTHCHECK_TIMEOUT HEALTHCHECK_INTERVAL ROLLBACK_DEFAULT
}

# _validate_maintenance_window <window>  -> 0 if empty or well-formed,
# otherwise echoes an error and returns 1. Format is HH:MM-HH:MM (24h).
_validate_maintenance_window() {
    local w="$1"
    [[ -z "$w" ]] && return 0
    [[ "$w" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && return 0
    echo "Error: MAINTENANCE_WINDOW must be HH:MM-HH:MM (24h), got: $w" >&2
    return 1
}

# _in_maintenance_window <window "HH:MM-HH:MM"> <now "HHMM">  -> 0 if now falls
# inside the window, 1 if outside. Pure (no clock reads). Start is inclusive,
# end exclusive; a start greater than end means the window spans midnight.
# Forces base-10 so zero-padded times (e.g. 0900) never hit octal arithmetic.
_in_maintenance_window() {
    local window="$1" now="$2" start end
    start=${window%-*}; start=${start//:/}
    end=${window#*-};   end=${end//:/}
    start=$((10#$start)); end=$((10#$end)); now=$((10#$now))
    if (( start <= end )); then
        (( now >= start && now < end ))
    else
        (( now >= start || now < end ))   # spans midnight
    fi
}

check_maintenance_window() {
    [[ -z "$MAINTENANCE_WINDOW" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log "Maintenance window check bypassed (dry-run)"
        return 0
    fi
    if _in_maintenance_window "$MAINTENANCE_WINDOW" "$(date +%H%M)"; then
        log "Within maintenance window ($MAINTENANCE_WINDOW), proceeding."
    else
        log "Outside maintenance window ($MAINTENANCE_WINDOW), skipping."
        exit 0
    fi
}

# The cd runs inside a subshell so the working-directory change never leaks
# into the caller (which processes many containers across different workdirs).
compose_pull_wrapper() {
    [[ "$1" == /* ]] || { log "Error: compose workdir is not an absolute path: $1"; return 1; }
    ( cd "$1" || { log "Error: cannot cd to compose workdir: $1"; exit 1; }
      "${DOCKER_BINARY}" compose pull "$2" )
}

compose_up_wrapper() {
    [[ "$1" == /* ]] || { log "Error: compose workdir is not an absolute path: $1"; return 1; }
    ( cd "$1" || { log "Error: cannot cd to compose workdir: $1"; exit 1; }
      "${DOCKER_BINARY}" compose up -d --always-recreate-deps "$2" )
}

# Take an exclusive run lock so two hoist runs never process the same fleet
# concurrently (double pulls, racing compose up, clobbered run-result state).
# Prefers flock (kernel lock, auto-released when the fd closes on exit); falls
# back to an atomic mkdir lock with stale-PID detection when flock is absent.
# A held lock is not an error — hoist exits 0 so overlapping cron ticks are
# harmless.
_acquire_run_lock() {
    local lock="${CACHE_LOCATION}/hoist.lock"
    if command -v flock >/dev/null 2>&1; then
        exec {_LOCK_FD}>"$lock" || { log "Error: cannot open run lock $lock"; exit 1; }
        if ! flock -n "$_LOCK_FD"; then
            log "Another hoist run holds the lock ($lock); exiting."
            exit 0
        fi
        return 0
    fi
    # flock unavailable: atomic mkdir lock. mkdir fails if the dir exists, which
    # is our mutex; a recorded PID that is no longer alive means a crashed run.
    local lockdir="${lock}.d"
    while ! mkdir "$lockdir" 2>/dev/null; do
        local holder=""
        [[ -f "$lockdir/pid" ]] && holder=$(cat "$lockdir/pid" 2>/dev/null)
        if [[ -n $holder ]] && ! kill -0 "$holder" 2>/dev/null; then
            log "Removing stale run lock (pid $holder no longer running)"
            rm -rf "$lockdir"
            continue
        fi
        log "Another hoist run holds the lock ($lockdir, pid ${holder:-unknown}); exiting."
        exit 0
    done
    echo "$$" > "$lockdir/pid"
    _RUN_LOCKDIR="$lockdir"
    # EXIT also fires after the INT/TERM handler runs `exit 130`, so this one
    # trap covers normal and signalled termination. Background workers run in
    # subshells that reset traps, so they won't remove the lock.
    trap '[[ -n "${_RUN_LOCKDIR:-}" ]] && rm -rf "$_RUN_LOCKDIR"' EXIT
}

validate_webhook_url() {
    [[ "$1" =~ ^https?:// ]] || { log "Error: invalid webhook URL (must start with http:// or https://): $1"; return 1; }
}

validate_script_path() {
    local path="$1"
    [[ -z "$path" ]] && return 0
    [[ "$path" == /* ]] || { log "SECURITY: script path must be absolute: $path"; return 1; }
    [[ -x "$path" ]] || { log "SECURITY: script path is not executable: $path"; return 1; }
}

# _semver_compare <a> <b>  -> echoes -1 / 0 / 1 for a<b, a==b, a>b.
# Numeric base-10 comparison (no octal traps on zero-padded fields) and
# pre-release aware: with equal numeric triples a release outranks a
# pre-release (1.0.0 > 1.0.0-rc.1), per semver §11.
_semver_compare() {
    local a_full="$1" b_full="$2"
    local IFS=.
    local -a a=(${a_full%%-*}) b=(${b_full%%-*})
    local i av bv
    for i in 0 1 2; do
        av=${a[i]:-0}; bv=${b[i]:-0}
        av=${av%%[!0-9]*}; bv=${bv%%[!0-9]*}   # drop any trailing non-digits
        av=$((10#${av:-0})); bv=$((10#${bv:-0}))
        ((av > bv)) && { echo 1; return; }
        ((av < bv)) && { echo -1; return; }
    done
    local pa="" pb=""
    [[ $a_full == *-* ]] && pa=${a_full#*-}
    [[ $b_full == *-* ]] && pb=${b_full#*-}
    if [[ -z $pa && -n $pb ]]; then echo 1; return; fi   # release > pre-release
    if [[ -n $pa && -z $pb ]]; then echo -1; return; fi  # pre-release < release
    echo 0
}

# 0 (true) if a > b
_semver_gt() { [[ $(_semver_compare "$1" "$2") == 1 ]]; }

# 0 (true) if a == b (numeric triple + pre-release rank)
_semver_eq() { [[ $(_semver_compare "$1" "$2") == 0 ]]; }

# _semver_satisfies <constraint> <version>  -> 0 if version satisfies constraint
# Supports: ^X.Y.Z (same major), ~X.Y.Z (same major+minor), >=X, <=X, >X, <X,
# =X, X (exact), comma-separated conjunctions (every part must hold), and an
# optional leading v/V on both the constraint and the candidate version.
_semver_satisfies() {
    local constraint="$1" version="$2"
    [[ -z $version ]] && return 0   # no version label = can't enforce, fail-open
    version="${version#[vV]}"

    # Comma-separated parts form a conjunction: every part must be satisfied
    # (e.g. ">=0.1.2,<0.2" pins the 0.1.x line).
    if [[ $constraint == *,* ]]; then
        local part
        local IFS=,
        for part in $constraint; do
            part="${part#"${part%%[![:space:]]*}"}"   # ltrim
            part="${part%"${part##*[![:space:]]}"}"    # rtrim
            [[ -z $part ]] && continue
            _semver_satisfies "$part" "$version" || return 1
        done
        return 0
    fi

    local op base
    # Patterns are single-quoted so bash does not tilde-expand '~' (which would
    # turn the arm into $HOME and silently never match).
    case "$constraint" in
        '^'*)  op="^";  base="${constraint#\^}" ;;
        '~'*)  op="~";  base="${constraint#\~}" ;;
        ">="*) op=">="; base="${constraint#>=}" ;;
        "<="*) op="<="; base="${constraint#<=}" ;;
        ">"*)  op=">";  base="${constraint#>}" ;;
        "<"*)  op="<";  base="${constraint#<}" ;;
        "="*)  op="=";  base="${constraint#=}" ;;
        *)     op="=";  base="$constraint" ;;
    esac
    base="${base#[vV]}"
    local IFS=.
    local -a c=(${base%%-*}) v=(${version%%-*})
    # Arms quoted so '~' (and '^') are matched literally, not tilde-expanded.
    case "$op" in
        '^')  [[ ${v[0]:-0} == "${c[0]:-0}" ]] || return 1
            _semver_gt "$version" "$base" || _semver_eq "$version" "$base" ;;
        '~')  [[ ${v[0]:-0} == "${c[0]:-0}" && ${v[1]:-0} == "${c[1]:-0}" ]] || return 1
            _semver_gt "$version" "$base" || _semver_eq "$version" "$base" ;;
        ">=") _semver_gt "$version" "$base" || _semver_eq "$version" "$base" ;;
        "<=") ! _semver_gt "$version" "$base" ;;
        ">")  _semver_gt "$version" "$base" ;;
        "<")  _semver_gt "$base" "$version" ;;
        "=")  _semver_eq "$version" "$base" ;;
    esac
}

# _parse_to_epoch <iso_str>  -> echoes seconds-since-epoch, or returns 1.
# Portable across GNU date (-d), Homebrew gdate, and BSD date (-j -f) for
# common ISO formats.
_parse_to_epoch() {
    local input="$1" out
    if out=$(date -d "$input" +%s 2>/dev/null); then echo "$out"; return 0; fi
    if command -v gdate >/dev/null 2>&1 && out=$(gdate -d "$input" +%s 2>/dev/null); then
        echo "$out"; return 0
    fi
    local fmt
    for fmt in '%Y-%m-%dT%H:%M:%SZ' '%Y-%m-%dT%H:%M:%S' '%Y-%m-%d %H:%M:%S' '%Y-%m-%d'; do
        if out=$(date -j -f "$fmt" "$input" +%s 2>/dev/null); then
            echo "$out"; return 0
        fi
    done
    return 1
}

# _check_pause_until <iso_str>  -> 0 if past the pause time (proceed), 1 if still paused
_check_pause_until() {
    local target now
    target=$(_parse_to_epoch "$1") || {
        log "Warning: pause_until value '$1' is not parseable; ignoring"
        return 0
    }
    now=$(date +%s)
    (( now >= target ))
}

# _wait_for_healthy <container> <timeout_seconds>
#   0 = container reached healthy / running
#   1 = unhealthy, exited, or timed out
_wait_for_healthy() {
    local container="$1" timeout="$2"
    local interval="${HEALTHCHECK_INTERVAL:-2}"
    if ! [[ $timeout =~ ^[1-9][0-9]*$ ]]; then
        log "$container: healthcheck timeout '$timeout' is not a positive integer; using default 120"
        timeout=120
    fi
    if ! [[ $interval =~ ^[1-9][0-9]*$ ]]; then
        log "Warning: HEALTHCHECK_INTERVAL '$interval' is not a positive integer; using default 2"
        interval=2
    fi
    # Detect whether the image defines a HEALTHCHECK at all. Without one,
    # this function can only wait for `running`/`exited` — not real health.
    local has_health
    has_health=$("${DOCKER_BINARY}" inspect --format \
        '{{if .State.Health}}yes{{else}}no{{end}}' "$container" 2>/dev/null) || return 1
    if [[ $has_health != yes ]]; then
        log "$container: healthcheck.wait set but image defines no HEALTHCHECK — falling back to State.Status (running/exited only)"
    fi

    local deadline=$(( $(date +%s) + timeout ))
    local status
    while (( $(date +%s) < deadline )); do
        status=$("${DOCKER_BINARY}" inspect --format \
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "$container" 2>/dev/null) || return 1
        case "$status" in
            healthy|running) return 0 ;;
            unhealthy|exited|dead) return 1 ;;
            starting|created|restarting|paused) ;;
            *) ;;
        esac
        sleep "$interval"
    done
    return 1
}

# _rollback_container <container> <workdir> <service> <image_name> <old_image_sha>
#   Re-aliases the previous image SHA back onto the original tag and re-runs compose up.
#   Requires the old image to still be present locally (PRUNE_IMAGES may have removed it).
_rollback_container() {
    local container="$1" workdir="$2" service="$3" image_name="$4" old_sha="$5"
    if [[ -z "$old_sha" ]]; then
        log "$container: rollback skipped — old image SHA unknown"
        return 1
    fi
    if ! "${DOCKER_BINARY}" image inspect "$old_sha" >/dev/null 2>&1; then
        log "$container: rollback failed — old image $old_sha no longer present locally (was it pruned?)"
        return 1
    fi
    if [[ ! -d $workdir ]]; then
        log "$container: rollback failed — compose workdir '$workdir' is missing"
        return 1
    fi
    # Remember what the tag currently points at so a failed rollback can be
    # restored rather than leaving the tag aliased to an image that was never
    # brought up.
    local prev_target
    prev_target=$("${DOCKER_BINARY}" image inspect --format '{{.Id}}' "$image_name" 2>/dev/null)
    log "$container: rolling back to $old_sha"
    if ! "${DOCKER_BINARY}" tag "$old_sha" "$image_name"; then
        log "$container: rollback failed — could not re-tag $old_sha as $image_name"
        return 1
    fi
    # Re-run compose up without pulling — picks up the now-aliased image.
    # '--pull never' is the supported flag ('--no-pull' does not exist and made
    # this path silently fall back to pulling). stderr is captured into the log.
    local up_err
    if ! up_err=$( cd "$workdir" && "${DOCKER_BINARY}" compose up -d --pull never "$service" 2>&1 ); then
        log "$container: rollback failed — compose up did not succeed: ${up_err}"
        # Undo the re-tag so the tag still reflects what is actually running.
        if [[ -n $prev_target ]]; then
            "${DOCKER_BINARY}" tag "$prev_target" "$image_name" >/dev/null 2>&1 \
                || log "$container: warning — could not restore tag $image_name to $prev_target"
        fi
        return 1
    fi
    log "$container: rollback complete"
    return 0
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "Error: neither sha256sum nor shasum available" >&2
        return 1
    fi
}

_iso_ts() {
    # %3N is GNU-only; BSD date drops or echoes the literal token, varying by libc.
    # Validate the result against a strict ISO-8601 millisecond pattern; otherwise
    # downgrade to second precision so webhook payloads stay parseable.
    local ts
    ts=$(date -u +'%FT%T.%3NZ' 2>/dev/null)
    if [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]; then
        printf '%s' "$ts"
    else
        date -u +'%FT%TZ'
    fi
}

_hoist_hostname() {
    if [[ -n $HOIST_HOSTNAME ]]; then
        printf '%s' "$HOIST_HOSTNAME"
    elif command -v hostname >/dev/null 2>&1; then
        hostname -s 2>/dev/null || hostname
    elif [[ -n ${HOSTNAME:-} ]]; then
        printf '%s' "$HOSTNAME"
    elif [[ -r /etc/hostname ]]; then
        tr -d '\n' < /etc/hostname
    else
        printf 'unknown'
    fi
}

_self_update_notify() {
    local new_ver="$1" release_url="$2"
    local payload
    if [[ -n $GLOBAL_DISCORD_WEBHOOK ]]; then
        payload=$(jq -n \
            --arg title "Hoist update available: v${new_ver}" \
            --arg url "$release_url" \
            --arg cur "$HOIST_VERSION" \
            --arg footer "Powered by Hoist • $(_hoist_hostname)" \
            '{"embeds":[{"title":$title,
               "description":("Current: v" + $cur + "\nRun `hoist --update` to upgrade"),
               "url":$url,"color":16776960,
               "footer":{"text":$footer}}],
              "username":"Hoist"}') || {
            [[ $VERBOSE == true ]] && log "Warning: failed to build Discord payload for self-update notify"
        }
        [[ -n $payload ]] && curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
            -H "User-Agent: Hoist" -H "Content-Type: application/json" \
            -d "$payload" -- "$GLOBAL_DISCORD_WEBHOOK" 2>/dev/null || \
            { [[ $VERBOSE == true ]] && log "Warning: Discord self-update notification failed"; }
    fi
    if [[ -n $GLOBAL_SLACK_WEBHOOK ]]; then
        payload=$(jq -n \
            --arg t "Hoist v${new_ver} available (current: v${HOIST_VERSION}). Run --update to upgrade. ${release_url}" \
            '{"text":$t}') || {
            [[ $VERBOSE == true ]] && log "Warning: failed to build Slack payload for self-update notify"
        }
        [[ -n $payload ]] && curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
            -H "User-Agent: Hoist" -H "Content-Type: application/json" \
            -d "$payload" -- "$GLOBAL_SLACK_WEBHOOK" 2>/dev/null || \
            { [[ $VERBOSE == true ]] && log "Warning: Slack self-update notification failed"; }
    fi
    if [[ -n $GLOBAL_GENERIC_WEBHOOK ]]; then
        payload=$(jq -n \
            --arg type "self_update_available" \
            --arg cur "$HOIST_VERSION" \
            --arg new "$new_ver" \
            --arg url "$release_url" \
            --arg ts "$(_iso_ts)" \
            '{"type":$type,"current_version":$cur,"new_version":$new,"release_url":$url,"timestamp":$ts}') || {
            [[ $VERBOSE == true ]] && log "Warning: failed to build generic payload for self-update notify"
        }
        [[ -n $payload ]] && curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
            -H "User-Agent: Hoist" -H "Content-Type: application/json" \
            -d "$payload" -- "$GLOBAL_GENERIC_WEBHOOK" 2>/dev/null || \
            { [[ $VERBOSE == true ]] && log "Warning: generic self-update notification failed"; }
    fi
}

_self_update_apply() {
    local new_ver="$1" asset_url="$2" sha256_url="$3" silent="${4:-false}"
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null)
    [[ -z $script_path ]] && script_path=$(cd "$(dirname "$0")" && echo "$(pwd)/$(basename "$0")")

    [[ -f $script_path ]] || {
        log "Error: cannot resolve script path for self-update: $script_path"
        return 1
    }
    [[ -w $script_path ]] || { log "Error: $script_path is not writable — cannot self-update"; return 1; }

    local tmp_script tmp_sha256 script_dir
    script_dir=$(dirname "$script_path")
    # Create the replacement in the script's own directory so the final mv is a
    # same-filesystem atomic rename, not a cross-fs copy into the live inode
    # (which a concurrent reader could observe half-written).
    tmp_script=$(mktemp "${script_dir}/.hoist-update-XXXXXX") || {
        log "Error: cannot create temp file in ${script_dir} for update download"
        return 1
    }
    tmp_sha256=$(mktemp /tmp/hoist-update-XXXXXX.sha256) || {
        log "Error: cannot create temp file for SHA256"
        rm -f "$tmp_script"
        return 1
    }

    _suu_cleanup() { rm -f "$tmp_script" "$tmp_sha256"; }

    [[ $silent == false ]] && log "Downloading hoist.sh v${new_ver}..."
    curl -fsSL --max-time 60 --connect-timeout 10 \
        -H "User-Agent: Hoist/${HOIST_VERSION}" \
        -o "$tmp_script" "$asset_url" || {
        log "Error: failed to download hoist v${new_ver} from ${asset_url}"
        _suu_cleanup; return 1
    }

    [[ $silent == false ]] && log "Downloading SHA256 checksum..."
    curl -fsSL --max-time 10 --connect-timeout 5 \
        -H "User-Agent: Hoist/${HOIST_VERSION}" \
        -o "$tmp_sha256" "$sha256_url" || {
        log "Error: failed to download SHA256 for hoist v${new_ver} from ${sha256_url}"
        _suu_cleanup; return 1
    }

    local expected_hash actual_hash
    expected_hash=$(awk '{print $1}' "$tmp_sha256")
    [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || {
        log "Error: malformed SHA256 file (got: '${expected_hash}')"
        _suu_cleanup; return 1
    }
    actual_hash=$(_sha256 "$tmp_script") || {
        log "Error: cannot compute SHA256 (no sha256sum or shasum available)"
        _suu_cleanup; return 1
    }
    if [[ $expected_hash != "$actual_hash" ]]; then
        log "Error: SHA256 mismatch — aborting update (expected: ${expected_hash}, got: ${actual_hash})"
        _suu_cleanup; return 1
    fi

    # Preserve original file mode and ownership so the replaced script remains
    # readable/executable for non-root users (mktemp creates 0600, which would
    # otherwise lock everyone but the updater out).
    local orig_mode orig_owner
    orig_mode=$(stat -c '%a' "$script_path" 2>/dev/null)
    [[ -z $orig_mode ]] && orig_mode=$(stat -f '%Lp' "$script_path" 2>/dev/null)
    [[ -z $orig_mode ]] && orig_mode=755
    orig_owner=$(stat -c '%u:%g' "$script_path" 2>/dev/null)
    [[ -z $orig_owner ]] && orig_owner=$(stat -f '%u:%g' "$script_path" 2>/dev/null)

    chmod "$orig_mode" "$tmp_script" || chmod +x "$tmp_script"
    [[ -n $orig_owner ]] && chown "$orig_owner" "$tmp_script" 2>/dev/null
    mv "$tmp_script" "$script_path" || { log "Error: mv failed — update aborted"; _suu_cleanup; return 1; }
    log "Updated to v${new_ver}. Restart hoist to use the new version."
    rm -f "$tmp_sha256" "${CACHE_LOCATION}/hoist-self-v${new_ver}.notified"
}

_self_update_check() {
    local interactive="${1:-false}"
    local force="${2:-false}"
    local timeout_arg=5
    [[ $interactive == true ]] && timeout_arg=15

    local api_response _api_raw _http_code
    _api_raw=$(curl -sSL -w '\n%{http_code}' \
        --max-time "$timeout_arg" --connect-timeout 5 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "User-Agent: Hoist/${HOIST_VERSION}" \
        "https://api.github.com/repos/${HOIST_REPO}/releases/latest" 2>/dev/null)
    _http_code="${_api_raw##*$'\n'}"
    api_response="${_api_raw%$'\n'*}"

    if [[ $_http_code == 000 || -z $_http_code ]]; then
        if [[ $interactive == true ]]; then log "Error: could not reach GitHub API (network failure or timeout)"; exit 1; fi
        [[ $VERBOSE == true ]] && log "Self-update check failed (network), skipping"
        return 0
    fi
    if [[ $_http_code == 404 ]]; then
        if [[ $interactive == true ]]; then
            log "Error: no releases published yet for ${HOIST_REPO} — see https://github.com/${HOIST_REPO}/releases"
            exit 1
        fi
        [[ $VERBOSE == true ]] && log "Self-update: no releases published for ${HOIST_REPO}, skipping"
        return 0
    fi
    if [[ $_http_code != 200 ]]; then
        if [[ $interactive == true ]]; then log "Error: GitHub API returned HTTP ${_http_code}"; exit 1; fi
        [[ $VERBOSE == true ]] && log "Self-update: GitHub API returned HTTP ${_http_code}, skipping"
        return 0
    fi

    local latest_tag latest_version release_url asset_url sha256_url release_body
    latest_tag=$(jq -r '.tag_name // empty' <<< "$api_response")
    [[ -z $latest_tag ]] && {
        if [[ $interactive == true ]]; then log "Error: malformed API response"; exit 1; fi
        return 0
    }
    latest_version="${latest_tag#v}"
    release_url=$(jq -r '.html_url // empty' <<< "$api_response")
    [[ -z $release_url ]] && release_url="https://github.com/${HOIST_REPO}/releases/tag/v${latest_version}"
    asset_url=$(jq -r '.assets[] | select(.name == "hoist.sh") | .browser_download_url' <<< "$api_response")
    sha256_url=$(jq -r '.assets[] | select(.name == "hoist.sh.sha256") | .browser_download_url' <<< "$api_response")
    release_body=$(jq -r '.body // empty' <<< "$api_response")
    if [[ -z $asset_url || -z $sha256_url ]]; then
        if [[ $interactive == true ]]; then
            log "Error: release v${latest_version} is missing hoist.sh or hoist.sh.sha256 assets"
            exit 1
        fi
        [[ $VERBOSE == true ]] && log "Update v${latest_version} skipped — release assets not found"
        return 0
    fi

    if ! _semver_gt "$latest_version" "$HOIST_VERSION"; then
        if [[ $interactive == true ]]; then log "Already up to date (v${HOIST_VERSION})"; exit 0; fi
        [[ $VERBOSE == true ]] && log "hoist is up to date (v${HOIST_VERSION})"
        return 0
    fi

    local sentinel="${CACHE_LOCATION}/hoist-self-v${latest_version}.notified"

    # Sentinel suppresses repeat notifications on automated runs; --update (interactive) always proceeds
    if [[ $interactive == false && -f $sentinel ]]; then
        [[ $VERBOSE == true ]] && log "Update notification already sent for v${latest_version}"
        return 0
    fi

    log "hoist v${latest_version} available (current: v${HOIST_VERSION}) — run with --update to upgrade"
    log "  Release: ${release_url}"

    if [[ $interactive == false ]]; then
        _self_update_notify "$latest_version" "$release_url"
        ( umask 177 && printf '%s' "$latest_version" > "$sentinel" ) || \
            log "Warning: could not write update sentinel ${sentinel} — notifications may repeat"
        if [[ $UPDATE_CHECK == "update" ]]; then
            log "UPDATE_CHECK=update — applying automatically"
            _self_update_apply "$latest_version" "$asset_url" "$sha256_url" true || \
                log "Auto-update to v${latest_version} failed — continuing container management"
        fi
        return 0
    fi

    if [[ -n $release_body ]]; then
        printf '\n%s\n\n' "$(sed 's/^/  /' <<< "$release_body" | head -30)"
    fi

    if [[ $DRY_RUN == true ]]; then
        log "[dry-run] would download: $asset_url"
        log "[dry-run] would verify SHA256 from: $sha256_url"
        log "[dry-run] would replace: $(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"
        exit 0
    fi

    if [[ $force == false ]]; then
        read -rp "Update now? [y/N] " _answer
        [[ ${_answer,,} == y ]] || { log "Update cancelled."; exit 0; }
    fi

    _self_update_apply "$latest_version" "$asset_url" "$sha256_url" false || exit 1
    exit 0
}

# ============================================================================
# Cron / scheduler setup (--cron <action>)
# ============================================================================

_CRON_PATH_D="/etc/cron.d/hoist"
_CRON_LOG_FILE="/var/log/hoist.log"
_CRON_SYSTEMD_SERVICE="/etc/systemd/system/hoist.service"
_CRON_SYSTEMD_TIMER="/etc/systemd/system/hoist.timer"
_CRON_SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
_CRON_SYSTEMD_USER_SERVICE="$_CRON_SYSTEMD_USER_DIR/hoist.service"
_CRON_SYSTEMD_USER_TIMER="$_CRON_SYSTEMD_USER_DIR/hoist.timer"
_CRON_MARKER="# Managed by hoist --cron install"

# Run a command with sudo iff the nearest existing ancestor of target isn't
# writable. Walks up so deeply-nested missing paths are handled correctly.
_sudo_if_needed() {
    local target="$1"; shift
    local probe="$target"
    while [[ ! -e "$probe" && "$probe" != "/" ]]; do
        probe="$(dirname "$probe")"
    done
    if [[ -w "$probe" ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "Error: cannot write to $target and sudo is not available" >&2
        return 1
    fi
}

_resolve_hoist_path() {
    local p
    p=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null)
    [[ -z $p ]] && p=$(cd "$(dirname "$0")" 2>/dev/null && echo "$(pwd)/$(basename "$0")")
    [[ -f $p ]] || { echo "Error: cannot resolve hoist binary path: ${p:-<unknown>}" >&2; return 1; }
    printf '%s' "$p"
}

# Echoes one of: launchd-doc, both, systemd, cron, none.
_detect_scheduler() {
    if [[ "$(uname -s)" == Darwin ]]; then
        echo "launchd-doc"
        return 0
    fi
    local has_systemd=false has_cron=false
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        has_systemd=true
    fi
    if [[ -d /etc/cron.d ]] \
       || command -v crond >/dev/null 2>&1 \
       || command -v cron  >/dev/null 2>&1 \
       || [[ -d /etc/crontabs ]]; then
        has_cron=true
    fi
    if   [[ $has_systemd == true && $has_cron == true ]]; then echo "both"
    elif [[ $has_systemd == true ]];                       then echo "systemd"
    elif [[ $has_cron == true ]];                          then echo "cron"
    else                                                        echo "none"
    fi
}

_cron_preset_to_cron() {
    case "$1" in
        30min)   echo "*/30 * * * *" ;;
        hourly)  echo "0 * * * *" ;;
        6hourly) echo "0 */6 * * *" ;;
        daily)   echo "0 3 * * *" ;;
        weekly)  echo "0 3 * * 0" ;;
        *) return 1 ;;
    esac
}

_cron_preset_to_systemd() {
    case "$1" in
        30min)   echo "*:0/30" ;;
        hourly)  echo "hourly" ;;
        6hourly) echo "0/6:00:00" ;;
        daily)   echo "*-*-* 03:00:00" ;;
        weekly)  echo "Sun *-*-* 03:00:00" ;;
        *) return 1 ;;
    esac
}

_validate_cron_expr() {
    local expr="$1" n
    n=$(awk '{print NF}' <<< "$expr")
    [[ $n -eq 5 ]] || { echo "Error: cron expression must have exactly 5 fields (got $n): $expr" >&2; return 1; }
    return 0
}

_validate_systemd_calendar() {
    local expr="$1"
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        echo "Error: systemd-analyze not available — cannot validate OnCalendar expression: $expr" >&2
        echo "       Install the systemd package or use --backend cron." >&2
        return 1
    fi
    systemd-analyze calendar "$expr" >/dev/null 2>&1 \
        || { echo "Error: invalid systemd OnCalendar expression: $expr" >&2; return 1; }
}

# Render preset OR custom expression for the chosen backend. Echoes result.
_cron_render_schedule() {
    local backend="$1" input="$2"
    case "$input" in
        30min|hourly|6hourly|daily|weekly)
            if [[ $backend == cron ]]; then _cron_preset_to_cron "$input"
            else                            _cron_preset_to_systemd "$input"
            fi ;;
        *)
            if [[ $backend == cron ]]; then
                _validate_cron_expr "$input" || return 1
            else
                _validate_systemd_calendar "$input" || return 1
            fi
            printf '%s' "$input" ;;
    esac
}

# ----- cron backend -----

_cron_render_file() {
    local schedule_expr="$1" run_user="$2" hoist_bin="$3"
    cat <<EOF
${_CRON_MARKER} — do not edit; re-run \`hoist --cron install\` to change.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${schedule_expr} ${run_user} ${hoist_bin} >> ${_CRON_LOG_FILE} 2>&1
EOF
}

_cron_backend_install() {
    local schedule_expr="$1" run_user="$2" hoist_bin="$3"
    if [[ -e $_CRON_PATH_D ]] && ! head -n1 "$_CRON_PATH_D" 2>/dev/null | grep -qF "$_CRON_MARKER"; then
        log "Error: refusing to overwrite hand-managed $_CRON_PATH_D (no hoist marker found)"
        log "       remove it manually if you want hoist to manage scheduling"
        return 1
    fi

    local content; content=$(_cron_render_file "$schedule_expr" "$run_user" "$hoist_bin")
    if [[ $DRY_RUN == true ]]; then
        log "[dry-run] would write $_CRON_PATH_D:"
        printf '%s\n' "$content" | sed 's/^/    /'
        log "[dry-run] would touch $_CRON_LOG_FILE"
        return 0
    fi

    local cron_dir; cron_dir=$(dirname "$_CRON_PATH_D")
    if [[ ! -d $cron_dir ]]; then
        _sudo_if_needed "$cron_dir" mkdir -p "$cron_dir" \
            || { log "Error: cannot create $cron_dir"; return 1; }
    fi

    local tmp
    tmp=$(mktemp /tmp/hoist-cron.XXXXXX) || { log "Error: cannot create temp file"; return 1; }
    printf '%s\n' "$content" > "$tmp"
    _sudo_if_needed "$_CRON_PATH_D" install -m 0644 "$tmp" "$_CRON_PATH_D" \
        || { rm -f "$tmp"; log "Error: failed to install $_CRON_PATH_D"; return 1; }
    rm -f "$tmp"

    if _sudo_if_needed "$_CRON_LOG_FILE" touch "$_CRON_LOG_FILE" 2>/dev/null; then
        if [[ $run_user != root ]]; then
            _sudo_if_needed "$_CRON_LOG_FILE" chown "$run_user" "$_CRON_LOG_FILE" 2>/dev/null \
                || log "Warning: could not chown $_CRON_LOG_FILE to $run_user — schedule will fail to write logs"
        fi
    else
        log "Warning: could not create $_CRON_LOG_FILE — cron will fail to redirect output"
    fi
    log "Installed $_CRON_PATH_D (schedule: $schedule_expr, user: $run_user)"
    log "Logs: $_CRON_LOG_FILE"
}

_cron_backend_remove() {
    if [[ ! -e $_CRON_PATH_D ]]; then
        log "cron: nothing to remove ($_CRON_PATH_D not present)"
        return 0
    fi
    if ! head -n1 "$_CRON_PATH_D" 2>/dev/null | grep -qF "$_CRON_MARKER"; then
        log "Error: $_CRON_PATH_D is not hoist-managed — refusing to remove"
        return 1
    fi
    if [[ $DRY_RUN == true ]]; then
        log "[dry-run] would remove $_CRON_PATH_D"
        return 0
    fi
    _sudo_if_needed "$_CRON_PATH_D" rm -f "$_CRON_PATH_D" || return 1
    log "Removed $_CRON_PATH_D"
}

_cron_backend_status() {
    [[ -e $_CRON_PATH_D ]] || return 1
    if head -n1 "$_CRON_PATH_D" 2>/dev/null | grep -qF "$_CRON_MARKER"; then
        log "cron: managed schedule active at $_CRON_PATH_D"
        grep -E '^[^# ].*[*0-9]' "$_CRON_PATH_D" | tail -n1 | sed 's/^/    /'
    else
        log "cron: $_CRON_PATH_D exists but is NOT hoist-managed"
    fi
    return 0
}

# ----- systemd backend -----

_systemd_render_service() {
    local run_user="$1" hoist_bin="$2"
    cat <<EOF
${_CRON_MARKER} — do not edit; re-run \`hoist --cron install\` to change.
[Unit]
Description=Hoist — auto-update Docker containers via labels
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
User=${run_user}
ExecStart=${hoist_bin}
EOF
}

_systemd_render_timer() {
    local on_calendar="$1"
    cat <<EOF
${_CRON_MARKER} — do not edit; re-run \`hoist --cron install\` to change.
[Unit]
Description=Run hoist on schedule

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

_systemd_backend_install() {
    local on_calendar="$1" run_user="$2" hoist_bin="$3"
    local f
    for f in "$_CRON_SYSTEMD_SERVICE" "$_CRON_SYSTEMD_TIMER"; do
        if [[ -e $f ]] && ! head -n1 "$f" 2>/dev/null | grep -qF "$_CRON_MARKER"; then
            log "Error: refusing to overwrite hand-managed $f (no hoist marker found)"
            return 1
        fi
    done

    local svc tmr
    svc=$(_systemd_render_service "$run_user" "$hoist_bin")
    tmr=$(_systemd_render_timer "$on_calendar")

    if [[ $DRY_RUN == true ]]; then
        log "[dry-run] would write $_CRON_SYSTEMD_SERVICE:"
        printf '%s\n' "$svc" | sed 's/^/    /'
        log "[dry-run] would write $_CRON_SYSTEMD_TIMER:"
        printf '%s\n' "$tmr" | sed 's/^/    /'
        log "[dry-run] would: systemctl daemon-reload && systemctl enable --now hoist.timer"
        return 0
    fi

    local tmp_svc tmp_tmr
    tmp_svc=$(mktemp /tmp/hoist-systemd.XXXXXX) || return 1
    tmp_tmr=$(mktemp /tmp/hoist-systemd.XXXXXX) || { rm -f "$tmp_svc"; return 1; }
    printf '%s\n' "$svc" > "$tmp_svc"
    printf '%s\n' "$tmr" > "$tmp_tmr"
    _sudo_if_needed "$_CRON_SYSTEMD_SERVICE" install -m 0644 "$tmp_svc" "$_CRON_SYSTEMD_SERVICE" \
        || { rm -f "$tmp_svc" "$tmp_tmr"; log "Error: failed to install $_CRON_SYSTEMD_SERVICE"; return 1; }
    _sudo_if_needed "$_CRON_SYSTEMD_TIMER" install -m 0644 "$tmp_tmr" "$_CRON_SYSTEMD_TIMER" \
        || { rm -f "$tmp_svc" "$tmp_tmr"; log "Error: failed to install $_CRON_SYSTEMD_TIMER"; return 1; }
    rm -f "$tmp_svc" "$tmp_tmr"
    _sudo_if_needed /etc/systemd systemctl daemon-reload || return 1
    _sudo_if_needed /etc/systemd systemctl enable --now hoist.timer || return 1
    log "Installed hoist.timer (OnCalendar=$on_calendar, user: $run_user)"
    log "Logs: journalctl -u hoist.service"
}

_systemd_backend_remove() {
    local found=false f
    for f in "$_CRON_SYSTEMD_SERVICE" "$_CRON_SYSTEMD_TIMER"; do
        [[ -e $f ]] || continue
        found=true
        head -n1 "$f" 2>/dev/null | grep -qF "$_CRON_MARKER" \
            || { log "Error: $f is not hoist-managed — refusing to remove"; return 1; }
    done
    if [[ $found == false ]]; then
        log "systemd: nothing to remove (no hoist.service or hoist.timer)"
        return 0
    fi
    if [[ $DRY_RUN == true ]]; then
        log "[dry-run] would: systemctl disable --now hoist.timer; rm hoist.{service,timer}; daemon-reload"
        return 0
    fi
    _sudo_if_needed /etc/systemd systemctl disable --now hoist.timer 2>/dev/null || true
    _sudo_if_needed "$_CRON_SYSTEMD_SERVICE" rm -f "$_CRON_SYSTEMD_SERVICE" "$_CRON_SYSTEMD_TIMER" || return 1
    _sudo_if_needed /etc/systemd systemctl daemon-reload || return 1
    log "Removed hoist.service and hoist.timer"
}

_systemd_backend_status() {
    [[ -e $_CRON_SYSTEMD_TIMER ]] || return 1
    if head -n1 "$_CRON_SYSTEMD_TIMER" 2>/dev/null | grep -qF "$_CRON_MARKER"; then
        log "systemd: managed timer at $_CRON_SYSTEMD_TIMER"
        systemctl list-timers hoist.timer --all 2>/dev/null | head -n2 | sed 's/^/    /'
    else
        log "systemd: $_CRON_SYSTEMD_TIMER exists but is NOT hoist-managed"
    fi
    return 0
}

# ----- systemd user backend -----

_systemd_render_service_user() {
    local hoist_bin="$1"
    local env_lines="$2"
    cat <<EOF
${_CRON_MARKER} — do not edit; re-run \`hoist --cron install\` to change.
[Unit]
Description=Hoist — auto-update Docker containers via labels

[Service]
Type=oneshot
${env_lines}ExecStart=${hoist_bin}
EOF
}

# Decide whether to pin DOCKER_HOST into the user unit.
# Returns the value to pin on stdout, or empty if no pin is needed.
# Precedence: explicit --docker-host flag wins. Otherwise auto-detect: pin
# only when DOCKER_HOST is set in the caller's env (so we know the user
# relies on it) AND the user manager doesn't already have it AND no docker
# context is steering the connection. This covers the common rootless-docker
# case where DOCKER_HOST lives in ~/.zshrc / ~/.bashrc and would silently
# disappear under a systemd --user timer.
_detect_user_docker_host() {
    if [[ -n ${CRON_DOCKER_HOST_FLAG:-} ]]; then
        printf '%s' "$CRON_DOCKER_HOST_FLAG"
        return 0
    fi
    [[ -n ${DOCKER_HOST:-} ]] || return 0
    if systemctl --user show-environment 2>/dev/null | grep -q '^DOCKER_HOST='; then
        return 0
    fi
    local ctx
    ctx=$(docker context show 2>/dev/null || true)
    [[ -z $ctx || $ctx == default ]] || return 0
    printf '%s' "$DOCKER_HOST"
}

_systemd_render_timer_user() {
    local on_calendar="$1"
    cat <<EOF
${_CRON_MARKER} — do not edit; re-run \`hoist --cron install\` to change.
[Unit]
Description=Run hoist on schedule

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=default.target
EOF
}

_systemd_user_backend_install() {
    local on_calendar="$1" hoist_bin="$2"
    local f
    for f in "$_CRON_SYSTEMD_USER_SERVICE" "$_CRON_SYSTEMD_USER_TIMER"; do
        if [[ -e $f ]] && ! head -n1 "$f" 2>/dev/null | grep -qF "$_CRON_MARKER"; then
            log "Error: refusing to overwrite hand-managed $f (no hoist marker found)"
            return 1
        fi
    done

    local pinned_docker_host env_lines="" pin_source=""
    pinned_docker_host=$(_detect_user_docker_host)
    if [[ -n $pinned_docker_host ]]; then
        env_lines="Environment=DOCKER_HOST=${pinned_docker_host}"$'\n'
        if [[ -n ${CRON_DOCKER_HOST_FLAG:-} ]]; then
            pin_source="--docker-host flag"
        else
            pin_source="rootless docker detected"
        fi
    fi

    local svc tmr
    svc=$(_systemd_render_service_user "$hoist_bin" "$env_lines")
    tmr=$(_systemd_render_timer_user "$on_calendar")

    if [[ $DRY_RUN == true ]]; then
        log "[dry-run] would write $_CRON_SYSTEMD_USER_SERVICE:"
        printf '%s\n' "$svc" | sed 's/^/    /'
        log "[dry-run] would write $_CRON_SYSTEMD_USER_TIMER:"
        printf '%s\n' "$tmr" | sed 's/^/    /'
        log "[dry-run] would: systemctl --user daemon-reload && systemctl --user enable --now hoist.timer"
        [[ -n $pinned_docker_host ]] && \
            log "[dry-run] would pin DOCKER_HOST=${pinned_docker_host} (${pin_source})"
        return 0
    fi

    mkdir -p "$_CRON_SYSTEMD_USER_DIR" \
        || { log "Error: cannot create $_CRON_SYSTEMD_USER_DIR"; return 1; }
    printf '%s\n' "$svc" > "$_CRON_SYSTEMD_USER_SERVICE" \
        || { log "Error: failed to write $_CRON_SYSTEMD_USER_SERVICE"; return 1; }
    printf '%s\n' "$tmr" > "$_CRON_SYSTEMD_USER_TIMER" \
        || { log "Error: failed to write $_CRON_SYSTEMD_USER_TIMER"; return 1; }
    systemctl --user daemon-reload || return 1
    systemctl --user enable --now hoist.timer || return 1
    log "Installed user hoist.timer (OnCalendar=$on_calendar)"
    [[ -n $pinned_docker_host ]] && \
        log "Pinned DOCKER_HOST=${pinned_docker_host} into hoist.service (${pin_source})"
    log "Logs: journalctl --user -u hoist.service"
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "^Linger=yes"; then
        log "Tip: run 'loginctl enable-linger $USER' so the timer starts at boot without a login session"
    fi
}

_systemd_user_backend_remove() {
    local found=false f
    for f in "$_CRON_SYSTEMD_USER_SERVICE" "$_CRON_SYSTEMD_USER_TIMER"; do
        [[ -e $f ]] || continue
        found=true
        head -n1 "$f" 2>/dev/null | grep -qF "$_CRON_MARKER" \
            || { log "Error: $f is not hoist-managed — refusing to remove"; return 1; }
    done
    if [[ $found == false ]]; then
        log "systemd (user): nothing to remove"
        return 0
    fi
    if [[ $DRY_RUN == true ]]; then
        log "[dry-run] would: systemctl --user disable --now hoist.timer; rm hoist.{service,timer}; --user daemon-reload"
        return 0
    fi
    systemctl --user disable --now hoist.timer 2>/dev/null || true
    rm -f "$_CRON_SYSTEMD_USER_SERVICE" "$_CRON_SYSTEMD_USER_TIMER" || return 1
    systemctl --user daemon-reload || return 1
    log "Removed user hoist.service and hoist.timer"
}

_systemd_user_backend_status() {
    [[ -e $_CRON_SYSTEMD_USER_TIMER ]] || return 1
    if head -n1 "$_CRON_SYSTEMD_USER_TIMER" 2>/dev/null | grep -qF "$_CRON_MARKER"; then
        log "systemd (user): managed timer at $_CRON_SYSTEMD_USER_TIMER"
        systemctl --user list-timers hoist.timer --all 2>/dev/null | head -n2 | sed 's/^/    /'
    else
        log "systemd (user): $_CRON_SYSTEMD_USER_TIMER exists but is NOT hoist-managed"
    fi
    return 0
}

# ----- launchd doc fallback (macOS) -----

_launchd_doc() {
    cat >&2 <<EOF
hoist --cron is not implemented for macOS (launchd) — see docs:

  https://github.com/${HOIST_REPO}/blob/master/docs/scheduling.md#macos-launchd

Quick start: place a plist at ~/Library/LaunchAgents/com.sumguy.hoist.plist
and load it with: launchctl load -w <path>
EOF
}

# ----- prompts (write to stderr; echo result on stdout) -----

_prompt_scope() {
    {
        echo "Install scope:"
        echo "  user   — systemd --user units in ~/.config/systemd/user/ (no sudo needed)"
        echo "  system — /etc/cron.d or /etc/systemd/system/ (sudo may be required)"
    } >&2
    local ans
    read -rp "Scope [user]: " ans >&2
    ans="${ans:-user}"
    case "${ans,,}" in
        user|system) printf '%s' "${ans,,}" ;;
        *) echo "Error: invalid scope: $ans (expected 'user' or 'system')" >&2; return 1 ;;
    esac
}

_cron_user_no_systemd_guidance() {
    local hoist_bin="$1"
    cat >&2 <<EOF
User-scope scheduling requires systemd, which was not detected on this system.

To schedule hoist with cron you need to install a file into /etc/cron.d/ (system-wide,
requires root). Options:

  sudo hoist --cron install --scope system --schedule <preset> --user <name>

Or generate the file and place it yourself:

  hoist --cron print --schedule <preset> --user <name> | sudo tee /etc/cron.d/hoist

EOF
    if [[ -t 1 ]]; then
        local ans
        read -rp "Print a sample /etc/cron.d/hoist file now? [y/N] " ans >&2
        if [[ ${ans,,} == y ]]; then
            local schedule_input run_user schedule_expr
            schedule_input=$(_prompt_schedule) || return 1
            run_user=$(_prompt_user) || return 1
            schedule_expr=$(_cron_render_schedule cron "$schedule_input") || return 1
            _cron_render_file "$schedule_expr" "$run_user" "$hoist_bin"
        fi
    fi
    return 2
}

_prompt_backend() {
    local detected="$1"
    if [[ $detected != both ]]; then
        echo "$detected"
        return 0
    fi
    local ans
    read -rp "Backend? [systemd/cron] (default: systemd): " ans >&2
    case "${ans,,}" in
        ""|systemd) echo systemd ;;
        cron)       echo cron ;;
        *) echo "Error: invalid backend: $ans" >&2; return 1 ;;
    esac
}

_prompt_schedule() {
    {
        echo "Schedule presets:"
        echo "  30min    - every 30 minutes"
        echo "  hourly   - on the hour (default)"
        echo "  6hourly  - every 6 hours"
        echo "  daily    - daily at 03:00"
        echo "  weekly   - Sunday 03:00"
        echo "  custom   - enter your own expression"
    } >&2
    local ans
    read -rp "Schedule [hourly]: " ans >&2
    ans="${ans:-hourly}"
    if [[ $ans == custom ]]; then
        read -rp "Custom expression: " ans >&2
        [[ -n $ans ]] || { echo "Error: empty schedule" >&2; return 1; }
    fi
    printf '%s' "$ans"
}

_validate_user() {
    local user="$1"
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$user" >/dev/null 2>&1 \
            || { echo "Error: user does not exist: $user" >&2; return 1; }
    elif ! id "$user" >/dev/null 2>&1; then
        echo "Error: user does not exist: $user" >&2; return 1
    fi
    if [[ $user != root ]] && ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "Warning: user '$user' is not in the docker group — hoist will fail unless that's fixed" >&2
    fi
    return 0
}

_prompt_user() {
    local default="root"
    [[ -n ${SUDO_USER:-} ]] && default="$SUDO_USER"
    local ans
    read -rp "Run hoist as which user? [$default]: " ans >&2
    ans="${ans:-$default}"
    _validate_user "$ans" || return 1
    printf '%s' "$ans"
}

# ----- orchestrators -----

_cron_install_orchestrate() {
    local schedule_input="${CRON_SCHEDULE_FLAG:-}"
    local run_user="${CRON_USER_FLAG:-}"
    local backend="${CRON_BACKEND_FLAG:-}"
    local scope="${CRON_SCOPE_FLAG:-}"
    local detected
    detected=$(_detect_scheduler)
    case "$detected" in
        launchd-doc) _launchd_doc; return 2 ;;
        none)        log "Error: no supported scheduler found (need cron or systemd)"; return 1 ;;
    esac

    if [[ -n $backend && $backend != cron && $backend != systemd ]]; then
        log "Error: --backend must be 'cron' or 'systemd' (got: $backend)"; return 1
    fi
    if [[ -n $backend && $detected != both && $detected != "$backend" ]]; then
        log "Error: --backend $backend requested but only '$detected' is available"; return 1
    fi
    if [[ -n $scope && $scope != user && $scope != system ]]; then
        log "Error: --scope must be 'user' or 'system' (got: $scope)"; return 1
    fi

    # Root always installs system-wide; skip the scope prompt.
    [[ $EUID -eq 0 ]] && scope=system

    # Fail fast on non-TTY when a prompt would be required.
    local needs_prompt=false
    [[ -z $schedule_input ]] && needs_prompt=true
    [[ $EUID -ne 0 && -z $scope ]] && needs_prompt=true
    [[ ( -z $scope || $scope == system ) && -z $run_user ]] && needs_prompt=true
    [[ $detected == both && -z $backend && ( -z $scope || $scope == system ) ]] && needs_prompt=true
    if [[ $needs_prompt == true && ! -t 0 ]]; then
        log "Error: --cron install needs an interactive terminal for missing values."
        local flags="--schedule"
        [[ $EUID -ne 0 ]] && flags="$flags, --scope"
        [[ -z $scope || $scope == system ]] && flags="$flags, --user"
        [[ $detected == both && ( -z $scope || $scope == system ) ]] && flags="$flags, --backend"
        log "  Pass $flags to run non-interactively."
        return 1
    fi

    [[ -n $scope ]] || scope=$(_prompt_scope) || return 1

    if [[ -n ${CRON_DOCKER_HOST_FLAG:-} && $scope != user ]]; then
        log "Error: --docker-host is only supported with --scope user."
        return 1
    fi

    # ---- user scope: systemd --user only ----
    if [[ $scope == user ]]; then
        if [[ -n $backend && $backend == cron ]]; then
            log "Error: --backend cron is not supported with --scope user."
            log "  Use --scope system for cron, or omit --backend to use systemd --user."
            return 1
        fi
        if [[ $detected != systemd && $detected != both ]]; then
            local hoist_bin; hoist_bin=$(_resolve_hoist_path) || return 1
            _cron_user_no_systemd_guidance "$hoist_bin"
            return $?
        fi
        backend=systemd
        [[ -n $schedule_input ]] || schedule_input=$(_prompt_schedule) || return 1
        local schedule_expr
        schedule_expr=$(_cron_render_schedule "$backend" "$schedule_input") || return 1
        local hoist_bin; hoist_bin=$(_resolve_hoist_path) || return 1

        local fully_scripted=false
        [[ -n ${CRON_SCHEDULE_FLAG:-} && -n ${CRON_SCOPE_FLAG:-} ]] && fully_scripted=true

        if [[ $DRY_RUN != true && $fully_scripted == false ]]; then
            log "About to install (user scope):"
            log "  units:     $_CRON_SYSTEMD_USER_DIR"
            log "  schedule:  $schedule_expr"
            log "  hoist bin: $hoist_bin"
            local ans
            read -rp "Proceed? [y/N] " ans
            [[ ${ans,,} == y ]] || { log "Cancelled."; return 0; }
        fi
        _systemd_user_backend_install "$schedule_expr" "$hoist_bin"
        return $?
    fi

    # ---- system scope: existing flow ----
    [[ -n $backend ]]        || backend=$(_prompt_backend "$detected") || return 1
    [[ -n $schedule_input ]] || schedule_input=$(_prompt_schedule) || return 1
    if [[ -n $run_user ]]; then
        _validate_user "$run_user" || return 1
    else
        run_user=$(_prompt_user) || return 1
    fi

    local schedule_expr
    schedule_expr=$(_cron_render_schedule "$backend" "$schedule_input") || return 1

    local hoist_bin
    hoist_bin=$(_resolve_hoist_path) || return 1

    local fully_scripted=false
    [[ -n ${CRON_SCHEDULE_FLAG:-} && -n ${CRON_USER_FLAG:-} ]] \
        && { [[ $detected != both || -n ${CRON_BACKEND_FLAG:-} ]]; } \
        && fully_scripted=true

    if [[ $DRY_RUN != true && $fully_scripted == false ]]; then
        log "About to install:"
        log "  backend:   $backend"
        log "  schedule:  $schedule_expr"
        log "  user:      $run_user"
        log "  hoist bin: $hoist_bin"
        local ans
        read -rp "Proceed? [y/N] " ans
        [[ ${ans,,} == y ]] || { log "Cancelled."; return 0; }
    fi

    case "$backend" in
        cron)    _cron_backend_install "$schedule_expr" "$run_user" "$hoist_bin" ;;
        systemd) _systemd_backend_install "$schedule_expr" "$run_user" "$hoist_bin" ;;
    esac
}

_cron_remove_orchestrate() {
    local detected; detected=$(_detect_scheduler)
    if [[ $detected == launchd-doc ]]; then _launchd_doc; return 2; fi

    local removed_any=false
    if [[ -e $_CRON_PATH_D ]]; then
        if _cron_backend_remove; then removed_any=true; else return 1; fi
    fi
    if [[ -e $_CRON_SYSTEMD_TIMER || -e $_CRON_SYSTEMD_SERVICE ]]; then
        if _systemd_backend_remove; then removed_any=true; else return 1; fi
    fi
    if [[ -e $_CRON_SYSTEMD_USER_TIMER || -e $_CRON_SYSTEMD_USER_SERVICE ]]; then
        if _systemd_user_backend_remove; then removed_any=true; else return 1; fi
    fi
    [[ $removed_any == true ]] || log "Nothing to remove."
    return 0
}

_cron_print_orchestrate() {
    local backend="${CRON_BACKEND_FLAG:-}"
    local detected; detected=$(_detect_scheduler)
    if [[ -n $backend ]]; then
        if [[ $backend != cron && $backend != systemd ]]; then
            log "Error: --backend must be 'cron' or 'systemd' (got: $backend)"; return 1
        fi
    else
        case "$detected" in
            both|systemd) backend=systemd ;;
            cron|none)    backend=cron ;;
            launchd-doc)  _launchd_doc; return 2 ;;
        esac
    fi
    local schedule_input="${CRON_SCHEDULE_FLAG:-hourly}"
    local run_user="${CRON_USER_FLAG:-root}"
    local hoist_bin schedule_expr
    hoist_bin=$(_resolve_hoist_path) || return 1
    schedule_expr=$(_cron_render_schedule "$backend" "$schedule_input") || return 1
    case "$backend" in
        cron)
            echo "# === ${_CRON_PATH_D} ==="
            _cron_render_file "$schedule_expr" "$run_user" "$hoist_bin" ;;
        systemd)
            echo "# === ${_CRON_SYSTEMD_SERVICE} ==="
            _systemd_render_service "$run_user" "$hoist_bin"
            echo
            echo "# === ${_CRON_SYSTEMD_TIMER} ==="
            _systemd_render_timer "$schedule_expr" ;;
        *)
            log "Error: unknown backend: $backend"; return 1 ;;
    esac
}

_cron_status_orchestrate() {
    local detected; detected=$(_detect_scheduler)
    log "Detected scheduler(s): $detected"
    local found=false
    _cron_backend_status          && found=true
    _systemd_backend_status       && found=true
    _systemd_user_backend_status  && found=true
    if [[ $found == false ]]; then
        log "No managed schedule installed."
        return 1
    fi
    return 0
}

_cron_menu() {
    {
        echo "Hoist scheduling:"
        echo "  1) install"
        echo "  2) remove"
        echo "  3) print"
        echo "  4) status"
        echo "  5) cancel"
    } >&2
    local ans
    read -rp "Action [1]: " ans >&2
    ans="${ans:-1}"
    case "$ans" in
        1|install) echo install ;;
        2|remove)  echo remove ;;
        3|print)   echo print ;;
        4|status)  echo status ;;
        5|cancel|q) echo cancel ;;
        *) echo "Error: invalid choice: $ans" >&2; return 2 ;;
    esac
}

_cron_dispatch() {
    if [[ -z $CRON_ACTION ]]; then
        CRON_ACTION=$(_cron_menu) || exit 2
        [[ $CRON_ACTION == cancel ]] && { log "Cancelled."; exit 0; }
    fi
    case "$CRON_ACTION" in
        install) _cron_install_orchestrate; exit $? ;;
        remove)  _cron_remove_orchestrate;  exit $? ;;
        print)   _cron_print_orchestrate;   exit $? ;;
        status)  _cron_status_orchestrate;  exit $? ;;
        *)
            log "Error: unknown --cron action: $CRON_ACTION"
            log "  valid: install | remove | print | status"
            exit 2 ;;
    esac
}

send_discord_notification() {
    local description="$1" container="$2" old_version="$3" new_version="$4"
    local image="$5" webhook="$6" old_revision="$7" new_revision="$8"
    local old_digest="$9" new_digest="${10}" color="${11:-3447003}"
    local v_ind=">" r_ind=">" d_ind=">"
    [[ $old_digest == "$new_digest" ]] && d_ind="="

    local fields
    fields=$(jq -n \
        --arg container "$container" \
        --arg image "$image" \
        --arg old_d "${old_digest:0:11}" \
        --arg new_d "${new_digest:0:11}" \
        --arg d_ind "$d_ind" \
        '[{"name":"Container","value":("```" + $container + "```")},
          {"name":"Image","value":("```" + $image + "```")},
          {"name":"Image ID","value":("```\n" + $old_d + "\n =" + $d_ind + " " + $new_d + "```")}]')

    if [[ -n $old_version && -n $new_version && -n $old_revision && -n $new_revision ]]; then
        [[ $old_version == "$new_version" ]] && v_ind="="
        [[ $old_revision == "$new_revision" ]] && r_ind="="
        fields=$(jq -n \
            --argjson base "$fields" \
            --arg old_v "$old_version" --arg new_v "$new_version" --arg v_ind "$v_ind" \
            --arg old_r "${old_revision:0:6}" --arg new_r "${new_revision:0:6}" --arg r_ind "$r_ind" \
            '$base + [{"name":"Version","value":("```\n" + $old_v + "\n =" + $v_ind + " " + $new_v + "```")},
                      {"name":"Revision","value":("```\n" + $old_r + "\n =" + $r_ind + " " + $new_r + "```")}]')
    fi

    local payload
    payload=$(jq -n \
        --arg title "$description" \
        --argjson color "$color" \
        --argjson fields "$fields" \
        --arg ts "$(_iso_ts)" \
        --arg footer "Powered by Hoist • $(_hoist_hostname)" \
        '{"embeds":[{"title":$title,"color":$color,"fields":$fields,
            "footer":{"text":$footer},"timestamp":$ts}],
          "username":"Hoist"}')
    validate_webhook_url "$webhook" || return 1
    curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
        -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$webhook"
}

send_generic_webhook() {
    local payload
    payload=$(jq -n \
        --arg type "$1" --arg container "$2" \
        --arg old_version "$3" --arg new_version "$4" \
        --arg image "$5" \
        --arg old_revision "$7" --arg new_revision "$8" \
        --arg old_image_id "$9" --arg new_image_id "${10}" \
        --arg ts "$(_iso_ts)" \
        '{"type":$type,"container":$container,"image":$image,
          "old_image_id":$old_image_id,"new_image_id":$new_image_id,
          "old_version":$old_version,"new_version":$new_version,
          "old_revision":$old_revision,"new_revision":$new_revision,
          "timestamp":$ts}')
    validate_webhook_url "$6" || return 1
    curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
        -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$6"
}

send_slack_notification() {
    local payload
    payload=$(jq -n --arg text "$1" '{"text":$text}')
    validate_webhook_url "$2" || return 1
    curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
        -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$2"
}

# send_telegram_notification <text> <bot_token> <chat_id>
send_telegram_notification() {
    local text="$1" token="$2" chat_id="$3"
    [[ -n $token && -n $chat_id ]] || { log "Telegram: missing bot_token or chat_id"; return 1; }
    local payload
    payload=$(jq -n --arg text "$text" --arg chat "$chat_id" \
        '{"chat_id":$chat,"text":$text,"disable_web_page_preview":true}')
    # No -L: Telegram bot token is in the URL path; following a redirect
    # to a different host would leak the token.
    curl -fsS --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
        -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" \
        "https://api.telegram.org/bot${token}/sendMessage"
}

# send_gotify_notification <title> <message> <url>  (url may include ?token=...)
send_gotify_notification() {
    local title="$1" message="$2" url="$3"
    validate_webhook_url "$url" || return 1
    local payload
    payload=$(jq -n --arg t "$title" --arg m "$message" \
        '{"title":$t,"message":$m,"priority":5}')
    # No -L: Gotify URLs typically embed the token as ?token=...; a redirect
    # to another host would leak it.
    curl -fsS --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
        -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$url"
}

# send_ntfy_notification <title> <message> <url> [token]
send_ntfy_notification() {
    local title="$1" message="$2" url="$3" token="${4:-}"
    validate_webhook_url "$url" || return 1
    local -a hdrs=(-H "User-Agent: Hoist" -H "Title: $title" -H "Priority: default")
    [[ -n $token ]] && hdrs+=(-H "Authorization: Bearer $token")
    # No -L: ntfy bearer token in Authorization header would leak on redirect.
    curl -fsS --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
        "${hdrs[@]}" -d "$message" "$url"
}

# send_teams_notification <title> <message> <webhook>
send_teams_notification() {
    local title="$1" message="$2" webhook="$3"
    validate_webhook_url "$webhook" || return 1
    local payload
    payload=$(jq -n --arg t "$title" --arg m "$message" \
        '{"@type":"MessageCard","@context":"https://schema.org/extensions",
          "summary":$t,"themeColor":"0076D7","title":$t,"text":$m}')
    # No -L: Teams webhook URL is itself a credential; following redirects
    # to a different host risks exposing it.
    curl -fsS --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
        -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$webhook"
}

# send_matrix_notification <message> <homeserver> <room_id> <access_token>
send_matrix_notification() {
    local message="$1" homeserver="$2" room_id="$3" token="$4"
    [[ -n $homeserver && -n $room_id && -n $token ]] || { log "Matrix: missing homeserver/room_id/token"; return 1; }
    validate_webhook_url "$homeserver" || return 1
    local txn url payload
    txn="hoist-$(date +%s%N)-$$"
    url="${homeserver%/}/_matrix/client/v3/rooms/${room_id}/send/m.room.message/${txn}"
    payload=$(jq -n --arg body "$message" '{"msgtype":"m.text","body":$body}')
    # No -L: Matrix access token in Authorization header would leak on redirect.
    curl -fsS --max-time "$CURL_TIMEOUT" --connect-timeout 10 -X PUT \
        -H "User-Agent: Hoist" -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" -d "$payload" "$url"
}

# _hc_ping [start|fail|""]  (suffix optional; empty = success)
_hc_ping() {
    [[ -n $HEALTHCHECKS_PING_URL ]] || return 0
    local suffix="${1:-}" url="${HEALTHCHECKS_PING_URL%/}"
    [[ -n $suffix ]] && url="${url}/${suffix}"
    # No -L: the URL contains a check UUID that acts as a credential.
    curl -fsS --max-time 10 -H "User-Agent: Hoist" "$url" >/dev/null 2>&1 || true
}

# _skip_for_rollup <channel>  -> 0 if per-container send should be skipped
# (rollup will handle it). Falls back to per-container send when rollup is
# enabled but the channel's GLOBAL_* fallback is unset, so users with only
# per-container labels still get notifications.
_skip_for_rollup() {
    [[ $WEBHOOK_ROLLUP == true ]] || return 1
    [[ ",${WEBHOOK_ROLLUP_CHANNELS}," == *",$1,"* ]] || return 1
    case "$1" in
        discord)  [[ -n $GLOBAL_DISCORD_WEBHOOK ]] ;;
        slack)    [[ -n $GLOBAL_SLACK_WEBHOOK ]] ;;
        generic)  [[ -n $GLOBAL_GENERIC_WEBHOOK ]] ;;
        telegram) [[ -n $GLOBAL_TELEGRAM_BOT_TOKEN && -n $GLOBAL_TELEGRAM_CHAT_ID ]] ;;
        gotify)   [[ -n $GLOBAL_GOTIFY_URL ]] ;;
        ntfy)     [[ -n $GLOBAL_NTFY_URL ]] ;;
        teams)    [[ -n $GLOBAL_TEAMS_WEBHOOK ]] ;;
        matrix)   [[ -n $GLOBAL_MATRIX_HOMESERVER && -n $GLOBAL_MATRIX_ROOM_ID && -n $GLOBAL_MATRIX_TOKEN ]] ;;
        *)        return 1 ;;
    esac
}

# write_rollup_entry <status> <container> <image> <old_digest> <new_digest>
write_rollup_entry() {
    [[ $WEBHOOK_ROLLUP == true ]] || return 0
    local safe
    safe=$(printf '%s' "$2" | tr -cs '[:alnum:]._-' '_')
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" \
        > "${CACHE_LOCATION}/hoist-${safe}.rollup"
}

# Aggregate all .rollup files into a single multi-line summary, send to each rollup channel
send_rollup_notifications() {
    [[ $WEBHOOK_ROLLUP == true ]] || return 0
    local f lines=""
    for f in "${CACHE_LOCATION}"/hoist-*.rollup; do
        [[ -f $f ]] || continue
        local status container image old new
        IFS=$'\t' read -r status container image old new < "$f"
        local short_old="${old:0:11}" short_new="${new:0:11}"
        lines+="• [${status}] ${container} (${image}) ${short_old} → ${short_new}"$'\n'
    done
    [[ -z $lines ]] && return 0
    local title="Hoist run summary"
    local message="${title}"$'\n'"${lines%$'\n'}"

    local ch
    IFS=',' read -ra _rollup_channels <<< "$WEBHOOK_ROLLUP_CHANNELS"
    for ch in "${_rollup_channels[@]}"; do
        case "$ch" in
            discord)
                [[ -n $GLOBAL_DISCORD_WEBHOOK ]] || continue
                log "Rollup: sending Discord summary..."
                send_discord_notification "$title" "rollup" "" "" "$message" \
                    "$GLOBAL_DISCORD_WEBHOOK" "" "" "" "" 3447003 || true ;;
            slack)
                [[ -n $GLOBAL_SLACK_WEBHOOK ]] || continue
                log "Rollup: sending Slack summary..."
                send_slack_notification "$message" "$GLOBAL_SLACK_WEBHOOK" || true ;;
            generic)
                [[ -n $GLOBAL_GENERIC_WEBHOOK ]] || continue
                log "Rollup: sending generic webhook summary..."
                local payload
                payload=$(jq -n --arg type "rollup" --arg ts "$(_iso_ts)" --arg msg "$message" \
                    '{"type":$type,"timestamp":$ts,"message":$msg}')
                # No -L: generic webhook URL is itself a credential.
                curl -fsS --max-time "$CURL_TIMEOUT" --connect-timeout 10 \
                    -H "User-Agent: Hoist" -H "Content-Type: application/json" \
                    -d "$payload" "$GLOBAL_GENERIC_WEBHOOK" || true ;;
            telegram)
                [[ -n $GLOBAL_TELEGRAM_BOT_TOKEN && -n $GLOBAL_TELEGRAM_CHAT_ID ]] || continue
                log "Rollup: sending Telegram summary..."
                send_telegram_notification "$message" "$GLOBAL_TELEGRAM_BOT_TOKEN" "$GLOBAL_TELEGRAM_CHAT_ID" || true ;;
            gotify)
                [[ -n $GLOBAL_GOTIFY_URL ]] || continue
                log "Rollup: sending Gotify summary..."
                send_gotify_notification "$title" "$message" "$GLOBAL_GOTIFY_URL" || true ;;
            ntfy)
                [[ -n $GLOBAL_NTFY_URL ]] || continue
                log "Rollup: sending ntfy summary..."
                send_ntfy_notification "$title" "$message" "$GLOBAL_NTFY_URL" "$GLOBAL_NTFY_TOKEN" || true ;;
            teams)
                [[ -n $GLOBAL_TEAMS_WEBHOOK ]] || continue
                log "Rollup: sending Teams summary..."
                send_teams_notification "$title" "$message" "$GLOBAL_TEAMS_WEBHOOK" || true ;;
            matrix)
                [[ -n $GLOBAL_MATRIX_HOMESERVER && -n $GLOBAL_MATRIX_ROOM_ID && -n $GLOBAL_MATRIX_TOKEN ]] || continue
                log "Rollup: sending Matrix summary..."
                send_matrix_notification "$message" "$GLOBAL_MATRIX_HOMESERVER" \
                    "$GLOBAL_MATRIX_ROOM_ID" "$GLOBAL_MATRIX_TOKEN" || true ;;
        esac
    done
}

process_container() {
    local container_name="$1"
    local safe_name
    safe_name=$(printf '%s' "$container_name" | tr -cs '[:alnum:]._-' '_')
    local _result_file="${CACHE_LOCATION}/hoist-${safe_name}.run-result"
    local -a _tokens=()
    log "$container_name: Checking..."

    local inspect
    inspect=$("${DOCKER_BINARY}" inspect "$container_name") || {
        log "$container_name: inspect failed"
        _tokens+=("update_failed")
        printf '%s\n' "${_tokens[@]}" >> "$_result_file"
        return 1
    }

    local image_name container_image_digest
    local docker_compose_service docker_compose_version docker_compose_workdir
    local old_oci_version old_oci_revision
    local hoist_update hoist_notify hoist_discord_webhook hoist_generic_webhook hoist_slack_webhook
    local hoist_telegram_bot_token hoist_telegram_chat_id
    local hoist_gotify_url hoist_ntfy_url hoist_ntfy_token hoist_teams_webhook
    local hoist_matrix_homeserver hoist_matrix_room_id hoist_matrix_token
    local hoist_pause_until hoist_constraint hoist_group
    local hoist_healthcheck_wait hoist_healthcheck_timeout hoist_rollback
    local hoist_registry_authfile
    local -a hoist_script_update hoist_script_notify

    local _jq_out
    _jq_out=$(jq -r --arg tag "$TAG" '
        .[0] |
        .Config.Image,
        .Image,
        (.Config.Labels["com.docker.compose.service"] // ""),
        (.Config.Labels["com.docker.compose.version"] // ""),
        (.Config.Labels["com.docker.compose.project.working_dir"] // ""),
        (.Config.Labels["org.opencontainers.image.version"] // ""),
        (.Config.Labels["org.opencontainers.image.revision"] // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).update"]            // .Config.Labels["org.hotio.pullio\($tag).update"]            // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).notify"]            // .Config.Labels["org.hotio.pullio\($tag).notify"]            // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).discord.webhook"]   // .Config.Labels["org.hotio.pullio\($tag).discord.webhook"]   // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).generic.webhook"]   // .Config.Labels["org.hotio.pullio\($tag).generic.webhook"]   // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).slack.webhook"]     // .Config.Labels["org.hotio.pullio\($tag).slack.webhook"]     // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).script.update"]     // .Config.Labels["org.hotio.pullio\($tag).script.update"]     // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).script.notify"]     // .Config.Labels["org.hotio.pullio\($tag).script.notify"]     // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).registry.authfile"] // .Config.Labels["org.hotio.pullio\($tag).registry.authfile"] // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).telegram.bot_token"] // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).telegram.chat_id"]   // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).gotify.url"]         // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).ntfy.url"]           // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).ntfy.token"]         // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).teams.webhook"]      // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).matrix.homeserver"]  // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).matrix.room_id"]     // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).matrix.token"]       // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).pause_until"]        // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).constraint"]         // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).group"]              // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).healthcheck.wait"]    // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).healthcheck.timeout"] // ""),
        (.Config.Labels["com.sumguy.hoist\($tag).rollback"]            // "")
    ' <<< "$inspect") || {
        log "$container_name: failed to parse inspect output"
        _tokens+=("update_failed")
        printf '%s\n' "${_tokens[@]}" >> "$_result_file"
        return 1
    }
    readarray -t _vals <<< "$_jq_out"

    image_name="${_vals[0]}"
    container_image_digest="${_vals[1]}"
    docker_compose_service="${_vals[2]}"
    docker_compose_version="${_vals[3]}"
    docker_compose_workdir="${_vals[4]}"
    old_oci_version="${_vals[5]}"
    old_oci_revision="${_vals[6]}"
    hoist_update="${_vals[7]}"
    hoist_notify="${_vals[8]}"
    hoist_discord_webhook="${_vals[9]}"
    hoist_generic_webhook="${_vals[10]}"
    hoist_slack_webhook="${_vals[11]}"
    read -ra hoist_script_update <<< "${_vals[12]}"
    read -ra hoist_script_notify <<< "${_vals[13]}"
    hoist_registry_authfile="${_vals[14]}"
    hoist_telegram_bot_token="${_vals[15]}"
    hoist_telegram_chat_id="${_vals[16]}"
    hoist_gotify_url="${_vals[17]}"
    hoist_ntfy_url="${_vals[18]}"
    hoist_ntfy_token="${_vals[19]}"
    hoist_teams_webhook="${_vals[20]}"
    hoist_matrix_homeserver="${_vals[21]}"
    hoist_matrix_room_id="${_vals[22]}"
    hoist_matrix_token="${_vals[23]}"
    hoist_pause_until="${_vals[24]}"
    hoist_constraint="${_vals[25]}"
    hoist_group="${_vals[26]}"
    hoist_healthcheck_wait="${_vals[27]}"
    hoist_healthcheck_timeout="${_vals[28]}"
    hoist_rollback="${_vals[29]}"

    local effective_discord="${hoist_discord_webhook:-$GLOBAL_DISCORD_WEBHOOK}"
    local effective_generic="${hoist_generic_webhook:-$GLOBAL_GENERIC_WEBHOOK}"
    local effective_slack="${hoist_slack_webhook:-$GLOBAL_SLACK_WEBHOOK}"
    local effective_telegram_bot_token="${hoist_telegram_bot_token:-$GLOBAL_TELEGRAM_BOT_TOKEN}"
    local effective_telegram_chat_id="${hoist_telegram_chat_id:-$GLOBAL_TELEGRAM_CHAT_ID}"
    local effective_gotify_url="${hoist_gotify_url:-$GLOBAL_GOTIFY_URL}"
    local effective_ntfy_url="${hoist_ntfy_url:-$GLOBAL_NTFY_URL}"
    local effective_ntfy_token="${hoist_ntfy_token:-$GLOBAL_NTFY_TOKEN}"
    local effective_teams_webhook="${hoist_teams_webhook:-$GLOBAL_TEAMS_WEBHOOK}"
    local effective_matrix_homeserver="${hoist_matrix_homeserver:-$GLOBAL_MATRIX_HOMESERVER}"
    local effective_matrix_room_id="${hoist_matrix_room_id:-$GLOBAL_MATRIX_ROOM_ID}"
    local effective_matrix_token="${hoist_matrix_token:-$GLOBAL_MATRIX_TOKEN}"
    if [[ -n "${hoist_script_update[0]}" ]]; then
        validate_script_path "${hoist_script_update[0]}" || {
            log "$container_name: script.update label rejected; skipping"
            hoist_script_update=()
        }
    fi
    if [[ -n "${hoist_script_notify[0]}" ]]; then
        validate_script_path "${hoist_script_notify[0]}" || {
            log "$container_name: script.notify label rejected; skipping"
            hoist_script_notify=()
        }
    fi

    if [[ -n $docker_compose_version ]] && { _is_true "$hoist_update" || _is_true "$hoist_notify"; }; then
        if [[ -n $docker_compose_workdir && -n $docker_compose_service ]]; then
            local _dedup_key
            _dedup_key=$(printf '%s:%s' "$docker_compose_workdir" "$docker_compose_service" \
                | tr -cs '[:alnum:]._-' '_')
            if ! mkdir "${CACHE_LOCATION}/hoist-compose-${_dedup_key}.deduped" 2>/dev/null; then
                [[ $VERBOSE == true ]] && log "$container_name: replica of '$docker_compose_service' already processed this run — skipping"
                return 0
            fi
        fi
        if [[ -n $hoist_pause_until ]] && ! _check_pause_until "$hoist_pause_until"; then
            log "$container_name: paused until $hoist_pause_until"
            _tokens+=("paused")
            printf '%s\n' "${_tokens[@]}" >> "$_result_file"
            return 0
        fi
        if [[ -n "$hoist_registry_authfile" ]]; then
            if [[ "$hoist_registry_authfile" != /* ]]; then
                log "$container_name: Skipping registry login — authfile path is not absolute: $hoist_registry_authfile"
            elif [[ -f "$hoist_registry_authfile" ]]; then
                log "$container_name: Registry login..."
                if [[ $DRY_RUN != true ]]; then
                    jq -r .password < "$hoist_registry_authfile" | \
                        "${DOCKER_BINARY}" login \
                            --username "$(jq -r .username < "$hoist_registry_authfile")" \
                            --password-stdin \
                            "$(jq -r .registry < "$hoist_registry_authfile")"
                fi
            fi
        fi

        local image_digest new_oci_version new_oci_revision
        if [[ $DRY_RUN == true ]]; then
            # Read-only: do not pull (a pull would re-point the tag and demote
            # the running image to dangling). We therefore can't compare digests
            # — report eligibility (configured + not paused) rather than claiming
            # an update is available.
            log "$container_name: [dry-run] eligible — a live run would pull and check for an update"
            image_digest="$container_image_digest"
            _is_true "$hoist_update" && _tokens+=("would_update")
            _is_true "$hoist_notify" && _tokens+=("would_notify")
        else
            log "$container_name: Pulling image..."
            compose_pull_wrapper "$docker_compose_workdir" "$docker_compose_service" || {
                log "$container_name: Pull failed"
                if [[ -n $hoist_group ]]; then
                    local _g_safe
                    _g_safe=$(printf '%s' "$hoist_group" | tr -cs '[:alnum:]._-' '_')
                    : > "${CACHE_LOCATION}/hoist-group-${_g_safe}.failed"
                fi
                _tokens+=("update_failed")
                printf '%s\n' "${_tokens[@]}" >> "$_result_file"
                return 1
            }

            local image_inspect _img_out
            image_inspect=$("${DOCKER_BINARY}" image inspect "$image_name" 2>/dev/null) || {
                log "$container_name: docker image inspect failed for $image_name (image missing after pull?)"
                _tokens+=("update_failed")
                printf '%s\n' "${_tokens[@]}" >> "$_result_file"
                return 1
            }
            _img_out=$(jq -r '
                .[0] |
                .Id,
                (.Config.Labels["org.opencontainers.image.version"] // ""),
                (.Config.Labels["org.opencontainers.image.revision"] // "")
            ' <<< "$image_inspect") || {
                log "$container_name: failed to parse image inspect output"
                _tokens+=("update_failed")
                printf '%s\n' "${_tokens[@]}" >> "$_result_file"
                return 1
            }
            readarray -t _img <<< "$_img_out"
            image_digest="${_img[0]}"
            new_oci_version="${_img[1]}"
            new_oci_revision="${_img[2]}"
            # docker prints `[]` for a missing image, so jq succeeds with a null
            # .Id — guard against an empty digest before any compare/update.
            if [[ -z $image_digest || $image_digest == null ]]; then
                log "$container_name: image inspect returned no image ID for $image_name"
                _tokens+=("update_failed")
                printf '%s\n' "${_tokens[@]}" >> "$_result_file"
                return 1
            fi
        fi

        local status="🔄 Update available" status_generic="update_available" color=3447003

        # Constraint check: if violated, block update but still allow notify
        local _constraint_blocked=false
        if [[ -n $hoist_constraint && -n $new_oci_version ]] \
           && ! _semver_satisfies "$hoist_constraint" "$new_oci_version"; then
            log "$container_name: constraint '$hoist_constraint' violated by version '$new_oci_version' — blocking update"
            _constraint_blocked=true
            _tokens+=("constraint_blocked")
            status="🔒 Update blocked by constraint ${hoist_constraint} (image=${new_oci_version})"
            status_generic="update_blocked"
            color=15105570
        fi

        # Group abort: if any peer in the same group already failed to pull, skip update
        local _group_aborted=false
        if [[ -n $hoist_group ]]; then
            local _g_safe
            _g_safe=$(printf '%s' "$hoist_group" | tr -cs '[:alnum:]._-' '_')
            if [[ -f "${CACHE_LOCATION}/hoist-group-${_g_safe}.failed" ]]; then
                log "$container_name: group '$hoist_group' has a failed peer — aborting update"
                _group_aborted=true
                _tokens+=("group_aborted")
                status="🚫 Update aborted (group '${hoist_group}' had a failed peer)"
                status_generic="update_aborted"
                color=15105570
            fi
        fi

        if [[ $image_digest != "$container_image_digest" && $_constraint_blocked != true && $_group_aborted != true ]] \
           && _is_true "$hoist_update"; then
            if [[ $DRY_RUN == true ]]; then
                log "$container_name: [dry-run] would update container"
            else
                if [[ -n "${hoist_script_update[*]}" ]]; then
                    log "$container_name: Stopping container..."
                    "${DOCKER_BINARY}" stop "$container_name"
                    log "$container_name: Executing update script..."
                    export HOIST_CONTAINER="$container_name"
                    export HOIST_IMAGE="$image_name"
                    export HOIST_OLD_IMAGE_ID="${container_image_digest#sha256:}"
                    export HOIST_NEW_IMAGE_ID="${image_digest#sha256:}"
                    export HOIST_OLD_VERSION="$old_oci_version"
                    export HOIST_NEW_VERSION="$new_oci_version"
                    export HOIST_OLD_REVISION="$old_oci_revision"
                    export HOIST_NEW_REVISION="$new_oci_revision"
                    export HOIST_COMPOSE_SERVICE="$docker_compose_service"
                    export HOIST_COMPOSE_WORKDIR="$docker_compose_workdir"
                    "${hoist_script_update[@]}"
                fi
                log "$container_name: Updating container..."
                local _rollback_enabled=false
                if _is_true "$hoist_rollback" || { [[ -z $hoist_rollback ]] && _is_true "$ROLLBACK_DEFAULT"; }; then
                    _rollback_enabled=true
                fi
                local _hc_timeout="${hoist_healthcheck_timeout:-$HEALTHCHECK_TIMEOUT}"
                local _update_ok=false _hc_ok=true
                if compose_up_wrapper "$docker_compose_workdir" "$docker_compose_service"; then
                    _update_ok=true
                    if _is_true "$hoist_healthcheck_wait"; then
                        log "$container_name: Waiting up to ${_hc_timeout}s for healthy..."
                        if ! _wait_for_healthy "$container_name" "$_hc_timeout"; then
                            _hc_ok=false
                            log "$container_name: container failed healthcheck after update"
                        fi
                    fi
                fi

                if [[ $_update_ok == true && $_hc_ok == true ]]; then
                    status="✅ Update succeeded"
                    status_generic="update_success"
                    color=3066993
                    _tokens+=("updated")
                else
                    if [[ $_update_ok == true && $_hc_ok != true ]]; then
                        status="❌ Update unhealthy"
                        status_generic="update_failure"
                        _tokens+=("unhealthy")
                    else
                        log "$container_name: Update failed"
                        status="❌ Update failed"
                        status_generic="update_failure"
                        _tokens+=("update_failed")
                    fi
                    color=15158332
                    if [[ $_rollback_enabled == true ]]; then
                        if _rollback_container "$container_name" "$docker_compose_workdir" "$docker_compose_service" "$image_name" "$container_image_digest"; then
                            _tokens+=("rolled_back")
                            status+=" (rolled back)"
                        else
                            _tokens+=("rollback_failed")
                            status+=" (rollback failed)"
                        fi
                    fi
                fi
                rm -f "${CACHE_LOCATION}/hoist-${safe_name}.notified"
            fi
        fi

        if [[ $image_digest != "$container_image_digest" && $DRY_RUN != true ]] && _is_true "$hoist_notify"; then
            local notified_digest
            notified_digest=$(cat "${CACHE_LOCATION}/hoist-${safe_name}.notified" 2>/dev/null || true)
            if [[ $notified_digest != "$image_digest" ]]; then
                if [[ -n "${hoist_script_notify[*]}" ]]; then
                    log "$container_name: Executing notify script..."
                    export HOIST_CONTAINER="$container_name"
                    export HOIST_IMAGE="$image_name"
                    export HOIST_OLD_IMAGE_ID="${container_image_digest#sha256:}"
                    export HOIST_NEW_IMAGE_ID="${image_digest#sha256:}"
                    export HOIST_OLD_VERSION="$old_oci_version"
                    export HOIST_NEW_VERSION="$new_oci_version"
                    export HOIST_OLD_REVISION="$old_oci_revision"
                    export HOIST_NEW_REVISION="$new_oci_revision"
                    export HOIST_COMPOSE_SERVICE="$docker_compose_service"
                    export HOIST_COMPOSE_WORKDIR="$docker_compose_workdir"
                    "${hoist_script_notify[@]}"
                fi
                local _slack_msg="[$container_name] $status: $image_name"
                if [[ -n $effective_discord ]] && ! _skip_for_rollup discord; then
                    log "$container_name: Sending Discord notification..."
                    send_discord_notification "$status" "$container_name" \
                        "$old_oci_version" "$new_oci_version" "$image_name" \
                        "$effective_discord" "$old_oci_revision" "$new_oci_revision" \
                        "${container_image_digest#sha256:}" "${image_digest#sha256:}" "$color"
                fi
                if [[ -n $effective_generic ]] && ! _skip_for_rollup generic; then
                    log "$container_name: Sending generic webhook..."
                    send_generic_webhook "$status_generic" "$container_name" \
                        "$old_oci_version" "$new_oci_version" "$image_name" \
                        "$effective_generic" "$old_oci_revision" "$new_oci_revision" \
                        "${container_image_digest#sha256:}" "${image_digest#sha256:}"
                fi
                if [[ -n $effective_slack ]] && ! _skip_for_rollup slack; then
                    log "$container_name: Sending Slack notification..."
                    send_slack_notification "$_slack_msg" "$effective_slack"
                fi
                if [[ -n $effective_telegram_bot_token && -n $effective_telegram_chat_id ]] && ! _skip_for_rollup telegram; then
                    log "$container_name: Sending Telegram notification..."
                    send_telegram_notification "$_slack_msg" "$effective_telegram_bot_token" "$effective_telegram_chat_id"
                fi
                if [[ -n $effective_gotify_url ]] && ! _skip_for_rollup gotify; then
                    log "$container_name: Sending Gotify notification..."
                    send_gotify_notification "$status" "$_slack_msg" "$effective_gotify_url"
                fi
                if [[ -n $effective_ntfy_url ]] && ! _skip_for_rollup ntfy; then
                    log "$container_name: Sending ntfy notification..."
                    send_ntfy_notification "$status" "$_slack_msg" "$effective_ntfy_url" "$effective_ntfy_token"
                fi
                if [[ -n $effective_teams_webhook ]] && ! _skip_for_rollup teams; then
                    log "$container_name: Sending Teams notification..."
                    send_teams_notification "$status" "$_slack_msg" "$effective_teams_webhook"
                fi
                if [[ -n $effective_matrix_homeserver && -n $effective_matrix_room_id && -n $effective_matrix_token ]] && ! _skip_for_rollup matrix; then
                    log "$container_name: Sending Matrix notification..."
                    send_matrix_notification "$_slack_msg" "$effective_matrix_homeserver" \
                        "$effective_matrix_room_id" "$effective_matrix_token"
                fi
                write_rollup_entry "$status_generic" "$container_name" "$image_name" \
                    "${container_image_digest#sha256:}" "${image_digest#sha256:}"
                ( umask 177 && printf '%s' "$image_digest" > "${CACHE_LOCATION}/hoist-${safe_name}.notified" )
                _tokens+=("notified")
            fi
        fi
    else
        [[ $VERBOSE == true ]] && log "$container_name: Skipped (no hoist labels)"
        _tokens+=("skipped")
    fi
    if [[ ${#_tokens[@]} -eq 0 ]]; then
        _tokens+=("no_change")
    fi
    printf '%s\n' "${_tokens[@]}" >> "$_result_file"
}

print_summary() {
    local updated=0 update_failed=0 notified=0 no_change=0 skipped=0
    local would_update=0 would_notify=0
    local paused=0 constraint_blocked=0 group_aborted=0
    local unhealthy=0 rolled_back=0 rollback_failed=0
    local f token
    for f in "${CACHE_LOCATION}"/hoist-*.run-result; do
        [[ -f $f ]] || continue
        while IFS= read -r token; do
            case "$token" in
                updated)            (( updated++ )) ;;
                update_failed)      (( update_failed++ )) ;;
                notified)           (( notified++ )) ;;
                no_change)          (( no_change++ )) ;;
                skipped)            (( skipped++ )) ;;
                would_update)       (( would_update++ )) ;;
                would_notify)       (( would_notify++ )) ;;
                paused)             (( paused++ )) ;;
                constraint_blocked) (( constraint_blocked++ )) ;;
                group_aborted)      (( group_aborted++ )) ;;
                unhealthy)          (( unhealthy++ )) ;;
                rolled_back)        (( rolled_back++ )) ;;
                rollback_failed)    (( rollback_failed++ )) ;;
            esac
        done < "$f"
    done

    local msg
    if [[ $DRY_RUN == true ]]; then
        # Dry-run does not pull, so it cannot know which containers actually have
        # a newer image waiting — only which are configured (and not paused) to
        # act. Report eligibility, not a spurious "would update" claim.
        msg="Run complete (dry-run): ${would_update} eligible to update, ${would_notify} eligible to notify (not pulled — run live to detect available updates), ${skipped} skipped"
    else
        local updated_part="${updated} updated"
        [[ $update_failed -gt 0 ]] && updated_part+=" (${update_failed} failed)"
        msg="Run complete: ${updated_part}, ${notified} notified, ${no_change} no-change, ${skipped} skipped"
    fi
    [[ $unhealthy -gt 0 ]]          && msg+=", ${unhealthy} unhealthy"
    [[ $rolled_back -gt 0 ]]        && msg+=", ${rolled_back} rolled-back"
    [[ $rollback_failed -gt 0 ]]    && msg+=", ${rollback_failed} ROLLBACK-FAILED"
    [[ $paused -gt 0 ]]             && msg+=", ${paused} paused"
    [[ $constraint_blocked -gt 0 ]] && msg+=", ${constraint_blocked} constraint-blocked"
    [[ $group_aborted -gt 0 ]]      && msg+=", ${group_aborted} group-aborted"
    log "$msg"
}

list_containers() {
    printf '%-20s %-32s %-7s %-7s %-18s %s\n' "CONTAINER" "IMAGE" "UPDATE" "NOTIFY" "POLICY" "CACHED DIGEST"
    local container_name
    for container_name in "${containers[@]}"; do
        local inspect
        inspect=$("${DOCKER_BINARY}" inspect "$container_name" 2>/dev/null) || {
            printf '%-20s %-32s %-7s %-7s %-18s %s\n' "$container_name" "(inspect failed)" "-" "-" "-" "-"
            continue
        }

        local _jq_out
        _jq_out=$(jq -r --arg tag "$TAG" '
            .[0] |
            .Config.Image,
            (.Config.Labels["com.sumguy.hoist\($tag).update"] // .Config.Labels["org.hotio.pullio\($tag).update"] // ""),
            (.Config.Labels["com.sumguy.hoist\($tag).notify"] // .Config.Labels["org.hotio.pullio\($tag).notify"] // ""),
            (.Config.Labels["com.sumguy.hoist\($tag).pause_until"] // ""),
            (.Config.Labels["com.sumguy.hoist\($tag).constraint"] // ""),
            (.Config.Labels["com.sumguy.hoist\($tag).group"] // "")
        ' <<< "$inspect") || {
            printf '%-20s %-32s %-7s %-7s %-18s %s\n' "$container_name" "(parse failed)" "-" "-" "-" "-"
            continue
        }
        readarray -t _lv <<< "$_jq_out"

        local image="${_lv[0]}" update_label="${_lv[1]}" notify_label="${_lv[2]}"
        local pause_label="${_lv[3]}" constraint_label="${_lv[4]}" group_label="${_lv[5]}"
        local update_col notify_col policy_col cached_col

        if [[ -z $update_label && -z $notify_label ]]; then
            update_col="-"
            notify_col="-"
        else
            _is_true "$update_label" && update_col="yes" || update_col="no"
            _is_true "$notify_label" && notify_col="yes" || notify_col="no"
        fi

        local _policy_parts=()
        [[ -n $pause_label ]]      && _policy_parts+=("paused:${pause_label}")
        [[ -n $constraint_label ]] && _policy_parts+=("pin:${constraint_label}")
        [[ -n $group_label ]]      && _policy_parts+=("group:${group_label}")
        if [[ ${#_policy_parts[@]} -eq 0 ]]; then
            policy_col="-"
        else
            policy_col=$(local IFS=','; printf '%s' "${_policy_parts[*]}")
        fi

        local safe_name
        safe_name=$(printf '%s' "$container_name" | tr -cs '[:alnum:]._-' '_')
        local raw_digest
        raw_digest=$(cat "${CACHE_LOCATION}/hoist-${safe_name}.notified" 2>/dev/null || true)
        if [[ -n $raw_digest ]]; then
            local stripped="${raw_digest#sha256:}"
            cached_col="${stripped:0:13}"
        else
            cached_col="-"
        fi

        printf '%-20s %-32s %-7s %-7s %-18s %s\n' \
            "$container_name" "$image" "$update_col" "$notify_col" "$policy_col" "$cached_col"
    done
}

# The main run sequence; invoked from the entry-point guard at the bottom.
_main() {
if [[ $DO_CRON == true ]]; then
    _cron_dispatch
fi

if [[ $DO_SELF_UPDATE == true ]]; then
    _self_update_check true "$FORCE"
fi

if [[ $UPDATE_CHECK != "off" ]]; then
    _self_update_check false false
fi

declare -a containers
# Capture docker ps separately from the sort so its exit status isn't masked by
# the pipe — a dead daemon must fail loudly, not look like a 0-container run.
_ps_out=$("${DOCKER_BINARY}" ps --format '{{.Names}}') || {
    log "Error: 'docker ps' failed — is the Docker daemon running and is DOCKER_HOST correct?"
    _hc_ping fail
    exit 1
}
if [[ -z $_ps_out ]]; then
    containers=()
else
    readarray -t containers < <(sort -k1 <<< "$_ps_out")
fi

# Apply --only / --exclude filters
if [[ -n "$ONLY_LIST" || -n "$EXCLUDE_LIST" ]]; then
    declare -A _only_set _exclude_set
    if [[ -n "$ONLY_LIST" ]]; then
        IFS=',' read -ra _only_arr <<< "$ONLY_LIST"
        for n in "${_only_arr[@]}"; do
            [[ "$n" =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] && n="${BASH_REMATCH[1]}" || n=""
            [[ -n "$n" ]] && _only_set[$n]=1
        done
    fi
    if [[ -n "$EXCLUDE_LIST" ]]; then
        IFS=',' read -ra _excl_arr <<< "$EXCLUDE_LIST"
        for n in "${_excl_arr[@]}"; do
            [[ "$n" =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] && n="${BASH_REMATCH[1]}" || n=""
            [[ -n "$n" ]] && _exclude_set[$n]=1
        done
    fi
    declare -a _filtered=()
    declare -A _seen_names=()
    for c in "${containers[@]}"; do
        _seen_names[$c]=1
        if [[ -n "$ONLY_LIST" && -z "${_only_set[$c]+x}" ]]; then continue; fi
        if [[ -n "${_exclude_set[$c]+x}" ]]; then continue; fi
        _filtered+=("$c")
    done
    # Warn on unknown names in filter lists
    for n in "${!_only_set[@]}";    do [[ -z "${_seen_names[$n]+x}" ]] && log "Warning: --only name '$n' not found among running containers"; done
    for n in "${!_exclude_set[@]}"; do [[ -z "${_seen_names[$n]+x}" ]] && log "Warning: --exclude name '$n' not found among running containers"; done
    containers=("${_filtered[@]}")
fi

if [[ $DO_LIST == true ]]; then
    list_containers
    exit 0
fi

# Serialize runs (after --list, which is read-only and needs no lock) so the
# shared run-result/rollup state below isn't clobbered by an overlapping run.
_acquire_run_lock

rm -f "${CACHE_LOCATION}"/hoist-*.run-result "${CACHE_LOCATION}"/hoist-*.rollup "${CACHE_LOCATION}"/hoist-group-*.failed 2>/dev/null || true
rmdir "${CACHE_LOCATION}"/hoist-compose-*.deduped 2>/dev/null || true
setup_environment
check_maintenance_window
_hc_ping start

log "Processing ${#containers[@]} containers (parallelism: $PARALLEL)"

if (( PARALLEL > 1 )); then
    running=0
    for container_name in "${containers[@]}"; do
        if (( running >= PARALLEL )); then
            wait -n
            (( running-- ))
        fi
        process_container "$container_name" &
        (( running++ ))
    done
    wait
else
    for container_name in "${containers[@]}"; do
        process_container "$container_name"
    done
fi

print_summary
send_rollup_notifications

if [[ $DRY_RUN != true && $PRUNE_IMAGES == true ]]; then
    log "Pruning docker images..."
    "${DOCKER_BINARY}" image prune --force
fi

# A run is "failed" if any container emitted update_failed / unhealthy /
# rollback_failed. This drives both the HC.io ping and the process exit code so
# cron MAILTO, systemd Type=oneshot, and CI all observe the failure.
_run_failed=false
if grep -Elq '^(update_failed|unhealthy|rollback_failed)$' "${CACHE_LOCATION}"/hoist-*.run-result 2>/dev/null; then
    _run_failed=true
fi

if [[ $_run_failed == true ]]; then
    _hc_ping fail
else
    _hc_ping
fi

[[ $_run_failed == true ]] && exit 1
exit 0
}

# Entry point: run only when executed directly, not when sourced (e.g. by the
# bats test suite, which sources this file to exercise pure functions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _init "$@"
    _main
fi
