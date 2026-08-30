#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJECT_DIR/zimbra_amavis_openssl_autofix.sh"
FAKE_BIN="$PROJECT_DIR/tests/amavis_fakes"
TEST_TMP="$(mktemp -d)"
TEST_USER="$(id -un)"
INSTRUMENTED_SCRIPT="$TEST_TMP/zimbra_amavis_openssl_autofix.test.sh"
FAKE_HOME="$TEST_TMP/zimbra"
STATE_DIR="$TEST_TMP/amavis-state"

cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1" expected="$2"
    grep -Fq -- "$expected" "$file" || {
        sed -n '1,200p' "$file" >&2
        fail "expected $file to contain: $expected"
    }
}

assert_not_contains() {
    local file="$1" unexpected="$2"
    if grep -Fq -- "$unexpected" "$file"; then
        sed -n '1,200p' "$file" >&2
        fail "expected $file not to contain: $unexpected"
    fi
}

write_amavisctl() {
    local dest="$1" variant="${2:-normal}"
    cat > "$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
zmsetvars() { :; }
EOF
    case "$variant" in
        normal)
            printf '\nzmsetvars\n' >> "$dest"
            ;;
        patched)
            cat >> "$dest" <<EOF

zmsetvars
# ZIMBRA_AMAVIS_OPENSSL_FIX_BEGIN
export LD_LIBRARY_PATH=${FAKE_HOME}/common/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
# ZIMBRA_AMAVIS_OPENSSL_FIX_END
EOF
            ;;
        no-zmsetvars)
            ;;
        two-zmsetvars)
            printf '\nzmsetvars\nzmsetvars\n' >> "$dest"
            ;;
        *)
            fail "unknown zmamavisdctl variant: $variant"
            ;;
    esac
    cat >> "$dest" <<'EOF'

state_dir="${FAKE_AMAVIS_STATE_DIR:?}"
mkdir -p -- "$state_dir"

case "${1:-}" in
    status)
        if [[ -f "$state_dir/running" ]]; then
            printf 'amavisd is running\n'
            exit 0
        fi
        printf 'amavisd is not running\n'
        exit 1
        ;;
    restart|start)
        if [[ -n "${FAKE_AMAVIS_RESTART_SLEEP_MARKER:-}" && ! -e "$FAKE_AMAVIS_RESTART_SLEEP_MARKER" ]]; then
            : > "$FAKE_AMAVIS_RESTART_SLEEP_MARKER"
            sleep 30
        fi
        : > "$state_dir/running"
        : > "$state_dir/$1"
        printf 'amavisd %sed\n' "$1"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$dest"
}

prepare_fake_home() {
    local variant="${1:-normal}" running="${2:-1}"
    mkdir -p \
        "$FAKE_HOME/bin" \
        "$FAKE_HOME/common/lib" \
        "$FAKE_HOME/common/sbin" \
        "$STATE_DIR"
    : > "$FAKE_HOME/common/lib/libssl.so.3"
    : > "$FAKE_HOME/common/lib/libcrypto.so.3"
    printf 'zmsetvars() { :; }\n' > "$FAKE_HOME/bin/zmshutil"
    cp "$FAKE_BIN/zimbra-command" "$FAKE_HOME/bin/zmcontrol"
    cp "$FAKE_BIN/zimbra-command" "$FAKE_HOME/common/sbin/postqueue"
    chmod +x "$FAKE_HOME/bin/zmcontrol" "$FAKE_HOME/common/sbin/postqueue"
    write_amavisctl "$FAKE_HOME/bin/zmamavisdctl" "$variant"
    rm -f "$STATE_DIR/running" "$STATE_DIR/restart" "$STATE_DIR/start"
    if [[ "$running" == "1" ]]; then
        : > "$STATE_DIR/running"
    fi
}

prepare_instrumented_script() {
    # The sed expression intentionally matches a literal $EUID.
    # shellcheck disable=SC2016
    sed 's/^\[\[ "$EUID" -eq 0 \]\] || die "Run this script as root on the destination Zimbra server\."$/: # root check disabled for isolated tests/' \
        "$SCRIPT" > "$INSTRUMENTED_SCRIPT"
    chmod +x "$INSTRUMENTED_SCRIPT"
    grep -Fq '# root check disabled for isolated tests' "$INSTRUMENTED_SCRIPT" || \
        fail 'test instrumentation did not disable the root check'
}

