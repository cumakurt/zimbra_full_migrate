#!/usr/bin/env bash
#
# zimbra_full_migrate.sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Cuma Kurt
# Author: Cuma Kurt <https://www.linkedin.com/in/cuma-kurt-34414917/>
# Source: https://github.com/cumakurt/zimbra_full_migrate
#
# Zimbra -> Zimbra tenant/mailbox migration orchestrator
#
# Runs on the NEW/DESTINATION Zimbra server as the "zimbra" user.
# Reads the OLD/SOURCE Zimbra over SSH. No large temporary mailbox archive
# is created on the old server.
#
# Migrates:
#   - domains (and basic portable domain settings)
#   - COS names + portable COS settings
#   - accounts
#   - password hashes
#   - account COS assignments
#   - common portable account attributes/preferences
#   - forwarding addresses
#   - account aliases
#   - Sieve mail filters
#   - distribution lists, DL aliases, and members
#   - mailbox contents via TGZ REST export/import:
#       mail, folders, contacts, calendars, tasks, tags and REST metadata
#
# Resume:
#   Every phase has checkpoint files under STATE_DIR.
#   Re-running the script skips completed work.
#
# Live cutover:
#   Run once for the bulk migration.
#   At final cutover stop user access/delivery on the old server and run:
#       ./zimbra_full_migrate.sh --delta
#   --delta re-exports mailbox data for all users and imports with
#   resolve=skip, while keeping provisioning checkpoints.
#
# IMPORTANT:
#   This is NOT a bit-for-bit server clone. It deliberately does NOT copy:
#   server IDs, LDAP UUIDs, mailbox IDs, /opt/zimbra/store raw blobs,
#   MySQL/MariaDB files, MTA queue, TLS private keys, licenses, server
#   topology, localconfig secrets, or other host-specific internals.
#

set -o pipefail
umask 077

# ---------------------------------------------------------------------------
# USER CONFIGURATION
# ---------------------------------------------------------------------------

# Preserve inherited environment values so they can be restored after CONFIG
# is sourced. Precedence is: defaults < CONFIG < environment < CLI.
_ZFM_CONFIG_VARS=(
    OLD_HOST OLD_SSH_USER MAILBOX_PARALLEL MAILBOX_RESOLVE KEEP_ARCHIVES
    VERIFY_TGZ MIN_FREE_GB MIGRATE_ADMIN_ACCOUNTS MIGRATE_SYSTEM_ACCOUNTS
    BASEDIR MIG_ROOT UI_VERBOSE NO_COLOR
)
declare -A _ZFM_ENV_SET=()
declare -A _ZFM_ENV_VALUE=()
for _zfm_name in "${_ZFM_CONFIG_VARS[@]}"; do
    if [[ -v "$_zfm_name" ]]; then
        _ZFM_ENV_SET["$_zfm_name"]=1
        _ZFM_ENV_VALUE["$_zfm_name"]="${!_zfm_name}"
    fi
done

# Old Zimbra server. It must be set in CONFIG or supplied as:
#   OLD_HOST=192.168.1.10 ./zimbra_full_migrate.sh
OLD_HOST="${OLD_HOST:-}"
OLD_SSH_USER="${OLD_SSH_USER:-zimbra}"

# Number of simultaneous mailbox export/import jobs.
MAILBOX_PARALLEL="${MAILBOX_PARALLEL:-4}"

# Conflict mode for mailbox imports.
# "skip" is safest for resumable / repeated migration.
MAILBOX_RESOLVE="${MAILBOX_RESOLVE:-skip}"

# Keep imported TGZ after successful import?
# 0 = delete immediately to save disk space
# 1 = keep archives
KEEP_ARCHIVES="${KEEP_ARCHIVES:-0}"

# Verify downloaded TGZ with gzip -t before importing.
VERIFY_TGZ="${VERIFY_TGZ:-1}"

# Safety reserve on destination filesystems, in GiB.
MIN_FREE_GB="${MIN_FREE_GB:-10}"

# Whether to migrate source administrator accounts.
# Target admin accounts are risky to overwrite. Default: skip.
MIGRATE_ADMIN_ACCOUNTS="${MIGRATE_ADMIN_ACCOUNTS:-0}"

# Whether to migrate Zimbra system/resource accounts (galsync/spam/ham/etc).
# Default: skip.
MIGRATE_SYSTEM_ACCOUNTS="${MIGRATE_SYSTEM_ACCOUNTS:-0}"

# ---------------------------------------------------------------------------
# LOCAL PATHS
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Existing migration CONFIG is optional. BASEDIR can come from it.
if [[ -f "$SCRIPT_DIR/CONFIG" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/CONFIG"
fi

for _zfm_name in "${_ZFM_CONFIG_VARS[@]}"; do
    if [[ "${_ZFM_ENV_SET[$_zfm_name]:-0}" == "1" ]]; then
        printf -v "$_zfm_name" '%s' "${_ZFM_ENV_VALUE[$_zfm_name]}"
    fi
done
unset _ZFM_CONFIG_VARS _ZFM_ENV_SET _ZFM_ENV_VALUE _zfm_name

BASEDIR="${BASEDIR:-$SCRIPT_DIR}"

# Empty MIG_ROOT is treated as unset so the script can pick a writable root.
if [[ -n "${MIG_ROOT:-}" ]]; then
    MIG_ROOT_EXPLICIT=1
    PREFERRED_MIG_ROOT="$MIG_ROOT"
else
    MIG_ROOT_EXPLICIT=0
    PREFERRED_MIG_ROOT="$BASEDIR/.zimbra-full-migration"
fi

MIG_ROOT="$PREFERRED_MIG_ROOT"
MIG_ROOT_FALLBACK_FROM=""
STATE_DIR=""
DISCOVERY_DIR=""
DUMP_DIR=""
STAGE_DIR=""
LOG_DIR=""
REPORT_DIR=""
LOCK_DIR=""
TMP_ROOT=""
WORK_TMP=""
ACTIVE_PROCESS_GROUP=""

ZMPROV="/opt/zimbra/bin/zmprov"
ZMMAILBOX="/opt/zimbra/bin/zmmailbox"
ZMCONTROL="/opt/zimbra/bin/zmcontrol"

DELTA_MODE=0
ONLY_PHASE=""
ONLY_USER=""
STATUS_ONLY=0
PREFLIGHT_ONLY=0
DEFER_DOMAIN_STATUS=0

# ---------------------------------------------------------------------------
# LOGGING / CONSOLE
# ---------------------------------------------------------------------------
# File log keeps the full trail. The terminal shows phases, progress,
# warnings, and errors only. Set UI_VERBOSE=1 for per-item screen lines.
# Set NO_COLOR=1 to disable ANSI colors.

UI_VERBOSE="${UI_VERBOSE:-0}"
UI_PROGRESS_ACTIVE=0

ui_init() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_CYAN=$'\033[36m'
        S_OK='✓'
        S_WARN='!'
        S_ERR='✕'
        S_RUN='▸'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
        S_OK='+'
        S_WARN='!'
        S_ERR='x'
        S_RUN='>'
    fi
    export C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_CYAN
    export S_OK S_WARN S_ERR S_RUN UI_VERBOSE
}

ts() { date '+%F %T'; }

_log_line() {
    printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG_DIR/migration.log"
}

log() {
    _log_line "$*"
}

ui_break_progress() {
    if [[ "${UI_PROGRESS_ACTIVE:-0}" == "1" ]]; then
        printf '\n'
        UI_PROGRESS_ACTIVE=0
    fi
}

ui_phase() {
    ui_break_progress
    printf '\n%s%s %s%s%s\n' "$C_CYAN" "$S_RUN" "$C_BOLD" "$1" "$C_RESET"
}

ui_ok() {
    ui_break_progress
    printf '  %s%s%s %s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$1"
}

ui_warn() {
    ui_break_progress
    printf '  %s%s%s %s\n' "$C_YELLOW" "$S_WARN" "$C_RESET" "$1" >&2
}

ui_err() {
    ui_break_progress
    printf '  %s%s%s %s\n' "$C_RED" "$S_ERR" "$C_RESET" "$1" >&2
}

ui_kv() {
    printf '  %s%-12s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"
}

ui_note() {
    log "$1"
    if [[ "$UI_VERBOSE" == "1" ]]; then
        printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"
    fi
}

ui_progress() {
    local label="$1" cur="$2" total="$3"
    UI_PROGRESS_ACTIVE=1
    printf '\r  %s%-12s%s %s / %s   ' "$C_DIM" "$label" "$C_RESET" "$cur" "$total"
}

ui_progress_end() {
    if [[ "${UI_PROGRESS_ACTIVE:-0}" == "1" ]]; then
        printf '\n'
        UI_PROGRESS_ACTIVE=0
    fi
}

ui_ratio() {
    local label="$1" done="$2" total="${3:-}" extra="${4:-}"
    local color="$C_DIM" detail

    if [[ -n "$total" && "$total" != "0" ]]; then
        if [[ "$done" -eq "$total" ]]; then
            color="$C_GREEN"
        elif [[ "$done" -gt 0 ]]; then
            color="$C_YELLOW"
        fi
        detail="${done} / ${total}"
    else
        detail="$done"
        [[ "$done" != "0" ]] && color="$C_GREEN"
    fi
    printf '  %s%-12s%s %s%s%s' "$C_DIM" "$label" "$C_RESET" "$color" "$detail" "$C_RESET"
    if [[ -n "$extra" ]]; then
        printf '  %s%s%s' "$C_YELLOW" "$extra" "$C_RESET"
    fi
    printf '\n'
}

warn() {
    _log_line "WARNING: $*"
    ui_warn "$*"
}

err() {
    _log_line "ERROR: $*"
    ui_err "$*"
}

mbox_tick_reset() {
    : > "$WORK_TMP/mbox.ok"
    : > "$WORK_TMP/mbox.fail"
    : > "$WORK_TMP/mbox.skip"
}

mbox_tick() {
    local kind="$1" user="${2:-}" detail="${3:-}"
    local ok fail skip

    (
        flock -x 9
        case "$kind" in
            ok)   printf '%s\n' "$user" >> "$WORK_TMP/mbox.ok" ;;
            fail) printf '%s\n' "$user" >> "$WORK_TMP/mbox.fail" ;;
            skip) printf '%s\n' "$user" >> "$WORK_TMP/mbox.skip" ;;
        esac
        ok="$(count_lines "$WORK_TMP/mbox.ok")"
        fail="$(count_lines "$WORK_TMP/mbox.fail")"
        skip="$(count_lines "$WORK_TMP/mbox.skip")"

        if [[ "$kind" == "fail" ]]; then
            printf '\n'
            printf '  %s%s%s %s  %s\n' "$C_RED" "$S_ERR" "$C_RESET" "$user" "$detail" >&2
        fi
        printf '\r  %s%-12s%s %s ok  %s%s%s fail  %s skip   ' \
            "$C_DIM" "mailboxes" "$C_RESET" \
            "$ok" "$C_RED" "$fail" "$C_RESET" "$skip"
    ) 9>"$LOCK_DIR/ui.lock"
}

