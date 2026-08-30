#!/usr/bin/env bash
#
# zimbra_ssl_migrate.sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Cuma Kurt
# Author: Cuma Kurt <https://www.linkedin.com/in/cuma-kurt-34414917/>
# Source: https://github.com/cumakurt/zimbra_full_migrate
#
# Securely copy a deployed commercial/Let's Encrypt certificate, private key,
# and CA chain from an old Zimbra host; validate them; back up the destination;
# deploy them with zmcertmgr; verify the result; and stop without restarting
# Zimbra services.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---------------------------------------------------------------------------
# DEFAULTS
# ---------------------------------------------------------------------------

OLD_HOST=""
OLD_USER="zimbra"
SSH_PORT="22"
SSH_IDENTITY=""
VERIFY_ONLY=0
ALLOW_HOSTNAME_MISMATCH=0
ACCEPT_NEW_HOST_KEY=0
KEEP_STAGE=0
VERBOSE=0
MIN_WARN_DAYS=14

# The path overrides are primarily useful for isolated validation. A normal
# Zimbra installation should use the defaults.
ZIMBRA_HOME="${ZIMBRA_HOME:-/opt/zimbra}"
REMOTE_ZIMBRA_HOME="${REMOTE_ZIMBRA_HOME:-/opt/zimbra}"
ZIMBRA_USER="${ZIMBRA_USER:-zimbra}"
ZIMBRA_GROUP="${ZIMBRA_GROUP:-zimbra}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/zimbra-ssl-migration-backups}"
LOG_ROOT="${LOG_ROOT:-/var/log}"
LOCK_FILE="${LOCK_FILE:-${BACKUP_ROOT}/.zimbra-ssl-migrate.lock}"

REMOTE_COMM_DIR="${REMOTE_COMM_DIR:-${REMOTE_ZIMBRA_HOME}/ssl/zimbra/commercial}"
LOCAL_COMM_DIR="${ZIMBRA_HOME}/ssl/zimbra/commercial"
ZMCERTMGR="${ZIMBRA_HOME}/bin/zmcertmgr"
ZMHOSTNAME="${ZIMBRA_HOME}/bin/zmhostname"
ZMCONTROL="${ZIMBRA_HOME}/bin/zmcontrol"
REMOTE_ZMHOSTNAME="${REMOTE_ZIMBRA_HOME}/bin/zmhostname"
REMOTE_ZMCONTROL="${REMOTE_ZIMBRA_HOME}/bin/zmcontrol"

SCRIPT_NAME="$(basename "$0")"
START_TS="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE=""
LOG_READY=0
STAGE_DIR=""
BACKUP_DIR=""
BACKUP_TAR=""
ROLLBACK_ABSENT_FILE=""
ROLLBACK_LEAF=""
ROLLBACK_CHAIN=""
ROLLBACK_NATIVE_READY=0
TRANSACTION_ACTIVE=0
ACTIVE_PROCESS_GROUP=""

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
    local mode="$1" source="$2" target="$3" log_file="$4"

    printf '\n%b%s%b\n' "$C_BOLD$C_BLUE" 'Zimbra SSL Migration' "$C_RESET"
    printf '%b%s%b\n' "$C_DIM" '────────────────────────────────────────────────────────────' "$C_RESET"
    printf '  %-9s %s\n' 'Mode' "$mode"
    printf '  %-9s %s\n' 'Source' "$source"
    printf '  %-9s %s\n' 'Target' "$target"
    printf '  %-9s %s\n' 'Log' "$log_file"
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME --old <old-zimbra-host-or-ip> [options]

Options:
  --old HOST                    Old Zimbra server IP/FQDN (required)
  --user USER                   SSH user on old server (default: zimbra)
  --port PORT                   SSH port (default: 22)
  --identity FILE               SSH private key path
  --verify-only                 Fetch and validate; do not change the target
  --allow-hostname-mismatch     Allow mismatch with destination zmhostname
  --accept-new-host-key         Trust a previously unseen SSH host key once
  --keep-stage                  Keep staged secret files after success
  --verbose                     Show detailed command progress on the console
  -h, --help                    Show this help

By default, the source SSH host key must already exist in root's known_hosts.
The script never restarts Zimbra services.
EOF
}

usage_error() {
    printf '[ERROR] %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

require_option_value() {
    local option="$1" remaining="$2" value="${3:-}"
    [[ "$remaining" -ge 2 && -n "$value" && "$value" != --* ]] || \
        usage_error "$option requires a value."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --old)
            require_option_value "$1" "$#" "${2:-}"
            OLD_HOST="$2"
            shift 2
            ;;
        --user)
            require_option_value "$1" "$#" "${2:-}"
            OLD_USER="$2"
            shift 2
            ;;
        --port)
            require_option_value "$1" "$#" "${2:-}"
            SSH_PORT="$2"
            shift 2
            ;;
        --identity)
            require_option_value "$1" "$#" "${2:-}"
            SSH_IDENTITY="$2"
            shift 2
            ;;
        --verify-only)
            VERIFY_ONLY=1
            shift
            ;;
        --allow-hostname-mismatch)
            ALLOW_HOSTNAME_MISMATCH=1
            shift
            ;;
        --accept-new-host-key)
            ACCEPT_NEW_HOST_KEY=1
            shift
            ;;
        --keep-stage)
            KEEP_STAGE=1
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

[[ -n "$OLD_HOST" ]] || usage_error "--old is required."
[[ "$OLD_HOST" =~ ^(\[[A-Za-z0-9_.:%-]+\]|[A-Za-z0-9][A-Za-z0-9_.:%-]*)$ ]] || \
    usage_error "Invalid source host/IP: $OLD_HOST"
