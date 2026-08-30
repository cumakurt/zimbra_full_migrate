# Zimbra DKIM Migration

[English](README-DKIM.md) · [Türkçe](README-DKIM.tr.md)

`zimbra_dkim_migrate.sh` copies already deployed DKIM selectors, identities, and private keys from an old Zimbra server to a new Zimbra server. It validates each key pair, optionally checks public DNS, imports LDAP attributes, verifies the result, and never restarts Zimbra services.

This document applies only to `zimbra_dkim_migrate.sh`. Tenant/mailbox and SSL migration scripts have separate documentation.

> **Use at your own risk — all operational responsibility belongs to the operator.** This script handles DKIM private keys and changes live Zimbra LDAP domain attributes. The person or organization running it is solely responsible for authorization, key custody, SSH host verification, DNS, backups, testing, compatibility, change approval, downtime, rollback, service restart, and validation of outbound mail authentication. The software is provided without warranty; to the maximum extent permitted by applicable law, the author and contributors are not liable for data loss, key exposure, outage, failed rollback, security incidents, or direct/indirect damage. See [LICENSE](LICENSE).

## Scope

The script:

- runs on the new/destination Zimbra server as `root`
- connects to the old/source server over non-interactive SSH as `zimbra`
- lists source domains (`zmprov gad`) unless `--domain` is repeated
- exports each domain's DKIM configuration with `zmdkimkeyutil -q`
- validates selector, identity, private key, and stored `p=` against the derived public key
- optionally compares public DNS `selector._domainkey.domain` TXT with the source key
- refuses selector collisions on the destination
- backs up the current destination DKIM query before replacement
- imports the source key into destination LDAP
- rolls back the previous destination DKIM if import or post-import verification fails
- does **not** generate new DKIM keys, change DNS, or restart Zimbra services

OpenDKIM / `amavis` / MTA processes keep using the previously loaded key until you restart them yourself.

## Requirements

Destination:

- a conventional Zimbra installation under `/opt/zimbra`
- Bash, OpenSSL, Perl, `ssh`, `awk`, `grep`, `sed`, `sha256sum`, `flock`, `setsid`
- execution as `root`
- a valid `zimbra` operating-system user
- enough space under `/root/zimbra-dkim-migration`

Source:

- SSH access as `zimbra` by default
- key-based/non-interactive authentication (`BatchMode=yes`)
- `zmprov` and `zmdkimkeyutil` on the source host

Use the same dedicated root SSH key as SSL migration. Do not create a second key unless the first one was lost.

## SSH key and run

If you already completed the SSL SSH steps, skip key creation and reuse `/root/.ssh/id_ed25519_zimbra`.

### 1. Create the key on the new server as root (only if it does not exist)

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_zimbra
```

### 2. Append the public key on the old server (only if it is not already there)

On the **new server**:

```bash
cat /root/.ssh/id_ed25519_zimbra.pub
```

On the **old server**, as root, append that **one line** to the end of `/opt/zimbra/.ssh/authorized_keys`. Create the directory if needed. Do not overwrite existing keys.

```bash
mkdir -p /opt/zimbra/.ssh
chmod 700 /opt/zimbra/.ssh
chown zimbra:zimbra /opt/zimbra/.ssh
vi /opt/zimbra/.ssh/authorized_keys
chown zimbra:zimbra /opt/zimbra/.ssh/authorized_keys
chmod 600 /opt/zimbra/.ssh/authorized_keys
```

### 3. Run the script on the new server as root

Optional read-only check first:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --dry-run
```

Then migrate:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra
```

After the change is accepted, remove only this public-key line from the old server's `authorized_keys` if no other migration still needs it. If the source host key is not yet in root's `known_hosts`, add `--accept-new-host-key`.

## Quick start

```bash
chmod 700 zimbra_dkim_migrate.sh
```

Complete the SSH steps above, then run `--dry-run` / `--verify-only` before the real import. Dry-run exports and validates source keys and reviews the destination; it does not change LDAP.

Limit the run to one domain:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --domain example.com \
  --dry-run
```

