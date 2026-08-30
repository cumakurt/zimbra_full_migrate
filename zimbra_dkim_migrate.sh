#!/usr/bin/env bash
#
# zimbra_dkim_migrate.sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Cuma Kurt
# Author: Cuma Kurt <https://www.linkedin.com/in/cuma-kurt-34414917/>
# Source: https://github.com/cumakurt/zimbra_full_migrate
#
# Copy already deployed DKIM configurations from an old Zimbra host to a new
# Zimbra host. The script validates keys, optionally checks DNS, imports LDAP
# attributes, verifies the result, and never restarts Zimbra services.

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
DRY_RUN=0
STRICT_DNS=0
SKIP_DNS=0
REPLACE_EXISTING=1
FAIL_FAST=0
PURGE_EXPORT=0
ACCEPT_NEW_HOST_KEY=0
VERBOSE=0
declare -a ONLY_DOMAINS=()

ZIMBRA_HOME="${ZIMBRA_HOME:-/opt/zimbra}"
REMOTE_ZIMBRA_HOME="${REMOTE_ZIMBRA_HOME:-/opt/zimbra}"
ZIMBRA_USER="${ZIMBRA_USER:-zimbra}"
ZIMBRA_GROUP="${ZIMBRA_GROUP:-zimbra}"
RUN_ROOT="${RUN_ROOT:-/root/zimbra-dkim-migration}"
LOCK_FILE="${LOCK_FILE:-${RUN_ROOT}/.zimbra-dkim-migrate.lock}"
DKIM_IMPORT_HELPER="${DKIM_IMPORT_HELPER:-}"

ZMPROV="${ZIMBRA_HOME}/bin/zmprov"
ZMDKIM="${ZIMBRA_HOME}/libexec/zmdkimkeyutil"
ZMCONTROL="${ZIMBRA_HOME}/bin/zmcontrol"
ZMHOSTNAME="${ZIMBRA_HOME}/bin/zmhostname"
OPENDKIM_TEST="${ZIMBRA_HOME}/common/sbin/opendkim-testkey"
OPENDKIM_CONF="${ZIMBRA_HOME}/conf/opendkim.conf"
REMOTE_ZMPROV="${REMOTE_ZIMBRA_HOME}/bin/zmprov"
REMOTE_ZMDKIM="${REMOTE_ZIMBRA_HOME}/libexec/zmdkimkeyutil"
REMOTE_ZMHOSTNAME="${REMOTE_ZIMBRA_HOME}/bin/zmhostname"
REMOTE_ZMCONTROL="${REMOTE_ZIMBRA_HOME}/bin/zmcontrol"

SCRIPT_NAME="$(basename "$0")"
START_TS="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE=""
LOG_READY=0
RUN_DIR=""
SRC_DIR=""
PARSED_DIR=""
BACKUP_DIR=""
STATE_DIR=""
REPORT=""
HELPER=""
ACTIVE_PROCESS_GROUP=""
SRC_TOTAL=0
SRC_DKIM=0
OK_COUNT=0
ALREADY_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
DNS_OK=0
DNS_WARN=0

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

    printf '\n%b%s%b\n' "$C_BOLD$C_BLUE" 'Zimbra DKIM Migration' "$C_RESET"
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
  --dry-run, --verify-only      Export and validate; do not change the target
  --strict-dns                  Require DNS DKIM TXT to match the source key
  --skip-dns                    Skip DNS validation
  --no-replace                  Do not replace a different target DKIM
  --fail-fast                   Stop on the first domain failure
  --domain DOMAIN               Migrate only DOMAIN; repeatable
  --purge-source-export         Delete exported source keys after success
  --accept-new-host-key         Trust a previously unseen SSH host key once
  --verbose                     Show detailed command progress on the console
  -h, --help                    Show this help

Use the same root SSH identity as SSL migration, typically
/root/.ssh/id_ed25519_zimbra. The script never restarts Zimbra services.
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
        --dry-run|--verify-only)
            DRY_RUN=1
            shift
            ;;
        --strict-dns)
            STRICT_DNS=1
            shift
            ;;
        --skip-dns)
            SKIP_DNS=1
            shift
            ;;
        --no-replace)
            REPLACE_EXISTING=0
            shift
            ;;
        --fail-fast)
            FAIL_FAST=1
            shift
            ;;
        --domain)
            require_option_value "$1" "$#" "${2:-}"
            ONLY_DOMAINS+=("$2")
            shift 2
            ;;
        --purge-source-export)
            PURGE_EXPORT=1
            shift
            ;;
        --accept-new-host-key)
            ACCEPT_NEW_HOST_KEY=1
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
[[ "$STRICT_DNS" -eq 0 || "$SKIP_DNS" -eq 0 ]] || \
    usage_error "--strict-dns and --skip-dns conflict."