ui_show_failures() {
    local n
    [[ -s "$REPORT_DIR/failures.txt" ]] || return 0
    n="$(count_lines "$REPORT_DIR/failures.txt")"
    ui_err "${n} failed  $REPORT_DIR/failures.txt"
    head -n 8 "$REPORT_DIR/failures.txt" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '    %s%s%s\n' "$C_RED" "$line" "$C_RESET" >&2
    done
    if [[ "$n" -gt 8 ]]; then
        printf '    %s+%s more%s\n' "$C_DIM" "$((n - 8))" "$C_RESET" >&2
    fi
}

usage() {
    cat <<'EOF'
Usage:
  ./zimbra_full_migrate.sh
  ./zimbra_full_migrate.sh --delta
  ./zimbra_full_migrate.sh --phase PHASE
  ./zimbra_full_migrate.sh --user user@example.com
  ./zimbra_full_migrate.sh --status
  ./zimbra_full_migrate.sh --preflight

--phase and --user require a value.

Phases:
  discover
  domains
  cos
  accounts
  attrs
  aliases
  filters
  dl
  mailboxes
  finalize
  verify

Configuration:
  Optional CONFIG file next to this script, or environment variables:
  OLD_HOST, OLD_SSH_USER, MAILBOX_PARALLEL, MAILBOX_RESOLVE,
  KEEP_ARCHIVES, VERIFY_TGZ, MIN_FREE_GB, MIGRATE_ADMIN_ACCOUNTS,
  MIGRATE_SYSTEM_ACCOUNTS, BASEDIR, MIG_ROOT, UI_VERBOSE, NO_COLOR
  OLD_HOST is required for preflight and migration commands.

Examples:
  OLD_HOST=192.168.1.10 ./zimbra_full_migrate.sh
  MAILBOX_PARALLEL=6 ./zimbra_full_migrate.sh --phase mailboxes
  ./zimbra_full_migrate.sh --user user@example.com
  ./zimbra_full_migrate.sh --delta
  ./zimbra_full_migrate.sh --status
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delta)
            DELTA_MODE=1
            shift
            ;;
        --phase)
            if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
                echo "Option --phase requires a phase name." >&2
                usage
                exit 2
            fi
            ONLY_PHASE="$2"
            shift 2
            ;;
        --user)
            if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
                echo "Option --user requires an account address." >&2
                usage
                exit 2
            fi
            ONLY_USER="$2"
            shift 2
            ;;
        --status)
            STATUS_ONLY=1
            shift
            ;;
        --preflight)
            PREFLIGHT_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -n "$ONLY_PHASE" ]]; then
    case "$ONLY_PHASE" in
        discover|domains|cos|accounts|attrs|aliases|filters|dl|mailboxes|finalize|verify) ;;
        *)
            echo "Unknown phase: $ONLY_PHASE" >&2
            usage
            exit 2
            ;;
    esac
fi

if [[ "$STATUS_ONLY" == "1" && ( "$PREFLIGHT_ONLY" == "1" || "$DELTA_MODE" == "1" || -n "$ONLY_PHASE" || -n "$ONLY_USER" ) ]]; then
    echo "Option --status cannot be combined with migration options." >&2
    exit 2
fi

if [[ "$PREFLIGHT_ONLY" == "1" && ( "$DELTA_MODE" == "1" || -n "$ONLY_PHASE" || -n "$ONLY_USER" ) ]]; then
    echo "Option --preflight cannot be combined with migration options." >&2
    exit 2
fi

set_mig_paths() {
    MIG_ROOT="$1"
    STATE_DIR="$MIG_ROOT/state"
    DISCOVERY_DIR="$MIG_ROOT/discovery"
    DUMP_DIR="$MIG_ROOT/dumps"
    STAGE_DIR="$MIG_ROOT/stage"
    LOG_DIR="$MIG_ROOT/logs"
    REPORT_DIR="$MIG_ROOT/reports"
    LOCK_DIR="$MIG_ROOT/locks"
    TMP_ROOT="$MIG_ROOT/tmp"
    WORK_TMP=""
}

ensure_migration_dirs() {
    local managed_dir
    mkdir -p \
        "$MIG_ROOT" \
        "$STATE_DIR" \
        "$DISCOVERY_DIR" \
        "$DUMP_DIR/accounts" \
        "$STAGE_DIR" \
        "$LOG_DIR/mailboxes" \
        "$REPORT_DIR" \
        "$LOCK_DIR" \
        "$TMP_ROOT" 2>/dev/null || return 1

    for managed_dir in \
        "$MIG_ROOT" "$STATE_DIR" "$DISCOVERY_DIR" "$DUMP_DIR" \
        "$DUMP_DIR/accounts" "$STAGE_DIR" "$LOG_DIR" "$LOG_DIR/mailboxes" \
        "$REPORT_DIR" "$LOCK_DIR" "$TMP_ROOT"
    do
        [[ -d "$managed_dir" && ! -L "$managed_dir" && -O "$managed_dir" ]] || return 1
        chmod 700 -- "$managed_dir" 2>/dev/null || return 1
    done

    [[ -d "$MIG_ROOT" && -w "$MIG_ROOT" ]] || return 1
    [[ -w "$STATE_DIR" && -w "$DISCOVERY_DIR" && -w "$DUMP_DIR" ]] || return 1
    [[ -w "$STAGE_DIR" && -w "$LOG_DIR" && -w "$REPORT_DIR" ]] || return 1
    [[ -w "$LOCK_DIR" && -w "$TMP_ROOT" && -w "$DUMP_DIR/accounts" ]] || return 1
    [[ -w "$LOG_DIR/mailboxes" ]] || return 1
    return 0
}

init_migration_root() {
    local candidate
    local -a candidates=()
    set_mig_paths "$PREFERRED_MIG_ROOT"
    if ensure_migration_dirs; then
        return 0
    fi

    if [[ "$MIG_ROOT_EXPLICIT" == "1" ]]; then
        echo "Cannot create or write migration directories: $PREFERRED_MIG_ROOT" >&2
        exit 1
    fi

    if [[ -n "${HOME:-}" ]]; then
        candidates+=("$HOME/.zimbra-full-migration")
    fi
    candidates+=(
        "/opt/zimbra/.zimbra-full-migration"
        "/tmp/zimbra-full-migration-$(id -u)"
    )

    for candidate in "${candidates[@]}"; do
        [[ -z "$candidate" || "$candidate" == "$PREFERRED_MIG_ROOT" ]] && continue
        set_mig_paths "$candidate"
        if ensure_migration_dirs; then
            MIG_ROOT_FALLBACK_FROM="$PREFERRED_MIG_ROOT"
            return 0
        fi
    done

    echo "Cannot create migration directories. Tried: $PREFERRED_MIG_ROOT, user home, /opt/zimbra/.zimbra-full-migration, /tmp/zimbra-full-migration-$(id -u)" >&2
    exit 1
}

if [[ "$STATUS_ONLY" != "1" && "$(id -un)" != "zimbra" ]]; then
    echo "Run this script as the zimbra user." >&2
    exit 1
fi

init_migration_root

ui_init

if [[ -n "$MIG_ROOT_FALLBACK_FROM" ]]; then
    ui_warn "Could not write $MIG_ROOT_FALLBACK_FROM; using $MIG_ROOT"
fi

cleanup_on_exit() {
    if [[ -n "$WORK_TMP" && "$WORK_TMP" == "$TMP_ROOT"/run.* ]]; then
        rm -rf -- "$WORK_TMP"
    fi
}
trap cleanup_on_exit EXIT

if [[ "$STATUS_ONLY" != "1" ]]; then
    exec 8>"$LOCK_DIR/migrate.lock"
    if ! flock -n 8; then
        echo "Another migration process already holds $LOCK_DIR/migrate.lock" >&2
        exit 1
    fi

    WORK_TMP="$(mktemp -d -p "$TMP_ROOT" run.XXXXXX)" || {
        echo "Cannot create a private run workspace under $TMP_ROOT" >&2
        exit 1
    }
fi

handle_signal() {
    local signal_name="$1" exit_code=130 i
    [[ "$signal_name" == "TERM" ]] && exit_code=143

    trap - INT TERM
    ui_break_progress
    ui_err "Interrupted by $signal_name; stopping active work."
    log "Interrupted by $signal_name"

    if [[ -n "$ACTIVE_PROCESS_GROUP" ]] && kill -0 -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null; then
        kill -TERM -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null || true
        for ((i = 0; i < 4; i++)); do
            kill -0 -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null; then
            kill -KILL -- "-$ACTIVE_PROCESS_GROUP" 2>/dev/null || true
        fi
        wait "$ACTIVE_PROCESS_GROUP" 2>/dev/null || true
        ACTIVE_PROCESS_GROUP=""
    fi

    exit "$exit_code"
}

trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

# ---------------------------------------------------------------------------
# STATE / CHECKPOINTS
# ---------------------------------------------------------------------------

state_file() {
    printf '%s/%s.ok' "$STATE_DIR" "$1"
}

state_has() {
    local phase="$1" key="$2" f
    f="$(state_file "$phase")"
    [[ -f "$f" ]] && grep -Fqx -- "$key" "$f"
}

state_add() {
    local phase="$1" key="$2" f lock
    f="$(state_file "$phase")"
    lock="$LOCK_DIR/$phase.lock"
    touch "$f"
    (
        flock -x 9
        grep -Fqx -- "$key" "$f" 2>/dev/null || printf '%s\n' "$key" >> "$f"
    ) 9>"$lock"
}

