#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJECT_DIR/zimbra_ssl_migrate.sh"
FAKE_BIN="$PROJECT_DIR/tests/ssl_fakes"
TEST_TMP="$(mktemp -d)"
TEST_USER="$(id -un)"
TEST_GROUP="$(id -gn)"
INSTRUMENTED_SCRIPT="$TEST_TMP/zimbra_ssl_migrate.test.sh"
SOURCE_CERT_DIR="$TEST_TMP/source-certs"
REMOTE_HOME="$TEST_TMP/remote-zimbra"

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
        sed -n '1,160p' "$file" >&2
        fail "expected $file to contain: $expected"
    }
}

certificate_fingerprint() {
    openssl x509 -in "$1" -outform DER | sha256sum | awk '{print $1}'
}

create_leaf() {
    local name="$1" key="$2" cert="$3" request
    request="$TEST_TMP/$name.csr"
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$key" -out "$request" -subj "/CN=destination.example.test" \
        >/dev/null 2>&1
    openssl x509 -req -in "$request" \
        -CA "$TEST_TMP/ca.crt" -CAkey "$TEST_TMP/ca.key" -CAcreateserial \
        -days 30 -sha256 -extfile "$TEST_TMP/leaf.ext" -out "$cert" \
        >/dev/null 2>&1
}

prepare_certificates() {
    mkdir -p "$SOURCE_CERT_DIR" "$REMOTE_HOME/bin"
    printf '%s\n' \
        'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature,keyEncipherment' \
        'extendedKeyUsage=serverAuth' \
        'subjectAltName=DNS:destination.example.test' \
        > "$TEST_TMP/leaf.ext"

    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -sha256 \
        -keyout "$TEST_TMP/ca.key" -out "$TEST_TMP/ca.crt" \
        -subj '/CN=SSL Migration Test CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        >/dev/null 2>&1

    create_leaf source "$SOURCE_CERT_DIR/commercial.key" "$TEST_TMP/source-leaf.crt"
    create_leaf old "$TEST_TMP/old.key" "$TEST_TMP/old-leaf.crt"
    cat "$TEST_TMP/source-leaf.crt" "$TEST_TMP/ca.crt" \
        > "$SOURCE_CERT_DIR/commercial.crt"
    cp "$TEST_TMP/ca.crt" "$SOURCE_CERT_DIR/commercial_ca.crt"

    for command_name in zmhostname zmcontrol; do
        cp "$FAKE_BIN/zimbra-command" "$REMOTE_HOME/bin/$command_name"
        chmod +x "$REMOTE_HOME/bin/$command_name"
    done
}

prepare_instrumented_script() {
    # The sed expression intentionally matches a literal $EUID.
    # shellcheck disable=SC2016
    sed 's/^\[\[ "$EUID" -eq 0 \]\] || die "Run this script as root on the NEW Zimbra server\."$/: # root check disabled for isolated tests/' \
        "$SCRIPT" > "$INSTRUMENTED_SCRIPT"
    chmod +x "$INSTRUMENTED_SCRIPT"
    grep -Fq '# root check disabled for isolated tests' "$INSTRUMENTED_SCRIPT" || \
        fail 'test instrumentation did not disable the root check'
}

prepare_fake_home() {
    local fake_home="$1" command_name
    mkdir -p \
        "$fake_home/bin" \
        "$fake_home/ssl/zimbra/commercial" \
        "$fake_home/conf/ca" \
        "$fake_home/tmp"

    for command_name in zmhostname zmcontrol zmcertmgr; do
        cp "$FAKE_BIN/zimbra-command" "$fake_home/bin/$command_name"
        chmod +x "$fake_home/bin/$command_name"
    done

    cp "$TEST_TMP/old.key" "$fake_home/ssl/zimbra/commercial/commercial.key"
    cp "$TEST_TMP/old-leaf.crt" "$fake_home/ssl/zimbra/commercial/commercial.crt"
    cat "$TEST_TMP/ca.crt" >> "$fake_home/ssl/zimbra/commercial/commercial.crt"
    cp "$TEST_TMP/ca.crt" "$fake_home/ssl/zimbra/commercial/commercial_ca.crt"
    cp "$TEST_TMP/old-leaf.crt" "$fake_home/conf/smtpd.crt"
    cp "$TEST_TMP/old.key" "$fake_home/conf/smtpd.key"
    printf 'original marker\n' > "$fake_home/conf/ca/original-marker"
}

