#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJECT_DIR/zimbra_dkim_migrate.sh"
FAKE_BIN="$PROJECT_DIR/tests/dkim_fakes"
TEST_TMP="$(mktemp -d)"
TEST_USER="$(id -un)"
TEST_GROUP="$(id -gn)"
INSTRUMENTED_SCRIPT="$TEST_TMP/zimbra_dkim_migrate.test.sh"
STORE="$TEST_TMP/dkim-store"
LIVE="$TEST_TMP/dkim-live"
REMOTE_HOME="$TEST_TMP/remote-zimbra"
LOCAL_HOME="$TEST_TMP/local-zimbra"

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

write_query() {
    local domain="$1" dest="$2" key p_value
    key="$TEST_TMP/${domain}.key"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key" \
        >/dev/null 2>&1
    p_value="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | base64 | tr -d '\r\n')"
    cat > "$dest" <<EOF
DKIM Domain: ${domain}
DKIM Selector: mail
DKIM Private Key:
$(cat "$key")
DKIM Public Signature:
v=DKIM1; k=rsa; p=${p_value}
DKIM Identity: ${domain}
EOF
}

prepare_homes() {
    local command_name
    mkdir -p \
        "$STORE" "$LIVE" \
        "$REMOTE_HOME/bin" "$REMOTE_HOME/libexec" \
        "$LOCAL_HOME/bin" "$LOCAL_HOME/libexec" \
        "$LOCAL_HOME/common/sbin" "$LOCAL_HOME/conf" \
        "$LOCAL_HOME/data/tmp"

    for command_name in zmhostname zmcontrol zmprov; do
        cp "$FAKE_BIN/zimbra-command" "$REMOTE_HOME/bin/$command_name"
        cp "$FAKE_BIN/zimbra-command" "$LOCAL_HOME/bin/$command_name"
        chmod +x "$REMOTE_HOME/bin/$command_name" "$LOCAL_HOME/bin/$command_name"
    done
    cp "$FAKE_BIN/zimbra-command" "$REMOTE_HOME/libexec/zmdkimkeyutil"
    cp "$FAKE_BIN/zimbra-command" "$LOCAL_HOME/libexec/zmdkimkeyutil"
    cp "$FAKE_BIN/zimbra-command" "$LOCAL_HOME/common/sbin/opendkim-testkey"
    chmod +x \
        "$REMOTE_HOME/libexec/zmdkimkeyutil" \
        "$LOCAL_HOME/libexec/zmdkimkeyutil" \
        "$LOCAL_HOME/common/sbin/opendkim-testkey"
    : > "$LOCAL_HOME/conf/opendkim.conf"
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

run_dkim() {
    local output="$1"
    shift
    env \
        PATH="$FAKE_BIN:$PATH" \
        ZIMBRA_HOME="$LOCAL_HOME" \
        REMOTE_ZIMBRA_HOME="$REMOTE_HOME" \
        ZIMBRA_USER="$TEST_USER" \
        ZIMBRA_GROUP="$TEST_GROUP" \
        RUN_ROOT="$TEST_TMP/runs" \
        LOCK_FILE="$TEST_TMP/runs/dkim.lock" \
        DKIM_IMPORT_HELPER="$FAKE_BIN/import-helper" \
        FAKE_DKIM_STORE="$STORE" \
        FAKE_LIVE_DKIM="$LIVE" \
        FAKE_SOURCE_DOMAINS="example.com" \
        FAKE_TARGET_HOSTNAME="destination.example.test" \
        "$INSTRUMENTED_SCRIPT" --old source.example.test --skip-dns "$@" > "$output" 2>&1
}

test_static_and_cli() {
    local output="$TEST_TMP/help.out" rc
    bash -n "$SCRIPT"
    shellcheck -x -S warning "$SCRIPT" "$PROJECT_DIR/tests/test_dkim.sh" "$FAKE_BIN"/*
    grep -Fqx '# SPDX-License-Identifier: AGPL-3.0-only' "$SCRIPT"
    grep -Fq 'Cuma Kurt' "$SCRIPT"
    grep -Fq 'github.com/cumakurt/zimbra_full_migrate' "$SCRIPT"
    grep -Fq 'all operational responsibility belongs to the operator' \
        "$PROJECT_DIR/README-DKIM.md"
    grep -Fq 'tüm operasyonel sorumluluk aracı kullanan kişiye/kuruma aittir' \
        "$PROJECT_DIR/README-DKIM.tr.md"

    "$SCRIPT" --help > "$output"
    assert_contains "$output" 'The script never restarts Zimbra services.'
    assert_contains "$output" '--verbose'
    assert_contains "$output" 'id_ed25519_zimbra'

    set +o errexit
    "$SCRIPT" --old > "$output" 2>&1
    rc=$?
    set -o errexit
    [[ "$rc" -eq 2 ]] || fail "missing --old value returned $rc instead of 2"

    set +o errexit
    "$SCRIPT" --old 'bad@host' > "$output" 2>&1
    rc=$?
    set -o errexit
    [[ "$rc" -eq 2 ]] || fail "invalid host returned $rc instead of 2"
}

test_dry_run() {
    write_query example.com "$STORE/example.com.query"
    run_dkim "$TEST_TMP/dry.out" --dry-run || {
        sed -n '1,240p' "$TEST_TMP/dry.out" >&2
        fail 'dry-run failed'
    }
    assert_contains "$TEST_TMP/dry.out" 'dry-run only'
    assert_contains "$TEST_TMP/dry.out" '[3/5] Export and cryptographic validation'
    assert_contains "$TEST_TMP/dry.out" 'NO ZIMBRA SERVICE WAS RESTARTED.'
    [[ ! -f "$LIVE/example.com.query" ]] || fail 'dry-run imported DKIM'
}

test_successful_import() {
    write_query example.com "$STORE/example.com.query"
    rm -f "$LIVE/example.com.query"
    run_dkim "$TEST_TMP/import.out" || {
        sed -n '1,280p' "$TEST_TMP/import.out" >&2
        fail 'successful DKIM import failed'
    }
    [[ -f "$LIVE/example.com.query" ]] || fail 'import did not publish target DKIM'
    assert_contains "$TEST_TMP/import.out" 'DKIM migration complete'
    assert_contains "$TEST_TMP/import.out" 'final audit exact-match OK'
}

test_already_identical() {
    write_query example.com "$STORE/example.com.query"
    cp -- "$STORE/example.com.query" "$LIVE/example.com.query"
    run_dkim "$TEST_TMP/same.out" || {
        sed -n '1,240p' "$TEST_TMP/same.out" >&2
        fail 'already-identical run failed'
    }
    assert_contains "$TEST_TMP/same.out" 'already identical'
}

test_ssh_error_is_concise() {
    local rc
    write_query example.com "$STORE/example.com.query"
    set +o errexit
    FAKE_SSH_FAIL=1 run_dkim "$TEST_TMP/ssh.out" --dry-run
    rc=$?
    set -o errexit
    [[ "$rc" -eq 1 ]] || fail "failed SSH returned $rc instead of 1"
    assert_contains "$TEST_TMP/ssh.out" 'SSH authentication failed for zimbra@source.example.test'
    if grep -Fq 'Permission denied (publickey,password).' "$TEST_TMP/ssh.out"; then
        fail 'quiet SSH failure printed raw command noise on the console'
    fi
}

chmod +x "$FAKE_BIN"/*
prepare_homes
prepare_instrumented_script
test_static_and_cli
test_dry_run
test_successful_import
test_already_identical
test_ssh_error_is_concise

printf 'All DKIM migration tests passed.\n'