state_remove() {
    local phase="$1" key="$2" f lock replacement grep_rc
    f="$(state_file "$phase")"
    lock="$LOCK_DIR/$phase.lock"
    [[ -f "$f" ]] || return 0

    (
        flock -x 9
        [[ -f "$f" ]] || exit 0
        replacement="$(mktemp -p "$STATE_DIR" ".${phase}.ok.XXXXXX")" || exit 1
        grep -Fvx -- "$key" "$f" > "$replacement"
        grep_rc=$?
        if [[ "$grep_rc" -gt 1 ]]; then
            rm -f -- "$replacement"
            exit 1
        fi
        mv -- "$replacement" "$f"
    ) 9>"$lock"
}

state_count() {
    local f
    f="$(state_file "$1")"
    if [[ ! -f "$f" ]]; then
        echo 0
        return 0
    fi
    sort -u "$f" | count_lines
}

count_lines() {
    local f="${1:-}"
    if [[ -n "$f" ]]; then
        if [[ ! -f "$f" ]]; then
            echo 0
            return 0
        fi
        awk 'END { print NR+0 }' "$f"
        return 0
    fi
    awk 'END { print NR+0 }'
}

tmp_file() {
    mktemp -p "$WORK_TMP" mig.XXXXXX
}

record_failure() {
    local phase="$1" key="$2" reason="$3" line
    line="$phase|$key|$reason"
    (
        flock -x 9
        touch "$REPORT_DIR/failures.txt"
        grep -Fqx -- "$line" "$REPORT_DIR/failures.txt" 2>/dev/null || \
            printf '%s\n' "$line" >> "$REPORT_DIR/failures.txt"
    ) 9>"$LOCK_DIR/failures.lock"
}

append_mailbox_size_report() {
    local user="$1" src="$2" dst="$3"
    (
        flock -x 9
        printf '%s|%s|%s|%s\n' \
            "$user" "$src" "$dst" "$(date '+%FT%T%z')" \
            >> "$REPORT_DIR/mailbox-sizes.raw"
    ) 9>"$LOCK_DIR/mailbox-sizes.lock"
}

parse_mailbox_size() {
    awk '
        {
            for (i=1;i<=NF;i++) {
                if ($i ~ /^[0-9]+$/) n=$i
            }
        }
        END { if (n != "") print n; else exit 1 }
    '
}

# ---------------------------------------------------------------------------
# SSH HELPERS
# ---------------------------------------------------------------------------

ssh_old() {
    # -n: do not read stdin. Without it, ssh consumes the caller's stdin
    # and breaks every `while read` loop that calls zmprov over SSH.
    ssh \
        -n \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=20 \
        -o Compression=no \
        "$OLD_SSH_USER@$OLD_HOST" "$@"
}

build_remote_cmd() {
    local out="" a q
    for a in "$@"; do
        printf -v q '%q' "$a"
        out+=" $q"
    done
    printf '%s' "$out"
}

remote_zmprov() {
    local args
    args="$(build_remote_cmd "$@")"
    ssh_old "/opt/zimbra/bin/zmprov$args"
}

remote_zmmailbox() {
    local args
    args="$(build_remote_cmd "$@")"
    ssh_old "/opt/zimbra/bin/zmmailbox$args"
}

# ---------------------------------------------------------------------------
# GENERIC HELPERS
# ---------------------------------------------------------------------------

trim_cr() {
    tr -d '\r'
}

safe_name() {
    local name="$1"
    name="${name//%/%25}"
    name="${name//\//%2F}"
    name="${name//:/%3A}"
    name="${name// /%20}"
    printf '%s' "$name"
}

attr_first() {
    local file="$1" attr="$2"
    [[ -f "$file" ]] || return 1
    awk -v a="$attr" '
        index($0, a ": ") == 1 {
            sub("^[^:]+:[[:space:]]*", "")
            print
            exit
        }
    ' "$file"
}

attr_values() {
    local file="$1" attr="$2"
    [[ -f "$file" ]] || return 1
    awk -v a="$attr" '
        index($0, a ": ") == 1 {
            sub("^[^:]+:[[:space:]]*", "")
            print
        }
    ' "$file"
}

bool_true() {
    [[ "${1^^}" == "TRUE" || "$1" == "1" || "${1,,}" == "yes" ]]
}

local_account_exists() {
    "$ZMPROV" -l ga "$1" >/dev/null 2>&1
}

local_domain_exists() {
    "$ZMPROV" -l gd "$1" >/dev/null 2>&1
}

local_cos_exists() {
    "$ZMPROV" -l gc "$1" >/dev/null 2>&1
}

local_dl_exists() {
    "$ZMPROV" -l gdl "$1" >/dev/null 2>&1
}

free_kb_for_path() {
    df -Pk "$1" | awk 'NR==2 {print $4}'
}

min_free_kb() {
    echo $(( MIN_FREE_GB * 1024 * 1024 ))
}

check_free_space() {
    local path="$1" label="$2" free required
    free="$(free_kb_for_path "$path")"
    required="$(min_free_kb)"
    if [[ -z "$free" || "$free" -lt "$required" ]]; then
        err "$label filesystem has less than ${MIN_FREE_GB} GiB free: $path"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------------------

validate_settings() {
    local name value

    if [[ ! "$MAILBOX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
        err "MAILBOX_PARALLEL must be a positive integer, got: $MAILBOX_PARALLEL"
        return 1
    fi
    if [[ ! "$MIN_FREE_GB" =~ ^[0-9]+$ ]]; then
        err "MIN_FREE_GB must be a non-negative integer, got: $MIN_FREE_GB"
        return 1
    fi

    for name in KEEP_ARCHIVES VERIFY_TGZ UI_VERBOSE; do
        value="${!name}"
        if [[ ! "$value" =~ ^[01]$ ]]; then
            err "$name must be 0 or 1, got: $value"
            return 1
        fi
    done

    for name in MIGRATE_ADMIN_ACCOUNTS MIGRATE_SYSTEM_ACCOUNTS; do
        value="${!name,,}"
        case "$value" in
            0|1|true|false|yes|no) ;;
            *)
                err "$name must be a boolean (0/1, true/false, yes/no), got: ${!name}"
                return 1
                ;;
        esac
    done

    if [[ -z "$OLD_HOST" || "$OLD_HOST" == *[[:space:]]* ]]; then
        err "OLD_HOST must be a non-empty host name or IP without whitespace."
        return 1
    fi
    if [[ -z "$OLD_SSH_USER" || "$OLD_SSH_USER" == *[[:space:]]* ]]; then
        err "OLD_SSH_USER must be a non-empty user name without whitespace."
        return 1
    fi
    MAILBOX_RESOLVE="${MAILBOX_RESOLVE,,}"
    case "$MAILBOX_RESOLVE" in
        skip|modify|reset|replace) ;;
        *)
            err "MAILBOX_RESOLVE must be skip, modify, reset, or replace; got: $MAILBOX_RESOLVE"
            return 1
            ;;
    esac
    return 0
}

preflight() {
    log "Running preflight checks"
    ui_phase "Preflight"

    validate_settings || return 1

    [[ "$(id -un)" == "zimbra" ]] || {
        err "Run this script as the zimbra user."
        return 1
    }

    for c in "$ZMPROV" "$ZMMAILBOX" "$ZMCONTROL"; do
        [[ -x "$c" ]] || {
            err "Required executable not found: $c"
            return 1
        }
    done

    for c in ssh awk sed grep sort sha256sum gzip flock xargs df mktemp openssl stat setsid sleep; do
        command -v "$c" >/dev/null 2>&1 || {
            err "Required command not found: $c"
            return 1
        }
    done

    if ! ensure_migration_dirs; then
        err "Cannot create or write migration directories: $MIG_ROOT"
        return 1
    fi
    ui_kv "data" "$MIG_ROOT"

    local ssh_err
    ssh_err="$(ssh_old 'printf OK' 2>&1)" || true
    if ! grep -q '^OK$' <<<"$ssh_err"; then
        err "Passwordless SSH to $OLD_SSH_USER@$OLD_HOST failed."
        [[ -n "$ssh_err" ]] && err "$ssh_err"
        return 1
    fi

    if ! ssh_old 'test -x /opt/zimbra/bin/zmprov -a -x /opt/zimbra/bin/zmmailbox'; then
        err "Remote host does not look like a usable Zimbra server."
        return 1
    fi

    local local_ver remote_ver local_host remote_host
    local_ver="$("$ZMCONTROL" -v 2>/dev/null || true)"
    remote_ver="$(ssh_old '/opt/zimbra/bin/zmcontrol -v' 2>/dev/null || true)"
    local_host="$("$ZMPROV" -l gas 2>/dev/null | head -n1 || true)"
    remote_host="$(ssh_old '/opt/zimbra/bin/zmhostname' 2>/dev/null || true)"

    log "Source host: ${remote_host:-$OLD_HOST}"
    log "Source version: ${remote_ver:-unknown}"
    log "Destination host: ${local_host:-unknown}"
    log "Destination version: ${local_ver:-unknown}"

    ui_kv "source" "${remote_host:-$OLD_HOST}  ${remote_ver:-unknown}"
    ui_kv "dest" "${local_host:-unknown}  ${local_ver:-unknown}"

    if [[ -n "$local_ver" && -n "$remote_ver" && "$local_ver" != "$remote_ver" ]]; then
        warn "Zimbra versions differ; test a few mailboxes before cutover."
    fi

    check_free_space "$STAGE_DIR" "Staging" || return 1

    if [[ -d /opt/zimbra/store ]]; then
        check_free_space /opt/zimbra/store "Zimbra store" || return 1
    fi

    log "Preflight checks passed"
    ui_ok "ready"
    return 0
}

# ---------------------------------------------------------------------------
# DISCOVERY
# ---------------------------------------------------------------------------

