# Zimbra Full Migrate

[English](README.md) · [Türkçe](README.tr.md)

Yeni bir Zimbra sunucusuna geçiş için işletim araçları: mantıksal tenant ve mailbox verisi, ticari TLS sertifikaları, DKIM anahtarları ve yerel Amavis / OpenSSL kütüphane-yolu onarımı.

Bu dosya dokümantasyon dizinidir. Her aracın ayrı İngilizce ve Türkçe rehberi vardır.

> **Kullanım riski ve tüm operasyonel sorumluluk aracı kullanan kişiye/kuruma aittir.** Bu araçlar canlı Zimbra nesnelerini, mailbox verisini, TLS özel anahtarlarını, DKIM anahtarlarını ve (Amavis için) bir servis kontrol script’ini değiştirir. Yetkilendirme, yedekleme, test, uyumluluk, değişiklik onayı, kesinti, geri dönüş ve doğrulamadan yalnızca çalıştıran kişi veya kurum sorumludur. Yazılım hiçbir garanti verilmeden sunulur; yürürlükteki hukukun izin verdiği azami ölçüde geliştirici ve katkıda bulunanlar veri kaybı, anahtar ifşası, kesinti, başarısız geri dönüş, güvenlik olayı veya doğrudan/dolaylı zarardan sorumlu tutulamaz. [LICENSE](LICENSE) dosyasına bakın.

## Dokümantasyon

- **[Tenant / mailbox migrasyonu](README-TENANT.tr.md)** · [English](README-TENANT.md)  
  `zimbra_full_migrate.sh` — kaldığı yerden devam edebilen Zimbra → Zimbra tenant ve mailbox orkestratörü (SSH + REST TGZ). Sunucu klonu değildir.

- **[SSL sertifika migrasyonu](README-SSL.tr.md)** · [English](README-SSL.md)  
  `zimbra_ssl_migrate.sh` — kullanımda olan ticari veya Let's Encrypt sertifika setini yeni sunucuya kopyalar. Zimbra’yı restart etmez.

- **[DKIM migrasyonu](README-DKIM.tr.md)** · [English](README-DKIM.md)  
  `zimbra_dkim_migrate.sh` — mevcut DKIM seçicilerini ve özel anahtarlarını hedef LDAP’e kopyalar. Zimbra’yı restart etmez.

- **[Amavis OpenSSL otomatik onarım](README-AMAVIS.tr.md)** · [English](README-AMAVIS.md)  
  `zimbra_amavis_openssl_autofix.sh` — Amavis’in kalkmasını engelleyen Zimbra `libssl` / işletim sistemi `libcrypto` uyumsuzluğunu teşhis eder ve doğrulanırsa onarır. Yalnızca Amavis’i restart eder; `zmcontrol restart` çalıştırmaz.

## Tipik kesim sırası

Script’ler birbirinden bağımsızdır. **Yeni** sunucuda sık kullanılan sıra:

1. Tenant / mailbox migrasyonu (`zimbra` kullanıcısı) — [README-TENANT.tr.md](README-TENANT.tr.md)
2. SSL sertifika migrasyonu (`root`) — [README-SSL.tr.md](README-SSL.tr.md)
3. DKIM migrasyonu (`root`) — [README-DKIM.tr.md](README-DKIM.tr.md)
4. Gelen posta `OPENSSL_x.y.z not found` ile düşüyorsa Amavis OpenSSL onarımı (`root`) — [README-AMAVIS.tr.md](README-AMAVIS.tr.md)
5. Her log incelendikten sonra işletenin kendi `zmcontrol restart` ve kabul testleri

SSL ve DKIM, eski sunucuya aynı root SSH kimliğini kullanır; genelde `/root/.ssh/id_ed25519_zimbra`. Tenant orkestratörünün kendi `zimbra` → `zimbra` SSH kurulumu vardır. Amavis script’i yeredir, SSH kullanmaz.

## Testler

| Paket | Komut |
| --- | --- |
| Tenant / mailbox | `./tests/test.sh` |
| SSL | `./tests/test_ssl.sh` |
| DKIM | `./tests/test_dkim.sh` |
| Amavis OpenSSL | `./tests/test_amavis.sh` |

Paketler Bash, ShellCheck ve (tenant ile SSL kesme testleri için) Python 3 ister. Sahte Zimbra/SSH komutları kullanır; canlı sunucu gerekmez.

## Geliştirici

Geliştiren ve sürdüren: [Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/).

Kaynak deposu: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## Lisans

Telif hakkı © 2026 Cuma Kurt.

Bu proje **GNU Affero General Public License v3.0 only** (`AGPL-3.0-only`) ile lisanslanmıştır. [LICENSE](LICENSE) dosyasına bakın. “only” ifadesi, lisansın sonraki AGPL sürümlerine kendiliğinden uzamadığı anlamına gelir.