run_ssl() {
    local fake_home="$1" run_root="$2" output="$3"
    shift 3
    env \
        PATH="$FAKE_BIN:$PATH" \
        ZIMBRA_HOME="$fake_home" \
        REMOTE_ZIMBRA_HOME="$REMOTE_HOME" \
        REMOTE_COMM_DIR="$SOURCE_CERT_DIR" \
        ZIMBRA_USER="$TEST_USER" \
        ZIMBRA_GROUP="$TEST_GROUP" \
        BACKUP_ROOT="$run_root/backups" \
        LOG_ROOT="$run_root/logs" \
        LOCK_FILE="$run_root/ssl.lock" \
        FAKE_SOURCE_CERT_DIR="$SOURCE_CERT_DIR" \
        FAKE_LOCAL_COMM_DIR="$fake_home/ssl/zimbra/commercial" \
        FAKE_ZIMBRA_HOME="$fake_home" \
        "$INSTRUMENTED_SCRIPT" --old source.example.test "$@" > "$output" 2>&1
}

test_static_and_cli() {
    local output="$TEST_TMP/help.out" rc
    bash -n "$SCRIPT"
    shellcheck -x -S warning "$SCRIPT" "$PROJECT_DIR/tests/test_ssl.sh" "$FAKE_BIN"/*
    grep -Fqx '# SPDX-License-Identifier: AGPL-3.0-only' "$SCRIPT"
    grep -Fq 'Cuma Kurt' "$SCRIPT"
    grep -Fq 'github.com/cumakurt/zimbra_full_migrate' "$SCRIPT"
    grep -Fq 'all operational responsibility belongs to the operator' \
        "$PROJECT_DIR/README-SSL.md"
    grep -Fq 'tüm operasyonel sorumluluk aracı kullanan kişiye/kuruma aittir' \
        "$PROJECT_DIR/README-SSL.tr.md"
    grep -Fq 'GNU AFFERO GENERAL PUBLIC LICENSE' "$PROJECT_DIR/LICENSE"

    "$SCRIPT" --help > "$output"
    assert_contains "$output" 'The script never restarts Zimbra services.'
    assert_contains "$output" '--verbose'

    set +o errexit
    "$SCRIPT" --old > "$output" 2>&1
    rc=$?
    set -o errexit
    [[ "$rc" -eq 2 ]] || fail "missing --old value returned $rc instead of 2"

    set +o errexit
    "$SCRIPT" --old bad@host > "$output" 2>&1
    rc=$?
    set -o errexit
    [[ "$rc" -eq 2 ]] || fail "invalid host returned $rc instead of 2"

    set +o errexit
    "$SCRIPT" --old source.example.test --port 65536 > "$output" 2>&1
    rc=$?
    set -o errexit
    [[ "$rc" -eq 2 ]] || fail "invalid port returned $rc instead of 2"
}

test_verify_only() {
    local fake_home="$TEST_TMP/verify-home" run_root="$TEST_TMP/verify-run"
    local before after
    prepare_fake_home "$fake_home"
    before="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"

    run_ssl "$fake_home" "$run_root" "$TEST_TMP/verify.out" --verify-only || {
        sed -n '1,240p' "$TEST_TMP/verify.out" >&2
        fail 'verify-only run failed'
    }

    after="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"
    [[ "$before" == "$after" ]] || fail 'verify-only changed the destination certificate'
    assert_contains "$TEST_TMP/verify.out" 'Verify-only mode completed'
    [[ -z "$(find "$run_root/backups" -type f -name '*.tar.gz' -print -quit)" ]] || \
        fail 'verify-only unexpectedly created a deployment backup'
    [[ -z "$(find "$fake_home/tmp" -mindepth 1 -print -quit)" ]] || \
        fail 'verify-only left a staging directory behind'
}

test_successful_deployment() {
    local fake_home="$TEST_TMP/success-home" run_root="$TEST_TMP/success-run"
    local expected actual backup log_file mode
    prepare_fake_home "$fake_home"
    expected="$(certificate_fingerprint "$TEST_TMP/source-leaf.crt")"

    run_ssl "$fake_home" "$run_root" "$TEST_TMP/success.out" || {
        sed -n '1,280p' "$TEST_TMP/success.out" >&2
        fail 'successful fake deployment failed'
    }

    actual="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"
    [[ "$actual" == "$expected" ]] || fail 'deployed certificate fingerprint is wrong'
    backup="$(find "$run_root/backups" -type f -name '*.tar.gz' -print -quit)"
    [[ -n "$backup" ]] || fail 'deployment backup was not created'
    tar -tzf "$backup" >/dev/null
    sha256sum -c "$backup.sha256" >/dev/null
    mode="$(stat -c '%a' "$fake_home/ssl/zimbra/commercial/commercial.key")"
    [[ "$mode" == "640" ]] || fail "commercial.key mode is $mode instead of 640"
    log_file="$(find "$run_root/logs" -type f -name '*.log' -print -quit)"
    [[ -n "$log_file" ]] || fail 'deployment log was not created'
    if LC_ALL=C grep -q $'\033' "$log_file"; then
        fail 'deployment log contains terminal escape sequences'
    fi
    assert_contains "$TEST_TMP/success.out" 'post-deployment verification succeeded'
    assert_contains "$TEST_TMP/success.out" 'SERVICES WERE NOT RESTARTED.'
    assert_contains "$TEST_TMP/success.out" '[1/7] Destination preflight'
    if grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} ' "$TEST_TMP/success.out"; then
        fail 'quiet console output contains timestamped detail lines'
    fi
    if grep -Fq 'Fake deployment complete.' "$TEST_TMP/success.out"; then
        fail 'quiet console output exposed raw zmcertmgr details'
    fi
}

test_legacy_zimbra_mode() {
    local fake_home="$TEST_TMP/legacy-home" run_root="$TEST_TMP/legacy-run" mode
    prepare_fake_home "$fake_home"

    FAKE_ZIMBRA_VERSION='Release 8.6.0.GA.fake' \
        run_ssl "$fake_home" "$run_root" "$TEST_TMP/legacy.out" || {
            sed -n '1,280p' "$TEST_TMP/legacy.out" >&2
            fail 'legacy Zimbra mode deployment failed'
        }

    mode="$(stat -c '%a' "$fake_home/ssl/zimbra/commercial/commercial.key")"
    [[ "$mode" == "740" ]] || fail "legacy commercial.key mode is $mode instead of 740"
    assert_contains "$TEST_TMP/legacy.out" 'Zimbra 8.6: certificate manager will run as root.'
}

test_ssh_error_is_concise() {
    local fake_home="$TEST_TMP/ssh-error-home" run_root="$TEST_TMP/ssh-error-run"
    local rc log_file
    prepare_fake_home "$fake_home"

    set +o errexit
    FAKE_SSH_FAIL=1 run_ssl "$fake_home" "$run_root" "$TEST_TMP/ssh-error.out" --verify-only
    rc=$?
    set -o errexit

    [[ "$rc" -eq 1 ]] || fail "failed SSH returned $rc instead of 1"
    assert_contains "$TEST_TMP/ssh-error.out" 'SSH authentication failed for zimbra@source.example.test'
    if grep -Fq 'Permission denied (publickey,password).' "$TEST_TMP/ssh-error.out"; then
        fail 'quiet SSH failure printed raw command noise on the console'
    fi
    log_file="$(find "$run_root/logs" -type f -name '*.log' -print -quit)"
    [[ -n "$log_file" ]] || fail 'SSH failure did not create a log'
    assert_contains "$log_file" 'Permission denied (publickey,password).'
}

test_failed_deployment_rolls_back() {
    local fake_home="$TEST_TMP/failure-home" run_root="$TEST_TMP/failure-run"
    local before after rc fail_marker="$TEST_TMP/deploy-failed-once"
    prepare_fake_home "$fake_home"
    before="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"

    set +o errexit
    FAKE_DEPLOY_FAIL_ONCE_MARKER="$fail_marker" \
        run_ssl "$fake_home" "$run_root" "$TEST_TMP/failure.out"
    rc=$?
    set -o errexit

    [[ "$rc" -eq 1 ]] || {
        sed -n '1,300p' "$TEST_TMP/failure.out" >&2
        fail "failed deployment returned $rc instead of 1"
    }
    after="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"
    [[ "$before" == "$after" ]] || fail 'failed deployment did not restore the old certificate'
    [[ ! -e "$fake_home/conf/ca/ca.pem" ]] || fail 'rollback kept a newly created CA file'
    [[ -f "$fake_home/conf/ca/original-marker" ]] || fail 'rollback lost an original CA file'
    assert_contains "$TEST_TMP/failure.out" 'Pre-deployment files and Zimbra certificate configuration were restored.'
}

test_interrupt_and_lock() {
    local fake_home="$TEST_TMP/interrupt-home" run_root="$TEST_TMP/interrupt-run"
    local marker="$TEST_TMP/scp-sleeping" before after
    prepare_fake_home "$fake_home"
    before="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"

    env \
        PATH="$FAKE_BIN:$PATH" \
        ZIMBRA_HOME="$fake_home" \
        REMOTE_ZIMBRA_HOME="$REMOTE_HOME" \
        REMOTE_COMM_DIR="$SOURCE_CERT_DIR" \
        ZIMBRA_USER="$TEST_USER" \
        ZIMBRA_GROUP="$TEST_GROUP" \
        BACKUP_ROOT="$run_root/backups" \
        LOG_ROOT="$run_root/logs" \
        LOCK_FILE="$run_root/ssl.lock" \
        FAKE_SOURCE_CERT_DIR="$SOURCE_CERT_DIR" \
        FAKE_LOCAL_COMM_DIR="$fake_home/ssl/zimbra/commercial" \
        FAKE_ZIMBRA_HOME="$fake_home" \
        FAKE_SCP_SLEEP_MARKER="$marker" \
        python3 - "$INSTRUMENTED_SCRIPT" "$marker" "$TEST_TMP/interrupt.out" <<'PY'
import os
import signal
import subprocess
import sys
import time

script, marker, output_path = sys.argv[1:]
environment = os.environ.copy()

with open(output_path, "wb") as output:
    process = subprocess.Popen(
        [script, "--old", "source.example.test"],
        env=environment,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    deadline = time.monotonic() + 8
    while not os.path.exists(marker):
        if process.poll() is not None:
            raise SystemExit(f"migration exited before interrupt point: {process.returncode}")
        if time.monotonic() >= deadline:
            process.kill()
            raise SystemExit("timed out waiting for fake scp")
        time.sleep(0.02)

    second = subprocess.run(
        [script, "--old", "source.example.test"],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=3,
        check=False,
    )
    if second.returncode != 1 or b"already running" not in second.stdout:
        process.kill()
        raise SystemExit("concurrent invocation was not rejected by the lock")

    started = time.monotonic()
    os.kill(process.pid, signal.SIGINT)
    return_code = process.wait(timeout=3)
    elapsed = time.monotonic() - started

if return_code != 130:
    raise SystemExit(f"Ctrl+C returned {return_code} instead of 130")
if elapsed >= 2:
    raise SystemExit(f"Ctrl+C took too long: {elapsed:.2f}s")
PY

    after="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"
    [[ "$before" == "$after" ]] || fail 'pre-deployment interrupt changed the destination certificate'
    [[ -z "$(find "$fake_home/tmp" -mindepth 1 -print -quit)" ]] || \
        fail 'interrupt left a staging directory behind'
    assert_contains "$TEST_TMP/interrupt.out" 'Interrupted by INT'
}

test_deploy_interrupt_rolls_back() {
    local fake_home="$TEST_TMP/deploy-interrupt-home" run_root="$TEST_TMP/deploy-interrupt-run"
    local marker="$TEST_TMP/deploy-sleeping" before after
    prepare_fake_home "$fake_home"
    before="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"

    env \
        PATH="$FAKE_BIN:$PATH" \
        ZIMBRA_HOME="$fake_home" \
        REMOTE_ZIMBRA_HOME="$REMOTE_HOME" \
        REMOTE_COMM_DIR="$SOURCE_CERT_DIR" \
        ZIMBRA_USER="$TEST_USER" \
        ZIMBRA_GROUP="$TEST_GROUP" \
        BACKUP_ROOT="$run_root/backups" \
        LOG_ROOT="$run_root/logs" \
        LOCK_FILE="$run_root/ssl.lock" \
        FAKE_SOURCE_CERT_DIR="$SOURCE_CERT_DIR" \
        FAKE_LOCAL_COMM_DIR="$fake_home/ssl/zimbra/commercial" \
        FAKE_ZIMBRA_HOME="$fake_home" \
        FAKE_DEPLOY_SLEEP_ONCE_MARKER="$marker" \
        python3 - "$INSTRUMENTED_SCRIPT" "$marker" "$TEST_TMP/deploy-interrupt.out" <<'PY'
import os
import signal
import subprocess
import sys
import time

script, marker, output_path = sys.argv[1:]
with open(output_path, "wb") as output:
    process = subprocess.Popen(
        [script, "--old", "source.example.test"],
        env=os.environ.copy(),
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    deadline = time.monotonic() + 10
    while not os.path.exists(marker):
        if process.poll() is not None:
            raise SystemExit(f"migration exited before deploy interrupt: {process.returncode}")
        if time.monotonic() >= deadline:
            process.kill()
            raise SystemExit("timed out waiting for fake deployment")
        time.sleep(0.02)

    started = time.monotonic()
    os.kill(process.pid, signal.SIGINT)
    return_code = process.wait(timeout=5)
    elapsed = time.monotonic() - started

if return_code != 130:
    raise SystemExit(f"deploy Ctrl+C returned {return_code} instead of 130")
if elapsed >= 4:
    raise SystemExit(f"deploy Ctrl+C plus rollback took too long: {elapsed:.2f}s")
PY

    after="$(certificate_fingerprint "$fake_home/ssl/zimbra/commercial/commercial.crt")"
    [[ "$before" == "$after" ]] || fail 'deployment interrupt did not restore the old certificate'
    [[ ! -e "$fake_home/conf/ca/ca.pem" ]] || fail 'deployment interrupt kept a new CA file'
    assert_contains "$TEST_TMP/deploy-interrupt.out" 'Pre-deployment files and Zimbra certificate configuration were restored.'
}

test_world_readable_source_key_is_accepted() {
    local fake_home="$TEST_TMP/perms-home" run_root="$TEST_TMP/perms-run" mode
    prepare_fake_home "$fake_home"
    chmod 0644 "$SOURCE_CERT_DIR/commercial.key"

    run_ssl "$fake_home" "$run_root" "$TEST_TMP/perms.out" || {
        chmod 0600 "$SOURCE_CERT_DIR/commercial.key"
        sed -n '1,280p' "$TEST_TMP/perms.out" >&2
        fail 'world-readable source key deployment failed'
    }
    chmod 0600 "$SOURCE_CERT_DIR/commercial.key"

    mode="$(stat -c '%a' "$fake_home/ssl/zimbra/commercial/commercial.key")"
    [[ "$mode" == "640" ]] || fail "destination commercial.key mode is $mode instead of 640"
    assert_contains "$TEST_TMP/perms.out" 'Source commercial.key is accessible to other users'
    assert_contains "$TEST_TMP/perms.out" 'destination will still use mode 0640'
}

prepare_certificates
prepare_instrumented_script
test_static_and_cli
test_verify_only
test_successful_deployment
test_legacy_zimbra_mode
test_ssh_error_is_concise
test_failed_deployment_rolls_back
test_interrupt_and_lock
test_deploy_interrupt_rolls_back
test_world_readable_source_key_is_accepted

printf 'All SSL migration tests passed.\n'