discover() {
    log "Discovering source Zimbra objects"
    ui_phase "Discover"

    # Invalidate the completion marker before refreshing inventory. A failed
    # refresh must never leave stale or partial discovery marked as usable.
    state_remove discover "COMPLETE" || return 1

    local domains_tmp cos_tmp accounts_tmp dls_tmp
    domains_tmp="$(tmp_file)"
    cos_tmp="$(tmp_file)"
    accounts_tmp="$(tmp_file)"
    dls_tmp="$(tmp_file)"

    if ! remote_zmprov -l gad 2>>"$LOG_DIR/migration.log" \
            | trim_cr | awk 'NF' | sort -u > "$domains_tmp"; then
        record_failure discover "domains" "INVENTORY_READ_FAILED"
        rm -f -- "$domains_tmp" "$cos_tmp" "$accounts_tmp" "$dls_tmp"
        return 1
    fi
    if ! remote_zmprov -l gac 2>>"$LOG_DIR/migration.log" \
            | trim_cr | awk 'NF' | sort -u > "$cos_tmp"; then
        record_failure discover "cos" "INVENTORY_READ_FAILED"
        rm -f -- "$domains_tmp" "$cos_tmp" "$accounts_tmp" "$dls_tmp"
        return 1
    fi
    if ! remote_zmprov -l gaa 2>>"$LOG_DIR/migration.log" \
            | trim_cr | awk 'NF' | sort -u > "$accounts_tmp"; then
        record_failure discover "accounts" "INVENTORY_READ_FAILED"
        rm -f -- "$domains_tmp" "$cos_tmp" "$accounts_tmp" "$dls_tmp"
        return 1
    fi
    if ! remote_zmprov -l gadl 2>>"$LOG_DIR/migration.log" \
            | trim_cr | awk 'NF' | sort -u > "$dls_tmp"; then
        record_failure discover "distribution-lists" "INVENTORY_READ_FAILED"
        rm -f -- "$domains_tmp" "$cos_tmp" "$accounts_tmp" "$dls_tmp"
        return 1
    fi

    if [[ ! -s "$domains_tmp" || ! -s "$cos_tmp" || ! -s "$accounts_tmp" ]]; then
        record_failure discover "inventory" "REQUIRED_INVENTORY_EMPTY"
        rm -f -- "$domains_tmp" "$cos_tmp" "$accounts_tmp" "$dls_tmp"
        return 1
    fi

    mv -- "$domains_tmp" "$DISCOVERY_DIR/domains.txt"
    mv -- "$cos_tmp" "$DISCOVERY_DIR/cos.txt"
    mv -- "$accounts_tmp" "$DISCOVERY_DIR/accounts-all.txt"
    mv -- "$dls_tmp" "$DISCOVERY_DIR/dls.txt"

    : > "$DISCOVERY_DIR/cos-map.txt"
    local failed=0
    while IFS= read -r cos; do
        [[ -z "$cos" ]] && continue
        local cid
        if cid="$(remote_zmprov -l gc "$cos" zimbraId 2>/dev/null | awk -F': ' '/^zimbraId:/ {print $2; exit}')" && \
                [[ -n "$cid" ]]; then
            printf '%s|%s\n' "$cid" "$cos" >> "$DISCOVERY_DIR/cos-map.txt"
        else
            record_failure discover "$cos" "COS_ID_READ_FAILED"
            failed=1
        fi
    done < "$DISCOVERY_DIR/cos.txt"

    # Build account migration list and mark source system/admin accounts.
    : > "$DISCOVERY_DIR/accounts.txt"
    : > "$DISCOVERY_DIR/accounts-skipped.txt"

    local n=0 total
    total="$(count_lines "$DISCOVERY_DIR/accounts-all.txt")"

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        n=$((n + 1))
        ui_progress "accounts" "$n" "$total"

        local sf dump is_admin is_system
        sf="$(safe_name "$user")"
        dump="$DUMP_DIR/accounts/$sf.ldap"

        if [[ ! -s "$dump" ]]; then
            remote_zmprov -l ga "$user" > "$dump.tmp" 2>>"$LOG_DIR/migration.log" || {
                rm -f "$dump.tmp"
                printf '%s|READ_FAILED\n' "$user" >> "$DISCOVERY_DIR/accounts-skipped.txt"
                record_failure discover "$user" "READ_FAILED"
                failed=1
                continue
            }
            mv "$dump.tmp" "$dump"
        fi

        is_admin="$(attr_first "$dump" zimbraIsAdminAccount)"
        is_system="$(attr_first "$dump" zimbraIsSystemResource)"

        if ! bool_true "$MIGRATE_ADMIN_ACCOUNTS" && bool_true "$is_admin"; then
            printf '%s|ADMIN_ACCOUNT\n' "$user" >> "$DISCOVERY_DIR/accounts-skipped.txt"
            continue
        fi

        if ! bool_true "$MIGRATE_SYSTEM_ACCOUNTS" && bool_true "$is_system"; then
            printf '%s|SYSTEM_RESOURCE\n' "$user" >> "$DISCOVERY_DIR/accounts-skipped.txt"
            continue
        fi

        # Additional well-known generated system mailbox local-parts.
        if ! bool_true "$MIGRATE_SYSTEM_ACCOUNTS"; then
            case "${user%%@*}" in
                galsync.*|spam.*|ham.*|virus-quarantine.*)
                    printf '%s|SYSTEM_GENERATED\n' "$user" >> "$DISCOVERY_DIR/accounts-skipped.txt"
                    continue
                    ;;
            esac
        fi

        printf '%s\n' "$user" >> "$DISCOVERY_DIR/accounts.txt"
    done < "$DISCOVERY_DIR/accounts-all.txt"
    ui_progress_end

    sort -u -o "$DISCOVERY_DIR/accounts.txt" "$DISCOVERY_DIR/accounts.txt"

    local n_dom n_cos n_acc n_skip n_dl
    n_dom="$(count_lines "$DISCOVERY_DIR/domains.txt")"
    n_cos="$(count_lines "$DISCOVERY_DIR/cos.txt")"
    n_acc="$(count_lines "$DISCOVERY_DIR/accounts.txt")"
    n_skip="$(count_lines "$DISCOVERY_DIR/accounts-skipped.txt")"
    n_dl="$(count_lines "$DISCOVERY_DIR/dls.txt")"
    log "Discovery complete: $n_dom domains, $n_cos COS, $n_acc migratable accounts, $n_dl DLs"
    ui_kv "domains" "$n_dom"
    ui_kv "cos" "$n_cos"
    ui_kv "accounts" "$n_acc"
    ui_kv "skipped" "$n_skip"
    ui_kv "dls" "$n_dl"
    [[ "$failed" == "0" ]] || return 1
    state_add discover "COMPLETE"
}

discovery_is_usable() {
    local all processed
    state_has discover "COMPLETE" || return 1
    [[ -s "$DISCOVERY_DIR/domains.txt" ]] || return 1
    [[ -s "$DISCOVERY_DIR/cos.txt" ]] || return 1
    [[ -f "$DISCOVERY_DIR/cos-map.txt" ]] || return 1
    [[ -f "$DISCOVERY_DIR/accounts.txt" ]] || return 1
    [[ -s "$DISCOVERY_DIR/accounts-all.txt" ]] || return 1
    [[ -f "$DISCOVERY_DIR/dls.txt" ]] || return 1

    [[ "$(count_lines "$DISCOVERY_DIR/cos-map.txt")" -eq "$(count_lines "$DISCOVERY_DIR/cos.txt")" ]] || return 1

    all="$(count_lines "$DISCOVERY_DIR/accounts-all.txt")"
    processed="$(( $(count_lines "$DISCOVERY_DIR/accounts.txt") + $(count_lines "$DISCOVERY_DIR/accounts-skipped.txt") ))"
    [[ "$all" -gt 0 && "$processed" -eq "$all" ]]
}

ensure_discovery() {
    if discovery_is_usable; then
        return 0
    fi
    if state_has discover "COMPLETE"; then
        warn "Discovery inventory is incomplete; re-running discovery"
    fi
    discover || return 1
}

# ---------------------------------------------------------------------------
# PORTABLE ATTRIBUTE COPY
# ---------------------------------------------------------------------------

is_forbidden_attr() {
    case "$1" in
        zimbraId|zimbraCreateTimestamp|zimbraLastLogonTimestamp|zimbraMailHost|\
        zimbraMailDeliveryAddress|zimbraMailAlias|zimbraMailSieveScript|\
        zimbraCOSId|zimbraDomainId|zimbraServerId|zimbraAuthTokenValidityValue|\
        zimbraPrefIdentityId|zimbraSignatureId|zimbraDataSourceId|\
        objectClass|entryCSN|entryUUID|creatorsName|modifiersName|createTimestamp|modifyTimestamp)
            return 0
            ;;
    esac
    return 1
}

account_attr_allowed() {
    local a="$1"
    is_forbidden_attr "$a" && return 1

    case "$a" in
        cn|displayName|givenName|sn|description|title|telephoneNumber|mobile|company|\
        street|l|st|postalCode|co|initials|middleName|\
        zimbraMailStatus|zimbraMailQuota|zimbraMailCanonicalAddress|\
        zimbraMailForwardingAddress|zimbraPasswordMustChange|zimbraPasswordLocked|\
        zimbraPref*|zimbraFeature*)
            return 0
            ;;
    esac
    return 1
}

cos_attr_allowed() {
    local a="$1"
    is_forbidden_attr "$a" && return 1
    [[ "$a" == zimbra* ]]
}

domain_attr_allowed() {
    local a="$1"
    is_forbidden_attr "$a" && return 1
    case "$a" in
        zimbraAuthMech|zimbraMailStatus|zimbraGalMode|\
        zimbraGalMaxResults|zimbraPrefTimeZoneId|zimbraVirtualHostname|\
        zimbraPublicServiceHostname|zimbraPublicServiceProtocol|zimbraPublicServicePort|\
        zimbraSkinLogoURL|zimbraSkinLogoLoginBanner|zimbraDomainMandatoryMailSignatureEnabled)
            return 0
            ;;
    esac
    return 1
}

dl_attr_allowed() {
    local a="$1"
    is_forbidden_attr "$a" && return 1
    case "$a" in
        displayName|description|zimbraHideInGal|zimbraMailStatus|\
        zimbraDistributionListSubscriptionPolicy|zimbraDistributionListUnsubscriptionPolicy|\
        zimbraDistributionListSendShareMessageToNewMembers|zimbraDistributionListSendShareMessageFromAddress)
            return 0
            ;;
    esac
    return 1
}

