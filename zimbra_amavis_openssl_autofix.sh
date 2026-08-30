#!/usr/bin/env bash
#
# zimbra_amavis_openssl_autofix.sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Cuma Kurt
# Author: Cuma Kurt <https://www.linkedin.com/in/cuma-kurt-34414917/>
# Source: https://github.com/cumakurt/zimbra_full_migrate
#
# Diagnose and, when the exact library-path mismatch is reproduced, repair
# Amavis startup failures where Net::SSLeay loads Zimbra libssl.so.3 together
# with the operating system's libcrypto.so.3 (OPENSSL_x.y.z not found).
# The persistent fix is scoped to zmamavisdctl. The script never runs
# zmcontrol restart.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---------------------------------------------------------------------------
# DEFAULTS
# ---------------------------------------------------------------------------

MODE="fix"
FLUSH_QUEUE=0
VERBOSE=0

ZIMBRA_HOME="${ZIMBRA_HOME:-/opt/zimbra}"
ZIMBRA_USER="${ZIMBRA_USER:-zimbra}"
RUN_ROOT="${RUN_ROOT:-/root/zimbra-amavis-openssl-autofix}"
LOG_ROOT="${LOG_ROOT:-/var/log}"
LOCK_FILE="${LOCK_FILE:-${RUN_ROOT}/.zimbra-amavis-openssl-autofix.lock}"
AMAVIS_RESTART_WAIT="${AMAVIS_RESTART_WAIT:-3}"

AMAVIS_CTL="${ZIMBRA_HOME}/bin/zmamavisdctl"
ZMCONTROL="${ZIMBRA_HOME}/bin/zmcontrol"
ZIMBRA_LIB="${ZIMBRA_HOME}/common/lib"
POSTQUEUE="${ZIMBRA_HOME}/common/sbin/postqueue"
ZMSHUTIL="${ZIMBRA_HOME}/bin/zmshutil"

PATCH_BEGIN="# ZIMBRA_AMAVIS_OPENSSL_FIX_BEGIN"
PATCH_END="# ZIMBRA_AMAVIS_OPENSSL_FIX_END"
PATCH_EXPORT=""

SCRIPT_NAME="$(basename "$0")"
START_TS="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE=""
LOG_READY=0
RUN_DIR=""
BACKUP_FILE=""
ACTIVE_PROCESS_GROUP=""
TOTAL_PHASES=4

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    S_OK='✓'
    S_WARN='!'
    S_ERROR='✗'
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    S_OK='+'
    S_WARN='!'
    S_ERROR='x'
fi

# ---------------------------------------------------------------------------
# OUTPUT AND CLI
# ---------------------------------------------------------------------------

write_log() {
    local level="$1" message="$2" timestamp
    timestamp="$(date '+%F %T')"
    if [[ "$LOG_READY" -eq 1 ]]; then
        if ! printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" >> "$LOG_FILE"; then
            printf '[WARN] Could not append to log: %s\n' "$LOG_FILE" >&2
        fi
    fi
}

console_line() {
    local color="$1" marker="$2" message="$3" fd="${4:-1}"
    printf '%b  %s %s%b\n' "$color" "$marker" "$message" "$C_RESET" >&"$fd"
}

log() {
    write_log INFO "$1"
    if [[ "$VERBOSE" -eq 1 ]]; then
        console_line "$C_DIM" '·' "$1"
    fi
}

ok() {
    write_log OK "$1"
    console_line "$C_GREEN" "$S_OK" "$1"
}

warn() {
    write_log WARN "$1"
    console_line "$C_YELLOW" "$S_WARN" "$1" 2
}

die() {
    write_log ERROR "$1"
    console_line "$C_RED" "$S_ERROR" "$1" 2
    exit "${2:-1}"
}

phase() {
    local current="$1" total="$2" message="$3"
    write_log PHASE "$message"
    printf '\n%b[%s/%s] %s%b\n' "$C_BOLD$C_BLUE" \
        "$current" "$total" "$message" "$C_RESET"
}

