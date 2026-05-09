#!/usr/bin/env bash
HOIST_VERSION="1.3.0"
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
MAINTENANCE_WINDOW=""
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

log() {
    local msg="[$(date +%T)] $*"
    echo "$msg"
    [[ -n $LOG_FILE ]] && echo "$msg" >> "$LOG_FILE"
}

_load_config() {
    local cfg=""
    if   [[ -n $HOIST_CONFIG && -f $HOIST_CONFIG ]];   then cfg="$HOIST_CONFIG"
    elif [[ -f "$(dirname "$0")/hoist.conf" ]];         then cfg="$(dirname "$0")/hoist.conf"
    elif [[ -f /etc/hoist/hoist.conf ]];                then cfg=/etc/hoist/hoist.conf
    fi
    [[ -n $cfg ]] && { log "Loading config: $cfg"; source "$cfg"; }
}
_load_config

while [[ "$1" != "" ]]; do
    case "$1" in
    --dry-run)    DRY_RUN=true; VERBOSE=true ;;
    --verbose)    VERBOSE=true ;;
    --tag=*)      val="${1#*=}"; [[ -n $val ]] && TAG=".$val" ;;
    --tag)        shift; [[ -n "$1" && "$1" != "--"* ]] && TAG=".$1" ;;
    --parallel=*) val="${1#*=}"; [[ $val =~ ^[0-9]+$ ]] && PARALLEL=$val ;;
    --parallel)   shift; [[ "$1" =~ ^[0-9]+$ ]] && PARALLEL="$1" ;;
    --update)     DO_SELF_UPDATE=true ;;
    --version)    echo "hoist v${HOIST_VERSION}"; exit 0 ;;
    --force)      FORCE=true ;;
    --list|--status) DO_LIST=true ;;
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
  --user <name>      User to run hoist as (--cron install). Default: root.
  --backend <name>   Force backend: cron | systemd. Default: auto-detect.

Config file (sourced before CLI flag parsing):
  \$HOIST_CONFIG, ./hoist.conf, or /etc/hoist/hoist.conf

Repo: https://github.com/${HOIST_REPO}
EOF
        exit 0 ;;
    esac
    shift
done