apply_grouped_attrs() {
    local object_type="$1" object_name="$2" dump="$3" logf="$4"
    local modify_cmd allow_fn failed=0

    case "$object_type" in
        account) modify_cmd="ma";  allow_fn="account_attr_allowed" ;;
        cos)     modify_cmd="mc";  allow_fn="cos_attr_allowed" ;;
        domain)  modify_cmd="md";  allow_fn="domain_attr_allowed" ;;
        dl)      modify_cmd="mdl"; allow_fn="dl_attr_allowed" ;;
        *) return 2 ;;
    esac

    if [[ ! -s "$dump" ]]; then
        warn "Skipping attributes for $object_type $object_name; dump missing: $dump"
        return 1
    fi

    local attrs_tmp
    attrs_tmp="$(tmp_file)"
    awk -F': ' '/^[A-Za-z0-9][A-Za-z0-9_-]*: / {print $1}' "$dump" | sort -u > "$attrs_tmp"

    local attr values_tmp first value
    while IFS= read -r attr; do
        "$allow_fn" "$attr" || continue

        values_tmp="$(tmp_file)"
        attr_values "$dump" "$attr" > "$values_tmp"
        [[ -s "$values_tmp" ]] || { rm -f "$values_tmp"; continue; }

        first="$(head -n1 "$values_tmp")"

        # Setting the first value resets the attribute, making reruns idempotent.
        if ! "$ZMPROV" "$modify_cmd" "$object_name" "$attr" "$first" >>"$logf" 2>&1; then
            warn "Could not set $object_type $object_name attribute $attr; continuing"
            failed=1
            rm -f "$values_tmp"
            continue
        fi

        while IFS= read -r value; do
            if ! "$ZMPROV" "$modify_cmd" "$object_name" "+$attr" "$value" >>"$logf" 2>&1; then
                warn "Could not add $object_type $object_name attribute $attr value; continuing"
                failed=1
            fi
        done < <(tail -n +2 "$values_tmp")

        rm -f "$values_tmp"
    done < "$attrs_tmp"

    rm -f "$attrs_tmp"
    return "$failed"
}

# ---------------------------------------------------------------------------
# DOMAINS
# ---------------------------------------------------------------------------

ensure_domain_dump() {
    local domain="$1" dump="$2"
    if [[ -s "$dump" ]]; then
        return 0
    fi
    remote_zmprov -l gd "$domain" > "$dump.tmp" 2>>"$LOG_DIR/migration.log" || {
        rm -f "$dump.tmp"
        return 1
    }
    mv "$dump.tmp" "$dump"
}

migrate_domains() {
    ensure_discovery || return 1
    log "Migrating domains"
    ui_phase "Domains"

    # Build source domain ID -> domain name map for alias-domain resolution.
    local dmap="$DISCOVERY_DIR/domain-map.txt"
    : > "$dmap"

    local domain dump did dtype failed=0
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        dump="$DUMP_DIR/domain.$(safe_name "$domain").ldap"
        ensure_domain_dump "$domain" "$dump" || continue
        did="$(attr_first "$dump" zimbraId)"
        [[ -n "$did" ]] && printf '%s|%s\n' "$did" "$domain" >> "$dmap"
    done < "$DISCOVERY_DIR/domains.txt"

    # Real domains first.
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        dump="$DUMP_DIR/domain.$(safe_name "$domain").ldap"
        # A prior run may have checkpointed a domain before its dump existed.
        if state_has domains "$domain" && [[ -s "$dump" ]]; then
            continue
        fi
        if ! ensure_domain_dump "$domain" "$dump"; then
            warn "Cannot read source domain: $domain"
            record_failure domains "$domain" "READ_FAILED"
            failed=1
            continue
        fi
        dtype="$(attr_first "$dump" zimbraDomainType)"

        if [[ "${dtype,,}" == "alias" ]]; then
            continue
        fi

        if local_domain_exists "$domain"; then
            ui_note "DOMAIN EXISTS: $domain"
        else
            if "$ZMPROV" -l cd "$domain" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "DOMAIN CREATED: $domain"
            else
                err "Domain creation failed: $domain"
                record_failure domains "$domain" "CREATE_FAILED"
                failed=1
                continue
            fi
        fi

        if ! apply_grouped_attrs domain "$domain" "$dump" "$LOG_DIR/migration.log"; then
            record_failure domains "$domain" "ATTRIBUTE_APPLY_FAILED"
            failed=1
            continue
        fi
        state_add domains "$domain"
    done < "$DISCOVERY_DIR/domains.txt"

    # Alias domains after targets exist.
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        dump="$DUMP_DIR/domain.$(safe_name "$domain").ldap"
        if state_has domains "$domain" && [[ -s "$dump" ]]; then
            continue
        fi
        if ! ensure_domain_dump "$domain" "$dump"; then
            record_failure domains "$domain" "READ_FAILED"
            failed=1
            continue
        fi
        dtype="$(attr_first "$dump" zimbraDomainType)"
        [[ "${dtype,,}" == "alias" ]] || continue

        local tid target
        tid="$(attr_first "$dump" zimbraDomainAliasTargetId)"
        target="$(awk -F'|' -v id="$tid" '$1==id {print $2; exit}' "$dmap")"

        if [[ -z "$target" ]]; then
            warn "Cannot resolve alias domain target for $domain; skipped"
            record_failure domains "$domain" "ALIAS_TARGET_UNRESOLVED"
            failed=1
            continue
        fi

        if local_domain_exists "$domain"; then
            ui_note "ALIAS DOMAIN EXISTS: $domain"
        else
            if "$ZMPROV" -l cad "$domain" "$target" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "ALIAS DOMAIN CREATED: $domain -> $target"
            else
                err "Alias domain creation failed: $domain -> $target"
                record_failure domains "$domain" "ALIAS_CREATE_FAILED"
                failed=1
                continue
            fi
        fi

        state_add domains "$domain"
    done < "$DISCOVERY_DIR/domains.txt"

    ui_ratio "domains" "$(state_count domains)" "$(count_lines "$DISCOVERY_DIR/domains.txt")"
    return "$failed"
}

# ---------------------------------------------------------------------------
# COS
# ---------------------------------------------------------------------------

migrate_cos() {
    ensure_discovery || return 1
    log "Migrating COS"
    ui_phase "COS"

    local cos dump failed=0
    while IFS= read -r cos; do
        [[ -z "$cos" ]] && continue
        state_has cos "$cos" && continue

        dump="$DUMP_DIR/cos.$(safe_name "$cos").ldap"
        remote_zmprov -l gc "$cos" > "$dump.tmp" 2>>"$LOG_DIR/migration.log" || {
            rm -f -- "$dump.tmp"
            err "Cannot read source COS: $cos"
            record_failure cos "$cos" "READ_FAILED"
            failed=1
            continue
        }
        mv -- "$dump.tmp" "$dump"

        if local_cos_exists "$cos"; then
            ui_note "COS EXISTS: $cos"
        else
            if "$ZMPROV" -l cc "$cos" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "COS CREATED: $cos"
            else
                err "COS creation failed: $cos"
                record_failure cos "$cos" "CREATE_FAILED"
                failed=1
                continue
            fi
        fi

        if ! apply_grouped_attrs cos "$cos" "$dump" "$LOG_DIR/migration.log"; then
            record_failure cos "$cos" "ATTRIBUTE_APPLY_FAILED"
            failed=1
            continue
        fi
        state_add cos "$cos"
    done < "$DISCOVERY_DIR/cos.txt"

    ui_ratio "cos" "$(state_count cos)" "$(count_lines "$DISCOVERY_DIR/cos.txt")"
    return "$failed"
}

# ---------------------------------------------------------------------------
# ACCOUNTS + PASSWORDS + COS
# ---------------------------------------------------------------------------

account_dump_path() {
    printf '%s/accounts/%s.ldap' "$DUMP_DIR" "$(safe_name "$1")"
}

ensure_account_dump() {
    local user="$1" dump
    dump="$(account_dump_path "$user")"
    if [[ ! -s "$dump" ]]; then
        remote_zmprov -l ga "$user" > "$dump.tmp" 2>>"$LOG_DIR/migration.log" || {
            rm -f "$dump.tmp"
            return 1
        }
        mv "$dump.tmp" "$dump"
    fi
}

migrate_one_account() {
    local user="$1" dump password cn display given sn old_cos_id cos_name tmp_pass
    state_has accounts "$user" && return 0

    ensure_account_dump "$user" || {
        err "Cannot read source account: $user"
        record_failure accounts "$user" "READ_FAILED"
        return 1
    }
    dump="$(account_dump_path "$user")"

    password="$(attr_first "$dump" userPassword)"
    cn="$(attr_first "$dump" cn)"
    display="$(attr_first "$dump" displayName)"
    given="$(attr_first "$dump" givenName)"
    sn="$(attr_first "$dump" sn)"
    old_cos_id="$(attr_first "$dump" zimbraCOSId)"
    cos_name="$(awk -F'|' -v id="$old_cos_id" '$1==id {print $2; exit}' "$DISCOVERY_DIR/cos-map.txt")"

    if local_account_exists "$user"; then
        ui_note "ACCOUNT EXISTS: $user"
    else
        tmp_pass="Migrate-$(openssl rand -hex 24)"
        local -a ca_args
        ca_args=(ca "$user" "$tmp_pass"
                 cn "${cn:-${user%%@*}}"
                 displayName "${display:-${cn:-${user%%@*}}}")
        [[ -n "$given" ]] && ca_args+=(givenName "$given")
        [[ -n "$sn" ]] && ca_args+=(sn "$sn")

        if "$ZMPROV" "${ca_args[@]}" >>"$LOG_DIR/migration.log" 2>&1
        then
            ui_note "ACCOUNT CREATED: $user"
        else
            err "Account creation failed: $user"
            record_failure accounts "$user" "CREATE_FAILED"
            return 1
        fi
    fi

    # Restore hash without printing it or writing it to the migration log.
    if [[ -n "$password" ]]; then
        if ! "$ZMPROV" ma "$user" userPassword "$password" >/dev/null 2>&1; then
            warn "Password hash restore failed: $user"
            record_failure accounts "$user" "PASSWORD_RESTORE_FAILED"
            return 1
        fi
    fi

    if [[ -n "$old_cos_id" && -z "$cos_name" ]]; then
        warn "Source COS could not be resolved: $user -> $old_cos_id"
        record_failure accounts "$user" "COS_RESOLUTION_FAILED"
        return 1
    fi

    if [[ -n "$cos_name" ]]; then
        if ! local_cos_exists "$cos_name"; then
            warn "Destination COS is missing: $user -> $cos_name"
            record_failure accounts "$user" "DEST_COS_MISSING"
            return 1
        fi
        if ! "$ZMPROV" sac "$user" "$cos_name" >>"$LOG_DIR/migration.log" 2>&1; then
            warn "COS assignment failed: $user -> $cos_name"
            record_failure accounts "$user" "COS_ASSIGNMENT_FAILED"
            return 1
        fi
    fi

    state_add accounts "$user"
    return 0
}