run_amavis() {
    local output="$1" run_root="$2"
    shift 2
    env \
        PATH="$FAKE_BIN:$PATH" \
        ZIMBRA_HOME="$FAKE_HOME" \
        ZIMBRA_USER="$TEST_USER" \
        RUN_ROOT="$run_root" \
        LOG_ROOT="$run_root/logs" \
        LOCK_FILE="$run_root/amavis.lock" \
        AMAVIS_RESTART_WAIT=0 \
        FAKE_ZIMBRA_LIB="$FAKE_HOME/common/lib" \
        FAKE_AMAVIS_STATE_DIR="$STATE_DIR" \
        FAKE_TARGET_HOSTNAME="destination.example.test" \
        "$INSTRUMENTED_SCRIPT" "$@" > "$output" 2>&1
}

test_static_and_cli() {
    local output="$TEST_TMP/help.out" rc
    bash -n "$SCRIPT"
    shellcheck -x -S warning "$SCRIPT" "$PROJECT_DIR/tests/test_amavis.sh" "$FAKE_BIN"/*
    grep -Fqx '# SPDX-License-Identifier: AGPL-3.0-only' "$SCRIPT"
    grep -Fq 'Cuma Kurt' "$SCRIPT"
    grep -Fq 'github.com/cumakurt/zimbra_full_migrate' "$SCRIPT"
    grep -Fq 'all operational responsibility belongs to the operator' \
        "$PROJECT_DIR/README-AMAVIS.md"
    grep -Fq 'tüm operasyonel sorumluluk aracı kullanan kişiye/kuruma aittir' \
        "$PROJECT_DIR/README-AMAVIS.tr.md"
    grep -Fq 'GNU AFFERO GENERAL PUBLIC LICENSE' "$PROJECT_DIR/LICENSE"

    "$SCRIPT" --help > "$output"
    assert_contains "$output" 'never runs zmcontrol restart'
    assert_contains "$output" '--verbose'
    assert_contains "$output" '--check-only, --verify-only'

    set +o errexit
    "$SCRIPT" --not-a-flag > "$output" 2>&1
    rc=$?
    set -o errexit
    [[ "$rc" -eq 2 ]] || fail "unknown option returned $rc instead of 2"
}

test_check_only_requires_repair() {
    local run_root="$TEST_TMP/check-run" output="$TEST_TMP/check.out" rc before after
    prepare_fake_home normal 1
    before="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    set +o errexit
    run_amavis "$output" "$run_root" --check-only
    rc=$?
    set -o errexit
    [[ "$rc" -eq 10 ]] || {
        sed -n '1,200p' "$output" >&2
        fail "check-only returned $rc instead of 10"
    }
    after="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    [[ "$before" == "$after" ]] || fail 'check-only modified zmamavisdctl'
    [[ ! -e "$STATE_DIR/restart" ]] || fail 'check-only restarted Amavis'
    assert_contains "$output" 'Check-only mode: repair is required but no files were modified.'
    assert_contains "$output" '[4/4] Confirm the Zimbra library workaround'
}

test_successful_repair() {
    local run_root="$TEST_TMP/fix-run" output="$TEST_TMP/fix.out"
    prepare_fake_home normal 0
    run_amavis "$output" "$run_root" --fix || {
        sed -n '1,240p' "$output" >&2
        fail 'successful repair failed'
    }
    grep -Fq '# ZIMBRA_AMAVIS_OPENSSL_FIX_BEGIN' "$FAKE_HOME/bin/zmamavisdctl" || \
        fail 'repair did not insert the patch marker'
    grep -Fq "export LD_LIBRARY_PATH=${FAKE_HOME}/common/lib" "$FAKE_HOME/bin/zmamavisdctl" || \
        fail 'repair did not insert the library-path export'
    [[ -f "$STATE_DIR/restart" ]] || fail 'repair did not restart Amavis'
    [[ -f "$STATE_DIR/running" ]] || fail 'repair did not mark Amavis running'
    compgen -G "$FAKE_HOME/bin/zmamavisdctl.backup-*" >/dev/null || \
        fail 'repair did not create a zmamavisdctl backup'
    bash -n "$FAKE_HOME/bin/zmamavisdctl" || fail 'patched zmamavisdctl failed bash -n'
    assert_contains "$output" 'Repair completed successfully.'
    assert_contains "$output" 'NO FULL ZIMBRA STACK WAS RESTARTED'
}

test_already_patched_skips_restart() {
    local run_root="$TEST_TMP/patched-run" output="$TEST_TMP/patched.out"
    prepare_fake_home patched 1
    run_amavis "$output" "$run_root" --fix || {
        sed -n '1,200p' "$output" >&2
        fail 'already-patched healthy run failed'
    }
    [[ ! -e "$STATE_DIR/restart" ]] || fail 'already-patched healthy run restarted Amavis'
    assert_contains "$output" 'Persistent patch is present and Amavis is healthy. No restart.'
}

test_healthy_baseline_exits_zero() {
    local run_root="$TEST_TMP/healthy-run" output="$TEST_TMP/healthy.out" before after
    prepare_fake_home normal 1
    before="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    FAKE_PERL_ALWAYS_OK=1 run_amavis "$output" "$run_root" --fix || {
        sed -n '1,200p' "$output" >&2
        fail 'healthy baseline run failed'
    }
    after="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    [[ "$before" == "$after" ]] || fail 'healthy run modified zmamavisdctl'
    assert_contains "$output" 'Amavis is already healthy. No repair required.'
}

test_unrelated_amavis_down_exits_three() {
    local run_root="$TEST_TMP/other-run" output="$TEST_TMP/other.out" rc before after
    prepare_fake_home normal 0
    before="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    set +o errexit
    FAKE_PERL_ALWAYS_OK=1 run_amavis "$output" "$run_root" --fix
    rc=$?
    set -o errexit
    [[ "$rc" -eq 3 ]] || {
        sed -n '1,200p' "$output" >&2
        fail "unrelated Amavis-down run returned $rc instead of 3"
    }
    after="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    [[ "$before" == "$after" ]] || fail 'unrelated failure modified zmamavisdctl'
    assert_contains "$output" 'OpenSSL/Net::SSLeay library-path issue cannot be reproduced'
}

test_workaround_failure_does_not_patch() {
    local run_root="$TEST_TMP/work-run" output="$TEST_TMP/work.out" rc before after
    prepare_fake_home normal 0
    before="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    set +o errexit
    FAKE_PERL_ALWAYS_FAIL=1 run_amavis "$output" "$run_root" --fix
    rc=$?
    set -o errexit
    [[ "$rc" -eq 1 ]] || {
        sed -n '1,200p' "$output" >&2
        fail "workaround-failure run returned $rc instead of 1"
    }
    after="$(cksum "$FAKE_HOME/bin/zmamavisdctl" | awk '{print $1}')"
    [[ "$before" == "$after" ]] || fail 'workaround failure modified zmamavisdctl'
    assert_contains "$output" 'not safely repairable by the LD_LIBRARY_PATH fix'
}

test_refuses_wrong_error_signature() {
    local run_root="$TEST_TMP/sig-run" output="$TEST_TMP/sig.out" rc
    prepare_fake_home normal 0
    set +o errexit
    FAKE_PERL_FAIL_MSG='permission denied on some unrelated module' \
        run_amavis "$output" "$run_root" --fix
    rc=$?
    set -o errexit
    [[ "$rc" -eq 1 ]] || {
        sed -n '1,200p' "$output" >&2
        fail "signature-mismatch run returned $rc instead of 1"
    }
    assert_contains "$output" 'expected OpenSSL/SSLeay error signature was not found'
    if grep -Fq '# ZIMBRA_AMAVIS_OPENSSL_FIX_BEGIN' "$FAKE_HOME/bin/zmamavisdctl"; then
        fail 'signature mismatch still patched zmamavisdctl'
    fi
}

test_refuses_ambiguous_zmsetvars() {
    local run_root="$TEST_TMP/zmset-run" output="$TEST_TMP/zmset.out" rc
    prepare_fake_home two-zmsetvars 0
    set +o errexit
    run_amavis "$output" "$run_root" --fix
    rc=$?
    set -o errexit
    [[ "$rc" -eq 1 ]] || {
        sed -n '1,200p' "$output" >&2
        fail "ambiguous zmsetvars run returned $rc instead of 1"
    }
    assert_contains "$output" "Expected exactly one standalone 'zmsetvars' line"
    if grep -Fq '# ZIMBRA_AMAVIS_OPENSSL_FIX_BEGIN' "$FAKE_HOME/bin/zmamavisdctl"; then
        fail 'ambiguous zmsetvars still patched zmamavisdctl'
    fi
}

test_flush_queue_flag() {
    local run_root="$TEST_TMP/flush-run" output="$TEST_TMP/flush.out"
    prepare_fake_home normal 0
    run_amavis "$output" "$run_root" --fix --flush-queue || {
        sed -n '1,200p' "$output" >&2
        fail 'flush-queue repair failed'
    }
    assert_contains "$output" 'Queue flush requested.'
}

test_interrupt_and_lock() {
    local run_root="$TEST_TMP/lock-run" marker="$TEST_TMP/perl-sleeping" rc
    prepare_fake_home normal 1

    env \
        PATH="$FAKE_BIN:$PATH" \
        ZIMBRA_HOME="$FAKE_HOME" \
        ZIMBRA_USER="$TEST_USER" \
        RUN_ROOT="$run_root" \
        LOG_ROOT="$run_root/logs" \
        LOCK_FILE="$run_root/amavis.lock" \
        AMAVIS_RESTART_WAIT=0 \
        FAKE_ZIMBRA_LIB="$FAKE_HOME/common/lib" \
        FAKE_AMAVIS_STATE_DIR="$STATE_DIR" \
        FAKE_PERL_SLEEP_MARKER="$marker" \
        python3 - "$INSTRUMENTED_SCRIPT" "$marker" "$TEST_TMP/interrupt.out" "$TEST_TMP/lock.out" <<'PY'
import os
import signal
import subprocess
import sys
import time

script, marker, interrupt_out, lock_out = sys.argv[1:]
env = os.environ.copy()
with open(interrupt_out, "wb") as output:
    first = subprocess.Popen(
        [script, "--check-only"],
        env=env,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

deadline = time.monotonic() + 10
while not os.path.exists(marker):
    if first.poll() is not None:
        raise SystemExit(f"first process exited before sleep: {first.returncode}")
    if time.monotonic() >= deadline:
        first.kill()
        raise SystemExit("timed out waiting for fake perl sleep")
    time.sleep(0.02)

with open(lock_out, "wb") as output:
    second = subprocess.run(
        [script, "--check-only"],
        env=env,
        stdout=output,
        stderr=subprocess.STDOUT,
        check=False,
    )
if second.returncode != 1:
    first.kill()
    raise SystemExit(f"locked second process returned {second.returncode} instead of 1")

started = time.monotonic()
os.kill(first.pid, signal.SIGINT)
return_code = first.wait(timeout=5)
elapsed = time.monotonic() - started
if return_code != 130:
    raise SystemExit(f"Ctrl+C returned {return_code} instead of 130")
if elapsed >= 4:
    raise SystemExit(f"Ctrl+C took too long: {elapsed:.2f}s")
PY

    assert_contains "$TEST_TMP/lock.out" 'Another Amavis OpenSSL autofix process is already running.'
    assert_contains "$TEST_TMP/interrupt.out" 'Interrupted by INT'
}

chmod +x "$FAKE_BIN"/*
prepare_instrumented_script
test_static_and_cli
test_check_only_requires_repair
test_successful_repair
test_already_patched_skips_restart
test_healthy_baseline_exits_zero
test_unrelated_amavis_down_exits_three
test_workaround_failure_does_not_patch
test_refuses_wrong_error_signature
test_refuses_ambiguous_zmsetvars
test_flush_queue_flag
test_interrupt_and_lock

printf 'All Amavis OpenSSL autofix tests passed.\n'
