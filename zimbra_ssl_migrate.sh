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
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
fi

# ---------------------------------------------------------------------------
# OUTPUT AND CLI
# ---------------------------------------------------------------------------

emit() {
    local level="$1" color="$2" message="$3" fd=1 timestamp
    timestamp="$(date '+%F %T')"
    [[ "$level" == "WARN" || "$level" == "ERROR" ]] && fd=2

    if [[ "$LOG_READY" -eq 1 ]]; then
        if ! printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" >> "$LOG_FILE"; then
            printf '[WARN] Could not append to log: %s\n' "$LOG_FILE" >&2
        fi
    fi

    printf '%b[%s] [%s] %s%b\n' \
        "$color" "$timestamp" "$level" "$message" "$C_RESET" >&"$fd"
}

log()  { emit INFO "$C_BLUE" "$1"; }
ok()   { emit OK "$C_GREEN" "$1"; }
warn() { emit WARN "$C_YELLOW" "$1"; }
die()  { emit ERROR "$C_RED" "$1"; exit "${2:-1}"; }

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

run_in_group() {
    local rc

    setsid "$@" &
    ACTIVE_PROCESS_GROUP=$!
    if wait "$ACTIVE_PROCESS_GROUP"; then
        rc=0
    else
        rc=$?
    fi
    ACTIVE_PROCESS_GROUP=""
    return "$rc"
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

CERTMGR_AS_ROOT=0
run_certmgr() {
    if [[ "$CERTMGR_AS_ROOT" -eq 1 ]]; then
        run_in_group "$ZMCERTMGR" "$@"
    else
        run_zimbra "$ZMCERTMGR" "$@"
    fi
}

run_certmgr_logged() {
    run_certmgr "$@" > >(tee -a "$LOG_FILE") 2>&1
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
log "Target: $(hostname -f 2>/dev/null || hostname)"
log "Log: $LOG_FILE"

# ---------------------------------------------------------------------------
# SOURCE AND DESTINATION DISCOVERY
# ---------------------------------------------------------------------------

TARGET_HOST_OUTPUT="${STAGE_DIR}/target-host.out"
TARGET_VERSION_OUTPUT="${STAGE_DIR}/target-version.out"
SOURCE_HOST_OUTPUT="${STAGE_DIR}/source-host.out"
SOURCE_VERSION_OUTPUT="${STAGE_DIR}/source-version.out"

run_zimbra "$ZMHOSTNAME" > "$TARGET_HOST_OUTPUT" 2>/dev/null || \
    die "Could not determine destination Zimbra hostname."
TARGET_ZMHOST="$(tail -n1 "$TARGET_HOST_OUTPUT" | tr -d '\r')"
[[ -n "$TARGET_ZMHOST" ]] || die "Destination zmhostname returned an empty value."

if run_zimbra "$ZMCONTROL" -v > "$TARGET_VERSION_OUTPUT" 2>/dev/null; then
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
    else
        log "Detected Zimbra 8.7+; zmcertmgr will run as $ZIMBRA_USER."
    fi
else
    warn "Could not parse the Zimbra version; using the Zimbra 8.7+ zmcertmgr mode."
fi

log "Testing SSH connectivity and host-key trust..."
SSH_TEST_OUTPUT="${STAGE_DIR}/ssh-test.out"
if ! run_in_group ssh "${SSH_OPTS[@]}" "$REMOTE" "printf 'SSH_OK\\n'" > "$SSH_TEST_OUTPUT"; then
    die "SSH connection failed for $REMOTE. Verify authentication and known_hosts."
fi
grep -Fqx 'SSH_OK' "$SSH_TEST_OUTPUT" || \
    die "Unexpected response from source SSH endpoint: $REMOTE"
ok "SSH connection and source host-key verification succeeded."

REMOTE_HOST_CMD="$(shell_join "$REMOTE_ZMHOSTNAME")"
REMOTE_VERSION_CMD="$(shell_join "$REMOTE_ZMCONTROL" -v)"
if run_in_group ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_HOST_CMD" > "$SOURCE_HOST_OUTPUT" 2>/dev/null; then
    SOURCE_ZMHOST="$(tail -n1 "$SOURCE_HOST_OUTPUT" | tr -d '\r')"
else
    SOURCE_ZMHOST=""
fi
if run_in_group ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_VERSION_CMD" > "$SOURCE_VERSION_OUTPUT" 2>/dev/null; then
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
    run_in_group ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_CHECK_CMD" || \
        die "Source file is missing, empty, or unreadable by $OLD_USER: $remote_file"
done
ok "Source key, leaf certificate, and CA chain are readable."

REMOTE_KEY_MODE_OUTPUT="${STAGE_DIR}/remote-key-mode.out"
printf -v REMOTE_KEY_MODE_CMD 'stat -c %%a -- %q' "$REMOTE_KEY"
run_in_group ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_KEY_MODE_CMD" \
    > "$REMOTE_KEY_MODE_OUTPUT" 2>/dev/null || \
    die "Could not inspect source commercial.key permissions."
REMOTE_KEY_MODE="$(tail -n1 "$REMOTE_KEY_MODE_OUTPUT" | tr -d '\r')"
[[ "$REMOTE_KEY_MODE" =~ ^[0-7]{3,4}$ ]] || \
    die "Source commercial.key returned an invalid permission mode: $REMOTE_KEY_MODE"
if ((8#$REMOTE_KEY_MODE & 0007)); then
    die "Source commercial.key is accessible to other users (mode $REMOTE_KEY_MODE); fix its permissions first."
fi
log "Source commercial.key mode: $REMOTE_KEY_MODE"

RAW_KEY="${STAGE_DIR}/source-commercial.key"
RAW_CRT="${STAGE_DIR}/source-commercial.crt"
RAW_CA="${STAGE_DIR}/source-commercial_ca.crt"
STAGED_KEY="${STAGE_DIR}/commercial.key"
LEAF_CRT="${STAGE_DIR}/commercial.crt"
CHAIN_CRT="${STAGE_DIR}/commercial_ca.crt"

log "Downloading certificate material into the private staging directory..."
run_in_group scp "${SCP_OPTS[@]}" "${REMOTE}:${REMOTE_KEY}" "$RAW_KEY" >/dev/null || \
    die "Could not download source commercial.key."
run_in_group scp "${SCP_OPTS[@]}" "${REMOTE}:${REMOTE_CRT}" "$RAW_CRT" >/dev/null || \
    die "Could not download source commercial.crt."
run_in_group scp "${SCP_OPTS[@]}" "${REMOTE}:${REMOTE_CA}" "$RAW_CA" >/dev/null || \
    die "Could not download source commercial_ca.crt."

chmod 600 "$RAW_KEY" "$RAW_CRT" "$RAW_CA"
cp -- "$RAW_KEY" "$STAGED_KEY"
cp -- "$RAW_CA" "$CHAIN_CRT"

# A deployed commercial.crt may contain the leaf followed by the CA chain.
# zmcertmgr expects the leaf and CA chain as separate deployment inputs.
awk '
    /-----BEGIN CERTIFICATE-----/ {
        if (seen == 0) { capture=1; seen=1 }
    }
    capture { print }
    /-----END CERTIFICATE-----/ && capture { exit }
' "$RAW_CRT" > "$LEAF_CRT"

chmod 600 "$STAGED_KEY" "$LEAF_CRT" "$CHAIN_CRT"
[[ -s "$STAGED_KEY" && -s "$LEAF_CRT" && -s "$CHAIN_CRT" ]] || \
    die "One or more staged certificate files are empty."
if grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$RAW_CRT" "$RAW_CA"; then
    die "A certificate/CA input unexpectedly contains private-key material."
fi

CRT_COUNT="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$RAW_CRT" || true)"
CA_COUNT="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$CHAIN_CRT" || true)"
[[ "$CRT_COUNT" -ge 1 ]] || die "Source commercial.crt has no PEM certificate."
[[ "$CA_COUNT" -ge 1 ]] || die "Source commercial_ca.crt has no PEM certificate."
log "Source commercial.crt PEM count: $CRT_COUNT"
log "Source commercial_ca.crt PEM count: $CA_COUNT"

chown -R "$ZIMBRA_USER:$ZIMBRA_GROUP" "$STAGE_DIR"
chmod 700 "$STAGE_DIR"
chmod 600 "$STAGED_KEY" "$LEAF_CRT" "$CHAIN_CRT" "$RAW_KEY" "$RAW_CRT" "$RAW_CA"

log "Validating certificate syntax, trust chain, time, and private key..."
openssl x509 -in "$LEAF_CRT" -noout >/dev/null || \
    die "Leaf certificate is not a valid X.509 PEM certificate."
openssl pkey -in "$STAGED_KEY" -noout -passin pass: >/dev/null 2>&1 || \
    die "Private key is invalid or encrypted; Zimbra requires non-interactive access."
openssl verify -purpose sslserver -CAfile "$CHAIN_CRT" "$LEAF_CRT" >/dev/null || \
    die "OpenSSL could not build a currently valid server-certificate chain."

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

log "Checking certificate against destination zmhostname: $TARGET_ZMHOST"
if openssl x509 -in "$LEAF_CRT" -checkhost "$TARGET_ZMHOST" -noout >/dev/null 2>&1; then
    ok "Certificate matches destination zmhostname: $TARGET_ZMHOST"
else
    warn "Certificate does not match destination zmhostname: $TARGET_ZMHOST"
    openssl x509 -in "$LEAF_CRT" -noout -ext subjectAltName 2>/dev/null | tee -a "$LOG_FILE" || true
    [[ "$ALLOW_HOSTNAME_MISMATCH" -eq 1 ]] || \
        die "Hostname mismatch; use --allow-hostname-mismatch only when explicitly intended."
    warn "Hostname mismatch was explicitly accepted by the operator."
fi

log "Running Zimbra-native verification against staged files..."
run_certmgr_logged verifycrt comm "$STAGED_KEY" "$LEAF_CRT" "$CHAIN_CRT" || \
    die "Zimbra zmcertmgr rejected the staged certificate set; target was not changed."
ok "Zimbra-native verification succeeded."

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    ok "Verify-only mode completed; no target certificate file was changed."
    log "Zimbra services were not restarted."
    exit 0
fi

# ---------------------------------------------------------------------------
# VERIFIED BACKUP AND ROLLBACK PREPARATION
# ---------------------------------------------------------------------------

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
run_in_group tar -C / -czpf "$BACKUP_TAR" "${EXISTING_BACKUP_PATHS[@]}" || \
    die "Could not create the pre-deployment backup."
chmod 600 "$BACKUP_TAR" "$ROLLBACK_ABSENT_FILE"
run_in_group tar -tzf "$BACKUP_TAR" > "${BACKUP_DIR}/archive-manifest.txt" || \
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
    if run_certmgr verifycrt comm "$CURRENT_KEY" "$ROLLBACK_LEAF" "$ROLLBACK_CHAIN" \
            > "${BACKUP_DIR}/rollback-verification.log" 2>&1; then
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
openssl verify -purpose sslserver -CAfile "$DEPLOYED_CA" "$DEPLOYED_LEAF" >/dev/null || \
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