migrate_accounts() {
    ensure_discovery || return 1
    log "Migrating accounts/passwords/COS assignments"
    ui_phase "Accounts"

    local user n=0 total failed=0 fail_n=0
    total="$(count_lines "$DISCOVERY_DIR/accounts.txt")"

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ -n "$ONLY_USER" && "$user" != "$ONLY_USER" ]] && continue
        n=$((n + 1))
        log "ACCOUNT [$n/$total]: $user"
        ui_progress "accounts" "$n" "$total"
        if ! migrate_one_account "$user"; then
            failed=1
            fail_n=$((fail_n + 1))
        fi
    done < "$DISCOVERY_DIR/accounts.txt"
    ui_progress_end

    if [[ "$fail_n" -gt 0 ]]; then
        ui_ratio "accounts" "$(state_count accounts)" "$total" "${fail_n} failed"
    else
        ui_ratio "accounts" "$(state_count accounts)" "$total"
    fi
    return "$failed"
}

# ---------------------------------------------------------------------------
# ACCOUNT PORTABLE ATTRIBUTES / PREFS / FORWARDING
# ---------------------------------------------------------------------------

migrate_attrs() {
    ensure_discovery || return 1
    log "Migrating portable account attributes/preferences/forwarding"
    ui_phase "Attributes"

    local user dump n=0 total failed=0
    total="$(count_lines "$DISCOVERY_DIR/accounts.txt")"
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ -n "$ONLY_USER" && "$user" != "$ONLY_USER" ]] && continue
        n=$((n + 1))
        ui_progress "attrs" "$n" "$total"
        state_has attrs "$user" && continue
        if ! local_account_exists "$user"; then
            record_failure attrs "$user" "DEST_ACCOUNT_MISSING"
            failed=1
            continue
        fi

        if ! ensure_account_dump "$user"; then
            record_failure attrs "$user" "READ_FAILED"
            failed=1
            continue
        fi
        dump="$(account_dump_path "$user")"

        if ! apply_grouped_attrs account "$user" "$dump" "$LOG_DIR/migration.log"; then
            record_failure attrs "$user" "ATTRIBUTE_APPLY_FAILED"
            failed=1
            continue
        fi
        state_add attrs "$user"
        ui_note "ATTRS OK: $user"
    done < "$DISCOVERY_DIR/accounts.txt"
    ui_progress_end
    ui_ratio "attrs" "$(state_count attrs)" "$total"
    return "$failed"
}

# ---------------------------------------------------------------------------
# ACCOUNT ALIASES
# ---------------------------------------------------------------------------

migrate_aliases() {
    ensure_discovery || return 1
    log "Migrating account aliases"
    ui_phase "Aliases"

    local user dump alias local_dump n=0 total failed=0
    total="$(count_lines "$DISCOVERY_DIR/accounts.txt")"
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ -n "$ONLY_USER" && "$user" != "$ONLY_USER" ]] && continue
        n=$((n + 1))
        ui_progress "aliases" "$n" "$total"
        if ! local_account_exists "$user"; then
            record_failure aliases "$user" "DEST_ACCOUNT_MISSING"
            failed=1
            continue
        fi

        if ! ensure_account_dump "$user"; then
            record_failure aliases "$user" "READ_FAILED"
            failed=1
            continue
        fi
        dump="$(account_dump_path "$user")"
        local_dump="$(tmp_file)"
        if ! "$ZMPROV" -l ga "$user" zimbraMailAlias > "$local_dump" 2>>"$LOG_DIR/migration.log"; then
            warn "Cannot read destination aliases: $user"
            record_failure aliases "$user" "DEST_ALIAS_READ_FAILED"
            failed=1
            rm -f -- "$local_dump"
            continue
        fi

        while IFS= read -r alias; do
            [[ -z "$alias" ]] && continue
            local key="$user|$alias"
            state_has aliases "$key" && continue

            if grep -Fqx "zimbraMailAlias: $alias" "$local_dump"; then
                state_add aliases "$key"
                continue
            fi

            if "$ZMPROV" aaa "$user" "$alias" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "ALIAS ADDED: $alias -> $user"
                state_add aliases "$key"
            else
                warn "Alias could not be added (possibly already in use): $alias -> $user"
                record_failure aliases "$key" "ADD_FAILED"
                failed=1
            fi
        done < <(attr_values "$dump" zimbraMailAlias)

        rm -f "$local_dump"
    done < "$DISCOVERY_DIR/accounts.txt"
    ui_progress_end
    ui_ratio "aliases" "$(state_count aliases)"
    return "$failed"
}

# ---------------------------------------------------------------------------
# SIEVE FILTERS
# ---------------------------------------------------------------------------

fetch_remote_sieve() {
    local user="$1" outfile="$2"
    remote_zmprov -l ga "$user" zimbraMailSieveScript 2>>"$LOG_DIR/migration.log" | \
        awk '
            BEGIN { p=0 }
            /^zimbraMailSieveScript: / {
                sub(/^zimbraMailSieveScript:[[:space:]]*/, "")
                print
                p=1
                next
            }
            p { print }
        ' > "$outfile"
}

migrate_filters() {
    ensure_discovery || return 1
    log "Migrating Sieve filters"
    ui_phase "Filters"

    local user f hash key n=0 total failed=0
    total="$(count_lines "$DISCOVERY_DIR/accounts.txt")"
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ -n "$ONLY_USER" && "$user" != "$ONLY_USER" ]] && continue
        n=$((n + 1))
        ui_progress "filters" "$n" "$total"
        if ! local_account_exists "$user"; then
            record_failure filters "$user" "DEST_ACCOUNT_MISSING"
            failed=1
            continue
        fi

        f="$DUMP_DIR/filter.$(safe_name "$user").sieve"
        if ! fetch_remote_sieve "$user" "$f.tmp"; then
            rm -f "$f.tmp"
            warn "Cannot read filter: $user"
            record_failure filters "$user" "READ_FAILED"
            failed=1
            continue
        fi

        if [[ ! -s "$f.tmp" ]]; then
            rm -f "$f.tmp"
            continue
        fi

        mv "$f.tmp" "$f"
        hash="$(sha256sum "$f" | awk '{print $1}')"
        key="$user|$hash"

        state_has filters "$key" && continue

        if "$ZMPROV" ma "$user" zimbraMailSieveScript "$(<"$f")" >>"$LOG_DIR/migration.log" 2>&1; then
            ui_note "FILTER OK: $user"
            state_add filters "$key"
        else
            warn "Filter restore failed: $user"
            record_failure filters "$user" "RESTORE_FAILED"
            failed=1
        fi
    done < "$DISCOVERY_DIR/accounts.txt"
    ui_progress_end
    ui_ratio "filters" "$(state_count filters)"
    return "$failed"
}

# ---------------------------------------------------------------------------
# DISTRIBUTION LISTS
# ---------------------------------------------------------------------------

migrate_dl() {
    ensure_discovery || return 1
    log "Migrating distribution lists and members"
    ui_phase "Distribution lists"

    local dl dump alias member local_members source_members batch failed=0
    while IFS= read -r dl; do
        [[ -z "$dl" ]] && continue
        state_has dl "$dl" && continue

        dump="$DUMP_DIR/dl.$(safe_name "$dl").ldap"
        remote_zmprov -l gdl "$dl" > "$dump.tmp" 2>>"$LOG_DIR/migration.log" || {
            rm -f -- "$dump.tmp"
            warn "Cannot read source DL: $dl"
            record_failure dl "$dl" "READ_FAILED"
            failed=1
            continue
        }
        mv -- "$dump.tmp" "$dump"

        if ! local_dl_exists "$dl"; then
            if "$ZMPROV" cdl "$dl" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "DL CREATED: $dl"
            else
                err "DL creation failed: $dl"
                record_failure dl "$dl" "CREATE_FAILED"
                failed=1
                continue
            fi
        fi

        local object_ok=1
        if ! apply_grouped_attrs dl "$dl" "$dump" "$LOG_DIR/migration.log"; then
            record_failure dl "$dl" "ATTRIBUTE_APPLY_FAILED"
            object_ok=0
            failed=1
        fi

        # DL aliases
        local local_dl_dump
        local_dl_dump="$(tmp_file)"
        if ! "$ZMPROV" -l gdl "$dl" > "$local_dl_dump" 2>>"$LOG_DIR/migration.log"; then
            warn "Cannot read destination DL aliases: $dl"
            record_failure dl "$dl" "DEST_ALIAS_READ_FAILED"
            failed=1
            rm -f -- "$local_dl_dump"
            continue
        fi

        while IFS= read -r alias; do
            [[ -z "$alias" ]] && continue
            if grep -Fqx "zimbraMailAlias: $alias" "$local_dl_dump"; then
                continue
            fi
            if "$ZMPROV" adla "$dl" "$alias" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "DL ALIAS: $alias -> $dl"
            else
                warn "DL alias failed: $alias -> $dl"
                record_failure dl "$dl|$alias" "ALIAS_ADD_FAILED"
                object_ok=0
                failed=1
            fi
        done < <(attr_values "$dump" zimbraMailAlias)
        rm -f "$local_dl_dump"

        # Existing local members once.
        local_members="$(tmp_file)"
        if ! "$ZMPROV" gdlm "$dl" 2>>"$LOG_DIR/migration.log" | trim_cr | \
                awk '!/^[[:space:]]*(#|$)/ && /@/' | sort -u > "$local_members"; then
            warn "Cannot read destination DL members: $dl"
            record_failure dl "$dl" "DEST_MEMBER_READ_FAILED"
            failed=1
            rm -f -- "$local_members"
            continue
        fi

        source_members="$(tmp_file)"
        if ! remote_zmprov gdlm "$dl" 2>>"$LOG_DIR/migration.log" | trim_cr | \
                awk '!/^[[:space:]]*(#|$)/ && /@/' | sort -u > "$source_members"; then
            warn "Cannot read source DL members: $dl"
            record_failure dl "$dl" "MEMBER_READ_FAILED"
            failed=1
            rm -f -- "$local_members" "$source_members"
            continue
        fi

        batch="$(tmp_file)"
        : > "$batch"
        local members_ok=1

        while IFS= read -r member; do
            [[ -z "$member" ]] && continue
            if [[ ! "$member" =~ ^[^[:space:]]+@[^[:space:]]+$ ]]; then
                warn "Skipping malformed DL member: $dl -> $member"
                record_failure dl "$dl" "INVALID_MEMBER"
                object_ok=0
                failed=1
                continue
            fi
            if grep -Fqx -- "$member" "$local_members"; then
                continue
            fi
            if [[ "$dl" =~ ^[[:alnum:]._%+@-]+$ && "$member" =~ ^[[:alnum:]._%+@-]+$ ]]; then
                printf 'adlm %s %s\n' "$dl" "$member" >> "$batch"
            elif ! "$ZMPROV" adlm "$dl" "$member" >>"$LOG_DIR/migration.log" 2>&1; then
                warn "DL member addition failed: $dl -> $member"
                record_failure dl "$dl" "MEMBER_ADD_FAILED"
                members_ok=0
                failed=1
            fi
        done < "$source_members"

        if [[ -s "$batch" ]]; then
            if "$ZMPROV" -f "$batch" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "DL MEMBERS OK: $dl ($(count_lines "$batch") added)"
            else
                warn "One or more DL member additions failed: $dl"
                record_failure dl "$dl" "MEMBER_ADD_FAILED"
                members_ok=0
                failed=1
            fi
        fi

        rm -f "$batch" "$local_members" "$source_members"
        if [[ "$members_ok" == "1" && "$object_ok" == "1" ]]; then
            state_add dl "$dl"
        fi
    done < "$DISCOVERY_DIR/dls.txt"

    ui_ratio "dls" "$(state_count dl)" "$(count_lines "$DISCOVERY_DIR/dls.txt")"
    return "$failed"
}

