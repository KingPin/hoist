#!/usr/bin/env bash
HOIST_VERSION="1.2.0"
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

[[ -x "$DOCKER_BINARY" ]] || { echo "Error: docker binary not found: ${DOCKER_BINARY:-docker}"; exit 1; }

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
