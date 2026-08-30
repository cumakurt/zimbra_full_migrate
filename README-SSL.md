# Zimbra SSL Migration

[English](README-SSL.md) · [Türkçe](README-SSL.tr.md)

`zimbra_ssl_migrate.sh` securely transfers an already deployed commercial or Let's Encrypt certificate set from an old Zimbra server to a new Zimbra server. It validates the certificate, key, CA chain, validity period, hostname, and Zimbra compatibility before changing the destination.

This document applies only to `zimbra_ssl_migrate.sh`. The tenant/mailbox migration script has separate documentation.

> **Use at your own risk — all operational responsibility belongs to the operator.** This script handles live TLS private keys and changes active Zimbra certificate files and configuration. The person or organization running it is solely responsible for authorization, key custody, SSH host verification, backups, testing, compatibility, change approval, downtime, rollback, service restart, certificate renewal, regulatory compliance, and validation of every client-facing service. The software is provided without warranty; to the maximum extent permitted by applicable law, the author and contributors are not liable for data loss, key exposure, outage, failed rollback, security incidents, or direct/indirect damage. See [LICENSE](LICENSE).

## Scope

The script:

- runs on the new/destination Zimbra server as `root`
- connects to the old/source server over non-interactive SSH
- reads these source files:
  - `/opt/zimbra/ssl/zimbra/commercial/commercial.key`
  - `/opt/zimbra/ssl/zimbra/commercial/commercial.crt`
  - `/opt/zimbra/ssl/zimbra/commercial/commercial_ca.crt`
- extracts only the first certificate from a deployed `commercial.crt`, because that file may already contain an appended CA chain
- verifies the private key, leaf certificate, server trust chain, current validity, target `zmhostname`, and `zmcertmgr verifycrt`
- creates and verifies a private pre-deployment backup
- installs the key with version-appropriate permissions and deploys the certificate through `zmcertmgr`
- verifies the deployed certificate fingerprint, chain, private-key match, and `viewdeployedcrt`
- does **not** restart Zimbra services

It does not issue or renew certificates, alter DNS, copy certificates to every node of a multi-server installation, or test the public TLS endpoint after restart.

## Requirements

Destination:

- a conventional Zimbra installation under `/opt/zimbra`
- Bash and an OpenSSL version whose `x509` command supports `-checkhost`
- `ssh`, `scp`, `openssl`, `awk`, `grep`, `sed`, `sha256sum`, `tar`, `flock`, `setsid`, and the other standard tools checked during preflight
- execution as `root`
- a valid `zimbra` operating-system user
- enough space under `/root/zimbra-ssl-migration-backups` for the current SSL state

Source:

- SSH access as `zimbra` by default
- key-based/non-interactive authentication (`BatchMode=yes`)
- the three non-empty, readable commercial certificate files listed above

The source certificate and private key travel over SSH but remain highly sensitive. Protect the destination log, backup, root SSH identity, and any retained staging directory.

## SSH key setup from the new server as root

The SSL migration runs on the **new server as root**, so the SSH key and source host record must belong to root—not to the destination `zimbra` user. The following example creates a dedicated key only for this migration. Replace the example hostname and port before running anything.

**Important:** Steps 1, 2, 4, 5, and 6 share the same `OLD_ZIMBRA`, `OLD_SSH_PORT`, and `SSL_MIGRATE_KEY` shell variables in one root session. If you open a new session, re-run the variable block at the top of the relevant step. Without those variables, step 2 fails with `Saving key "" failed`.

### 1. Become root on the new server and define the connection

Run on the **new Zimbra server**:

```bash
sudo -i

OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

printf 'Source: %s:%s\nKey: %s\n' \
  "$OLD_ZIMBRA" "$OLD_SSH_PORT" "$SSL_MIGRATE_KEY"
```

Confirm that `OLD_ZIMBRA` really identifies the old/source Zimbra server. Do not continue with a guessed address.

### 2. Create a dedicated Ed25519 key on the new server

Still as root on the **new server**. If you skipped step 1 or opened a new root session, run the variable block below first:

```bash
# If you skipped step 1 or opened a new root session, set these first:
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA is empty; replace the example hostname with the real source address.}"
: "${OLD_SSH_PORT:?OLD_SSH_PORT is empty.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY is empty; set the key file path.}"

install -d -o root -g root -m 0700 /root/.ssh

if [[ -e "$SSL_MIGRATE_KEY" || -e "${SSL_MIGRATE_KEY}.pub" ]]; then
  printf 'Key already exists; inspect and reuse it or choose another path: %s\n' \
    "$SSL_MIGRATE_KEY" >&2
else
  ssh-keygen -t ed25519 -a 100 -N '' \
    -C "zimbra-ssl-migrate@$(hostname -f)" \
    -f "$SSL_MIGRATE_KEY"
fi

chmod 0600 "$SSL_MIGRATE_KEY"
chmod 0644 "${SSL_MIGRATE_KEY}.pub"
ssh-keygen -lf "${SSL_MIGRATE_KEY}.pub"
```