# ---------------------------------------------------------------------------
# MAILBOX MIGRATION
# ---------------------------------------------------------------------------

source_mailbox_size() {
    remote_zmmailbox -z -m "$1" -t 0 gms 2>/dev/null | parse_mailbox_size
}

destination_mailbox_size() {
    "$ZMMAILBOX" -z -m "$1" -t 0 gms 2>/dev/null | parse_mailbox_size
}

migrate_mailbox_worker() {
    local user="$1"
    local sf archive partial mlog remote_args rc src_size dst_size

    sf="$(safe_name "$user")"
    archive="$STAGE_DIR/$sf.tgz"
    partial="$STAGE_DIR/$sf.tgz.part"
    mlog="$LOG_DIR/mailboxes/$sf.log"

    if [[ "$DELTA_MODE" != "1" ]] && state_has mailboxes "$user"; then
        log "SKIP: $user"
        mbox_tick skip "$user"
        return 0
    fi

    # Remove the previous bulk/delta checkpoint before starting a new delta.
    # An interrupted or failed delta must remain visible as incomplete.
    if [[ "$DELTA_MODE" == "1" ]] && ! state_remove mailboxes "$user"; then
        log "FAILED: $user - checkpoint invalidation"
        record_failure mailboxes "$user" "CHECKPOINT_INVALIDATION_FAILED"
        mbox_tick fail "$user" "checkpoint update"
        return 1
    fi

    if ! local_account_exists "$user"; then
        log "NOUSER: $user"
        record_failure mailboxes "$user" "DEST_ACCOUNT_MISSING"
        mbox_tick fail "$user" "account missing"
        return 1
    fi

    # Delta must never reuse a stale cached archive.
    if [[ "$DELTA_MODE" == "1" ]]; then
        rm -f "$archive" "$partial"
    fi

    if [[ ! -s "$archive" ]]; then
        check_free_space "$STAGE_DIR" "Staging" || {
            log "NOSPACE: $user"
            record_failure mailboxes "$user" "NOSPACE"
            mbox_tick fail "$user" "no space"
            return 1
        }

        printf '[%s] export start\n' "$(ts)" >> "$mlog"
        rm -f "$partial"

        remote_args="$(build_remote_cmd \
            -z -m "$user" -t 0 \
            getRestURL '//?fmt=tgz&meta=1&query=is:anywhere')"

        if ! ssh_old "/opt/zimbra/bin/zmmailbox$remote_args" \
                > "$partial" 2>>"$mlog"
        then
            log "FAILED: $user - source export/SSH"
            record_failure mailboxes "$user" "EXPORT_FAILED"
            mbox_tick fail "$user" "export/SSH"
            rm -f "$partial"
            return 1
        fi

        if [[ ! -s "$partial" ]]; then
            log "FAILED: $user - zero-byte export"
            record_failure mailboxes "$user" "EMPTY_EXPORT"
            mbox_tick fail "$user" "empty export"
            rm -f "$partial"
            return 1
        fi

        if [[ "$VERIFY_TGZ" == "1" ]]; then
            if ! gzip -t "$partial" 2>>"$mlog"; then
                log "CORRUPT: $user"
                record_failure mailboxes "$user" "CORRUPT_TGZ"
                mbox_tick fail "$user" "corrupt tgz"
                rm -f "$partial"
                return 1
            fi
        fi

        mv "$partial" "$archive"
        printf '[%s] export complete bytes=%s\n' "$(ts)" "$(stat -c %s "$archive" 2>/dev/null || echo 0)" >> "$mlog"
    else
        log "CACHED: $user"
        if [[ "$VERIFY_TGZ" == "1" ]] && ! gzip -t "$archive" 2>>"$mlog"; then
            log "CORRUPT: $user - cached archive"
            record_failure mailboxes "$user" "CORRUPT_CACHED_TGZ"
            mbox_tick fail "$user" "corrupt cached tgz"
            rm -f -- "$archive"
            return 1
        fi
    fi

    "$ZMMAILBOX" \
        -z -m "$user" -t 0 \
        postRestURL "//?fmt=tgz&resolve=$MAILBOX_RESOLVE" "$archive" \
        >>"$mlog" 2>&1
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
        if ! src_size="$(source_mailbox_size "$user")"; then
            src_size=""
            log "SIZE WARNING: $user - source size unavailable"
        fi
        if ! dst_size="$(destination_mailbox_size "$user")"; then
            dst_size=""
            log "SIZE WARNING: $user - destination size unavailable"
        fi

        append_mailbox_size_report "$user" "$src_size" "$dst_size"

        state_add mailboxes "$user"

        if [[ "$KEEP_ARCHIVES" != "1" ]]; then
            rm -f "$archive"
        fi

        log "OK: $user"
        mbox_tick ok "$user"
        return 0
    fi

    log "FAILED: $user - import rc=$rc (archive kept)"
    record_failure mailboxes "$user" "IMPORT_FAILED"
    mbox_tick fail "$user" "import rc=$rc"
    # xargs treats 255 as a request to abort the entire queue. Normalize all
    # mailbox failures to 1 so every queued mailbox still gets a chance to run.
    return 1
}

export -f ts _log_line log warn err ui_break_progress ui_ok ui_warn ui_err \
          ui_note ui_progress mbox_tick \
          state_file state_has state_add state_remove \
          ssh_old build_remote_cmd remote_zmmailbox \
          safe_name local_account_exists check_free_space \
          free_kb_for_path min_free_kb source_mailbox_size \
          destination_mailbox_size migrate_mailbox_worker \
          count_lines tmp_file record_failure append_mailbox_size_report \
          parse_mailbox_size

export OLD_HOST OLD_SSH_USER ZMPROV ZMMAILBOX \
       STATE_DIR STAGE_DIR LOG_DIR REPORT_DIR LOCK_DIR WORK_TMP \
       MAILBOX_RESOLVE KEEP_ARCHIVES VERIFY_TGZ MIN_FREE_GB DELTA_MODE

migrate_mailboxes() {
    ensure_discovery || return 1
    log "Migrating mailbox contents with $MAILBOX_PARALLEL parallel workers (delta=$DELTA_MODE)"
    ui_phase "Mailboxes"
    ui_kv "workers" "$MAILBOX_PARALLEL"
    [[ "$DELTA_MODE" == "1" ]] && ui_kv "mode" "delta"
    mbox_tick_reset

    local queue user
    queue="$(tmp_file)"

    if [[ -n "$ONLY_USER" ]]; then
        if grep -Fqx -- "$ONLY_USER" "$DISCOVERY_DIR/accounts.txt"; then
            printf '%s\0' "$ONLY_USER" > "$queue"
        else
            err "Requested user not found in source migration list: $ONLY_USER"
            rm -f "$queue"
            return 1
        fi
    else
        while IFS= read -r user; do
            [[ -z "$user" ]] && continue
            printf '%s\0' "$user"
        done < "$DISCOVERY_DIR/accounts.txt" > "$queue"
    fi

    # A dedicated process group lets Ctrl+C stop xargs, workers, SSH, and
    # zmmailbox descendants together instead of leaving orphaned transfers.
    # $1 is expanded by the worker shell.
    # shellcheck disable=SC2016
    setsid xargs -0 -r -P "$MAILBOX_PARALLEL" -n 1 \
        bash -c 'migrate_mailbox_worker "$1"' _ < "$queue" &
    ACTIVE_PROCESS_GROUP=$!

    local rc
    wait "$ACTIVE_PROCESS_GROUP"
    rc=$?
    ACTIVE_PROCESS_GROUP=""
    rm -f "$queue"
    printf '\n'
    local ok fail extra=""
    ok="$(count_lines "$WORK_TMP/mbox.ok")"
    fail="$(count_lines "$WORK_TMP/mbox.fail")"
    [[ "$fail" != "0" ]] && extra="${fail} failed"
    ui_ratio "mailboxes" "$(state_count mailboxes)" "$(count_lines "$DISCOVERY_DIR/accounts.txt")" "$extra"
    log "Mailbox workers: ${ok} ok, ${fail} failed"
    return "$rc"
}

# ---------------------------------------------------------------------------
# FINALIZE ACCOUNT AND DOMAIN STATUS
# ---------------------------------------------------------------------------

