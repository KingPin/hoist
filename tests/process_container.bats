#!/usr/bin/env bats
# Behaviour-locking tests for process_container. process_container is the heart
# of hoist and is being split into helpers — these tests pin the run-result
# token contract (the public outcome of every code path) so the refactor can be
# verified byte-for-byte. docker is faked; compose pull/up are stubbed where a
# path would otherwise shell out.

setup() {
    # DOCKER_BINARY is resolved at source time (hoist.sh:5) via ${DOCKER_BINARY:-…},
    # so it must be exported BEFORE load_hoist or `which docker` wins.
    export FD_DIR="${BATS_TEST_TMPDIR}/fd"
    mkdir -p "$FD_DIR"
    cat > "${FD_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
# Minimal docker stand-in: serves canned JSON for inspect / image inspect and
# no-ops the mutating verbs that some paths reach.
case "$1" in
    inspect)       cat "${FD_DIR}/inspect.json" ;;
    image)         cat "${FD_DIR}/image.json" ;;
    stop|tag|login|compose) exit 0 ;;
    *)             exit 0 ;;
esac
EOF
    chmod +x "${FD_DIR}/docker"
    export DOCKER_BINARY="${FD_DIR}/docker"

    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist

    # Per-test globals (overridable in the test body).
    CACHE_LOCATION="${BATS_TEST_TMPDIR}"
    TAG=""
    DRY_RUN=false
    VERBOSE=false
    WEBHOOK_ROLLUP=false
}

# Build the [.[0]] inspect document. $1=image $2=container-digest $3=labels-json
_write_inspect() {
    printf '[{"Config":{"Image":"%s","Labels":%s},"Image":"%s"}]\n' \
        "$1" "$3" "$2" > "${FD_DIR}/inspect.json"
}

# Build the image-inspect document. $1=new-digest $2=oci-version $3=oci-revision
_write_image() {
    printf '[{"Id":"%s","Config":{"Labels":{"org.opencontainers.image.version":"%s","org.opencontainers.image.revision":"%s"}}}]\n' \
        "$1" "$2" "$3" > "${FD_DIR}/image.json"
}

# Read the tokens process_container wrote for a container.
_tokens_for() {
    cat "${CACHE_LOCATION}/hoist-${1}.run-result" 2>/dev/null
}

@test "process_container: a container with no hoist labels is skipped" {
    _write_inspect "nginx:latest" "sha256:OLD" '{}'
    run process_container "plain"
    [ "$status" -eq 0 ]
    [[ "$(_tokens_for plain)" == "skipped" ]]
}

@test "process_container: hoist labels but no compose metadata -> not_compose_managed" {
    _write_inspect "nginx:latest" "sha256:OLD" '{"com.sumguy.hoist.update":"true"}'
    run process_container "orphan"
    [ "$status" -eq 0 ]
    [[ "$(_tokens_for orphan)" == "not_compose_managed" ]]
}

@test "process_container: dry-run on an eligible container reports would_update/would_notify" {
    DRY_RUN=true
    _write_inspect "nginx:latest" "sha256:OLD" \
        '{"com.docker.compose.version":"2","com.docker.compose.service":"web","com.docker.compose.project.working_dir":"/srv/web","com.sumguy.hoist.update":"true","com.sumguy.hoist.notify":"true"}'
    run process_container "dryc"
    [ "$status" -eq 0 ]
    local out; out="$(_tokens_for dryc)"
    [[ "$out" == *"would_update"* ]]
    [[ "$out" == *"would_notify"* ]]
}

@test "process_container: a future pause_until yields the paused token" {
    _write_inspect "nginx:latest" "sha256:OLD" \
        '{"com.docker.compose.version":"2","com.docker.compose.service":"web","com.docker.compose.project.working_dir":"/srv/paused","com.sumguy.hoist.update":"true","com.sumguy.hoist.pause_until":"2099-01-01"}'
    run process_container "pausedc"
    [ "$status" -eq 0 ]
    [[ "$(_tokens_for pausedc)" == "paused" ]]
}

@test "process_container: a live update with a changed digest emits updated" {
    compose_pull_wrapper() { return 0; }
    compose_up_wrapper() { return 0; }
    _write_inspect "nginx:latest" "sha256:OLD" \
        '{"com.docker.compose.version":"2","com.docker.compose.service":"web","com.docker.compose.project.working_dir":"/srv/upd","com.sumguy.hoist.update":"true"}'
    _write_image "sha256:NEW" "1.2.3" "abc"
    run process_container "updc"
    [ "$status" -eq 0 ]
    [[ "$(_tokens_for updc)" == *"updated"* ]]
}

@test "process_container: a violated constraint blocks the update" {
    compose_pull_wrapper() { return 0; }
    compose_up_wrapper() { return 0; }
    _write_inspect "nginx:latest" "sha256:OLD" \
        '{"com.docker.compose.version":"2","com.docker.compose.service":"web","com.docker.compose.project.working_dir":"/srv/con","com.sumguy.hoist.update":"true","com.sumguy.hoist.constraint":"^1.0.0"}'
    _write_image "sha256:NEW" "2.0.0" "abc"
    run process_container "conc"
    [ "$status" -eq 0 ]
    local out; out="$(_tokens_for conc)"
    [[ "$out" == *"constraint_blocked"* ]]
    [[ "$out" != *"updated"* ]]
}

@test "process_container: a pull failure emits update_failed and returns non-zero" {
    compose_pull_wrapper() { return 1; }
    _write_inspect "nginx:latest" "sha256:OLD" \
        '{"com.docker.compose.version":"2","com.docker.compose.service":"web","com.docker.compose.project.working_dir":"/srv/pf","com.sumguy.hoist.update":"true"}'
    run process_container "pfc"
    [ "$status" -ne 0 ]
    [[ "$(_tokens_for pfc)" == *"update_failed"* ]]
}