[[ "$OLD_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || \
    usage_error "Invalid SSH user: $OLD_USER"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || usage_error "SSH port must be an integer."
SSH_PORT_NUMBER=$((10#$SSH_PORT))
((SSH_PORT_NUMBER >= 1 && SSH_PORT_NUMBER <= 65535)) || \
    usage_error "SSH port must be between 1 and 65535."

for configured_path in "$ZIMBRA_HOME" "$REMOTE_ZIMBRA_HOME" "$REMOTE_COMM_DIR" \
    "$BACKUP_ROOT" "$LOG_ROOT" "$LOCK_FILE"; do
    [[ "$configured_path" == /* && "$configured_path" != "/" ]] || \
        usage_error "Internal filesystem paths must be absolute and must not be /: $configured_path"
done

# ---------------------------------------------------------------------------
# PROCESS CONTROL, CLEANUP, AND ROLLBACK
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

run_in_group() {
    setsid "$@" &
    ACTIVE_PROCESS_GROUP=$!
    wait_for_active_group
}

run_in_group_logged() {
    setsid "$@" >> "$LOG_FILE" 2>&1 &
    ACTIVE_PROCESS_GROUP=$!
    wait_for_active_group
}

run_in_group_capture() {
    local output_file="$1"
    shift
    setsid "$@" > "$output_file" 2>> "$LOG_FILE" &
    ACTIVE_PROCESS_GROUP=$!
    wait_for_active_group
}

run_in_group_combined() {
    local output_file="$1"
    shift
    setsid "$@" > "$output_file" 2>&1 &
    ACTIVE_PROCESS_GROUP=$!
    wait_for_active_group
}

shell_join() {
    local result="" argument quoted
    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        result+="${result:+ }${quoted}"
    done
    printf '%s' "$result"
}

run_zimbra() {
    local command
    command="$(shell_join "$@")"
    run_in_group su - "$ZIMBRA_USER" -c "$command"
}

run_zimbra_capture() {
    local output_file="$1" command
    shift
    command="$(shell_join "$@")"
    run_in_group_capture "$output_file" su - "$ZIMBRA_USER" -c "$command"
}

CERTMGR_AS_ROOT=0
run_certmgr() {
    if [[ "$CERTMGR_AS_ROOT" -eq 1 ]]; then
        run_in_group "$ZMCERTMGR" "$@"
    else
        run_zimbra "$ZMCERTMGR" "$@"
    fi
}

run_certmgr_logged() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        run_certmgr "$@" > >(tee -a "$LOG_FILE") 2>&1
    elif [[ "$CERTMGR_AS_ROOT" -eq 1 ]]; then
        run_in_group_logged "$ZMCERTMGR" "$@"
    else
        local command
        command="$(shell_join "$ZMCERTMGR" "$@")"
        run_in_group_logged su - "$ZIMBRA_USER" -c "$command"
    fi
}

run_certmgr_combined() {
    local output_file="$1" command
    shift
    if [[ "$CERTMGR_AS_ROOT" -eq 1 ]]; then
        run_in_group_combined "$output_file" "$ZMCERTMGR" "$@"
    else
        command="$(shell_join "$ZMCERTMGR" "$@")"
        run_in_group_combined "$output_file" su - "$ZIMBRA_USER" -c "$command"
    fi
}

run_certmgr_or_die() {
    local fail_message="$1" output_file line
    shift
    output_file="${STAGE_DIR}/zmcertmgr-last.out"
    if run_certmgr_combined "$output_file" "$@"; then
        cat "$output_file" >> "$LOG_FILE"
        if [[ "$VERBOSE" -eq 1 ]]; then
            cat "$output_file"
        fi
        return 0
    fi
    cat "$output_file" >> "$LOG_FILE"
    if [[ -s "$output_file" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && warn "$line"
        done < <(tail -n 30 "$output_file")
    fi
    die "$fail_message"
}

pem_certificate_fingerprint() {
    openssl x509 -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

pem_certificate_field() {
    local file="$1" field="$2" value
    if value="$(openssl x509 -in "$file" -noout "-${field}" -nameopt RFC2253 2>/dev/null)"; then
        printf '%s\n' "${value#"${field}"=}"
        return 0
    fi
    value="$(openssl x509 -in "$file" -noout "-${field}" 2>/dev/null)" || return 1
    printf '%s\n' "${value#"${field}"=}"
}

split_pem_certificates() {
    local bundle="$1" dest_dir="$2"
    rm -rf -- "$dest_dir"
    mkdir -p -- "$dest_dir"
    [[ -s "$bundle" ]] || return 0
    awk -v dest="$dest_dir" '
        /-----BEGIN CERTIFICATE-----/ {
            n++
            f = sprintf("%s/%02d.pem", dest, n)
            capture = 1
        }
        capture { print > f }
        /-----END CERTIFICATE-----/ && capture {
            capture = 0
            close(f)
        }
    ' "$bundle"
}

chain_has_fingerprint() {
    local chain="$1" fingerprint="$2" part scan_dir
    [[ -s "$chain" ]] || return 1
    scan_dir="${STAGE_DIR}/.chain-scan.$$"
    split_pem_certificates "$chain" "$scan_dir"
    for part in "$scan_dir"/*.pem; do
        [[ -f "$part" ]] || continue
        if [[ "$(pem_certificate_fingerprint "$part")" == "$fingerprint" ]]; then
            rm -rf -- "$scan_dir"
            return 0
        fi
    done
    rm -rf -- "$scan_dir"
    return 1
}

append_unique_chain_certificate() {
    local chain="$1" cert="$2" fingerprint
    fingerprint="$(pem_certificate_fingerprint "$cert")"
    [[ -n "$fingerprint" ]] || return 1
    [[ "$fingerprint" != "$LEAF_FINGERPRINT" ]] || return 1
    if ! openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1; then
        log "Skipping expired certificate while building the CA chain."
        return 1
    fi
    chain_has_fingerprint "$chain" "$fingerprint" && return 1
    cat "$cert" >> "$chain"
    printf '\n' >> "$chain"
    return 0
}

append_certs_from_bundle() {
    local chain="$1" bundle="$2" part split_dir
    split_dir="${STAGE_DIR}/.bundle-split.$$"
    split_pem_certificates "$bundle" "$split_dir"
    for part in "$split_dir"/*.pem; do
        [[ -f "$part" ]] || continue
        append_unique_chain_certificate "$chain" "$part" || true
    done
    rm -rf -- "$split_dir"
}

find_issuer_certificate() {
    local wanted_subject="$1" bundle="$2" part split_dir subject
    split_dir="${STAGE_DIR}/.issuer-split.$$"
    split_pem_certificates "$bundle" "$split_dir"
    for part in "$split_dir"/*.pem; do
        [[ -f "$part" ]] || continue
        subject="$(pem_certificate_field "$part" subject)" || continue
        if [[ "$subject" == "$wanted_subject" ]] && \
                openssl x509 -in "$part" -checkend 0 -noout >/dev/null 2>&1; then
            cp -- "$part" "${STAGE_DIR}/.found-issuer.pem"
            rm -rf -- "$split_dir"
            return 0
        fi
    done
    rm -rf -- "$split_dir"
    return 1
}

local_trust_bundles() {
    local candidate
    for candidate in \
        /etc/ssl/certs/ca-certificates.crt \
        /etc/pki/tls/certs/ca-bundle.crt \
        "${ZIMBRA_HOME}/ssl/zimbra/ca/ca.pem" \
        "${ZIMBRA_HOME}/conf/ca/ca.pem" \
        "${LOCAL_COMM_DIR}/commercial_ca.crt"
    do
        [[ -f "$candidate" && -r "$candidate" ]] || continue
        printf '%s\n' "$candidate"
    done
}

verify_leaf_against_chain_file() {
    local extra=() help_text
    [[ -s "$CHAIN_CRT" ]] || return 1
    help_text="$(openssl verify -help 2>&1 || true)"
    [[ "$help_text" == *'-no-CAfile'* ]] && extra+=(-no-CAfile)
    [[ "$help_text" == *'-no-CApath'* ]] && extra+=(-no-CApath)
    openssl verify -purpose sslserver -CAfile "$CHAIN_CRT" "${extra[@]}" \
        "$LEAF_CRT" >> "$LOG_FILE" 2>&1
}

# zmcertmgr trusts only the provided CA file. OpenSSL 3 may also use the
# system store, so a source Let's Encrypt chain that omits the root (or still
# contains the expired DST Root CA X3) can pass openssl and fail zmcertmgr.
prepare_zmcertmgr_chain() {
    local tip issuer subject bundle added depth
    : > "$CHAIN_CRT"

    CRT_COUNT="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$RAW_CRT" || true)"
    SOURCE_CA_COUNT="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$RAW_CA" || true)"
    [[ "$CRT_COUNT" -ge 1 ]] || die "Source commercial.crt has no PEM certificate."
    [[ "$SOURCE_CA_COUNT" -ge 1 ]] || die "Source commercial_ca.crt has no PEM certificate."
    log "Source commercial.crt PEM count: $CRT_COUNT"
    log "Source commercial_ca.crt PEM count: $SOURCE_CA_COUNT"

    if [[ "$CRT_COUNT" -gt 1 ]]; then
        append_certs_from_bundle "$CHAIN_CRT" "$RAW_CRT"
    fi
    append_certs_from_bundle "$CHAIN_CRT" "$RAW_CA"

    for ((depth = 0; depth < 8; depth++)); do
        verify_leaf_against_chain_file && return 0
        if [[ -s "$CHAIN_CRT" ]]; then
            split_pem_certificates "$CHAIN_CRT" "${STAGE_DIR}/.chain-tip"
            tip="$(printf '%s\n' "${STAGE_DIR}/.chain-tip/"*.pem | tail -n1)"
        else
            tip="$LEAF_CRT"
        fi
        [[ -s "$tip" ]] || break
        issuer="$(pem_certificate_field "$tip" issuer)" || break
        subject="$(pem_certificate_field "$tip" subject)" || break
        [[ "$issuer" != "$subject" ]] || break
        added=0
        while IFS= read -r bundle; do
            if find_issuer_certificate "$issuer" "$bundle"; then
                if append_unique_chain_certificate "$CHAIN_CRT" "${STAGE_DIR}/.found-issuer.pem"; then
                    log "Appended a local trust anchor to complete the CA chain."
                    added=1
                    break
                fi
            fi
        done < <(local_trust_bundles)
        [[ "$added" -eq 1 ]] || break
    done

    verify_leaf_against_chain_file
}

ensure_zimbra_can_read_stage() {
    [[ "$CERTMGR_AS_ROOT" -eq 0 ]] || return 0
    if run_zimbra test -r "$STAGED_KEY" && \
            run_zimbra test -r "$LEAF_CRT" && \
            run_zimbra test -r "$CHAIN_CRT"; then
        return 0
    fi
    chmod a+x "$ZIMBRA_TMP" 2>/dev/null || true
    chown -R "$ZIMBRA_USER:$ZIMBRA_GROUP" "$STAGE_DIR"
    chmod 700 "$STAGE_DIR"
    chmod 600 "$STAGED_KEY" "$LEAF_CRT" "$CHAIN_CRT"
    run_zimbra test -r "$STAGED_KEY" && \
        run_zimbra test -r "$LEAF_CRT" && \
        run_zimbra test -r "$CHAIN_CRT" || \
        die "The zimbra user cannot read the staged certificate files under $STAGE_DIR."
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

restore_file_snapshot() {
    local path restore_ok=0

    if [[ -s "$BACKUP_TAR" ]] && run_in_group tar -xzpf "$BACKUP_TAR" -C /; then
        restore_ok=1
    else
        warn "Could not restore the target file snapshot from $BACKUP_TAR"
    fi

    if [[ "$restore_ok" -eq 1 && -s "$ROLLBACK_ABSENT_FILE" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            case "$path" in
                "$ZIMBRA_HOME"/*)
                    rm -rf -- "$path" || restore_ok=0
                    ;;
                *)
                    warn "Refusing to remove unsafe rollback path: $path"
                    restore_ok=0
                    ;;
            esac
        done < "$ROLLBACK_ABSENT_FILE"
    fi

    [[ "$restore_ok" -eq 1 ]]
}

rollback_target() {
    local snapshot_ok=0 native_ok=0

    warn "The deployment did not complete; restoring the pre-deployment target state."

    if restore_file_snapshot; then
        snapshot_ok=1
    fi

    # A native re-deploy of the previous certificate also restores the Zimbra
    # LDAP certificate attributes. The exact file snapshot is restored once
    # more afterward so permissions/content match the pre-run state.
    if [[ "$snapshot_ok" -eq 1 && "$ROLLBACK_NATIVE_READY" -eq 1 ]]; then
        if run_certmgr_logged deploycrt comm "$ROLLBACK_LEAF" "$ROLLBACK_CHAIN"; then
            native_ok=1
        else
            warn "Zimbra-native rollback failed; the file snapshot will still be restored."
        fi
        restore_file_snapshot || snapshot_ok=0
    fi

    TRANSACTION_ACTIVE=0
    if [[ "$snapshot_ok" -eq 1 && "$native_ok" -eq 1 ]]; then
        ok "Pre-deployment files and Zimbra certificate configuration were restored."
    elif [[ "$snapshot_ok" -eq 1 ]]; then
        warn "Pre-deployment files were restored, but Zimbra LDAP certificate attributes may require manual verification."
    else
        warn "Automatic rollback was incomplete. Do not restart services; use backup: $BACKUP_DIR"
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT ERR INT TERM
    set +e
    trap '' INT TERM

    if [[ "$rc" -ne 0 && "$TRANSACTION_ACTIVE" -eq 1 ]]; then
        rollback_target
    fi

    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        case "$STAGE_DIR" in
            "$ZIMBRA_HOME"/tmp/ssl-migrate.*)
                if [[ "$rc" -eq 0 && "$KEEP_STAGE" -eq 1 ]]; then
                    warn "Secret staging directory retained by request: $STAGE_DIR"
                else
                    rm -rf -- "$STAGE_DIR" || true
                fi
                ;;
            *)
                warn "Refusing to remove unexpected staging path: $STAGE_DIR"
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
# LOCAL PREFLIGHT AND PRIVATE WORKSPACE
# ---------------------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run this script as root on the NEW Zimbra server."
[[ -d "$ZIMBRA_HOME" && ! -L "$ZIMBRA_HOME" ]] || \
    die "Zimbra installation is missing or is a symlink: $ZIMBRA_HOME"
[[ -x "$ZMCERTMGR" ]] || die "zmcertmgr not found: $ZMCERTMGR"
[[ -x "$ZMHOSTNAME" ]] || die "zmhostname not found: $ZMHOSTNAME"
[[ -x "$ZMCONTROL" ]] || die "zmcontrol not found: $ZMCONTROL"
[[ -d "$LOCAL_COMM_DIR" && ! -L "$LOCAL_COMM_DIR" ]] || \
    die "Target commercial SSL directory is missing or is a symlink: $LOCAL_COMM_DIR"
id "$ZIMBRA_USER" >/dev/null 2>&1 || die "Zimbra operating-system user not found: $ZIMBRA_USER"

for command in ssh scp openssl awk grep sed sha256sum tar tail tee tr \
    hostname install stat date su id flock setsid sleep mktemp chown chmod rm cp mkdir \
    dirname gzip; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

OPENSSL_X509_HELP="$(openssl x509 -help 2>&1 || true)"
[[ "$OPENSSL_X509_HELP" == *-checkhost* ]] || \
    die "This script requires an OpenSSL x509 implementation with -checkhost support."
unset OPENSSL_X509_HELP

if [[ -n "$SSH_IDENTITY" ]]; then
    [[ -f "$SSH_IDENTITY" && -r "$SSH_IDENTITY" && ! -L "$SSH_IDENTITY" ]] || \
        die "SSH identity must be a readable regular file, not a symlink: $SSH_IDENTITY"
    IDENTITY_MODE="$(stat -c '%a' "$SSH_IDENTITY" 2>/dev/null || true)"
    if [[ "$IDENTITY_MODE" =~ ^[0-7]{3,4}$ && $((8#$IDENTITY_MODE & 077)) -ne 0 ]]; then
        warn "SSH identity permissions are broader than 0600: $SSH_IDENTITY ($IDENTITY_MODE)"
    fi
fi

for directory in "$BACKUP_ROOT" "$LOG_ROOT" "$(dirname "$LOCK_FILE")"; do
    [[ ! -L "$directory" ]] || die "Security-sensitive directory must not be a symlink: $directory"
    mkdir -p -- "$directory"
    [[ -d "$directory" ]] || die "Could not create directory: $directory"
done
chmod 700 "$BACKUP_ROOT"

[[ ! -L "$LOCK_FILE" ]] || die "Lock file must not be a symlink: $LOCK_FILE"
exec 9>> "$LOCK_FILE"
chmod 600 "$LOCK_FILE"
flock -n 9 || die "Another Zimbra SSL migration process is already running."

LOG_FILE="$(mktemp "$LOG_ROOT/zimbra-ssl-migrate-${START_TS}.XXXXXX.log")"
chmod 600 "$LOG_FILE"
LOG_READY=1

ZIMBRA_TMP="${ZIMBRA_HOME}/tmp"
[[ ! -L "$ZIMBRA_TMP" ]] || die "Zimbra temporary directory must not be a symlink: $ZIMBRA_TMP"
mkdir -p -- "$ZIMBRA_TMP"
[[ -d "$ZIMBRA_TMP" ]] || die "Could not create Zimbra temporary directory: $ZIMBRA_TMP"
STAGE_DIR="$(mktemp -d "$ZIMBRA_TMP/ssl-migrate.XXXXXXXX")"
chmod 700 "$STAGE_DIR"

REMOTE="${OLD_USER}@${OLD_HOST}"
SSH_HOST_KEY_MODE=yes
if [[ "$ACCEPT_NEW_HOST_KEY" -eq 1 ]]; then
    SSH_HOST_KEY_MODE=accept-new
    warn "A previously unseen SSH host key will be accepted. Verify its fingerprint out of band."
fi

SSH_OPTS=(
    -n
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=12
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=2
    -o Compression=no
    -o "StrictHostKeyChecking=${SSH_HOST_KEY_MODE}"
)
SCP_OPTS=(
    -P "$SSH_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=12
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=2
    -o Compression=no
    -o "StrictHostKeyChecking=${SSH_HOST_KEY_MODE}"
)
if [[ -n "$SSH_IDENTITY" ]]; then
    SSH_OPTS+=(-i "$SSH_IDENTITY")
    SCP_OPTS+=(-i "$SSH_IDENTITY")
fi

log "Zimbra SSL migration started."
log "Source: $REMOTE"
TARGET_SYSTEM_HOST="$(hostname -f 2>/dev/null || hostname)"
log "Target: $TARGET_SYSTEM_HOST"
log "Log: $LOG_FILE"

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    RUN_MODE="verify only"
    TOTAL_PHASES=4
else
    RUN_MODE="deploy"
    TOTAL_PHASES=7
fi
ui_banner "$RUN_MODE" "$REMOTE" "$TARGET_SYSTEM_HOST" "$LOG_FILE"
phase 1 "$TOTAL_PHASES" "Destination preflight"

# ---------------------------------------------------------------------------
# SOURCE AND DESTINATION DISCOVERY
# ---------------------------------------------------------------------------

TARGET_HOST_OUTPUT="${STAGE_DIR}/target-host.out"
TARGET_VERSION_OUTPUT="${STAGE_DIR}/target-version.out"
SOURCE_HOST_OUTPUT="${STAGE_DIR}/source-host.out"
SOURCE_VERSION_OUTPUT="${STAGE_DIR}/source-version.out"

run_zimbra_capture "$TARGET_HOST_OUTPUT" "$ZMHOSTNAME" || \
    die "Could not determine destination Zimbra hostname."
TARGET_ZMHOST="$(tail -n1 "$TARGET_HOST_OUTPUT" | tr -d '\r')"
[[ -n "$TARGET_ZMHOST" ]] || die "Destination zmhostname returned an empty value."

if run_zimbra_capture "$TARGET_VERSION_OUTPUT" "$ZMCONTROL" -v; then
    TARGET_ZMVER="$(tail -n1 "$TARGET_VERSION_OUTPUT" | tr -d '\r')"
else
    TARGET_ZMVER=""
fi
log "Destination zmhostname: $TARGET_ZMHOST"
[[ -n "$TARGET_ZMVER" ]] && log "Destination version: $TARGET_ZMVER"

KEY_MODE=0640
if [[ "$TARGET_ZMVER" =~ [Rr]elease[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
    ZCS_MAJOR="${BASH_REMATCH[1]}"
    ZCS_MINOR="${BASH_REMATCH[2]}"
    if ((ZCS_MAJOR < 8 || (ZCS_MAJOR == 8 && ZCS_MINOR < 7))); then
        CERTMGR_AS_ROOT=1
        KEY_MODE=0740
        log "Detected pre-8.7 Zimbra; zmcertmgr will run as root."
        ok "Zimbra ${ZCS_MAJOR}.${ZCS_MINOR}: certificate manager will run as root."
    else
        log "Detected Zimbra 8.7+; zmcertmgr will run as $ZIMBRA_USER."
        ok "Zimbra ${ZCS_MAJOR}.${ZCS_MINOR}: certificate manager will run as $ZIMBRA_USER."
    fi
else
    warn "Could not parse the Zimbra version; using the Zimbra 8.7+ zmcertmgr mode."
fi

phase 2 "$TOTAL_PHASES" "Source access and secure transfer"
log "Testing SSH connectivity and host-key trust..."
SSH_TEST_OUTPUT="${STAGE_DIR}/ssh-test.out"
if ! run_in_group_capture "$SSH_TEST_OUTPUT" \
        ssh "${SSH_OPTS[@]}" "$REMOTE" "printf 'SSH_OK\\n'"; then
    die "SSH authentication failed for $REMOTE; verify the identity and known_hosts (details: $LOG_FILE)."
fi
grep -Fqx 'SSH_OK' "$SSH_TEST_OUTPUT" || \
    die "Unexpected response from source SSH endpoint: $REMOTE"
ok "SSH connection and source host-key verification succeeded."

REMOTE_HOST_CMD="$(shell_join "$REMOTE_ZMHOSTNAME")"
REMOTE_VERSION_CMD="$(shell_join "$REMOTE_ZMCONTROL" -v)"
if run_in_group_capture "$SOURCE_HOST_OUTPUT" \
        ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_HOST_CMD"; then
    SOURCE_ZMHOST="$(tail -n1 "$SOURCE_HOST_OUTPUT" | tr -d '\r')"
else
    SOURCE_ZMHOST=""
fi
if run_in_group_capture "$SOURCE_VERSION_OUTPUT" \
        ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_VERSION_CMD"; then
    SOURCE_ZMVER="$(tail -n1 "$SOURCE_VERSION_OUTPUT" | tr -d '\r')"
else
    SOURCE_ZMVER=""
fi
[[ -n "$SOURCE_ZMHOST" ]] && log "Source zmhostname: $SOURCE_ZMHOST"
[[ -n "$SOURCE_ZMVER" ]] && log "Source version: $SOURCE_ZMVER"

# ---------------------------------------------------------------------------
# SECURE TRANSFER AND STRUCTURAL VALIDATION
# ---------------------------------------------------------------------------

REMOTE_KEY="${REMOTE_COMM_DIR}/commercial.key"
REMOTE_CRT="${REMOTE_COMM_DIR}/commercial.crt"
REMOTE_CA="${REMOTE_COMM_DIR}/commercial_ca.crt"

log "Checking source certificate files..."
for remote_file in "$REMOTE_KEY" "$REMOTE_CRT" "$REMOTE_CA"; do
    printf -v REMOTE_CHECK_CMD 'test -s %q && test -r %q' "$remote_file" "$remote_file"
    run_in_group_logged ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_CHECK_CMD" || \
        die "Source file is missing, empty, or unreadable by $OLD_USER: $remote_file"
done
ok "Source key, leaf certificate, and CA chain are readable."

REMOTE_KEY_MODE_OUTPUT="${STAGE_DIR}/remote-key-mode.out"
printf -v REMOTE_KEY_MODE_CMD 'stat -c %%a -- %q' "$REMOTE_KEY"
run_in_group_capture "$REMOTE_KEY_MODE_OUTPUT" \
    ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_KEY_MODE_CMD" || \
    die "Could not inspect source commercial.key permissions."
REMOTE_KEY_MODE="$(tail -n1 "$REMOTE_KEY_MODE_OUTPUT" | tr -d '\r')"
[[ "$REMOTE_KEY_MODE" =~ ^[0-7]{3,4}$ ]] || \
    die "Source commercial.key returned an invalid permission mode: $REMOTE_KEY_MODE"
if ((8#$REMOTE_KEY_MODE & 0007)); then
    warn "Source commercial.key is accessible to other users (mode $REMOTE_KEY_MODE); destination will still use mode $KEY_MODE."
fi
log "Source commercial.key mode: $REMOTE_KEY_MODE"

RAW_KEY="${STAGE_DIR}/source-commercial.key"
RAW_CRT="${STAGE_DIR}/source-commercial.crt"
RAW_CA="${STAGE_DIR}/source-commercial_ca.crt"
STAGED_KEY="${STAGE_DIR}/commercial.key"
LEAF_CRT="${STAGE_DIR}/commercial.crt"
CHAIN_CRT="${STAGE_DIR}/commercial_ca.crt"

log "Downloading certificate material into the private staging directory..."
run_in_group_logged scp "${SCP_OPTS[@]}" "${REMOTE}:${REMOTE_KEY}" "$RAW_KEY" || \
    die "Could not download source commercial.key."
run_in_group_logged scp "${SCP_OPTS[@]}" "${REMOTE}:${REMOTE_CRT}" "$RAW_CRT" || \
    die "Could not download source commercial.crt."
run_in_group_logged scp "${SCP_OPTS[@]}" "${REMOTE}:${REMOTE_CA}" "$RAW_CA" || \
    die "Could not download source commercial_ca.crt."
ok "Certificate files transferred to the private staging area."

chmod 600 "$RAW_KEY" "$RAW_CRT" "$RAW_CA"
cp -- "$RAW_KEY" "$STAGED_KEY"

# A deployed commercial.crt may contain the leaf followed by the CA chain.
# zmcertmgr expects the leaf and CA chain as separate deployment inputs.
awk '
    /-----BEGIN CERTIFICATE-----/ {
        if (seen == 0) { capture=1; seen=1 }
    }
    capture { print }
    /-----END CERTIFICATE-----/ && capture { exit }
' "$RAW_CRT" > "$LEAF_CRT"

chmod 600 "$STAGED_KEY" "$LEAF_CRT"
[[ -s "$STAGED_KEY" && -s "$LEAF_CRT" && -s "$RAW_CA" ]] || \
    die "One or more staged certificate files are empty."
if grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$RAW_CRT" "$RAW_CA"; then
    die "A certificate/CA input unexpectedly contains private-key material."
fi
LEAF_FINGERPRINT="$(pem_certificate_fingerprint "$LEAF_CRT")"
[[ -n "$LEAF_FINGERPRINT" ]] || die "Could not fingerprint the staged leaf certificate."

phase 3 "$TOTAL_PHASES" "Cryptographic validation"
log "Validating certificate syntax, trust chain, time, and private key..."
openssl x509 -in "$LEAF_CRT" -noout >> "$LOG_FILE" 2>&1 || \
    die "Leaf certificate is not a valid X.509 PEM certificate."
openssl pkey -in "$STAGED_KEY" -noout -passin pass: >/dev/null 2>&1 || \
    die "Private key is invalid or encrypted; Zimbra requires non-interactive access."
prepare_zmcertmgr_chain || \
    die "Could not build a CA chain that zmcertmgr will accept from the source files and local trust store."
[[ -s "$CHAIN_CRT" ]] || die "The prepared CA chain is empty."
CHAIN_COUNT="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$CHAIN_CRT" || true)"
log "Prepared CA chain PEM count: $CHAIN_COUNT"

KEY_PUB_HASH="$(
    openssl pkey -in "$STAGED_KEY" -passin pass: -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
)"
CRT_PUB_HASH="$(
    openssl x509 -in "$LEAF_CRT" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
)"
[[ -n "$KEY_PUB_HASH" && "$KEY_PUB_HASH" == "$CRT_PUB_HASH" ]] || \
    die "Certificate and private key do not match."
ok "Certificate, chain, and private key are cryptographically consistent."

chown -R "$ZIMBRA_USER:$ZIMBRA_GROUP" "$STAGE_DIR"
chmod 700 "$STAGE_DIR"
chmod 600 "$STAGED_KEY" "$LEAF_CRT" "$CHAIN_CRT" "$RAW_KEY" "$RAW_CRT" "$RAW_CA"
ensure_zimbra_can_read_stage

SUBJECT="$(openssl x509 -in "$LEAF_CRT" -noout -subject | sed 's/^subject=//')"
ISSUER="$(openssl x509 -in "$LEAF_CRT" -noout -issuer | sed 's/^issuer=//')"
SERIAL="$(openssl x509 -in "$LEAF_CRT" -noout -serial | sed 's/^serial=//')"
NOT_BEFORE="$(openssl x509 -in "$LEAF_CRT" -noout -startdate | sed 's/^notBefore=//')"
NOT_AFTER="$(openssl x509 -in "$LEAF_CRT" -noout -enddate | sed 's/^notAfter=//')"
INCOMING_FINGERPRINT="$(openssl x509 -in "$LEAF_CRT" -outform DER | sha256sum | awk '{print $1}')"

log "Certificate subject: $SUBJECT"
log "Certificate issuer: $ISSUER"
log "Certificate serial: $SERIAL"
log "Valid from: $NOT_BEFORE"
log "Valid until: $NOT_AFTER"

WARN_SECONDS=$((MIN_WARN_DAYS * 86400))
if ! openssl x509 -in "$LEAF_CRT" -checkend "$WARN_SECONDS" -noout >/dev/null; then
    warn "Certificate expires within $MIN_WARN_DAYS days."
fi

phase 4 "$TOTAL_PHASES" "Zimbra compatibility"
log "Checking certificate against destination zmhostname: $TARGET_ZMHOST"
if openssl x509 -in "$LEAF_CRT" -checkhost "$TARGET_ZMHOST" -noout >/dev/null 2>&1; then
    ok "Certificate matches destination zmhostname: $TARGET_ZMHOST"
else
    warn "Certificate does not match destination zmhostname: $TARGET_ZMHOST"
    openssl x509 -in "$LEAF_CRT" -noout -ext subjectAltName >> "$LOG_FILE" 2>&1 || true
    [[ "$ALLOW_HOSTNAME_MISMATCH" -eq 1 ]] || \
        die "Hostname mismatch; use --allow-hostname-mismatch only when explicitly intended."
    warn "Hostname mismatch was explicitly accepted by the operator."
fi

log "Running Zimbra-native verification against staged files..."
run_certmgr_or_die \
    "Zimbra zmcertmgr rejected the staged certificate set; target was not changed." \
    verifycrt comm "$STAGED_KEY" "$LEAF_CRT" "$CHAIN_CRT"
ok "Zimbra-native verification succeeded."

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    ok "Verify-only mode completed; no target certificate file was changed."
    log "Zimbra services were not restarted."
    exit 0
fi

# ---------------------------------------------------------------------------
# VERIFIED BACKUP AND ROLLBACK PREPARATION
# ---------------------------------------------------------------------------

phase 5 "$TOTAL_PHASES" "Verified destination backup"
BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/${START_TS}.XXXXXXXX")"
chmod 700 "$BACKUP_DIR"
BACKUP_TAR="${BACKUP_DIR}/zimbra-ssl-predeploy.tar.gz"
ROLLBACK_ABSENT_FILE="${BACKUP_DIR}/absent-before-deploy.txt"

DEPLOYMENT_PATHS=(
    "$ZIMBRA_HOME/ssl"
    "$ZIMBRA_HOME/conf/ca"
    "$ZIMBRA_HOME/conf/imapd.crt"
    "$ZIMBRA_HOME/conf/imapd.key"
    "$ZIMBRA_HOME/conf/slapd.crt"
    "$ZIMBRA_HOME/conf/slapd.key"
    "$ZIMBRA_HOME/conf/smtpd.crt"
    "$ZIMBRA_HOME/conf/smtpd.key"
    "$ZIMBRA_HOME/conf/nginx.crt"
    "$ZIMBRA_HOME/conf/nginx.key"
    "$ZIMBRA_HOME/conf/imapd.keystore"
    "$ZIMBRA_HOME/mailboxd/etc/keystore"
    "$ZIMBRA_HOME/mailbox/etc/keystore"
    "$ZIMBRA_HOME/jetty/etc/keystore"
    "$ZIMBRA_HOME/common/lib/jvm/java/lib/security/cacerts"
    "$ZIMBRA_HOME/common/lib/jvm/java/jre/lib/security/cacerts"
    "$ZIMBRA_HOME/java/jre/lib/security/cacerts"
)

# Track individual files that zmcertmgr can create below already-existing
# directories. A plain tar extraction restores changed files but would not
# otherwise remove a file that did not exist before the attempted deployment.
ROLLBACK_TRACKED_PATHS=(
    "${LOCAL_COMM_DIR}/commercial.key"
    "${LOCAL_COMM_DIR}/commercial.crt"
    "${LOCAL_COMM_DIR}/commercial_ca.crt"
    "$ZIMBRA_HOME/ssl/zimbra/jetty.pkcs12"
    "$ZIMBRA_HOME/conf/ca"
    "$ZIMBRA_HOME/conf/ca/ca.pem"
    "$ZIMBRA_HOME/conf/imapd.crt"
    "$ZIMBRA_HOME/conf/imapd.key"
    "$ZIMBRA_HOME/conf/slapd.crt"
    "$ZIMBRA_HOME/conf/slapd.key"
    "$ZIMBRA_HOME/conf/smtpd.crt"
    "$ZIMBRA_HOME/conf/smtpd.key"
    "$ZIMBRA_HOME/conf/nginx.crt"
    "$ZIMBRA_HOME/conf/nginx.key"
    "$ZIMBRA_HOME/conf/imapd.keystore"
    "$ZIMBRA_HOME/mailboxd/etc/keystore"
    "$ZIMBRA_HOME/mailbox/etc/keystore"
    "$ZIMBRA_HOME/jetty/etc/keystore"
    "$ZIMBRA_HOME/common/lib/jvm/java/lib/security/cacerts"
    "$ZIMBRA_HOME/common/lib/jvm/java/jre/lib/security/cacerts"
    "$ZIMBRA_HOME/java/jre/lib/security/cacerts"
)

EXISTING_BACKUP_PATHS=()
: > "$ROLLBACK_ABSENT_FILE"
for target_path in "${DEPLOYMENT_PATHS[@]}"; do
    if [[ -e "$target_path" || -L "$target_path" ]]; then
        EXISTING_BACKUP_PATHS+=("${target_path#/}")
    fi
done
for target_path in "${ROLLBACK_TRACKED_PATHS[@]}"; do
    if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
        printf '%s\n' "$target_path" >> "$ROLLBACK_ABSENT_FILE"
    fi
done
[[ ${#EXISTING_BACKUP_PATHS[@]} -gt 0 ]] || die "No destination SSL path was available to back up."

log "Creating pre-deployment backup: $BACKUP_TAR"
run_in_group_logged tar -C / -czpf "$BACKUP_TAR" "${EXISTING_BACKUP_PATHS[@]}" || \
    die "Could not create the pre-deployment backup."
chmod 600 "$BACKUP_TAR" "$ROLLBACK_ABSENT_FILE"
run_in_group_capture "${BACKUP_DIR}/archive-manifest.txt" \
    tar -tzf "$BACKUP_TAR" || \
    die "The pre-deployment backup failed its archive integrity check."
sha256sum "$BACKUP_TAR" > "${BACKUP_TAR}.sha256"
chmod 600 "${BACKUP_DIR}/archive-manifest.txt" "${BACKUP_TAR}.sha256"

ROLLBACK_LEAF="${STAGE_DIR}/rollback-commercial.crt"
ROLLBACK_CHAIN="${STAGE_DIR}/rollback-commercial_ca.crt"
CURRENT_KEY="${LOCAL_COMM_DIR}/commercial.key"
CURRENT_CRT="${LOCAL_COMM_DIR}/commercial.crt"
CURRENT_CA="${LOCAL_COMM_DIR}/commercial_ca.crt"
if [[ -s "$CURRENT_KEY" && -s "$CURRENT_CRT" && -s "$CURRENT_CA" ]]; then
    awk '
        /-----BEGIN CERTIFICATE-----/ {
            if (seen == 0) { capture=1; seen=1 }
        }
        capture { print }
        /-----END CERTIFICATE-----/ && capture { exit }
    ' "$CURRENT_CRT" > "$ROLLBACK_LEAF"
    cp -- "$CURRENT_CA" "$ROLLBACK_CHAIN"
    chown "$ZIMBRA_USER:$ZIMBRA_GROUP" "$ROLLBACK_LEAF" "$ROLLBACK_CHAIN"
    chmod 600 "$ROLLBACK_LEAF" "$ROLLBACK_CHAIN"
    if run_certmgr_combined "${BACKUP_DIR}/rollback-verification.log" \
            verifycrt comm "$CURRENT_KEY" "$ROLLBACK_LEAF" "$ROLLBACK_CHAIN"; then
        ROLLBACK_NATIVE_READY=1
    else
        warn "The existing certificate cannot be used for Zimbra-native rollback; file rollback remains available."
    fi
fi

{
    printf 'Backup timestamp: %s\n' "$(date -Is)"
    printf 'Destination zmhostname: %s\n' "$TARGET_ZMHOST"
    printf 'Destination version: %s\n' "$TARGET_ZMVER"
    printf 'Source host: %s\n' "$OLD_HOST"
    printf 'Source zmhostname: %s\n' "$SOURCE_ZMHOST"
    printf 'Source version: %s\n' "$SOURCE_ZMVER"
    printf 'Incoming certificate subject: %s\n' "$SUBJECT"
    printf 'Incoming certificate issuer: %s\n' "$ISSUER"
    printf 'Incoming certificate serial: %s\n' "$SERIAL"
    printf 'Incoming certificate notBefore: %s\n' "$NOT_BEFORE"
    printf 'Incoming certificate notAfter: %s\n' "$NOT_AFTER"
    printf 'Incoming certificate SHA256: %s\n' "$INCOMING_FINGERPRINT"
} > "${BACKUP_DIR}/migration-info.txt"
chmod 600 "${BACKUP_DIR}/migration-info.txt" "${BACKUP_DIR}/rollback-verification.log" 2>/dev/null || true
ok "Verified pre-deployment backup created: $BACKUP_TAR"

# ---------------------------------------------------------------------------
# TRANSACTIONAL INSTALL, DEPLOYMENT, AND POST-DEPLOY VERIFICATION
# ---------------------------------------------------------------------------

phase 6 "$TOTAL_PHASES" "Certificate deployment"
TRANSACTION_ACTIVE=1
log "Installing the validated private key in the destination commercial directory..."
install -o "$ZIMBRA_USER" -g "$ZIMBRA_GROUP" -m "$KEY_MODE" \
    "$STAGED_KEY" "${LOCAL_COMM_DIR}/commercial.key"

INSTALLED_KEY_HASH="$(
    openssl pkey -in "${LOCAL_COMM_DIR}/commercial.key" -passin pass: \
        -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
)"
[[ "$INSTALLED_KEY_HASH" == "$CRT_PUB_HASH" ]] || \
    die "The installed private key failed its post-copy integrity check."

log "Running final Zimbra verification with the installed private key..."
run_certmgr_logged verifycrt comm "${LOCAL_COMM_DIR}/commercial.key" "$LEAF_CRT" "$CHAIN_CRT" || \
    die "Final Zimbra verification failed before deployment."

log "Deploying the certificate with zmcertmgr..."
run_certmgr_logged deploycrt comm "$LEAF_CRT" "$CHAIN_CRT" || \
    die "zmcertmgr deployment failed. Automatic rollback will now run."
ok "zmcertmgr deployment completed."

phase 7 "$TOTAL_PHASES" "Post-deployment verification"
log "Running Zimbra post-deployment inspection..."
run_certmgr_logged viewdeployedcrt || \
    die "viewdeployedcrt failed after deployment. Automatic rollback will now run."

DEPLOYED_CRT="${LOCAL_COMM_DIR}/commercial.crt"
DEPLOYED_CA="${LOCAL_COMM_DIR}/commercial_ca.crt"
DEPLOYED_LEAF="${STAGE_DIR}/deployed-commercial.crt"
[[ -s "$DEPLOYED_CRT" && -s "$DEPLOYED_CA" ]] || \
    die "Expected deployed commercial certificate files are missing."

awk '
    /-----BEGIN CERTIFICATE-----/ {
        if (seen == 0) { capture=1; seen=1 }
    }
    capture { print }
    /-----END CERTIFICATE-----/ && capture { exit }
' "$DEPLOYED_CRT" > "$DEPLOYED_LEAF"
chmod 600 "$DEPLOYED_LEAF"

DEPLOYED_FINGERPRINT="$(openssl x509 -in "$DEPLOYED_LEAF" -outform DER | sha256sum | awk '{print $1}')"
[[ "$DEPLOYED_FINGERPRINT" == "$INCOMING_FINGERPRINT" ]] || \
    die "Deployed certificate fingerprint does not match the incoming certificate."
openssl verify -purpose sslserver -CAfile "$DEPLOYED_CA" "$DEPLOYED_LEAF" \
    >> "$LOG_FILE" 2>&1 || \
    die "The deployed certificate chain failed post-deployment verification."
DEPLOYED_KEY_HASH="$(
    openssl pkey -in "${LOCAL_COMM_DIR}/commercial.key" -passin pass: \
        -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
)"
[[ "$DEPLOYED_KEY_HASH" == "$CRT_PUB_HASH" ]] || \
    die "The deployed certificate and commercial.key no longer match."

TRANSACTION_ACTIVE=0
ok "Certificate deployment and post-deployment verification succeeded."

printf '\n'
printf '%b============================================================%b\n' "$C_GREEN" "$C_RESET"
printf '%b Zimbra SSL migration completed successfully%b\n' "$C_GREEN" "$C_RESET"
printf '%b============================================================%b\n' "$C_GREEN" "$C_RESET"
printf ' Source             : %s\n' "$REMOTE"
printf ' Source zmhostname  : %s\n' "${SOURCE_ZMHOST:-unknown}"
printf ' Target zmhostname  : %s\n' "$TARGET_ZMHOST"
printf ' Certificate serial : %s\n' "$SERIAL"
printf ' Certificate expiry : %s\n' "$NOT_AFTER"
printf ' Backup             : %s\n' "$BACKUP_DIR"
printf ' Log                : %s\n' "$LOG_FILE"
printf '\n'
printf '%bSERVICES WERE NOT RESTARTED.%b\n' "$C_YELLOW" "$C_RESET"
printf 'After change approval, restart and verify manually:\n\n'
printf '  su - %s -c %q\n' "$ZIMBRA_USER" "$ZMCONTROL restart"
printf '  su - %s -c %q\n' "$ZIMBRA_USER" "$ZMCONTROL status"
printf '  su - %s -c %q\n\n' "$ZIMBRA_USER" "$ZMCERTMGR viewdeployedcrt"