for configured_path in "$ZIMBRA_HOME" "$REMOTE_ZIMBRA_HOME" "$RUN_ROOT" "$LOCK_FILE"; do
    [[ "$configured_path" == /* && "$configured_path" != "/" ]] || \
        usage_error "Internal filesystem paths must be absolute and must not be /: $configured_path"
done

# ---------------------------------------------------------------------------
# PROCESS CONTROL
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

run_zimbra_combined() {
    local output_file="$1" command
    shift
    command="$(shell_join "$@")"
    run_in_group_combined "$output_file" su - "$ZIMBRA_USER" -c "$command"
}

run_zimbra_logged_gd() {
    local domain="$1" output_file
    output_file="${RUN_DIR}/zmprov-gd-$(file_name_for "$domain").out"
    run_zimbra_combined "$output_file" "$ZMPROV" gd "$domain" \
        zimbraDomainName zimbraDomainType zimbraDomainStatus
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

on_interrupt() {
    warn "Interrupted; stopping the active process group."
    terminate_active_group
    exit 130
}

on_terminate() {
    warn "Terminated; stopping the active process group."
    terminate_active_group
    exit 143
}

trap on_interrupt INT
trap on_terminate TERM

# ---------------------------------------------------------------------------
# DKIM PARSING AND VALIDATION
# ---------------------------------------------------------------------------

safe_domain() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$ || "$1" =~ ^[A-Za-z0-9]$ ]]
}

safe_selector() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

file_name_for() {
    printf '%s' "$1" | tr '/:' '__'
}

trim_end() {
    perl -0777 -i -pe 's/[ \t\r\n]+\z/\n/s' "$1"
}

first_after() {
    awk -v m="$1" '
        BEGIN { f = 0 }
        {
            x = $0
            sub(/\r$/, "", x)
            low = tolower(x)
            key = tolower(m)
        }
        f && x !~ /^[[:space:]]*$/ { print x; exit }
        index(low, key) == 1 {
            rest = substr(x, length(m) + 1)
            sub(/^[[:space:]]+/, "", rest)
            if (rest != "") { print rest; exit }
            f = 1
        }
    ' "$2"
}

extract_key() {
    awk '{
        x = $0
        sub(/\r$/, "", x)
        l = tolower(x)
    }
    l ~ /^dkim private key:/ { f = 1; next }
    l ~ /^dkim public signature:/ { exit }
    f { print x }' "$1" > "$2"
    trim_end "$2"
}

extract_pub() {
    awk '{
        x = $0
        sub(/\r$/, "", x)
        l = tolower(x)
    }
    l ~ /^dkim public signature:/ { f = 1; next }
    l ~ /^dkim identity:/ { exit }
    f { print x }' "$1" > "$2"
    trim_end "$2"
}

extract_p() {
    # zmdkimkeyutil prints BIND-style TXT: "p=MIIB...AQAB" ) ; ----- DKIM ...
    # Take only the base64 alphabet so a trailing ')' or comment is not part of p=.
    perl -0777 -ne '
        $x = $_;
        $x =~ s/\r//g;
        $x =~ s/"//g;
        $x =~ s/[[:space:]]+//g;
        if ($x =~ /p=([A-Za-z0-9+\/=_-]+)/i) { print $1 }
    ' "$1"
}

derive_p() {
    if command -v base64 >/dev/null; then
        openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | base64 | tr -d '\r\n'
    else
        openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | openssl base64 -A
    fi
}

decode_base64_der() {
    local b64="$1" dest="$2"
    if command -v base64 >/dev/null; then
        printf '%s' "$b64" | base64 -d > "$dest" 2>/dev/null || return 1
    else
        printf '%s' "$b64" | openssl base64 -d -A > "$dest" 2>/dev/null || return 1
    fi
    [[ -s "$dest" ]]
}

public_der_hash_from_file() {
    openssl pkey -pubin -inform DER -in "$1" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
}

public_der_hash_from_private() {
    openssl pkey -in "$1" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
}

public_der_hash_from_p() {
    local b64="$1" der pem hash
    der="$(mktemp "${RUN_DIR:-/tmp}/dkim-pub.XXXXXX")"
    pem="${der}.pem"
    decode_base64_der "$b64" "$der" || { rm -f -- "$der" "$pem"; return 1; }
    hash="$(public_der_hash_from_file "$der")"
    if [[ -z "$hash" ]]; then
        {
            printf '%s\n' '-----BEGIN PUBLIC KEY-----'
            printf '%s\n' "$b64" | fold -w 64
            printf '%s\n' '-----END PUBLIC KEY-----'
        } > "$pem"
        hash="$(
            openssl pkey -pubin -in "$pem" -pubout -outform DER 2>/dev/null |
                sha256sum | awk '{print $1}'
        )"
    fi
    if [[ -z "$hash" ]]; then
        {
            printf '%s\n' '-----BEGIN RSA PUBLIC KEY-----'
            printf '%s\n' "$b64" | fold -w 64
            printf '%s\n' '-----END RSA PUBLIC KEY-----'
        } > "$pem"
        hash="$(
            openssl pkey -pubin -in "$pem" -pubout -outform DER 2>/dev/null |
                sha256sum | awk '{print $1}'
        )"
    fi
    rm -f -- "$der" "$pem"
    [[ -n "$hash" ]] || return 1
    printf '%s\n' "$hash"
}

norm() {
    printf '%s' "$1" | tr -d '"[:space:]'
}

parse_raw() {
    local raw="$1" out="$2"
    mkdir -p "$out"
    chmod 700 "$out"
    first_after 'DKIM Domain:' "$raw" > "$out/domain" || true
    first_after 'DKIM Selector:' "$raw" > "$out/selector" || true
    first_after 'DKIM Identity:' "$raw" > "$out/identity" || true
    extract_key "$raw" "$out/private.key"
    extract_pub "$raw" "$out/public.txt"
    chmod 600 "$out"/* 2>/dev/null || true
}

validate_parsed() {
    local expect="$1" parsed="$2" domain selector identity derived stored bits
    local derived_hash stored_hash
    domain="$(<"$parsed/domain")"
    selector="$(<"$parsed/selector")"
    identity="$(<"$parsed/identity")"
    [[ -n "$domain" ]] || return 11
    [[ -n "$selector" ]] || return 12
    [[ -s "$parsed/private.key" ]] || return 13
    [[ -s "$parsed/public.txt" ]] || return 14
    safe_domain "$domain" || return 15
    safe_selector "$selector" || return 16
    [[ "${domain,,}" == "${expect,,}" ]] || return 17
    openssl pkey -in "$parsed/private.key" -noout >/dev/null 2>&1 || return 18
    derived="$(norm "$(derive_p "$parsed/private.key" || true)")"
    stored="$(norm "$(extract_p "$parsed/public.txt" || true)")"
    [[ -n "$derived" ]] || return 19
    [[ -n "$stored" ]] || return 20
    derived_hash="$(public_der_hash_from_private "$parsed/private.key" || true)"
    stored_hash="$(public_der_hash_from_p "$stored" || true)"
    if [[ "$derived" != "$stored" && ( -z "$derived_hash" || "$derived_hash" != "$stored_hash" ) ]]; then
        return 21
    fi
    [[ -n "$identity" ]] || return 22
    bits="$(
        openssl pkey -in "$parsed/private.key" -text -noout 2>/dev/null |
            awk '/Private-Key:/{gsub(/[()]/,"",$2); print $2; exit}' || true
    )"
    printf '%s\n' "$derived" > "$parsed/public_b64"
    printf '%s\n' "${bits:-unknown}" > "$parsed/key_bits"
    chmod 600 "$parsed/public_b64" "$parsed/key_bits"
}

validation_error() {
    case "$1" in
        11) printf 'DKIMDomain is empty' ;;
        12) printf 'selector is empty' ;;
        13) printf 'private key is empty' ;;
        14) printf 'public signature is empty' ;;
        15) printf 'invalid DKIMDomain' ;;
        16) printf 'invalid selector' ;;
        17) printf 'DKIMDomain does not match the source domain' ;;
        18) printf 'private key is invalid' ;;
        19) printf 'cannot derive the public key' ;;
        20) printf 'cannot parse stored p=' ;;
        21) printf 'stored public key does not match the private key' ;;
        22) printf 'DKIMIdentity is empty' ;;
        *) printf 'validation error %s' "$1" ;;
    esac
}

same_cfg() {
    [[ "$(<"$1/selector")" == "$(<"$2/selector")" ]] &&
        [[ "$(<"$1/identity")" == "$(<"$2/identity")" ]] &&
        [[ "$(<"$1/domain")" == "$(<"$2/domain")" ]] &&
        [[ "$(<"$1/public_b64")" == "$(<"$2/public_b64")" ]]
}

find_dig() {
    command -v dig 2>/dev/null || {
        [[ -x "${ZIMBRA_HOME}/common/bin/dig" ]] && printf '%s\n' "${ZIMBRA_HOME}/common/bin/dig"
    } || true
}

dns_p() {
    local raw
    raw="$("$3" +short TXT "$2._domainkey.$1" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 1
    printf '%s\n' "$raw" | perl -0777 -ne '
        $x = $_;
        $x =~ s/\r//g;
        $x =~ s/"//g;
        $x =~ s/[[:space:]]+//g;
        if ($x =~ /p=([A-Za-z0-9+\/=_-]+)/i) { print $1 }
    '
}

report_row() {
    local note="${5//$'\t'/ }"
    note="${note//$'\n'/ }"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$note" >> "$REPORT"
}

fail_domain() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    report_row "$1" "$2" FAILED "$3" "$4"
    warn "$1: $4"
    [[ "$FAIL_FAST" -eq 1 ]] && die "Fail-fast is enabled."
}

target_query() {
    if run_zimbra_combined "$2" "$ZMDKIM" -q -d "$1"; then
        return 0
    fi
    grep -qiE 'No DKIM Information|doesn.t have DKIM|not found' "$2" && return 1
    return 2
}

selector_owner() {
    if run_zimbra_combined "$2" "$ZMDKIM" -q -s "$1"; then
        first_after 'DKIM Domain:' "$2" || true
        return 0
    fi
    grep -qiE 'No DKIM Information|No DKIM Information for Selector' "$2" && return 1
    return 2
}

write_ldap_helper() {
    local zimbra_home_perl
    printf -v zimbra_home_perl '%s' "$ZIMBRA_HOME"
    [[ "$zimbra_home_perl" =~ ^/[A-Za-z0-9/._-]+$ ]] || \
        die "Refusing to embed an unsafe Zimbra home path in the LDAP helper."

    cat > "$HELPER" <<PERL
#!/usr/bin/env perl
use strict;
use warnings;
use lib '${zimbra_home_perl}/common/lib/perl5';
use Net::LDAP;
use Net::LDAP::Util qw(ldap_error_name escape_filter_value);
use XML::Simple;
use Getopt::Long qw(:config no_ignore_case);

my (\$domain, \$dkim_domain, \$selector, \$keyfile, \$pubfile, \$identity);
GetOptions(
    'domain=s' => \\\$domain,
    'dkim-domain=s' => \\\$dkim_domain,
    'selector=s' => \\\$selector,
    'key=s' => \\\$keyfile,
    'public=s' => \\\$pubfile,
    'identity=s' => \\\$identity,
) or die "bad args\\n";
for my \$value (\$domain, \$dkim_domain, \$selector, \$keyfile, \$pubfile, \$identity) {
    die "missing argument\\n" unless defined(\$value) && length(\$value);
}
die "must run as zimbra\\n" unless getpwuid(\$<) eq 'zimbra';

open my \$key_fh, '<', \$keyfile or die "key open: \$!\\n";
local \$/;
my \$priv = <\$key_fh>;
close \$key_fh;
open my \$pub_fh, '<', \$pubfile or die "pub open: \$!\\n";
my \$pub = <\$pub_fh>;
close \$pub_fh;

my \$xml = XMLin('${zimbra_home_perl}/conf/localconfig.xml');
my \$url = \$xml->{key}->{ldap_master_url}->{value};
my \$dn = \$xml->{key}->{zimbra_ldap_userdn}->{value};
my \$pw = \$xml->{key}->{zimbra_ldap_password}->{value};
chomp \$pw;
my \$tls = \$xml->{key}->{ldap_starttls_supported}->{value};
my @masters = split(/\\s+/, \$url);
my \$ldap = Net::LDAP->new(\\@masters) or die "LDAP connect: \$@\\n";
if (\$url !~ /^ldaps/i && \$tls) {
    my \$tls_result = \$ldap->start_tls(
        verify => 'require',
        capath => '${zimbra_home_perl}/conf/ca',
    );
    die "StartTLS: " . \$tls_result->error . "\\n" if \$tls_result->code;
}
my \$bind = \$ldap->bind(\$dn, password => \$pw);
die "bind: " . \$bind->error . "\\n" if \$bind->code;

my \$domain_filter = escape_filter_value(\$domain);
my \$selector_filter = escape_filter_value(\$selector);
my \$search = \$ldap->search(
    base => '',
    filter => "(&(objectClass=zimbraDomain)(zimbraDomainName=\$domain_filter))",
    scope => 'sub',
);
die "domain search: " . \$search->error . "\\n" if \$search->code;
die "domain not found\\n" unless \$search->count;
my \$entry = \$search->entry(0);
my \$entry_dn = \$entry->dn;

my \$existing = \$ldap->search(
    base => '',
    filter => "(&(objectClass=zimbraDomain)(zimbraDomainName=\$domain_filter)(DKIMSelector=*))",
    scope => 'sub',
);
die "existing search: " . \$existing->error . "\\n" if \$existing->code;
die "domain already has DKIM\\n" if \$existing->count;

my \$collision = \$ldap->search(
    base => '',
    filter => "(&(objectClass=zimbraDomain)(DKIMSelector=\$selector_filter))",
    scope => 'sub',
);
die "collision search: " . \$collision->error . "\\n" if \$collision->code;
if (\$collision->count) {
    my \$owner = \$collision->entry(0)->get_value('zimbraDomainName') || 'unknown';
    die "selector already used by \$owner\\n";
}

my \$modify = \$ldap->modify(
    \$entry_dn,
    add => [
        objectClass => 'DKIM',
        DKIMSelector => \$selector,
        DKIMDomain => \$dkim_domain,
        DKIMKey => \$priv,
        DKIMPublicKey => \$pub,
        DKIMIdentity => \$identity,
    ],
);
die "LDAP import: " . ldap_error_name(\$modify->code) . " - " . \$modify->error . "\\n"
    if \$modify->code;
\$ldap->unbind;
print "DKIM import OK: \$domain / \$selector\\n";
PERL
    chmod 700 "$HELPER"
    chown "$ZIMBRA_USER:$ZIMBRA_GROUP" "$HELPER"
}

import_cfg() {
    local parsed="$1" domain="$2" work dkim_domain selector identity helper rc=0
    dkim_domain="$(<"$parsed/domain")"
    selector="$(<"$parsed/selector")"
    identity="$(<"$parsed/identity")"
    mkdir -p "${ZIMBRA_HOME}/data/tmp"
    work="${ZIMBRA_HOME}/data/tmp/dkim-migrate-${START_TS}-$$-$RANDOM"
    helper="${DKIM_IMPORT_HELPER:-$HELPER}"
    install -d -o "$ZIMBRA_USER" -g "$ZIMBRA_GROUP" -m 0700 "$work"
    install -o "$ZIMBRA_USER" -g "$ZIMBRA_GROUP" -m 0600 \
        "$parsed/private.key" "$work/private.key"
    install -o "$ZIMBRA_USER" -g "$ZIMBRA_GROUP" -m 0600 \
        "$parsed/public.txt" "$work/public.txt"
    if [[ -z "$DKIM_IMPORT_HELPER" ]]; then
        install -o "$ZIMBRA_USER" -g "$ZIMBRA_GROUP" -m 0700 "$HELPER" "$work/import.pl"
        helper="$work/import.pl"
    fi
    run_zimbra "$helper" \
        --domain "$domain" \
        --dkim-domain "$dkim_domain" \
        --selector "$selector" \
        --key "$work/private.key" \
        --public "$work/public.txt" \
        --identity "$identity" || rc=$?
    rm -rf -- "$work"
    return "$rc"
}

remove_cfg() {
    run_zimbra_logged_remove "$1"
}

run_zimbra_logged_remove() {
    run_zimbra "$ZMDKIM" -r -d "$1"
}

verify_import() {
    local domain="$1" expected="$2" raw="$3" parsed="$4" rc=0
    target_query "$domain" "$raw" || return 1
    parse_raw "$raw" "$parsed"
    validate_parsed "$domain" "$parsed" || rc=$?
    [[ "$rc" -eq 0 ]] || return 2
    same_cfg "$expected" "$parsed" || return 3
}

testkey() {
    local output rc=0
    [[ -x "$OPENDKIM_TEST" && -r "$OPENDKIM_CONF" ]] || return 2
    output="$(run_zimbra "$OPENDKIM_TEST" -d "$1" -s "$2" -x "$OPENDKIM_CONF" 2>&1)" || rc=$?
    printf '%s\n' "$output" >> "$LOG_FILE"
    return "$rc"
}

# ---------------------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run this script as root on the NEW Zimbra server."

for required in ssh openssl awk perl grep sed tr sha256sum install su sort flock setsid; do
    command -v "$required" >/dev/null || die "Missing command: $required"
done
[[ -x "$ZMPROV" && -x "$ZMDKIM" && -x "$ZMCONTROL" && -x "$ZMHOSTNAME" ]] || \
    die "Zimbra CLI tools were not found under $ZIMBRA_HOME"

if [[ -n "$SSH_IDENTITY" ]]; then
    [[ -f "$SSH_IDENTITY" && -r "$SSH_IDENTITY" && ! -L "$SSH_IDENTITY" ]] || \
        die "SSH identity must be a readable regular file, not a symlink: $SSH_IDENTITY"
    IDENTITY_MODE="$(stat -c '%a' "$SSH_IDENTITY" 2>/dev/null || true)"
    if [[ "$IDENTITY_MODE" =~ ^[0-7]{3,4}$ && $((8#$IDENTITY_MODE & 077)) -ne 0 ]]; then
        warn "SSH identity permissions are broader than 0600: $SSH_IDENTITY ($IDENTITY_MODE)"
    fi
fi

mkdir -p -- "$RUN_ROOT"
chmod 700 "$RUN_ROOT"
[[ ! -L "$LOCK_FILE" ]] || die "Lock file must not be a symlink: $LOCK_FILE"
exec 9>> "$LOCK_FILE"
chmod 600 "$LOCK_FILE"
flock -n 9 || die "Another Zimbra DKIM migration process is already running."

RUN_DIR="${RUN_ROOT}/${START_TS}"
SRC_DIR="${RUN_DIR}/source"
PARSED_DIR="${RUN_DIR}/parsed"
BACKUP_DIR="${RUN_DIR}/target-before"
STATE_DIR="${RUN_DIR}/state"
LOG_FILE="${RUN_DIR}/migration.log"
REPORT="${RUN_DIR}/report.tsv"
HELPER="${RUN_DIR}/dkim_ldap_import.pl"
mkdir -p "$SRC_DIR" "$PARSED_DIR" "$BACKUP_DIR" "$STATE_DIR"
chmod 700 "$RUN_DIR" "$SRC_DIR" "$PARSED_DIR" "$BACKUP_DIR" "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
LOG_READY=1
printf 'domain\tselector\tstatus\tdns_status\tnote\n' > "$REPORT"
chmod 600 "$REPORT"

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
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
    -o Compression=no
    -o "StrictHostKeyChecking=${SSH_HOST_KEY_MODE}"
)
if [[ -n "$SSH_IDENTITY" ]]; then
    SSH_OPTS+=(-i "$SSH_IDENTITY")
fi

TARGET_SYSTEM_HOST="$(hostname -f 2>/dev/null || hostname)"
if [[ "$DRY_RUN" -eq 1 ]]; then
    RUN_MODE="verify only"
else
    RUN_MODE="deploy"
fi
ui_banner "$RUN_MODE" "$REMOTE" "$TARGET_SYSTEM_HOST" "$LOG_FILE"

phase 1 5 "Destination preflight"
TARGET_HOST_OUTPUT="${RUN_DIR}/target-host.out"
TARGET_VERSION_OUTPUT="${RUN_DIR}/target-version.out"
run_zimbra_capture "$TARGET_HOST_OUTPUT" "$ZMHOSTNAME" || \
    die "Could not determine destination Zimbra hostname."
TARGET_ZMHOST="$(tail -n1 "$TARGET_HOST_OUTPUT" | tr -d '\r')"
[[ -n "$TARGET_ZMHOST" ]] || die "Destination zmhostname returned an empty value."
if run_zimbra_capture "$TARGET_VERSION_OUTPUT" "$ZMCONTROL" -v; then
    TARGET_ZMVER="$(tail -n1 "$TARGET_VERSION_OUTPUT" | tr -d '\r')"
    ok "Destination Zimbra: $TARGET_ZMVER"
else
    TARGET_ZMVER=""
    warn "Could not read the destination Zimbra version."
fi
log "Destination zmhostname: $TARGET_ZMHOST"
write_ldap_helper

phase 2 5 "Source access"
log "Testing SSH connectivity and host-key trust..."
SSH_TEST_OUTPUT="${RUN_DIR}/ssh-test.out"
if ! run_in_group_capture "$SSH_TEST_OUTPUT" \
        ssh "${SSH_OPTS[@]}" "$REMOTE" "printf 'SSH_OK\\n'"; then
    die "SSH authentication failed for $REMOTE; verify the identity and known_hosts (details: $LOG_FILE)."
fi
grep -Fqx 'SSH_OK' "$SSH_TEST_OUTPUT" || \
    die "Unexpected response from source SSH endpoint: $REMOTE"
ok "SSH connection and source host-key verification succeeded."

REMOTE_TOOL_CMD="$(shell_join test -x "$REMOTE_ZMPROV" -a -x "$REMOTE_ZMDKIM")"
run_in_group_logged ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_TOOL_CMD" || \
    die "Source Zimbra DKIM tools are unavailable."

SOURCE_HOST_OUTPUT="${RUN_DIR}/source-host.out"
SOURCE_VERSION_OUTPUT="${RUN_DIR}/source-version.out"
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

DIG=""
if [[ "$SKIP_DNS" -eq 0 ]]; then
    DIG="$(find_dig)"
    if [[ -z "$DIG" ]]; then
        [[ "$STRICT_DNS" -eq 0 ]] || die "dig was not found for --strict-dns."
        warn "dig was not found; DNS checks are skipped."
    fi
fi

declare -a DOMAINS=()
if ((${#ONLY_DOMAINS[@]})); then
    DOMAINS=("${ONLY_DOMAINS[@]}")
else
    DOMAIN_LIST_OUTPUT="${RUN_DIR}/source-domains.out"
    REMOTE_GAD_CMD="$(shell_join "$REMOTE_ZMPROV" gad)"
    run_in_group_capture "$DOMAIN_LIST_OUTPUT" \
        ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_GAD_CMD" || \
        die "Could not list source domains."
    mapfile -t DOMAINS < <(tr -d '\r' < "$DOMAIN_LIST_OUTPUT" | awk 'NF' | sort -u)
fi
SRC_TOTAL=${#DOMAINS[@]}
((SRC_TOTAL > 0)) || die "No source domains were found."
ok "Source domains to inspect: $SRC_TOTAL"

# ---------------------------------------------------------------------------
# EXPORT AND VALIDATE
# ---------------------------------------------------------------------------

phase 3 5 "Export and cryptographic validation"
declare -a DKIM_DOMAINS=()
for domain in "${DOMAINS[@]}"; do
    if ! safe_domain "$domain"; then
        warn "Malformed source domain skipped: $domain"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        report_row "$domain" '' SKIPPED N/A 'malformed source domain'
        continue
    fi
    file_key="$(file_name_for "$domain")"
    raw="${SRC_DIR}/${file_key}.query.txt"
    parsed="${PARSED_DIR}/source-${file_key}"
    query_cmd="$(shell_join "$REMOTE_ZMDKIM" -q -d "$domain")"
    rc=0
    run_in_group_combined "$raw" ssh "${SSH_OPTS[@]}" "$REMOTE" "$query_cmd" || rc=$?
    chmod 600 "$raw"
    if ((rc)); then
        if grep -qiE 'No DKIM Information|doesn.t have DKIM enabled' "$raw"; then
            rm -f -- "$raw"
            continue
        fi
        fail_domain "$domain" '' N/A "source DKIM query failed (exit $rc)"
        continue
    fi
    grep -qi '^DKIM Selector:' "$raw" || { rm -f -- "$raw"; continue; }
    SRC_DKIM=$((SRC_DKIM + 1))
    DKIM_DOMAINS+=("$domain")
    parse_raw "$raw" "$parsed"
    vrc=0
    validate_parsed "$domain" "$parsed" || vrc=$?
    if ((vrc)); then
        fail_domain "$domain" "$(cat "$parsed/selector" 2>/dev/null || true)" N/A \
            "source validation failed: $(validation_error "$vrc")"
        continue
    fi
    touch "$STATE_DIR/${file_key}.source-valid"
    ok "$domain: selector=$(<"$parsed/selector"), key=$(<"$parsed/key_bits") bits"
done
ok "Source DKIM domains found: $SRC_DKIM"
if ((SRC_DKIM == 0)); then
    warn "No source DKIM configuration was found."
    exit 0
fi

# ---------------------------------------------------------------------------
# TARGET PREFLIGHT AND MIGRATION
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" -eq 1 ]]; then
    phase 4 5 "Dry-run target review"
else
    phase 4 5 "Target preflight and migration"
fi

for domain in "${DKIM_DOMAINS[@]}"; do
    file_key="$(file_name_for "$domain")"
    [[ -f "$STATE_DIR/${file_key}.source-valid" ]] || continue
    src="${PARSED_DIR}/source-${file_key}"
    sel="$(<"$src/selector")"
    source_p="$(<"$src/public_b64")"
    dns_status=SKIPPED
    log "Processing $domain / $sel"

    if ! run_zimbra_logged_gd "$domain"; then
        fail_domain "$domain" "$sel" "$dns_status" 'domain is missing on the new Zimbra server'
        continue
    fi

    if [[ "$SKIP_DNS" -eq 0 && -n "$DIG" ]]; then
        dpk="$(norm "$(dns_p "$domain" "$sel" "$DIG" || true)")"
        if [[ -z "$dpk" ]]; then
            dns_status=MISSING
            DNS_WARN=$((DNS_WARN + 1))
            warn "$domain: DNS DKIM TXT is missing or unparseable"
            if [[ "$STRICT_DNS" -eq 1 ]]; then
                fail_domain "$domain" "$sel" "$dns_status" 'strict DNS: TXT missing'
                continue
            fi
        elif [[ "$dpk" != "$source_p" ]]; then
            dns_status=MISMATCH
            DNS_WARN=$((DNS_WARN + 1))
            warn "$domain: DNS public key does not match the source key"
            if [[ "$STRICT_DNS" -eq 1 ]]; then
                fail_domain "$domain" "$sel" "$dns_status" 'strict DNS: public key mismatch'
                continue
            fi
        else
            dns_status=OK
            DNS_OK=$((DNS_OK + 1))
            ok "$domain: DNS public key matches the source key"
        fi
    elif [[ "$SKIP_DNS" -eq 0 ]]; then
        dns_status=SKIPPED_NO_DIG
    fi

    coll="${RUN_DIR}/collision-${file_key}.txt"
    crc=0
    owner="$(selector_owner "$sel" "$coll" 2>/dev/null)" || crc=$?
    if ((crc == 0)) && [[ -n "$owner" && "${owner,,}" != "${domain,,}" ]]; then
        fail_domain "$domain" "$sel" "$dns_status" "selector collision on target: $owner"
        continue
    elif ((crc == 2)); then
        fail_domain "$domain" "$sel" "$dns_status" 'cannot check target selector collision'
        continue
    fi
    rm -f -- "$coll"

    traw="${BACKUP_DIR}/${file_key}.query.txt"
    qrc=0
    target_query "$domain" "$traw" || qrc=$?
    has=0
    tdir="${PARSED_DIR}/target-before-${file_key}"
    if ((qrc == 0)); then
        has=1
        chmod 600 "$traw"
        parse_raw "$traw" "$tdir"
        tv=0
        validate_parsed "$domain" "$tdir" || tv=$?
        if ((tv)); then
            fail_domain "$domain" "$sel" "$dns_status" \
                "existing target DKIM is unsafe to parse: $(validation_error "$tv")"
            continue
        fi
        if same_cfg "$src" "$tdir"; then
            ALREADY_COUNT=$((ALREADY_COUNT + 1))
            note='already identical'
            if testkey "$domain" "$sel"; then
                note='already identical; opendkim-testkey OK'
                ok "$domain: already identical and testkey OK"
            else
                warn "$domain: already identical; opendkim-testkey non-zero or unavailable"
            fi
            report_row "$domain" "$sel" ALREADY_OK "$dns_status" "$note"
            touch "$STATE_DIR/${file_key}.done"
            continue
        fi
        if [[ "$REPLACE_EXISTING" -eq 0 ]]; then
            SKIP_COUNT=$((SKIP_COUNT + 1))
            report_row "$domain" "$sel" SKIPPED_CONFLICT "$dns_status" \
                'different target DKIM; replacement disabled'
            warn "$domain: target DKIM conflict; skipped"
            continue
        fi
    elif ((qrc == 1)); then
        rm -f -- "$traw"
    else
        fail_domain "$domain" "$sel" "$dns_status" 'target DKIM query failed'
        continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        if ((has)); then
            report_row "$domain" "$sel" DRY_RUN_REPLACE "$dns_status" \
                'would replace existing target DKIM after backup'
        else
            report_row "$domain" "$sel" DRY_RUN_ADD "$dns_status" \
                'would import source DKIM'
        fi
        ok "$domain: dry-run only"
        continue
    fi

    if ((has)); then
        log "$domain: removing the current target DKIM immediately before import"
        run_zimbra_logged_remove "$domain" >> "$LOG_FILE" 2>&1 || {
            fail_domain "$domain" "$sel" "$dns_status" 'failed to remove the current target DKIM'
            continue
        }
    fi

    irc=0
    import_cfg "$src" "$domain" >> "$LOG_FILE" 2>&1 || irc=$?
    if ((irc)); then
        warn "$domain: source import failed (exit $irc)"
        if ((has)); then
            warn "$domain: automatic rollback started"
            cur="${RUN_DIR}/rollback-current-${file_key}.txt"
            if target_query "$domain" "$cur" >/dev/null 2>&1; then
                run_zimbra_logged_remove "$domain" >> "$LOG_FILE" 2>&1 || true
            fi
            rm -f -- "$cur"
            if import_cfg "$tdir" "$domain" >> "$LOG_FILE" 2>&1; then
                fail_domain "$domain" "$sel" "$dns_status" \
                    'source import failed; previous target DKIM restored'
            else
                fail_domain "$domain" "$sel" "$dns_status" \
                    "CRITICAL: import and rollback failed; inspect $RUN_DIR"
            fi
        else
            fail_domain "$domain" "$sel" "$dns_status" 'source import failed'
        fi
        continue
    fi

    vr="${RUN_DIR}/verify-${file_key}.txt"
    vp="${PARSED_DIR}/target-after-${file_key}"
    prc=0
    verify_import "$domain" "$src" "$vr" "$vp" || prc=$?
    if ((prc)); then
        warn "$domain: post-import verification failed ($prc)"
        run_zimbra_logged_remove "$domain" >> "$LOG_FILE" 2>&1 || true
        if ((has)); then
            if import_cfg "$tdir" "$domain" >> "$LOG_FILE" 2>&1; then
                fail_domain "$domain" "$sel" "$dns_status" \
                    'post-import verify failed; previous target DKIM restored'
            else
                fail_domain "$domain" "$sel" "$dns_status" \
                    'CRITICAL: verify failed and rollback failed'
            fi
        else
            fail_domain "$domain" "$sel" "$dns_status" \
                'post-import verify failed; new DKIM removed'
        fi
        continue
    fi
    rm -f -- "$vr"
    note='imported; LDAP/crypto verified'
    if testkey "$domain" "$sel"; then
        note="$note; opendkim-testkey OK"
        ok "$domain: opendkim-testkey OK"
    else
        warn "$domain: opendkim-testkey non-zero or unavailable; LDAP and cryptographic checks are OK"
    fi
    OK_COUNT=$((OK_COUNT + 1))
    report_row "$domain" "$sel" MIGRATED_OK "$dns_status" "$note"
    touch "$STATE_DIR/${file_key}.done"
    ok "$domain: DKIM migration complete"
done

phase 5 5 "Final audit and summary"
if [[ "$DRY_RUN" -eq 0 ]]; then
    for domain in "${DKIM_DOMAINS[@]}"; do
        file_key="$(file_name_for "$domain")"
        [[ -f "$STATE_DIR/${file_key}.done" ]] || continue
        src="${PARSED_DIR}/source-${file_key}"
        ar="${RUN_DIR}/audit-${file_key}.txt"
        ap="${PARSED_DIR}/audit-${file_key}"
        if verify_import "$domain" "$src" "$ar" "$ap"; then
            ok "$domain: final audit exact-match OK"
        else
            warn "$domain: final audit could not confirm an exact match"
        fi
        rm -f -- "$ar"
    done
fi

cat > "$RUN_DIR/summary.txt" <<EOF
Run: $(date -Is)
Source SSH: $REMOTE
Source zmhostname: ${SOURCE_ZMHOST:-unknown}
Source version: ${SOURCE_ZMVER:-unknown}
Target zmhostname: $TARGET_ZMHOST
Target version: ${TARGET_ZMVER:-unknown}
Source domains inspected: $SRC_TOTAL
Source DKIM domains: $SRC_DKIM
Migrated: $OK_COUNT
Already identical: $ALREADY_COUNT
Skipped: $SKIP_COUNT
Failed: $FAIL_COUNT
DNS exact matches: $DNS_OK
DNS warnings: $DNS_WARN
Dry run: $DRY_RUN
Services restarted: NO
EOF
chmod 600 "$RUN_DIR/summary.txt"
rm -f -- "$HELPER"
if [[ "$PURGE_EXPORT" -eq 1 && "$FAIL_COUNT" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    rm -rf -- "$SRC_DIR" "$PARSED_DIR"/source-*
    warn "Source key exports were purged as requested."
fi

printf '\n%b%s%b\n' "$C_BOLD$C_BLUE" 'DKIM migration finished' "$C_RESET"
printf '%b%s%b\n' "$C_DIM" '────────────────────────────────────────────────────────────' "$C_RESET"
printf '  %-24s %s\n' 'Inspected' "$SRC_TOTAL"
printf '  %-24s %s\n' 'Source DKIM' "$SRC_DKIM"
printf '  %-24s %s\n' 'Migrated' "$OK_COUNT"
printf '  %-24s %s\n' 'Already identical' "$ALREADY_COUNT"
printf '  %-24s %s\n' 'Skipped' "$SKIP_COUNT"
printf '  %-24s %s\n' 'Failed' "$FAIL_COUNT"
printf '  %-24s %s\n' 'DNS matches' "$DNS_OK"
printf '  %-24s %s\n' 'DNS warnings' "$DNS_WARN"
printf '  %-24s %s\n' 'Run directory' "$RUN_DIR"
printf '  %-24s %s\n' 'Report' "$REPORT"
printf '  %-24s %s\n' 'Log' "$LOG_FILE"
printf '\n'
warn "NO ZIMBRA SERVICE WAS RESTARTED."
log "DKIM data was written to Zimbra LDAP only."

((FAIL_COUNT == 0)) || exit 2
exit 0