`-N ''` creates an unencrypted dedicated key because the migration uses non-interactive `BatchMode`. Keep the root account and key protected. Never copy `zimbra_ssl_migrate_ed25519` (the private file) to the old server; only its `.pub` file is authorized there.

### 3. Obtain and independently verify the old server fingerprint

From a trusted console/session on the **old server**, run as root:

```bash
sudo -i

for host_key in /etc/ssh/ssh_host_*_key.pub; do
  [[ -f "$host_key" ]] && ssh-keygen -lf "$host_key"
done
```

Record the fingerprint for the host-key algorithm presented by SSH. Verify it through a channel independent of the new server connection—for example the old server's console, virtualization console, or an approved inventory record.

The migration script defaults to `StrictHostKeyChecking=yes`. Do not accept a new or changed host key unless the displayed fingerprint exactly matches the independently recorded value.

### 4. Copy the public key to the old server

The migration script connects to the source as `zimbra@`, so the public key must be added to the old server's `zimbra` `authorized_keys`. On many Zimbra installations the `zimbra` account has no password or password SSH is disabled, so `ssh-copy-id zimbra@...` **will not work**.

**Recommended:** From the new server, use your existing **root SSH access** to install the public key remotely. This step uses whatever root SSH identity already works for you; `SSL_MIGRATE_KEY` is only the public key being installed and is used later for `zimbra@` connections.

On the **new server** as root:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA is empty; replace the example hostname/IP with the real source address.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY is empty; set the key file path.}"
test -s "${SSL_MIGRATE_KEY}.pub" || {
  printf 'Public key not found: %s\n' "${SSL_MIGRATE_KEY}.pub" >&2
  exit 1
}

PUB_KEY="$(cat "${SSL_MIGRATE_KEY}.pub")"

ssh -p "$OLD_SSH_PORT" \
  -o StrictHostKeyChecking=yes \
  root@"$OLD_ZIMBRA" \
  bash -s -- "$PUB_KEY" <<'REMOTE'
set -euo pipefail
pub_key="$1"
zimbra_home="$(getent passwd zimbra | awk -F: '$1 == "zimbra" { print $6 }')"
test -n "$zimbra_home"

install -d -o zimbra -g zimbra -m 0700 "$zimbra_home/.ssh"
auth_keys="$zimbra_home/.ssh/authorized_keys"
touch "$auth_keys"
chown zimbra:zimbra "$auth_keys"
chmod 0600 "$auth_keys"

if ! grep -qxF "$pub_key" "$auth_keys"; then
  printf '%s\n' "$pub_key" >> "$auth_keys"
fi

command -v restorecon >/dev/null 2>&1 && \
  restorecon -RF "$zimbra_home/.ssh"

printf 'Authorized key installed for zimbra.\n'
REMOTE
```

You can use an IP address for `OLD_ZIMBRA` (for example `10.1.0.20`). If SSH prompts for host-key confirmation, compare the fingerprint with the value verified independently in step 3. Only the `.pub` line is installed; never copy the private key to the old server. Re-running the command does not duplicate an already-present key line.

#### Alternative: `ssh-copy-id` when `zimbra` password login works

If password SSH for `zimbra` is enabled on the old server:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA is empty; replace the example hostname with the real source address.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY is empty; set the key file path.}"

ssh-copy-id \
  -i "${SSL_MIGRATE_KEY}.pub" \
  -p "$OLD_SSH_PORT" \
  "zimbra@${OLD_ZIMBRA}"
```

#### Alternative: manual install from the old server console

If root SSH from the new server is not possible, display the public key on the **new server**:

```bash
SSL_MIGRATE_KEY="${SSL_MIGRATE_KEY:-/root/.ssh/zimbra_ssl_migrate_ed25519}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY is empty; set the key file path.}"

cat "${SSL_MIGRATE_KEY}.pub"
```

Then, from a trusted root console on the **old server**, determine the actual Zimbra home and install that one public-key line manually:

```bash
ZIMBRA_SSH_HOME="$(getent passwd zimbra | awk -F: '$1 == "zimbra" { print $6 }')"
test -n "$ZIMBRA_SSH_HOME"

install -d -o zimbra -g zimbra -m 0700 "$ZIMBRA_SSH_HOME/.ssh"
touch "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"
chown zimbra:zimbra "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"
chmod 0600 "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"

vi "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"
```

Paste exactly the single `.pub` line; never paste the private key. Preserve existing authorized keys. On an SELinux system, restore the context if the command is available:

```bash
command -v restorecon >/dev/null 2>&1 && \
  restorecon -RF "$ZIMBRA_SSH_HOME/.ssh"
```

### 5. Test the exact non-interactive connection from the new server

Run as root on the **new server**:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA is empty; replace the example hostname with the real source address.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY is empty; set the key file path.}"

ssh \
  -i "$SSL_MIGRATE_KEY" \
  -p "$OLD_SSH_PORT" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  "zimbra@${OLD_ZIMBRA}" \
  'id -un; /opt/zimbra/bin/zmhostname; \
   test -s /opt/zimbra/ssl/zimbra/commercial/commercial.key; \
   test -r /opt/zimbra/ssl/zimbra/commercial/commercial.key; \
   test -s /opt/zimbra/ssl/zimbra/commercial/commercial.crt; \
   test -s /opt/zimbra/ssl/zimbra/commercial/commercial_ca.crt; \
   printf "SSL_FILES_OK\n"'
```

Expected output includes `zimbra`, the old Zimbra hostname, and `SSL_FILES_OK`. A password/passphrase prompt or host-key prompt means the non-interactive setup is not complete.

You can also inspect source permissions without displaying secret contents:

```bash
ssh \
  -i "$SSL_MIGRATE_KEY" \
  -p "$OLD_SSH_PORT" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  "zimbra@${OLD_ZIMBRA}" \
  'stat -c "%a %U:%G %n" /opt/zimbra/ssl/zimbra/commercial/commercial.*'
```

The script rejects a source `commercial.key` that is accessible to “other” users. Typical Zimbra key modes are `0740` before Zimbra 8.7 and `0640` on 8.7 and newer.

### 6. Run verify-only, then the approved deployment

From the repository directory on the **new server**, still as root:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA is empty; replace the example hostname with the real source address.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY is empty; set the key file path.}"

./zimbra_ssl_migrate.sh \
  --old "$OLD_ZIMBRA" \
  --port "$OLD_SSH_PORT" \
  --identity "$SSL_MIGRATE_KEY" \
  --verify-only
```

Only after reviewing the verify-only result, run the real deployment during the approved maintenance window:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA is empty; replace the example hostname with the real source address.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY is empty; set the key file path.}"

./zimbra_ssl_migrate.sh \
  --old "$OLD_ZIMBRA" \
  --port "$OLD_SSH_PORT" \
  --identity "$SSL_MIGRATE_KEY"
```

### 7. Revoke the temporary SSH authorization after acceptance

Do not revoke access until deployment, manual Zimbra restart, endpoint validation, and the rollback/acceptance window are complete. Then remove only the dedicated `zimbra-ssl-migrate@...` public-key line from the old server's `authorized_keys`. Preserve unrelated keys. Remove or archive the dedicated private/public key pair on the new server according to the organization's key-retention policy.

If a controlled first connection cannot be prepared, `--accept-new-host-key` enables OpenSSH's `accept-new` mode. This accepts an unseen key but rejects a changed key; it is less safe than the independent fingerprint process above.

## Quick start

Make the file executable if needed:

```bash
chmod 700 zimbra_ssl_migrate.sh
```

First perform a read-only validation. Although it does not change the destination certificate, it temporarily downloads the source private key into a mode-`0700` staging directory and removes it on exit:

```bash
./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519 \
  --verify-only
```

Then deploy during an approved change window:

```bash
./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519
```

The certificate must match the destination's current `zmhostname`. Use the override only when the mismatch is intentional and independently reviewed, such as a staged hostname/DNS cutover:

```bash
./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --allow-hostname-mismatch
```

## Command-line reference

| Option | Meaning |
| --- | --- |
| `--old HOST` | Source Zimbra hostname or IP; required |
| `--user USER` | Source SSH user; default `zimbra` |
| `--port PORT` | Source SSH port; default `22` |
| `--identity FILE` | Root-readable SSH private key; symlinks are rejected |
| `--verify-only` | Transfer and validate without destination certificate changes |
| `--allow-hostname-mismatch` | Explicitly bypass the destination `zmhostname` match gate |
| `--accept-new-host-key` | Accept an unseen source SSH host key |
| `--keep-stage` | Keep the secret staging directory after a successful run |
| `--verbose` | Also display detailed command progress/output on the console |
| `-h`, `--help` | Display help |

`--keep-stage` leaves a readable copy of the migrated private key owned by the Zimbra user. Use it only for a specific diagnostic need and remove the directory securely afterward.

The default console is intentionally concise: a colored summary, numbered phases, and only necessary success/warning/error messages. Detailed timestamps, certificate metadata, SSH diagnostics, and `zmcertmgr` output remain in the displayed log file. For troubleshooting, add `--verbose`. To disable terminal colors, set `NO_COLOR=1`:

```bash
./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519 \
  --verify-only \
  --verbose

