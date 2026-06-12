#!/usr/bin/env bats
# Tests for the self-update check cache (Phase 5 #5). Automated runs persist the
# last successful check in CACHE_LOCATION and skip the GitHub API within the TTL;
# --force-update-check and interactive --update bypass it. curl is stubbed so we
# can assert whether the network call was made without touching GitHub.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist

    CACHE_LOCATION="${BATS_TEST_TMPDIR}"
    VERBOSE=false
    FORCE_UPDATE_CHECK=false
    UPDATE_CHECK_CACHE_TTL=21600

    CACHE_FILE="${CACHE_LOCATION}/hoist-self-update-check.cache"
    CURL_MARKER="${BATS_TEST_TMPDIR}/curl-was-called"

    # Default stub: record that the network call happened, then emit a 000 status
    # (network failure) so the function returns cleanly without parsing assets.
    curl() { : > "$CURL_MARKER"; printf '\n000'; }
}

@test "self-update cache: a fresh cache skips the API call" {
    printf '%s %s\n' "$(date +%s)" "9.9.9" > "$CACHE_FILE"
    run _self_update_check false false
    [ "$status" -eq 0 ]
    [ ! -f "$CURL_MARKER" ]
}

@test "self-update cache: a stale cache triggers a fresh API call" {
    printf '%s %s\n' "1" "9.9.9" > "$CACHE_FILE"   # epoch 1 = 1970, far past the TTL
    run _self_update_check false false
    [ "$status" -eq 0 ]
    [ -f "$CURL_MARKER" ]
}

@test "self-update cache: --force-update-check ignores a fresh cache" {
    FORCE_UPDATE_CHECK=true
    printf '%s %s\n' "$(date +%s)" "9.9.9" > "$CACHE_FILE"
    run _self_update_check false false
    [ "$status" -eq 0 ]
    [ -f "$CURL_MARKER" ]
}

@test "self-update cache: interactive checks always query live" {
    printf '%s %s\n' "$(date +%s)" "9.9.9" > "$CACHE_FILE"
    # Interactive path with an unreachable API exits 1 — but only because it made
    # the call despite the fresh cache, which is exactly what we want to prove.
    run _self_update_check true false
    [ -f "$CURL_MARKER" ]
}

@test "self-update cache: a successful check records the timestamp" {
    rm -f "$CACHE_FILE"
    curl() { printf '{"tag_name":"v1.0.0","html_url":"http://x","assets":[],"body":""}\n200'; }
    run _self_update_check false false
    [ -f "$CACHE_FILE" ]
    [[ "$(awk 'NR==1{print $1}' "$CACHE_FILE")" =~ ^[0-9]+$ ]]
}