finalize_accounts() {
    ensure_discovery || return 1
    log "Restoring final account status values"
    ui_phase "Finalize"

    local user dump status n=0 total failed=0
    total="$(count_lines "$DISCOVERY_DIR/accounts.txt")"
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ -n "$ONLY_USER" && "$user" != "$ONLY_USER" ]] && continue
        n=$((n + 1))
        ui_progress "finalize" "$n" "$total"
        state_has finalize "$user" && continue
        if ! local_account_exists "$user"; then
            record_failure finalize "$user" "DEST_ACCOUNT_MISSING"
            failed=1
            continue
        fi

        if ! ensure_account_dump "$user"; then
            record_failure finalize "$user" "READ_FAILED"
            failed=1
            continue
        fi
        dump="$(account_dump_path "$user")"
        status="$(attr_first "$dump" zimbraAccountStatus)"

        if [[ -n "$status" ]]; then
            if "$ZMPROV" ma "$user" zimbraAccountStatus "$status" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "FINAL STATUS: $user -> $status"
                state_add finalize "$user"
            else
                warn "Could not restore account status: $user -> $status"
                record_failure finalize "$user" "STATUS_RESTORE_FAILED"
                failed=1
            fi
        else
            state_add finalize "$user"
        fi
    done < "$DISCOVERY_DIR/accounts.txt"
    ui_progress_end
    ui_ratio "finalize" "$(state_count finalize)" "$total"

    # A targeted retry or a full run with an earlier failure must not finalize
    # domains before the rest of the tenant has completed.
    if [[ -n "$ONLY_USER" || "$DEFER_DOMAIN_STATUS" == "1" ]]; then
        [[ "$DEFER_DOMAIN_STATUS" == "1" ]] && \
            warn "Domain status restore deferred because earlier phases failed"
        return "$failed"
    fi

    # A suspended/shutdown domain can reject account and DL mutations. Restore
    # domain status only after every account-related operation has finished.
    local domain domain_dump domain_status domain_failed=0 domain_total
    domain_total="$(count_lines "$DISCOVERY_DIR/domains.txt")"
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        state_has domain_status "$domain" && continue
        if ! state_has domains "$domain"; then
            record_failure finalize "$domain" "DOMAIN_NOT_READY"
            domain_failed=1
            continue
        fi

        domain_dump="$DUMP_DIR/domain.$(safe_name "$domain").ldap"
        if ! ensure_domain_dump "$domain" "$domain_dump"; then
            record_failure finalize "$domain" "DOMAIN_READ_FAILED"
            domain_failed=1
            continue
        fi
        domain_status="$(attr_first "$domain_dump" zimbraDomainStatus)"

        if [[ -n "$domain_status" ]]; then
            if "$ZMPROV" md "$domain" zimbraDomainStatus "$domain_status" >>"$LOG_DIR/migration.log" 2>&1; then
                ui_note "FINAL DOMAIN STATUS: $domain -> $domain_status"
                state_add domain_status "$domain"
            else
                warn "Could not restore domain status: $domain -> $domain_status"
                record_failure finalize "$domain" "DOMAIN_STATUS_RESTORE_FAILED"
                domain_failed=1
            fi
        else
            state_add domain_status "$domain"
        fi
    done < "$DISCOVERY_DIR/domains.txt"
    ui_ratio "domain status" "$(state_count domain_status)" "$domain_total"

    [[ "$domain_failed" == "0" ]] || failed=1
    return "$failed"
}

# ---------------------------------------------------------------------------
# VERIFY / REPORT
# ---------------------------------------------------------------------------

verify() {
    ensure_discovery || return 1
    log "Building verification report"
    ui_phase "Verify"

    local report="$REPORT_DIR/verification.csv"
    printf 'account,source_mailbox_bytes,destination_mailbox_bytes,status\n' > "$report"

    local user src dst status failed=0 src_ok dst_ok
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ -n "$ONLY_USER" && "$user" != "$ONLY_USER" ]] && continue

        if ! local_account_exists "$user"; then
            printf '%s,0,0,DEST_ACCOUNT_MISSING\n' "$user" >> "$report"
            record_failure verify "$user" "DEST_ACCOUNT_MISSING"
            failed=1
            continue
        fi

        src_ok=1
        dst_ok=1
        if ! src="$(source_mailbox_size "$user")"; then
            src=""
            src_ok=0
        fi
        if ! dst="$(destination_mailbox_size "$user")"; then
            dst=""
            dst_ok=0
        fi

        status="CHECK"
        if state_has mailboxes "$user"; then
            status="IMPORTED"
        else
            record_failure verify "$user" "MAILBOX_NOT_IMPORTED"
            failed=1
        fi

        if [[ "$src_ok" == "0" && "$dst_ok" == "0" ]]; then
            status="SOURCE_AND_DEST_SIZE_UNAVAILABLE"
            record_failure verify "$user" "SOURCE_AND_DEST_SIZE_UNAVAILABLE"
            failed=1
        elif [[ "$src_ok" == "0" ]]; then
            status="SOURCE_SIZE_UNAVAILABLE"
            record_failure verify "$user" "SOURCE_SIZE_UNAVAILABLE"
            failed=1
        elif [[ "$dst_ok" == "0" ]]; then
            status="DEST_SIZE_UNAVAILABLE"
            record_failure verify "$user" "DEST_SIZE_UNAVAILABLE"
            failed=1
        elif [[ "${src:-0}" -gt 0 && "${dst:-0}" -eq 0 ]]; then
            status="WARNING_DEST_EMPTY"
            record_failure verify "$user" "DEST_MAILBOX_EMPTY"
            failed=1
        fi

        printf '%s,%s,%s,%s\n' "$user" "${src:-0}" "${dst:-0}" "$status" >> "$report"
    done < "$DISCOVERY_DIR/accounts.txt"

    log "Verification report: $report"
    ui_kv "report" "$report"
    return "$failed"
}

# ---------------------------------------------------------------------------
# STATUS
# ---------------------------------------------------------------------------

show_status() {
    local n_acc n_dom n_cos n_dl
    n_acc="$(count_lines "$DISCOVERY_DIR/accounts.txt")"
    n_dom="$(count_lines "$DISCOVERY_DIR/domains.txt")"
    n_cos="$(count_lines "$DISCOVERY_DIR/cos.txt")"
    n_dl="$(count_lines "$DISCOVERY_DIR/dls.txt")"

    printf '\n%s%s %sStatus%s\n' "$C_CYAN" "$S_RUN" "$C_BOLD" "$C_RESET"
    ui_kv "source" "${OLD_HOST:-not configured}"
    ui_kv "root" "$MIG_ROOT"
    printf '  %s%s%s\n' "$C_DIM" "──────────────" "$C_RESET"
    ui_ratio "domains" "$(state_count domains)" "$n_dom"
    ui_ratio "cos" "$(state_count cos)" "$n_cos"
    ui_ratio "accounts" "$(state_count accounts)" "$n_acc"
    ui_ratio "attrs" "$(state_count attrs)" "$n_acc"
    ui_ratio "aliases" "$(state_count aliases)"
    ui_ratio "filters" "$(state_count filters)"
    ui_ratio "dls" "$(state_count dl)" "$n_dl"
    ui_ratio "mailboxes" "$(state_count mailboxes)" "$n_acc"
    ui_ratio "finalize" "$(state_count finalize)" "$n_acc"
    ui_ratio "domain status" "$(state_count domain_status)" "$n_dom"
    printf '\n'
}

# ---------------------------------------------------------------------------
# PHASE RUNNER
# ---------------------------------------------------------------------------

run_phase() {
    local p="$1"
    case "$p" in
        discover)  discover ;;
        domains)   migrate_domains ;;
        cos)       migrate_cos ;;
        accounts)  migrate_accounts ;;
        attrs)     migrate_attrs ;;
        aliases)   migrate_aliases ;;
        filters)   migrate_filters ;;
        dl)        migrate_dl ;;
        mailboxes) migrate_mailboxes ;;
        finalize)  finalize_accounts ;;
        verify)    verify ;;
        *)
            err "Unknown phase: $p"
            return 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

finish_run() {
    local rc="$1"
    show_status
    if [[ -s "$REPORT_DIR/failures.txt" ]]; then
        ui_show_failures
        rc=1
    fi
    return "$rc"
}

if [[ "$STATUS_ONLY" == "1" ]]; then
    show_status
    exit 0
fi

preflight || exit 1

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
    exit 0
fi

printf '\n%s%s %sZimbra migrate%s  %s%s → this host%s\n' \
    "$C_CYAN" "$S_RUN" "$C_BOLD" "$C_RESET" "$C_DIM" "$OLD_HOST" "$C_RESET"
[[ "$DELTA_MODE" == "1" ]] && ui_kv "mode" "delta"
[[ -n "$ONLY_USER" ]] && ui_kv "user" "$ONLY_USER"

: > "$REPORT_DIR/failures.txt"

if [[ -n "$ONLY_PHASE" ]]; then
    run_phase "$ONLY_PHASE"
    rc=$?
    finish_run "$rc"
    exit $?
fi

# A single-user run is a targeted retry; required domain and COS objects must
# already exist on the destination.
if [[ -n "$ONLY_USER" ]]; then
    rc=0
    ensure_discovery || exit 1
    migrate_accounts  || rc=1
    migrate_attrs     || rc=1
    migrate_aliases   || rc=1
    migrate_filters   || rc=1
    migrate_mailboxes || rc=1
    finalize_accounts || rc=1
    verify            || rc=1
    finish_run "$rc"
    exit $?
fi

# Full run.
FAILED_PHASES=()
run_tracked_phase() {
    local p="$1" msg="$2"
    if ! run_phase "$p"; then
        FAILED_PHASES+=("$p")
        warn "$msg"
        return 1
    fi
    return 0
}

if run_tracked_phase discover "Discovery reported errors"; then
    run_tracked_phase domains   "Domain phase reported errors"
    run_tracked_phase cos       "COS phase reported errors"
    run_tracked_phase accounts  "Account phase reported errors"
    run_tracked_phase attrs     "Attribute phase reported errors"
    run_tracked_phase aliases   "Alias phase reported errors"
    run_tracked_phase filters   "Filter phase reported errors"
    run_tracked_phase dl        "Distribution-list phase reported errors"
    run_tracked_phase mailboxes "Mailbox phase reported errors"
    [[ ${#FAILED_PHASES[@]} -gt 0 ]] && DEFER_DOMAIN_STATUS=1
    run_tracked_phase finalize  "Finalize phase reported errors"
    run_tracked_phase verify    "Verification phase reported errors"
else
    warn "Dependent phases were skipped because discovery is incomplete"
fi

rc=0
if [[ ${#FAILED_PHASES[@]} -gt 0 ]]; then
    err "Failed phases: ${FAILED_PHASES[*]}"
    rc=1
fi

show_status

if [[ -s "$REPORT_DIR/failures.txt" ]]; then
    ui_show_failures
    rc=1
fi

if [[ "$rc" -eq 0 ]]; then
    ui_ok "finished"
else
    ui_err "finished with errors"
fi
ui_kv "next" "$0 --delta"
ui_kv "report" "$REPORT_DIR/verification.csv"
ui_kv "logs" "$LOG_DIR"
printf '\n'

exit "$rc"
