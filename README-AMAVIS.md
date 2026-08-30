# Zimbra Amavis OpenSSL Autofix

[English](README-AMAVIS.md) · [Türkçe](README-AMAVIS.tr.md)

`zimbra_amavis_openssl_autofix.sh` diagnoses a specific Amavis startup failure on a Zimbra host: `Net::SSLeay` loads Zimbra's `libssl.so.3` together with the operating system's `libcrypto.so.3` and exits with `OPENSSL_x.y.z not found`. When that exact mismatch is reproduced, the script inserts an idempotent `LD_LIBRARY_PATH` fix into `zmamavisdctl`, validates syntax, and restarts **Amavis only**.

This document applies only to `zimbra_amavis_openssl_autofix.sh`. Tenant/mailbox, SSL, and DKIM migration scripts have separate documentation.

> **Use at your own risk — all operational responsibility belongs to the operator.** This script modifies a Zimbra control script and can restart Amavis. The person or organization running it is solely responsible for authorization, change approval, backups, testing, compatibility, downtime, rollback, mail-flow validation, and any queue flush. The software is provided without warranty; to the maximum extent permitted by applicable law, the author and contributors are not liable for data loss, outage, failed rollback, security incidents, or direct/indirect damage. See [LICENSE](LICENSE).

## Scope

The script:

- runs on the Zimbra server as `root`
- does **not** connect to another host and does **not** need an SSH identity
- reproduces `Net::SSLeay` in a clean Zimbra environment with `LD_LIBRARY_PATH` removed
- confirms that putting `/opt/zimbra/common/lib` first makes the same test succeed
- refuses to patch unless the failure text matches the OpenSSL / `libssl` / `libcrypto` / `Net::SSLeay` signature
- creates a timestamped backup of `/opt/zimbra/bin/zmamavisdctl` before modification
- inserts a marked `export LD_LIBRARY_PATH=...` block immediately after the standalone `zmsetvars` line
- is idempotent; it will not add the block twice
- runs `bash -n` after the edit and restores the backup if syntax validation fails
- restarts Amavis with `zmamavisdctl restart` only when a repair is applied or Amavis is down after a confirmed diagnosis
- does **not** run `zmcontrol restart`

It does not generate certificates, change DKIM or DNS, rewrite Amavis policy, or repair unrelated Amavis/Perl failures.

## Requirements

- a conventional Zimbra installation under `/opt/zimbra` (OpenSSL 3 / `libssl.so.3` layout)
- Bash, Perl, `runuser`, `awk`, `grep`, `sed`, `flock`, `setsid`
- execution as `root`
- a valid `zimbra` operating-system user
- writable `zmamavisdctl` when running `--fix`
- enough space under `/root/zimbra-amavis-openssl-autofix` for the lock and short-lived run directory

`ss` is optional. When it is present, ports `10024` and `10026` are required after a restart. `postqueue` is optional and used only for the queue summary / `--flush-queue`.

## Diagnose first

```bash
sudo ./zimbra_amavis_openssl_autofix.sh --check-only
```

`--verify-only` is an alias of `--check-only`.

| Exit code | Meaning |
| --- | --- |
| `0` | Amavis is healthy, or the library-path issue is not present |
| `10` | The exact issue was reproduced; a repair would be required |
| `3` | Amavis is down, but the OpenSSL library-path issue was **not** reproduced |
| `2` | Invalid command-line arguments |
| `1` | Failure |

Check-only never modifies `zmamavisdctl` and never restarts a service.

## Repair

When check-only exits `10` and you have a maintenance window:

```bash
sudo ./zimbra_amavis_openssl_autofix.sh --fix
```

`--fix` is the default.

After a successful repair, Amavis has been restarted through `zmamavisdctl`. Other Zimbra services are left as they were. If mail is queued and you explicitly want Postfix to retry immediately:

```bash
sudo ./zimbra_amavis_openssl_autofix.sh --fix --flush-queue
```

Use `--verbose` to print command output on the console. File logs never include ANSI color. `NO_COLOR=1` disables color even on a TTY.

## What the patch looks like

The script requires exactly one standalone `zmsetvars` line in `zmamavisdctl`. After that line it inserts:

```bash
# ZIMBRA_AMAVIS_OPENSSL_FIX_BEGIN
export LD_LIBRARY_PATH=/opt/zimbra/common/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# ZIMBRA_AMAVIS_OPENSSL_FIX_END
```

The path follows `ZIMBRA_HOME` (default `/opt/zimbra`). Ownership and mode of `zmamavisdctl` are copied from the backup.

A backup is written next to the original file:

```text
/opt/zimbra/bin/zmamavisdctl.backup-YYYYMMDD-HHMMSS
```

If syntax validation fails, that backup is restored immediately.

## What this script will not do

- Patch when the baseline `Net::SSLeay` test already succeeds (the mismatch is not present)
- Patch when the workaround test also fails (a different root cause)
- Patch when the failure text does not look like the OpenSSL library-path signature
- Patch when `zmamavisdctl` does not contain exactly one standalone `zmsetvars` line
- Restart the full Zimbra stack
- Restart Amavis in `--check-only` mode
- Restart Amavis when the marked patch is already present and Amavis plus its listeners are healthy

A successful repair still leaves interactive `perl -MNet::SSLeay` failing unless you export `LD_LIBRARY_PATH` yourself. That is intentional: the persistent fix is scoped to Amavis startup, not every Zimbra shell.

## Ctrl+C and termination

Pressing `Ctrl+C` sends `SIGINT`. The script terminates the active `runuser` / Amavis control process group and exits with code `130`. `SIGTERM` exits with code `143`. A second concurrent run fails on the lock file instead of patching twice.

If you interrupt after the file was already replaced, keep the timestamped backup and inspect `zmamavisdctl` before starting Amavis again.

## Logs and lock

Each run writes a unique log:

```text
/var/log/zimbra-amavis-openssl-autofix-YYYYMMDD_HHMMSS.XXXXXX.log
```

The exclusive lock is:

```text
/root/zimbra-amavis-openssl-autofix/.zimbra-amavis-openssl-autofix.lock
```

Override roots in isolated tests with `ZIMBRA_HOME`, `RUN_ROOT`, `LOG_ROOT`, `LOCK_FILE`, and `AMAVIS_RESTART_WAIT`.

## Testing

Repository-level tests use fake `runuser`, `perl`, `ss`, and Zimbra commands; they do not require a live server:

```bash
./tests/test_amavis.sh
```

The suite covers syntax and ShellCheck, CLI validation, check-only immutability, successful repair, already-patched skip, healthy and unrelated-down exits, refused signatures, refused `zmsetvars` ambiguity, optional queue flush, concurrency locking, and immediate `Ctrl+C`.

These tests cannot prove compatibility with every Zimbra build, custom `zmamavisdctl`, or operating-system OpenSSL layout. Run `--check-only` on the target host, confirm the diagnosis, and keep the backup until mail flow is accepted.

## Developer

Developed and maintained by [Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/).

Source repository: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## License and operational ownership

Copyright © 2026 Cuma Kurt.

This software is licensed under the **GNU Affero General Public License v3.0 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE). The “only” designation means the license grant does not automatically extend to later AGPL versions.

The operator owns every decision and outcome related to use of this script. Before production use, the operator must independently verify authorization, Zimbra/version compatibility, backup recoverability, maintenance impact, Amavis restart impact on inbound mail, and rollback readiness. A zero exit code is not a substitute for operational acceptance testing.
