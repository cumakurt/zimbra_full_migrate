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

## SSH key and run

The script runs as **root on the new server** and connects to the old server as `zimbra`. Create a dedicated key, authorize only the public key on the old server, then pass the private-key path to the script. Never copy the private key to the old server.

### 1. Create the key on the new server as root

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_zimbra
```

### 2. Append the public key on the old server

On the **new server**, display the public key:

```bash
cat /root/.ssh/id_ed25519_zimbra.pub
```

On the **old server**, as root, append that **one line** to the end of `/opt/zimbra/.ssh/authorized_keys`. Create `/opt/zimbra/.ssh` if it does not exist. Do not overwrite existing keys.

```bash
mkdir -p /opt/zimbra/.ssh
chmod 700 /opt/zimbra/.ssh
chown zimbra:zimbra /opt/zimbra/.ssh
vi /opt/zimbra/.ssh/authorized_keys
```

Then:

```bash
chown zimbra:zimbra /opt/zimbra/.ssh/authorized_keys
chmod 600 /opt/zimbra/.ssh/authorized_keys
```

### 3. Run the script on the new server as root

Optional read-only check first:

```bash
./zimbra_ssl_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --verify-only
```

Then deploy:

```bash
./zimbra_ssl_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra
```

After the change is accepted, remove only this public-key line from the old server's `authorized_keys`. If the source host key is not yet in root's `known_hosts`, add `--accept-new-host-key`.

## Quick start

Make the file executable if needed:

```bash
chmod 700 zimbra_ssl_migrate.sh
```

Complete the three steps above, then run `--verify-only` before the real deploy. `--verify-only` does not change the destination certificate; it temporarily downloads the source private key into a mode-`0700` staging directory and removes it on exit.

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
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --verify-only \
  --verbose

NO_COLOR=1 ./zimbra_ssl_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
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
