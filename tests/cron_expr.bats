#!/usr/bin/env bats
# Cron expression validation: field-count, per-field grammar, @-shortcuts, and
# newline rejection (a multi-line value must never reach the generated cron.d).

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper.bash"
    load_hoist
}

@test "_validate_cron_expr: a well-formed 5-field expression passes" {
    run _validate_cron_expr "*/30 * * * *"
    [ "$status" -eq 0 ]
}

@test "_validate_cron_expr: ranges, lists and steps pass" {
    run _validate_cron_expr "0,30 0-6 * * MON-FRI"
    [ "$status" -eq 0 ]
}

@test "_validate_cron_expr: @-shortcuts are accepted" {
    run _validate_cron_expr "@daily"
    [ "$status" -eq 0 ]
    run _validate_cron_expr "@reboot"
    [ "$status" -eq 0 ]
}

@test "_validate_cron_expr: wrong field count is rejected" {
    run _validate_cron_expr "* * * *"
    [ "$status" -ne 0 ]
}

@test "_validate_cron_expr: a garbage field is rejected" {
    run _validate_cron_expr "* * * * ;rm"
    [ "$status" -ne 0 ]
}

@test "_validate_cron_expr: embedded newline is rejected" {
    run _validate_cron_expr $'*/30 * * * *\n0 0 * * * root rm -rf /'
    [ "$status" -ne 0 ]
}
