# Shared test helper: source hoist.sh so its functions are available without
# triggering the entry-point guard (which only fires when run directly).
load_hoist() {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../hoist.sh"
}
