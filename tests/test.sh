#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJECT_DIR/zimbra_full_migrate.sh"
TEST_TMP="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local text="$1" expected="$2"
    [[ "$text" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_exit_code() {
    local expected="$1"
    shift

    set +o errexit
    "$@" >"$TEST_TMP/command.out" 2>&1
    local actual=$?
    set -o errexit

    [[ "$actual" -eq "$expected" ]] || {
        sed -n '1,80p' "$TEST_TMP/command.out" >&2
        fail "expected exit $expected, got $actual: $*"
    }
}

test_static_validation() {
    local shell_file
    while IFS= read -r shell_file; do
        bash -n "$shell_file"
        shellcheck -x -S warning "$shell_file"
    done < <(find "$PROJECT_DIR" -path "$PROJECT_DIR/.zimbra-full-migration" -prune -o \
        -type f \( -name '*.sh' -o -path "$PROJECT_DIR/tests/fakes/*" \) -print)
    grep -Fqx '# SPDX-License-Identifier: AGPL-3.0-only' "$SCRIPT"
    grep -Fq 'GNU AFFERO GENERAL PUBLIC LICENSE' "$PROJECT_DIR/LICENSE"
}

test_cli_validation() {
    local output
    output="$($SCRIPT --help)"
    assert_contains "$output" 'Usage:'

    assert_exit_code 2 "$SCRIPT" --phase
    assert_exit_code 2 "$SCRIPT" --user
    assert_exit_code 2 "$SCRIPT" --phase invalid
    assert_exit_code 2 "$SCRIPT" --status --delta
    assert_exit_code 2 "$SCRIPT" --preflight --user user@example.com

    assert_exit_code 1 env PATH="$PROJECT_DIR/tests/fakes:$PATH" \
        OLD_HOST=source.example.test MAILBOX_RESOLVE=invalid \
        MIG_ROOT="$TEST_TMP/invalid-settings" "$SCRIPT" --preflight
    grep -Fq 'MAILBOX_RESOLVE must be' "$TEST_TMP/command.out" || \
        fail 'invalid MAILBOX_RESOLVE was not reported'
}

test_config_precedence() {
    local app_dir="$TEST_TMP/app"
    local config_root="$TEST_TMP/config-root"
    local environment_root="$TEST_TMP/environment-root"
    local output

    mkdir -p "$app_dir"
    cp "$SCRIPT" "$app_dir/zimbra_full_migrate.sh"
    chmod +x "$app_dir/zimbra_full_migrate.sh"
    printf '%s\n' \
        'OLD_HOST="config.example.test"' \
        "MIG_ROOT=\"$config_root\"" \
        > "$app_dir/CONFIG"

    output="$($app_dir/zimbra_full_migrate.sh --status)"
    assert_contains "$output" 'config.example.test'
    assert_contains "$output" "$config_root"

    output="$(OLD_HOST=environment.example.test MIG_ROOT="$environment_root" \
        "$app_dir/zimbra_full_migrate.sh" --status)"
    assert_contains "$output" 'environment.example.test'
    assert_contains "$output" "$environment_root"
}

test_status_preserves_active_workspace() {
    local migration_root="$TEST_TMP/status-root"
    local marker="$migration_root/tmp/run.active/marker"

    mkdir -p "$(dirname -- "$marker")"
    printf 'keep\n' > "$marker"
    MIG_ROOT="$migration_root" "$SCRIPT" --status >/dev/null
    [[ -f "$marker" ]] || fail '--status removed another run workspace'
}

test_full_pipeline_with_fakes() {
    local fake_bin="$PROJECT_DIR/tests/fakes"
    local fake_state="$TEST_TMP/fake-zimbra-state"
    local migration_root="$TEST_TMP/integration-root"
    local instrumented_script="$TEST_TMP/integration-script.sh"

    sed \
        -e "s#^ZMPROV=.*#ZMPROV=\"$fake_bin/zmprov\"#" \
        -e "s#^ZMMAILBOX=.*#ZMMAILBOX=\"$fake_bin/zmmailbox\"#" \
        -e "s#^ZMCONTROL=.*#ZMCONTROL=\"$fake_bin/zmcontrol\"#" \
        "$SCRIPT" > "$instrumented_script"
    chmod +x "$instrumented_script"

    if ! PATH="$fake_bin:$PATH" \
            FAKE_ZIMBRA_BIN="$fake_bin" \
            FAKE_ZIMBRA_STATE="$fake_state" \
            MIG_ROOT="$migration_root" \
            OLD_HOST=source.example.test \
            MAILBOX_PARALLEL=2 \
            "$instrumented_script" >"$TEST_TMP/integration.out" 2>&1; then
        sed -n '1,240p' "$TEST_TMP/integration.out" >&2
        fail 'fake full-pipeline migration failed'
    fi

    grep -Fqx 'COMPLETE' "$migration_root/state/discover.ok"
    grep -Fqx 'example.test' "$migration_root/state/domains.ok"
    grep -Fqx 'default' "$migration_root/state/cos.ok"
    grep -Fqx 'user@example.test' "$migration_root/state/accounts.ok"
    grep -Fqx 'user@example.test' "$migration_root/state/attrs.ok"
    grep -Fqx 'user@example.test|alias@example.test' "$migration_root/state/aliases.ok"
    grep -Fqx 'group@example.test' "$migration_root/state/dl.ok"
    grep -Fqx 'user@example.test' "$migration_root/state/mailboxes.ok"
    grep -Fqx 'user@example.test' "$migration_root/state/finalize.ok"
    grep -Fqx 'example.test' "$migration_root/state/domain_status.ok"
    [[ -f "$fake_state/domain-status-applied" ]] || \
        fail 'final domain status was not restored'
    grep -Fq 'user@example.test,123,123,IMPORTED' \
        "$migration_root/reports/verification.csv"
    [[ ! -s "$migration_root/reports/failures.txt" ]] || \
        fail 'fake full pipeline recorded unexpected failures'
    [[ ! -e "$migration_root/stage/user@example.test.tgz" ]] || \
        fail 'successful mailbox archive was not removed'

    set +o errexit
    PATH="$fake_bin:$PATH" \
        FAKE_ZIMBRA_BIN="$fake_bin" \
        FAKE_ZIMBRA_STATE="$fake_state" \
        FAKE_IMPORT_RC=7 \
        MIG_ROOT="$migration_root" \
        OLD_HOST=source.example.test \
        "$instrumented_script" --delta >"$TEST_TMP/delta-failure.out" 2>&1
    local delta_rc=$?
    set -o errexit

    [[ "$delta_rc" -eq 1 ]] || {
        sed -n '1,240p' "$TEST_TMP/delta-failure.out" >&2
        fail "failed delta returned $delta_rc instead of 1"
    }
    ! grep -Fqx 'user@example.test' "$migration_root/state/mailboxes.ok" || \
        fail 'failed delta left the old mailbox checkpoint in place'
    grep -Fq 'mailboxes|user@example.test|IMPORT_FAILED' \
        "$migration_root/reports/failures.txt"
    [[ -s "$migration_root/stage/user@example.test.tgz" ]] || \
        fail 'failed delta did not retain its mailbox archive'

    if ! PATH="$fake_bin:$PATH" \
            FAKE_ZIMBRA_BIN="$fake_bin" \
            FAKE_ZIMBRA_STATE="$fake_state" \
            MIG_ROOT="$migration_root" \
            OLD_HOST=source.example.test \
            "$instrumented_script" >"$TEST_TMP/delta-retry.out" 2>&1; then
        sed -n '1,240p' "$TEST_TMP/delta-retry.out" >&2
        fail 'retry after failed delta did not recover from the cached archive'
    fi
    grep -Fqx 'user@example.test' "$migration_root/state/mailboxes.ok"
    [[ ! -e "$migration_root/stage/user@example.test.tgz" ]] || \
        fail 'successful cached retry did not remove its archive'

    local failed_state="$TEST_TMP/failed-fake-zimbra-state"
    local failed_root="$TEST_TMP/failed-integration-root"
    set +o errexit
    PATH="$fake_bin:$PATH" \
        FAKE_ZIMBRA_BIN="$fake_bin" \
        FAKE_ZIMBRA_STATE="$failed_state" \
        FAKE_IMPORT_RC=7 \
        MIG_ROOT="$failed_root" \
        OLD_HOST=source.example.test \
        "$instrumented_script" >"$TEST_TMP/fresh-failure.out" 2>&1
    local failed_rc=$?
    set -o errexit

    [[ "$failed_rc" -eq 1 ]] || fail "fresh failed migration returned $failed_rc instead of 1"
    [[ ! -e "$failed_state/domain-status-applied" ]] || \
        fail 'domain status was finalized after an earlier phase failure'
    [[ ! -e "$failed_root/state/domain_status.ok" ]] || \
        fail 'deferred domain status received a checkpoint'
}

test_interrupt_exit_code() {
    local migration_root="$TEST_TMP/interrupt-root"
    local instrumented_script="$TEST_TMP/interrupt-script.sh"

    # Insert the same detached process-group pattern used by mailbox workers
    # so the real handler and descendant termination are both exercised.
    awk '
        { print }
        $0 == "trap '\''handle_signal TERM'\'' TERM" {
            print "setsid sleep 30 &"
            print "ACTIVE_PROCESS_GROUP=$!"
            print "wait \"$ACTIVE_PROCESS_GROUP\""
        }
    ' "$SCRIPT" > "$instrumented_script"
    chmod +x "$instrumented_script"

    python3 - "$instrumented_script" "$migration_root" "$TEST_TMP/interrupt.out" <<'PY'
import os
import signal
import subprocess
import sys
import time

script, migration_root, output_path = sys.argv[1:]
environment = os.environ.copy()
environment["MIG_ROOT"] = migration_root

with open(output_path, "wb") as output:
    process = subprocess.Popen(
        [script, "--status"],
        env=environment,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    time.sleep(0.2)
    started = time.monotonic()
    os.killpg(process.pid, signal.SIGINT)
    return_code = process.wait(timeout=3)
    elapsed = time.monotonic() - started

if return_code != 130:
    raise SystemExit(f"Ctrl+C path returned {return_code} instead of 130")
if elapsed >= 2:
    raise SystemExit(f"Ctrl+C path took too long to stop: {elapsed:.2f}s")
PY

    grep -Fq 'Interrupted by INT' "$TEST_TMP/interrupt.out" || \
        fail 'Ctrl+C path did not report the interruption'
}

test_static_validation
test_cli_validation
test_config_precedence
test_status_preserves_active_workspace
test_full_pipeline_with_fakes
test_interrupt_exit_code

printf 'All tests passed.\n'
