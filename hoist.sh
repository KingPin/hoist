#!/usr/bin/env bash

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
    --dry-run)    DRY_RUN=true ;;
    --tag=*)      val="${1#*=}"; [[ -n $val ]] && TAG=".$val" ;;
    --tag)        shift; [[ -n "$1" && "$1" != "--"* ]] && TAG=".$1" ;;
    --parallel=*) val="${1#*=}"; [[ $val =~ ^[0-9]+$ ]] && PARALLEL=$val ;;
    --parallel)   shift; [[ "$1" =~ ^[0-9]+$ ]] && PARALLEL="$1" ;;
    esac
    shift
done

log "TAG=${TAG} | DRY_RUN=${DRY_RUN} | PARALLEL=${PARALLEL}"

setup_environment() {
    export DOCKER_BINARY CACHE_LOCATION TAG DRY_RUN
    export PRUNE_IMAGES LOG_FILE MAINTENANCE_WINDOW
    export GLOBAL_DISCORD_WEBHOOK GLOBAL_SLACK_WEBHOOK GLOBAL_GENERIC_WEBHOOK
    if [[ $PARALLEL -gt 1 ]]; then
        export -f process_container compose_pull_wrapper compose_up_wrapper log
        export -f send_discord_notification send_generic_webhook send_slack_notification
        export -f check_maintenance_window
    fi
}

check_maintenance_window() {
    [[ -z "$MAINTENANCE_WINDOW" || "$DRY_RUN" == true ]] && return 0
    local start end current
    start=$(echo "$MAINTENANCE_WINDOW" | cut -d'-' -f1 | tr -d ':')
    end=$(echo "$MAINTENANCE_WINDOW" | cut -d'-' -f2 | tr -d ':')
    current=$(date +%H%M)
    if [[ "$start" -le "$end" ]]; then
        [[ "$current" -lt "$start" || "$current" -ge "$end" ]] && {
            log "Outside maintenance window ($MAINTENANCE_WINDOW), skipping."; exit 0; }
    else
        [[ "$current" -lt "$start" && "$current" -ge "$end" ]] && {
            log "Outside maintenance window ($MAINTENANCE_WINDOW), skipping."; exit 0; }
    fi
}

compose_pull_wrapper() {
    cd "$1" || exit 1
    "${DOCKER_BINARY}" compose pull "$2"
}

compose_up_wrapper() {
    cd "$1" || exit 1
    "${DOCKER_BINARY}" compose up -d --always-recreate-deps "$2"
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
        --arg ts "$(date -u +'%FT%T.%3NZ')" \
        '{"embeds":[{"title":$title,"color":$color,"fields":$fields,
            "footer":{"text":"Powered by Hoist"},"timestamp":$ts}],
          "username":"Hoist"}')
    curl -fsSL -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$webhook"
}

send_generic_webhook() {
    local payload
    payload=$(jq -n \
        --arg type "$1" --arg container "$2" \
        --arg old_version "$3" --arg new_version "$4" \
        --arg image "$5" \
        --arg old_revision "$7" --arg new_revision "$8" \
        --arg old_image_id "$9" --arg new_image_id "${10}" \
        --arg ts "$(date -u +'%FT%T.%3NZ')" \
        '{"type":$type,"container":$container,"image":$image,
          "old_image_id":$old_image_id,"new_image_id":$new_image_id,
          "old_version":$old_version,"new_version":$new_version,
          "old_revision":$old_revision,"new_revision":$new_revision,
          "timestamp":$ts}')
    curl -fsSL -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$6"
}

send_slack_notification() {
    local payload
    payload=$(jq -n --arg text "$1" '{"text":$text}')
    curl -fsSL -H "User-Agent: Hoist" -H "Content-Type: application/json" -d "$payload" "$2"
}

process_container() {
    local container_name="$1"
    local safe_name
    safe_name=$(printf '%s' "$container_name" | tr -cs '[:alnum:]._-' '_')
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

    readarray -t _vals < <(jq -r --arg tag "$TAG" '
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
    ' <<< "$inspect")

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

    if [[ -n $docker_compose_version && ($hoist_update == true || $hoist_notify == true) ]]; then
        if [[ -f $hoist_registry_authfile ]]; then
            log "$container_name: Registry login..."
            if [[ $DRY_RUN != true ]]; then
                jq -r .password < "$hoist_registry_authfile" | \
                    "${DOCKER_BINARY}" login \
                        --username "$(jq -r .username < "$hoist_registry_authfile")" \
                        --password-stdin \
                        "$(jq -r .registry < "$hoist_registry_authfile")"
            fi
        fi

        local image_digest new_oci_version new_oci_revision
        if [[ $DRY_RUN == true ]]; then
            log "$container_name: [dry-run] would pull image"
            image_digest="$container_image_digest"
        else
            log "$container_name: Pulling image..."
            compose_pull_wrapper "$docker_compose_workdir" "$docker_compose_service" || \
                log "$container_name: Pull failed"

            local image_inspect
            image_inspect=$("${DOCKER_BINARY}" image inspect "$image_name")
            readarray -t _img < <(jq -r '
                .[0] |
                .Id,
                (.Config.Labels["org.opencontainers.image.version"] // ""),
                (.Config.Labels["org.opencontainers.image.revision"] // "")
            ' <<< "$image_inspect")
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
                else
                    log "$container_name: Update failed"
                    status="❌ Update failed"
                    status_generic="update_failure"
                    color=15158332
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
                echo "$image_digest" > "${CACHE_LOCATION}/hoist-${safe_name}.notified"
            fi
        fi
    fi
}

trap 'exit 130' INT

declare -a containers
readarray -t containers < <("${DOCKER_BINARY}" ps --format '{{.Names}}' | sort -k1)
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

if [[ $DRY_RUN != true && $PRUNE_IMAGES == true ]]; then
    log "Pruning docker images..."
    "${DOCKER_BINARY}" image prune --force
fi