Require public DNS to match the source key:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --strict-dns
```

## Command-line reference

| Option | Meaning |
| --- | --- |
| `--old HOST` | Source Zimbra hostname or IP; required |
| `--user USER` | Source SSH user; default `zimbra` |
| `--port PORT` | Source SSH port; default `22` |
| `--identity FILE` | Root-readable SSH private key; symlinks are rejected |
| `--dry-run`, `--verify-only` | Export and validate without destination LDAP changes |
| `--strict-dns` | Fail when DNS TXT is missing or does not match the source `p=` |
| `--skip-dns` | Skip DNS validation |
| `--no-replace` | Skip domains that already have a different destination DKIM |
| `--fail-fast` | Stop on the first domain failure |
| `--domain DOMAIN` | Migrate only this domain; repeatable |
| `--purge-source-export` | Delete exported source private keys after a fully successful run |
| `--accept-new-host-key` | Accept an unseen source SSH host key |
| `--verbose` | Also display detailed command progress on the console |
| `-h`, `--help` | Display help |

The default console is concise: a colored summary, numbered phases, and only necessary success/warning/error messages. Detailed timestamps and command output remain in the displayed log file. For troubleshooting, add `--verbose`. To disable terminal colors, set `NO_COLOR=1`.

## Safety and transaction behavior

- A non-blocking lock prevents concurrent DKIM migrations.
- Every run gets a unique private directory under `/root/zimbra-dkim-migration`.
- Source host keys default to `StrictHostKeyChecking=yes`.
- SSH identity files must be regular files; symlinks are rejected.
- Domain and selector values are validated before SSH/LDAP use.
- LDAP filters escape domain and selector values.
- LDAP StartTLS verifies the directory certificate against `/opt/zimbra/conf/ca`.
- A destination DKIM is removed only immediately before import, after a parsed backup exists.
- Failed import or failed post-import verification restores the previous destination DKIM when one existed.
- Script-generated log entries do not contain terminal color escape sequences.
- The script never restarts Zimbra services.

## Working directory

```text
/root/zimbra-dkim-migration/<timestamp>/
├── migration.log
├── report.tsv
├── summary.txt
├── source/                 # exported source queries (contain private keys)
├── parsed/
├── target-before/          # destination DKIM before replacement
└── state/
```

These files contain DKIM private keys. Protect the directory, retain it according to policy, and remove it securely when no longer required. `--purge-source-export` deletes only the source export after a successful non-dry run.

## Ctrl+C and termination

`Ctrl+C` sends `SIGINT` and exits `130`. `SIGTERM` exits `143`. The active SSH or Zimbra command group is stopped. A domain that was mid-import may need manual inspection of the run directory and `zmdkimkeyutil -q`.

## Service activation and verification

LDAP is updated immediately, but running OpenDKIM/MTA processes are not reloaded. After review, restart during an approved window:

```bash
su - zimbra -c '/opt/zimbra/bin/zmcontrol restart'
su - zimbra -c '/opt/zimbra/libexec/zmdkimkeyutil -q -d example.com'
su - zimbra -c '/opt/zimbra/common/sbin/opendkim-testkey -d example.com -s SELECTOR -x /opt/zimbra/conf/opendkim.conf'
```

Then send a test message and inspect the `DKIM-Signature` header independently.

## Testing

```bash
./tests/test_dkim.sh
```

The suite covers syntax and ShellCheck, CLI validation, dry-run immutability, successful import, already-identical detection, and concise SSH failures. It does not require a live Zimbra server.

These tests cannot prove compatibility with every Zimbra build, LDAP topology, or DNS environment.

## Developer

Developed and maintained by [Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/).

Source repository: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## License and operational ownership

Copyright © 2026 Cuma Kurt.

This software is licensed under the **GNU Affero General Public License v3.0 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE).

The operator owns every decision and outcome related to use of this script. A zero exit code is not a substitute for operational acceptance testing.