NO_COLOR=1 ./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519 \
  --verify-only
```

## Safety and transaction behavior

- A non-blocking lock prevents concurrent SSL migrations.
- Every run gets a unique private staging directory and log file.
- Certificate files are rejected if a certificate/CA input contains private-key material.
- The source `commercial.key` is rejected if it is accessible to “other” users.
- OpenSSL validates the X.509 structure, current trust chain, server purpose, key match, expiration, and hostname.
- `zmcertmgr verifycrt` must pass before any destination change.
- Zimbra versions before 8.7 use root-mode `zmcertmgr` and key mode `0740`; detected versions 8.7 and newer use the `zimbra` user and key mode `0640`, following Zimbra's version-specific guidance.
- The deployment is accepted only when `viewdeployedcrt`, certificate SHA-256 fingerprint, trust chain, and key match all pass afterward.
- Script-generated log entries do not contain terminal color escape sequences.

The script deliberately uses the local-node `zmcertmgr` flow. On multi-node Zimbra installations, plan and validate every node separately.

## Backup and rollback

Immediately before the first destination change, the script creates:

```text
/root/zimbra-ssl-migration-backups/<timestamp.random>/
├── zimbra-ssl-predeploy.tar.gz
├── zimbra-ssl-predeploy.tar.gz.sha256
├── archive-manifest.txt
├── absent-before-deploy.txt
├── migration-info.txt
└── rollback-verification.log   # when a previous commercial set exists
```

The archive includes `/opt/zimbra/ssl` and known certificate/keystore targets that exist on the server. The script lists the archive and records a checksum before modifying the key.

If an error or interruption occurs after mutation begins, the script:

1. restores the saved destination files;
2. when the previous certificate set passes `verifycrt`, re-deploys it to restore Zimbra certificate configuration/LDAP attributes;
3. reapplies the exact file snapshot and removes known deployment files that did not exist before the run;
4. leaves services stopped/running exactly as they were—the script never performs a restart.

If the previous set is expired or otherwise invalid, native rollback may be unavailable. The file snapshot is still restored, and the script warns that Zimbra LDAP certificate attributes require manual verification. If rollback reports any failure, do not restart services; preserve the old server, log, and backup and resolve the state manually.

Backups contain private keys. They are created with restrictive permissions but must still be protected, retained according to policy, and securely removed when no longer required.

## Ctrl+C and termination

Pressing `Ctrl+C` sends `SIGINT`. The script immediately terminates the active SSH, SCP, tar, or `zmcertmgr` process group and exits with code `130`. `SIGTERM` exits with code `143`. If destination mutation has started, rollback runs before exit. Temporary secret staging data is removed unless a successful run explicitly used `--keep-stage`.

## Service activation and verification

Successful deployment changes files/configuration but does not reload running services. After reviewing the log, backup, change approval, and maintenance window, restart manually:

```bash
su - zimbra -c '/opt/zimbra/bin/zmcontrol restart'
su - zimbra -c '/opt/zimbra/bin/zmcontrol status'
su - zimbra -c '/opt/zimbra/bin/zmcertmgr viewdeployedcrt'
```

Then independently test every enabled public/internal endpoint—web/proxy, SMTP, IMAP, POP, LDAP, and mailboxd as applicable—and inspect the served chain, SANs, expiration, and client trust. Script success does not prove that DNS, load balancers, proxies, all cluster nodes, or external clients are correct.

## Testing

Repository-level SSL tests use generated certificates and fake SSH/Zimbra commands; they do not require a live server:

```bash
./tests/test_ssl.sh
```

The suite covers syntax and ShellCheck, CLI validation, verify-only immutability, successful deployment, backup integrity, deployment failure rollback, concurrency locking, immediate `Ctrl+C`, and rollback when interrupted during deployment.

These tests cannot prove compatibility with every Zimbra build, service topology, certificate authority, HSM, custom filesystem layout, or operating system. Run `--verify-only`, test a representative non-production system, and maintain an independently validated recovery plan before production use.

## Developer

Developed and maintained by [Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/).

Source repository: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## License and operational ownership

Copyright © 2026 Cuma Kurt.

This software is licensed under the **GNU Affero General Public License v3.0 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE). The “only” designation means the license grant does not automatically extend to later AGPL versions.

The operator owns every decision and outcome related to use of this script. Before production use, the operator must independently verify authorization, certificate/key provenance, source SSH identity, backup recoverability, Zimbra/version compatibility, maintenance impact, restart procedure, live endpoint behavior, renewal ownership, and rollback readiness. A zero exit code is not a substitute for operational acceptance testing.