# Bash 4+ check runs after arg parse so --version/--help still work on macOS
# system bash 3.2 — users need a way to diagnose what they have installed.
if [[ -z ${BASH_VERSINFO+x} || ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "Error: hoist requires bash 4+ (current: ${BASH_VERSION:-unknown})." >&2
    echo "  macOS: brew install bash, then ensure the Homebrew bash is first in PATH" >&2
    echo "         (e.g. /opt/homebrew/bin or /usr/local/bin), or invoke hoist with that bash explicitly." >&2
    echo "  Verify with: bash --version" >&2
    exit 1
fi

if [[ $DO_CRON != true ]]; then
    [[ -x "$DOCKER_BINARY" ]] || { echo "Error: docker binary not found: ${DOCKER_BINARY:-docker}"; exit 1; }
fi

for _wh_var in GLOBAL_DISCORD_WEBHOOK GLOBAL_SLACK_WEBHOOK GLOBAL_GENERIC_WEBHOOK; do
    _wh_val="${!_wh_var}"
    if [[ -n "$_wh_val" ]]; then
        [[ "$_wh_val" =~ ^https?:// ]] || { echo "Error: $_wh_var is not a valid http(s) URL: $_wh_val"; exit 1; }
    fi
done

log "TAG=${TAG} | DRY_RUN=${DRY_RUN} | PARALLEL=${PARALLEL} | VERBOSE=${VERBOSE}"

setup_environment() {
    export DOCKER_BINARY CACHE_LOCATION TAG DRY_RUN VERBOSE CURL_TIMEOUT
    export PRUNE_IMAGES LOG_FILE MAINTENANCE_WINDOW
    export GLOBAL_DISCORD_WEBHOOK GLOBAL_SLACK_WEBHOOK GLOBAL_GENERIC_WEBHOOK
    if [[ $PARALLEL -gt 1 ]]; then
        export -f process_container compose_pull_wrapper compose_up_wrapper log
        export -f send_discord_notification send_generic_webhook send_slack_notification
        export -f check_maintenance_window validate_webhook_url validate_script_path
        export -f _semver_gt _self_update_notify _self_update_apply _self_update_check _sha256 _iso_ts
    fi
}

check_maintenance_window() {
    [[ -z "$MAINTENANCE_WINDOW" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log "Maintenance window check bypassed (dry-run)"
        return 0
    fi
    local start end current
    start=$(echo "$MAINTENANCE_WINDOW" | cut -d'-' -f1 | tr -d ':')
    end=$(echo "$MAINTENANCE_WINDOW" | cut -d'-' -f2 | tr -d ':')
    current=$(date +%H%M)
    if [[ "$start" -le "$end" ]]; then
        if [[ "$current" -lt "$start" || "$current" -ge "$end" ]]; then
            log "Outside maintenance window ($MAINTENANCE_WINDOW), skipping."
            exit 0
        fi
    else
        if [[ "$current" -lt "$start" && "$current" -ge "$end" ]]; then
            log "Outside maintenance window ($MAINTENANCE_WINDOW), skipping."
            exit 0
        fi
    fi
    log "Within maintenance window ($MAINTENANCE_WINDOW), proceeding."
}

compose_pull_wrapper() {
    [[ "$1" == /* ]] || { log "Error: compose workdir is not an absolute path: $1"; return 1; }
    cd "$1" || { log "Error: cannot cd to compose workdir: $1"; return 1; }
    "${DOCKER_BINARY}" compose pull "$2"
}

compose_up_wrapper() {
    [[ "$1" == /* ]] || { log "Error: compose workdir is not an absolute path: $1"; return 1; }
    cd "$1" || { log "Error: cannot cd to compose workdir: $1"; return 1; }
    "${DOCKER_BINARY}" compose up -d --always-recreate-deps "$2"
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

_semver_gt() {
    local IFS=.
    local -a a=($1) b=($2)
    for i in 0 1 2; do
        local av=${a[i]:-0} bv=${b[i]:-0}
        av=${av%%[!0-9]*}   # strip pre-release suffix (e.g. "1-rc.1" -> "1")
        bv=${bv%%[!0-9]*}
        [[ $av -gt $bv ]] && return 0
        [[ $av -lt $bv ]] && return 1
    done
    return 1
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

_self_update_notify() {
    local new_ver="$1" release_url="$2"
    local payload
    if [[ -n $GLOBAL_DISCORD_WEBHOOK ]]; then
        payload=$(jq -n \
            --arg title "Hoist update available: v${new_ver}" \
            --arg url "$release_url" \
            --arg cur "$HOIST_VERSION" \
            '{"embeds":[{"title":$title,
               "description":("Current: v" + $cur + "\nRun `hoist --update` to upgrade"),
               "url":$url,"color":16776960,
               "footer":{"text":"Powered by Hoist"}}],
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

    local tmp_script tmp_sha256
    tmp_script=$(mktemp /tmp/hoist-update-XXXXXX) || {
        log "Error: cannot create temp file for update download"
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

    chmod +x "$tmp_script"
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

    local latest_tag latest_version release_url asset_url sha256_url
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
    local detected
    detected=$(_detect_scheduler)
    case "$detected" in
        launchd-doc) _launchd_doc; return 2 ;;
        none)        log "Error: no supported scheduler found (need cron or systemd)"; return 1 ;;
    esac

    if [[ -n $backend ]]; then
        if [[ $backend != cron && $backend != systemd ]]; then
            log "Error: --backend must be 'cron' or 'systemd' (got: $backend)"; return 1
        fi
        if [[ $detected != both && $detected != "$backend" ]]; then
            log "Error: --backend $backend requested but only '$detected' is available"; return 1
        fi
    fi

    # Fail fast on non-TTY when a prompt would be required.
    local needs_prompt=false
    [[ -z $schedule_input ]] && needs_prompt=true
    [[ -z $run_user ]] && needs_prompt=true
    [[ $detected == both && -z $backend ]] && needs_prompt=true
    if [[ $needs_prompt == true && ! -t 0 ]]; then
        log "Error: --cron install needs an interactive terminal for missing values."
        log "  Pass --schedule, --user$([[ $detected == both ]] && printf %s ', --backend') to run non-interactively."
        return 1
    fi

    [[ -n $backend ]]       || backend=$(_prompt_backend "$detected") || return 1
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
    _cron_backend_status     && found=true
    _systemd_backend_status  && found=true
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
    local old_digest="$9" new_digest="${10}" color="${11:-768753}"
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
        '{"embeds":[{"title":$title,"color":$color,"fields":$fields,
            "footer":{"text":"Powered by Hoist"},"timestamp":$ts}],
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
        return 1
    }

    local image_name container_image_digest
    local docker_compose_service docker_compose_version docker_compose_workdir
    local old_oci_version old_oci_revision
    local hoist_update hoist_notify hoist_discord_webhook hoist_generic_webhook hoist_slack_webhook
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
        (.Config.Labels["com.sumguy.hoist\($tag).registry.authfile"] // .Config.Labels["org.hotio.pullio\($tag).registry.authfile"] // "")
    ' <<< "$inspect") || { log "$container_name: failed to parse inspect output"; return 1; }
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
    local effective_discord="${hoist_discord_webhook:-$GLOBAL_DISCORD_WEBHOOK}"
    local effective_generic="${hoist_generic_webhook:-$GLOBAL_GENERIC_WEBHOOK}"
    local effective_slack="${hoist_slack_webhook:-$GLOBAL_SLACK_WEBHOOK}"
    read -ra hoist_script_update <<< "${_vals[12]}"
    read -ra hoist_script_notify <<< "${_vals[13]}"
    hoist_registry_authfile="${_vals[14]}"
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

    if [[ -n $docker_compose_version && ($hoist_update == true || $hoist_notify == true) ]]; then
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
            log "$container_name: [dry-run] would pull image"
            image_digest="$container_image_digest"
            [[ $hoist_update == true ]] && _tokens+=("would_update")
            [[ $hoist_notify == true ]] && _tokens+=("would_notify")
        else
            log "$container_name: Pulling image..."
            compose_pull_wrapper "$docker_compose_workdir" "$docker_compose_service" || {
                log "$container_name: Pull failed"
                return 1
            }

            local image_inspect _img_out
            image_inspect=$("${DOCKER_BINARY}" image inspect "$image_name")
            _img_out=$(jq -r '
                .[0] |
                .Id,
                (.Config.Labels["org.opencontainers.image.version"] // ""),
                (.Config.Labels["org.opencontainers.image.revision"] // "")
            ' <<< "$image_inspect") || { log "$container_name: failed to parse image inspect output"; return 1; }
            readarray -t _img <<< "$_img_out"
            image_digest="${_img[0]}"
            new_oci_version="${_img[1]}"
            new_oci_revision="${_img[2]}"
        fi

        local status="🔄 Update available" status_generic="update_available" color=768753

        if [[ $image_digest != "$container_image_digest" && $hoist_update == true ]]; then
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
                if compose_up_wrapper "$docker_compose_workdir" "$docker_compose_service"; then
                    status="✅ Update succeeded"
                    status_generic="update_success"
                    color=3066993
                    _tokens+=("updated")
                else
                    log "$container_name: Update failed"
                    status="❌ Update failed"
                    status_generic="update_failure"
                    color=15158332
                    _tokens+=("update_failed")
                fi
                rm -f "${CACHE_LOCATION}/hoist-${safe_name}.notified"
            fi
        fi

        if [[ $image_digest != "$container_image_digest" && $hoist_notify == true && $DRY_RUN != true ]]; then
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
                if [[ -n $effective_discord ]]; then
                    log "$container_name: Sending Discord notification..."
                    send_discord_notification "$status" "$container_name" \
                        "$old_oci_version" "$new_oci_version" "$image_name" \
                        "$effective_discord" "$old_oci_revision" "$new_oci_revision" \
                        "${container_image_digest#sha256:}" "${image_digest#sha256:}" "$color"
                fi
                if [[ -n $effective_generic ]]; then
                    log "$container_name: Sending generic webhook..."
                    send_generic_webhook "$status_generic" "$container_name" \
                        "$old_oci_version" "$new_oci_version" "$image_name" \
                        "$effective_generic" "$old_oci_revision" "$new_oci_revision" \
                        "${container_image_digest#sha256:}" "${image_digest#sha256:}"
                fi
                if [[ -n $effective_slack ]]; then
                    log "$container_name: Sending Slack notification..."
                    send_slack_notification "[$container_name] $status: $image_name" "$effective_slack"
                fi
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
    local f token
    for f in "${CACHE_LOCATION}"/hoist-*.run-result; do
        [[ -f $f ]] || continue
        while IFS= read -r token; do
            case "$token" in
                updated)       (( updated++ )) ;;
                update_failed) (( update_failed++ )) ;;
                notified)      (( notified++ )) ;;
                no_change)     (( no_change++ )) ;;
                skipped)       (( skipped++ )) ;;
                would_update)  (( would_update++ )) ;;
                would_notify)  (( would_notify++ )) ;;
            esac
        done < "$f"
    done

    local msg
    if [[ $DRY_RUN == true ]]; then
        msg="Run complete (dry-run): ${would_update} would update, ${would_notify} would notify, ${no_change} no-change, ${skipped} skipped"
    else
        local updated_part="${updated} updated"
        [[ $update_failed -gt 0 ]] && updated_part+=" (${update_failed} failed)"
        msg="Run complete: ${updated_part}, ${notified} notified, ${no_change} no-change, ${skipped} skipped"
    fi
    log "$msg"
}

list_containers() {
    printf '%-20s %-32s %-7s %-7s %s\n' "CONTAINER" "IMAGE" "UPDATE" "NOTIFY" "CACHED DIGEST"
    local container_name
    for container_name in "${containers[@]}"; do
        local inspect
        inspect=$("${DOCKER_BINARY}" inspect "$container_name" 2>/dev/null) || {
            printf '%-20s %-32s %-7s %-7s %s\n' "$container_name" "(inspect failed)" "-" "-" "-"
            continue
        }

        local _jq_out
        _jq_out=$(jq -r --arg tag "$TAG" '
            .[0] |
            .Config.Image,
            (.Config.Labels["com.sumguy.hoist\($tag).update"] // .Config.Labels["org.hotio.pullio\($tag).update"] // ""),
            (.Config.Labels["com.sumguy.hoist\($tag).notify"] // .Config.Labels["org.hotio.pullio\($tag).notify"] // "")
        ' <<< "$inspect") || {
            printf '%-20s %-32s %-7s %-7s %s\n' "$container_name" "(parse failed)" "-" "-" "-"
            continue
        }
        readarray -t _lv <<< "$_jq_out"

        local image="${_lv[0]}" update_label="${_lv[1]}" notify_label="${_lv[2]}"
        local update_col notify_col cached_col

        if [[ -z $update_label && -z $notify_label ]]; then
            update_col="-"
            notify_col="-"
        else
            [[ $update_label == true ]] && update_col="yes" || update_col="no"
            [[ $notify_label == true ]] && notify_col="yes" || notify_col="no"
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

        printf '%-20s %-32s %-7s %-7s %s\n' \
            "$container_name" "$image" "$update_col" "$notify_col" "$cached_col"
    done
}

trap 'exit 130' INT

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
readarray -t containers < <("${DOCKER_BINARY}" ps --format '{{.Names}}' | sort -k1)

if [[ $DO_LIST == true ]]; then
    list_containers
    exit 0
fi

rm -f "${CACHE_LOCATION}"/hoist-*.run-result 2>/dev/null || true
setup_environment
check_maintenance_window

log "Processing ${#containers[@]} containers (parallelism: $PARALLEL)"

if [[ $PARALLEL -gt 1 ]]; then
    printf '%s\n' "${containers[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'process_container "$@"' _ {}
else
    for container_name in "${containers[@]}"; do
        process_container "$container_name"
    done
fi

print_summary

if [[ $DRY_RUN != true && $PRUNE_IMAGES == true ]]; then
    log "Pruning docker images..."
    "${DOCKER_BINARY}" image prune --force
fi
