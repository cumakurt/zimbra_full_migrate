# Zimbra Full Migrate

[English](README.md) · [Türkçe](README.tr.md)

Operational tools for moving a Zimbra installation to a new host: logical tenant and mailbox data, commercial TLS certificates, DKIM keys, and a local Amavis / OpenSSL library-path repair.

This file is the documentation index. Each tool has its own English and Turkish guide.

> **Use at your own risk — all operational responsibility belongs to the operator.** These tools change live Zimbra objects, mailbox data, TLS private keys, DKIM keys, and (for Amavis) a service control script. The person or organization running them is solely responsible for authorization, backups, testing, compatibility, change approval, downtime, rollback, and validation. The software is provided without warranty; to the maximum extent permitted by applicable law, the author and contributors are not liable for data loss, key exposure, outage, failed rollback, security incidents, or direct/indirect damage. See [LICENSE](LICENSE).

## Documentation

- **[Tenant / mailbox migration](README-TENANT.md)** · [Türkçe](README-TENANT.tr.md)  
  `zimbra_full_migrate.sh` — resumable Zimbra-to-Zimbra tenant and mailbox orchestrator (SSH + REST TGZ). Does not clone the host.

- **[SSL certificate migration](README-SSL.md)** · [Türkçe](README-SSL.tr.md)  
  `zimbra_ssl_migrate.sh` — copies an already deployed commercial or Let's Encrypt certificate set to the new host. Does not restart Zimbra.

- **[DKIM migration](README-DKIM.md)** · [Türkçe](README-DKIM.tr.md)  
  `zimbra_dkim_migrate.sh` — copies already deployed DKIM selectors and private keys into destination LDAP. Does not restart Zimbra.

- **[Amavis OpenSSL autofix](README-AMAVIS.md)** · [Türkçe](README-AMAVIS.tr.md)  
  `zimbra_amavis_openssl_autofix.sh` — diagnoses and, when confirmed, repairs the Zimbra `libssl` / OS `libcrypto` mismatch that prevents Amavis from starting. Restarts Amavis only; never runs `zmcontrol restart`.

## Typical cutover order

These scripts are independent. A common sequence on the **new** server is:

1. Tenant / mailbox migration (`zimbra` user) — [README-TENANT.md](README-TENANT.md)
2. SSL certificate migration (`root`) — [README-SSL.md](README-SSL.md)
3. DKIM migration (`root`) — [README-DKIM.md](README-DKIM.md)
4. Amavis OpenSSL repair if inbound mail fails with `OPENSSL_x.y.z not found` (`root`) — [README-AMAVIS.md](README-AMAVIS.md)
5. Operator-owned `zmcontrol restart` and acceptance tests after reviewing each log

SSL and DKIM reuse the same root SSH identity to the old host, typically `/root/.ssh/id_ed25519_zimbra`. The tenant orchestrator uses its own `zimbra`-to-`zimbra` SSH setup. The Amavis script is local and does not use SSH.

## Tests

| Suite | Command |
| --- | --- |
| Tenant / mailbox | `./tests/test.sh` |
| SSL | `./tests/test_ssl.sh` |
| DKIM | `./tests/test_dkim.sh` |
| Amavis OpenSSL | `./tests/test_amavis.sh` |

The suites require Bash, ShellCheck, and (for tenant and SSL interrupt tests) Python 3. They use fake Zimbra/SSH commands and do not need a live server.

## Developer

Developed and maintained by [Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/).

Source repository: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## License

Copyright © 2026 Cuma Kurt.

This project is licensed under the **GNU Affero General Public License v3.0 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE). The “only” designation means this grant does not automatically extend to later AGPL versions.