ui_banner() {
    local mode="$1" host="$2" log_file="$3"

    printf '\n%b%s%b\n' "$C_BOLD$C_BLUE" 'Zimbra Amavis OpenSSL Autofix' "$C_RESET"
    printf '%b%s%b\n' "$C_DIM" '────────────────────────────────────────────────────────────' "$C_RESET"
    printf '  %-9s %s\n' 'Mode' "$mode"
    printf '  %-9s %s\n' 'Host' "$host"
    printf '  %-9s %s\n' 'Log' "$log_file"
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Options:
  --check-only, --verify-only   Diagnose only; do not modify files or restart
  --fix                         Diagnose and repair when confirmed (default)
  --flush-queue                 After a successful repair, flush the Postfix queue
  --verbose                     Show detailed command progress on the console
  -h, --help                    Show this help

What it repairs:
  Net::SSLeay / Amavis startup failures caused by Zimbra's libssl.so.3 being
  paired with the operating system's libcrypto.so.3 because
  ${ZIMBRA_HOME}/common/lib is not first in LD_LIBRARY_PATH.

Safety properties:
  * Does not patch unless the exact library-path failure is reproduced.
  * Creates a timestamped backup of zmamavisdctl before modification.
  * Is idempotent; it will not add the patch twice.
  * Validates bash syntax after modification and restores the backup on failure.
  * Restarts only Amavis (zmamavisdctl), and only when a repair is applied or
    Amavis is down after a confirmed diagnosis. It never runs zmcontrol restart.

Exit codes:
  0   Healthy, already repaired, or repair succeeded
  2   Invalid command-line arguments
  3   Amavis is down, but the OpenSSL library-path issue was not reproduced
  10  Check-only: repair is required
  1   Failure
EOF
}

usage_error() {
    printf '[ERROR] %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only|--verify-only)
            MODE="check"
            shift
            ;;
        --fix)
            MODE="fix"
            shift
            ;;
        --flush-queue)
            FLUSH_QUEUE=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage_error "Unknown argument: $1"
            ;;
    esac
done

