#!/usr/bin/env bats
# CLI argument parsing: TAG normalization (pure helper) and the validation
# behavior of the arg loop, exercised by invoking the script directly. The
# validation arms all exit before any docker call, so these are hermetic.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
}

HOIST="${BATS_TEST_DIRNAME}/../hoist.sh"

@test "_normalize_tag: empty stays empty" {
    [[ "$(_normalize_tag "")" == "" ]]
}

@test "_normalize_tag: bare tag gains a leading dot" {
    [[ "$(_normalize_tag "nightly")" == ".nightly" ]]
}

@test "_normalize_tag: already-dotted tag is unchanged" {
    [[ "$(_normalize_tag ".nightly")" == ".nightly" ]]
}

@test "argparse: unknown option exits 2" {
    run bash "$HOIST" --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "argparse: --tag with no value exits 2" {
    run bash "$HOIST" --tag
    [ "$status" -eq 2 ]
}

@test "argparse: --tag followed by another flag does not swallow it" {
    # The old shift-first form silently consumed --dry-run here; now it errors.
    run bash "$HOIST" --tag --dry-run
    [ "$status" -eq 2 ]
}

@test "argparse: --parallel with a non-integer exits 2" {
    run bash "$HOIST" --parallel abc
    [ "$status" -eq 2 ]
}

@test "argparse: --parallel with no value exits 2" {
    run bash "$HOIST" --parallel
    [ "$status" -eq 2 ]
}

@test "argparse: --version short-circuits cleanly" {
    run bash "$HOIST" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"hoist v"* ]]
}