[[ "$ZIMBRA_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || \
    usage_error "Invalid Zimbra operating-system user: $ZIMBRA_USER"
[[ "$AMAVIS_RESTART_WAIT" =~ ^[0-9]+$ ]] || \
    usage_error "AMAVIS_RESTART_WAIT must be a non-negative integer."

for configured_path in "$ZIMBRA_HOME" "$ZIMBRA_LIB" "$RUN_ROOT" "$LOG_ROOT" "$LOCK_FILE"; do
    [[ "$configured_path" == /* && "$configured_path" != "/" ]] || \
        usage_error "Internal filesystem paths must be absolute and must not be /: $configured_path"
done

[[ "$ZIMBRA_LIB" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
    usage_error "Unsafe Zimbra library path: $ZIMBRA_LIB"

PATCH_EXPORT="export LD_LIBRARY_PATH=${ZIMBRA_LIB}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

# ---------------------------------------------------------------------------
# PROCESS CONTROL AND CLEANUP
# ---------------------------------------------------------------------------

wait_for_active_group() {
    local rc
    if wait "$ACTIVE_PROCESS_GROUP"; then
        rc=0
    else
        rc=$?
    fi
    ACTIVE_PROCESS_GROUP=""
    return "$rc"
}

run_in_group_combined() {
    local output_file="$1"
    shift
    setsid "$@" > "$output_file" 2>&1 &
    ACTIVE_PROCESS_GROUP=$!
    wait_for_active_group
}

terminate_active_group() {
    local i
    [[ -n "$ACTIVE_PROCESS_GROUP" ]] || return 0

    if kill -0 -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null; then
        kill -TERM -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null || true
        for ((i = 0; i < 10; i++)); do
            kill -0 -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null; then
            kill -KILL -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null || true
        fi
    fi
    wait "$ACTIVE_PROCESS_GROUP" 2>/dev/null || true
    ACTIVE_PROCESS_GROUP=""
}

append_capture_to_log() {
    local output_file="$1"
    [[ "$LOG_READY" -eq 1 && -s "$output_file" ]] || return 0
    cat "$output_file" >> "$LOG_FILE" || true
}

show_capture_if_verbose() {
    local output_file="$1"
    [[ "$VERBOSE" -eq 1 && -s "$output_file" ]] || return 0
    sed 's/^/    /' "$output_file"
}

# Run as the Zimbra user without inheriting the caller's LD_LIBRARY_PATH.
# A login shell is intentionally not used: the test must reproduce service
# start, not a pre-existing interactive workaround.
run_zimbra_clean() {
    local output_file="$1"
    shift
    run_in_group_combined "$output_file" \
        runuser -u "$ZIMBRA_USER" -- env -u LD_LIBRARY_PATH "$@"
}

run_zimbra_shell() {
    local output_file="$1" cmd="$2" quoted_home
    printf -v quoted_home '%q' "$ZIMBRA_HOME"
    run_zimbra_clean "$output_file" \
        bash --noprofile --norc -c \
        "source ${quoted_home}/bin/zmshutil >/dev/null 2>&1 || exit 90; zmsetvars >/dev/null 2>&1 || exit 91; ${cmd}"
}

cleanup() {
    local rc=$?
    trap - EXIT ERR INT TERM
    set +e
    trap '' INT TERM

    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
        case "$RUN_DIR" in
            "$RUN_ROOT"/run-*)
                rm -rf -- "$RUN_DIR" || true
                ;;
            *)
                warn "Refusing to remove unexpected run directory: $RUN_DIR"
                ;;
        esac
    fi

    exit "$rc"
}
trap cleanup EXIT

on_error() {
    local rc=$? line="${BASH_LINENO[0]:-unknown}"
    trap - ERR
    warn "Unexpected failure at line $line (exit $rc)."
    [[ -n "$LOG_FILE" ]] && warn "Review log: $LOG_FILE"
    exit "$rc"
}
trap on_error ERR

handle_signal() {
    local signal_name="$1" exit_code=130
    [[ "$signal_name" == "TERM" ]] && exit_code=143

    trap - INT TERM
    warn "Interrupted by $signal_name; stopping active work immediately."
    terminate_active_group
    exit "$exit_code"
}
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

# ---------------------------------------------------------------------------
# PREFLIGHT, LOCK, AND LOG
# ---------------------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run this script as root on the destination Zimbra server."
[[ -d "$ZIMBRA_HOME" && ! -L "$ZIMBRA_HOME" ]] || \
    die "Zimbra installation is missing or is a symlink: $ZIMBRA_HOME"
id "$ZIMBRA_USER" >/dev/null 2>&1 || \
    die "Zimbra operating-system user not found: $ZIMBRA_USER"

for command in awk grep sed bash runuser id flock setsid sleep mktemp \
    chown chmod rm cp mkdir dirname hostname date tail cat; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done
command -v perl >/dev/null 2>&1 || die "Required command not found: perl"

[[ -f "$AMAVIS_CTL" && -x "$AMAVIS_CTL" && ! -L "$AMAVIS_CTL" ]] || \
    die "zmamavisdctl is missing, not executable, or is a symlink: $AMAVIS_CTL"
[[ -x "$ZMCONTROL" ]] || die "zmcontrol not found: $ZMCONTROL"
[[ -f "$ZMSHUTIL" && -r "$ZMSHUTIL" ]] || die "zmshutil not found: $ZMSHUTIL"
[[ -e "$ZIMBRA_LIB/libssl.so.3" ]] || die "Required library not found: $ZIMBRA_LIB/libssl.so.3"
[[ -e "$ZIMBRA_LIB/libcrypto.so.3" ]] || die "Required library not found: $ZIMBRA_LIB/libcrypto.so.3"

if [[ "$MODE" == "fix" && ! -w "$AMAVIS_CTL" ]]; then
    die "zmamavisdctl is not writable: $AMAVIS_CTL"
fi

for directory in "$RUN_ROOT" "$LOG_ROOT" "$(dirname "$LOCK_FILE")"; do
    [[ ! -L "$directory" ]] || die "Security-sensitive directory must not be a symlink: $directory"
    mkdir -p -- "$directory"
    [[ -d "$directory" ]] || die "Could not create directory: $directory"
done
chmod 700 "$RUN_ROOT"

[[ ! -L "$LOCK_FILE" ]] || die "Lock file must not be a symlink: $LOCK_FILE"
exec 9>> "$LOCK_FILE"
chmod 600 "$LOCK_FILE"
flock -n 9 || die "Another Amavis OpenSSL autofix process is already running."

LOG_FILE="$(mktemp "$LOG_ROOT/zimbra-amavis-openssl-autofix-${START_TS}.XXXXXX.log")"
chmod 600 "$LOG_FILE"
LOG_READY=1

RUN_DIR="$(mktemp -d "$RUN_ROOT/run-${START_TS}.XXXXXX")"
chmod 700 "$RUN_DIR"

# ---------------------------------------------------------------------------
# DIAGNOSIS AND REPAIR
# ---------------------------------------------------------------------------

amavis_is_running() {
    local output="$RUN_DIR/amavis-status.out"
    run_zimbra_clean "$output" "$AMAVIS_CTL" status || true
    append_capture_to_log "$output"
    grep -q 'amavisd is running' "$output"
}

amavis_listeners_ok() {
    local listeners
    if ! command -v ss >/dev/null 2>&1; then
        warn "ss command not found; listener verification skipped."
        return 0
    fi

    listeners="$(ss -lnt 2>/dev/null | awk '$4 ~ /:(10024|10026|10032)$/ {print $4}' | sort -u || true)"
    write_log INFO "Amavis listeners: ${listeners:-none}"
    printf '%s\n' "$listeners" | grep -q ':10024$' || return 1
    printf '%s\n' "$listeners" | grep -q ':10026$' || return 1
    return 0
}

show_service_status() {
    local output="$RUN_DIR/zmcontrol-status.out"
    log "Collecting Zimbra service status."
    run_zimbra_clean "$output" "$ZMCONTROL" status || true
    append_capture_to_log "$output"
    show_capture_if_verbose "$output"
}

baseline_ssl_test() {
    local output="$1"
    run_zimbra_shell "$output" \
        "unset LD_LIBRARY_PATH; perl -MNet::SSLeay -e 'print qq(Net::SSLeay OK\\n)'"
}

zimbra_lib_ssl_test() {
    local output="$1" quoted_lib
    printf -v quoted_lib '%q' "$ZIMBRA_LIB"
    run_zimbra_shell "$output" \
        "export LD_LIBRARY_PATH=${quoted_lib}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}; perl -MNet::SSLeay -e 'print qq(Net::SSLeay OK\\n)'"
}

is_openssl_path_signature() {
    local text="$1"
    grep -Eqi \
        "OPENSSL_[0-9]+\.[0-9]+\.[0-9]+.*not found|libcrypto\.so\.3|libssl\.so\.3|Net::SSLeay|SSLeay\.so" \
        <<< "$text"
}

patch_present() {
    grep -Fq "$PATCH_BEGIN" "$AMAVIS_CTL" || \
        grep -Fq "export LD_LIBRARY_PATH=${ZIMBRA_LIB}" "$AMAVIS_CTL" || \
        grep -Fq 'export LD_LIBRARY_PATH=/opt/zimbra/common/lib' "$AMAVIS_CTL"
}

make_backup() {
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_FILE="${AMAVIS_CTL}.backup-${ts}"
    [[ ! -e "$BACKUP_FILE" ]] || die "Backup path already exists: $BACKUP_FILE"
    cp -a -- "$AMAVIS_CTL" "$BACKUP_FILE"
    ok "Backup created: $BACKUP_FILE"
}

apply_patch() {
    local line_count insert_tmp

    if patch_present; then
        ok "Persistent LD_LIBRARY_PATH patch already exists in $AMAVIS_CTL"
        return 0
    fi

    line_count="$(grep -Ec '^[[:space:]]*zmsetvars[[:space:]]*$' "$AMAVIS_CTL" || true)"
    [[ "$line_count" == "1" ]] || \
        die "Expected exactly one standalone 'zmsetvars' line in $AMAVIS_CTL, found: $line_count. No modification made."

    make_backup
    insert_tmp="$(mktemp "$RUN_DIR/zmamavisdctl.XXXXXX")"
    if ! awk -v begin="$PATCH_BEGIN" -v export_line="$PATCH_EXPORT" -v end="$PATCH_END" '
        { print }
        $0 ~ /^[[:space:]]*zmsetvars[[:space:]]*$/ {
            print begin
            print export_line
            print end
        }
    ' "$BACKUP_FILE" > "$insert_tmp"; then
        rm -f -- "$insert_tmp"
        die "Could not prepare the patched zmamavisdctl content."
    fi

    chown --reference="$BACKUP_FILE" "$insert_tmp"
    chmod --reference="$BACKUP_FILE" "$insert_tmp"
    mv -f -- "$insert_tmp" "$AMAVIS_CTL"

    if ! bash -n "$AMAVIS_CTL"; then
        warn "Syntax validation failed. Restoring backup."
        cp -a -- "$BACKUP_FILE" "$AMAVIS_CTL"
        die "Patch rolled back because $AMAVIS_CTL failed bash syntax validation."
    fi

    grep -Fq "$PATCH_BEGIN" "$AMAVIS_CTL" || {
        cp -a -- "$BACKUP_FILE" "$AMAVIS_CTL"
        die "Patch marker missing after write; backup restored."
    }

    ok "Persistent library-path patch applied and syntax validated."
}

restart_and_verify() {
    local output="$RUN_DIR/amavis-restart.out" status_output="$RUN_DIR/zmcontrol-after.out"
    local svc status

    log "Restarting Amavis using a clean environment."
    run_zimbra_clean "$output" "$AMAVIS_CTL" restart || true
    append_capture_to_log "$output"
    show_capture_if_verbose "$output"

    if [[ "$AMAVIS_RESTART_WAIT" -gt 0 ]]; then
        sleep "$AMAVIS_RESTART_WAIT"
    fi

    if ! amavis_is_running; then
        warn "Amavis is still not running. Capturing a fresh start attempt for diagnostics."
        run_zimbra_clean "$output" "$AMAVIS_CTL" start || true
        append_capture_to_log "$output"
        show_capture_if_verbose "$output"
        die "Persistent patch was applied, but Amavis did not become healthy. There may be a second unrelated problem. Backup: ${BACKUP_FILE:-not-created}"
    fi
    ok "Amavis reports running."

    if ! amavis_listeners_ok; then
        die "Amavis is running but required listeners 10024 and 10026 are not active."
    fi
    if command -v ss >/dev/null 2>&1; then
        ok "Required Amavis listeners 10024 and 10026 are active."
    fi

    run_zimbra_clean "$status_output" "$ZMCONTROL" status || true
    append_capture_to_log "$status_output"
    show_capture_if_verbose "$status_output"
    status="$(cat "$status_output")"

    for svc in amavis antispam antivirus mta; do
        if ! awk -v s="$svc" '$1 == s && $2 == "Running" {found=1} END {exit !found}' <<< "$status"; then
            warn "Zimbra service '$svc' is not reported as Running."
        fi
    done
}

queue_report_and_optional_flush() {
    local output="$RUN_DIR/postqueue.out"
    [[ -x "$POSTQUEUE" ]] || return 0

    log "Collecting Postfix queue summary."
    run_zimbra_clean "$output" "$POSTQUEUE" -p || true
    append_capture_to_log "$output"
    if [[ "$VERBOSE" -eq 1 && -s "$output" ]]; then
        tail -n 5 "$output" | sed 's/^/    /'
    fi

    if (( FLUSH_QUEUE )); then
        log "Requesting immediate Postfix queue flush."
        if run_zimbra_clean "$output" "$POSTQUEUE" -f; then
            append_capture_to_log "$output"
            ok "Queue flush requested."
        else
            append_capture_to_log "$output"
            warn "Queue flush command returned an error."
        fi
    fi
}

already_healthy() {
    amavis_is_running || return 1
    amavis_listeners_ok || return 1
    return 0
}

# ---------------------------------------------------------------------------
# MAIN FLOW
# ---------------------------------------------------------------------------

TARGET_SYSTEM_HOST="$(hostname -f 2>/dev/null || hostname)"
if [[ "$MODE" == "check" ]]; then
    RUN_MODE="check only"
    TOTAL_PHASES=4
else
    RUN_MODE="fix"
    TOTAL_PHASES=6
fi

log "Zimbra Amavis OpenSSL autofix started."
log "Host: $TARGET_SYSTEM_HOST"
log "Zimbra home: $ZIMBRA_HOME"
log "Log: $LOG_FILE"
ui_banner "$RUN_MODE" "$TARGET_SYSTEM_HOST" "$LOG_FILE"

phase 1 "$TOTAL_PHASES" "Destination preflight"
ok "Prerequisite checks passed."

phase 2 "$TOTAL_PHASES" "Service snapshot"
show_service_status
if amavis_is_running; then
    ok "Amavis reports running."
else
    warn "Amavis is not running."
fi

phase 3 "$TOTAL_PHASES" "Reproduce the library-path failure"
log "Testing Net::SSLeay with LD_LIBRARY_PATH removed."
if baseline_ssl_test "$RUN_DIR/baseline-ssl.out"; then
    baseline_rc=0
else
    baseline_rc=$?
fi
append_capture_to_log "$RUN_DIR/baseline-ssl.out"
show_capture_if_verbose "$RUN_DIR/baseline-ssl.out"

if (( baseline_rc == 0 )); then
    ok "Net::SSLeay works without the workaround."
    if patch_present; then
        ok "A persistent patch is already present. No duplicate change is needed."
    fi
    if amavis_is_running; then
        ok "Amavis is already healthy. No repair required."
        queue_report_and_optional_flush
        exit 0
    fi
    warn "Amavis is stopped, but the OpenSSL/Net::SSLeay library-path issue cannot be reproduced."
    warn "This script will not modify Zimbra because the failure appears to have another cause."
    exit 3
fi

warn "Baseline Net::SSLeay test failed."
if [[ "$VERBOSE" -eq 1 ]]; then
    tail -n 12 "$RUN_DIR/baseline-ssl.out" | sed 's/^/    /' || true
fi

phase 4 "$TOTAL_PHASES" "Confirm the Zimbra library workaround"
log "Testing Net::SSLeay with $ZIMBRA_LIB first in LD_LIBRARY_PATH."
if zimbra_lib_ssl_test "$RUN_DIR/fixed-ssl.out"; then
    fixed_rc=0
else
    fixed_rc=$?
fi
append_capture_to_log "$RUN_DIR/fixed-ssl.out"
show_capture_if_verbose "$RUN_DIR/fixed-ssl.out"

if (( fixed_rc != 0 )); then
    warn "The workaround test also failed."
    if [[ "$VERBOSE" -eq 1 ]]; then
        tail -n 12 "$RUN_DIR/fixed-ssl.out" | sed 's/^/    /' || true
    fi
    die "This is not safely repairable by the LD_LIBRARY_PATH fix. No modification made."
fi

ok "Net::SSLeay succeeds when $ZIMBRA_LIB is prioritized."

if ! is_openssl_path_signature "$(cat "$RUN_DIR/baseline-ssl.out")"; then
    die "The behavior changes with LD_LIBRARY_PATH, but the expected OpenSSL/SSLeay error signature was not found. Refusing automatic modification."
fi

ok "Diagnosis confirmed: Zimbra OpenSSL library-path mismatch."

if [[ "$MODE" == "check" ]]; then
    warn "Check-only mode: repair is required but no files were modified."
    exit 10
fi

phase 5 "$TOTAL_PHASES" "Apply the zmamavisdctl library-path patch"
if patch_present && already_healthy; then
    ok "Persistent patch is present and Amavis is healthy. No restart."
    queue_report_and_optional_flush
    ok "No repair was required."
    [[ -n "$BACKUP_FILE" ]] && log "Backup retained at: $BACKUP_FILE"
    log "Log file: $LOG_FILE"
    exit 0
fi

apply_patch

phase 6 "$TOTAL_PHASES" "Restart Amavis and verify"
restart_and_verify
queue_report_and_optional_flush

warn "Plain interactive Perl may still need LD_LIBRARY_PATH manually; the persistent repair is intentionally scoped to Amavis startup."
ok "Repair completed successfully."
[[ -n "$BACKUP_FILE" ]] && log "Backup retained at: $BACKUP_FILE"
log "Log file: $LOG_FILE"
ok "NO FULL ZIMBRA STACK WAS RESTARTED (zmcontrol restart was not run)."
