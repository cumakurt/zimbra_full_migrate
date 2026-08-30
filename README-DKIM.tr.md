# Zimbra DKIM Migrasyonu

[English](README-DKIM.md) · [Türkçe](README-DKIM.tr.md) · [Index](README.tr.md)

`zimbra_dkim_migrate.sh`, eski Zimbra sunucusundaki mevcut DKIM seçicilerini, kimliklerini ve özel anahtarlarını yeni Zimbra sunucusuna kopyalar. Her anahtar çiftini doğrular, isteğe bağlı olarak genel DNS’i kontrol eder, LDAP özniteliklerini içe aktarır, sonucu doğrular ve Zimbra servislerini restart etmez.

Bu belge yalnızca `zimbra_dkim_migrate.sh` içindir. Diğer araçlar için [dokümantasyon dizinine](README.tr.md) bakın.

> **Kullanım riski ve tüm operasyonel sorumluluk aracı kullanan kişiye/kuruma aittir.** Bu script DKIM özel anahtarlarını işler ve canlı Zimbra LDAP domain özniteliklerini değiştirir. Yetkilendirme, anahtar güvenliği, SSH host doğrulaması, DNS, yedekleme, test, uyumluluk, değişiklik onayı, kesinti, geri dönüş, servis restart’ı ve giden posta kimlik doğrulamasından yalnızca script’i çalıştıran kişi veya kurum sorumludur. Yazılım hiçbir garanti verilmeden sunulur; yürürlükteki hukukun izin verdiği azami ölçüde geliştirici ve katkıda bulunanlar veri kaybı, anahtar ifşası, kesinti, başarısız geri dönüş, güvenlik olayı veya doğrudan/dolaylı zarardan sorumlu tutulamaz. [LICENSE](LICENSE) dosyasına bakın.

## Kapsam

Script:

- yeni/hedef Zimbra sunucusunda `root` olarak çalışır;
- eski/kaynak sunucuya `zimbra` kullanıcısıyla etkileşimsiz SSH ile bağlanır;
- `--domain` tekrarlanmadıkça kaynak domain’leri (`zmprov gad`) listeler;
- her domain’in DKIM yapılandırmasını `zmdkimkeyutil -q` ile dışa aktarır;
- seçiciyi, kimliği, özel anahtarı ve saklanan `p=` değerini türetilen açık anahtarla doğrular;
- isteğe bağlı olarak genel DNS `selector._domainkey.domain` TXT kaydını kaynak anahtarla karşılaştırır;
- hedefte seçici çakışmasını reddeder;
- değiştirmeden önce hedefin mevcut DKIM sorgusunu yedekler;
- kaynak anahtarı hedef LDAP’e aktarır;
- içe aktarma veya sonradan doğrulama başarısız olursa önceki hedef DKIM’i geri yükler;
- yeni DKIM anahtarı **üretmez**, DNS değiştirmez ve Zimbra servislerini **restart etmez**.

OpenDKIM / `amavis` / MTA süreçleri siz restart edene kadar eski yüklenmiş anahtarı kullanmaya devam eder.

## Gereksinimler

Hedef:

- `/opt/zimbra` altında standart bir Zimbra kurulumu;
- Bash, OpenSSL, Perl, `ssh`, `awk`, `grep`, `sed`, `sha256sum`, `flock`, `setsid`;
- `root` olarak çalıştırma;
- geçerli bir `zimbra` işletim sistemi kullanıcısı;
- `/root/zimbra-dkim-migration` altında yeterli alan.

Kaynak:

- varsayılan olarak `zimbra` kullanıcısıyla SSH;
- anahtar tabanlı/etkileşimsiz kimlik doğrulama (`BatchMode=yes`);
- kaynakta `zmprov` ve `zmdkimkeyutil`.

SSL migrasyonuyla **aynı** root SSH anahtarını kullanın. İlk anahtar kaybedilmedikçe ikinci bir anahtar üretmeyin.

## SSH anahtarı ve çalıştırma

SSL SSH adımlarını zaten tamamladıysanız anahtar oluşturmayı atlayıp `/root/.ssh/id_ed25519_zimbra` dosyasını yeniden kullanın.

### 1. Yeni sunucuda root olarak anahtar oluşturun (yalnızca yoksa)

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_zimbra
```

### 2. Açık anahtarı eski sunucuya ekleyin (yalnızca yoksa)

**Yeni sunucuda:**

```bash
cat /root/.ssh/id_ed25519_zimbra.pub
```

**Eski sunucuda** root olarak bu **tek satırı** `/opt/zimbra/.ssh/authorized_keys` dosyasının sonuna ekleyin. Dizin yoksa oluşturun. Mevcut anahtarların üzerine yazmayın.

```bash
mkdir -p /opt/zimbra/.ssh
chmod 700 /opt/zimbra/.ssh
chown zimbra:zimbra /opt/zimbra/.ssh
vi /opt/zimbra/.ssh/authorized_keys
chown zimbra:zimbra /opt/zimbra/.ssh/authorized_keys
chmod 600 /opt/zimbra/.ssh/authorized_keys
```

### 3. Script’i yeni sunucuda root olarak çalıştırın

İsterseniz önce salt doğrulama:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --dry-run
```

Sonra migrasyon:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra
```

İşlem kabul edildikten sonra, başka bir migrasyon bu anahtarı kullanmıyorsa eski sunucunun `authorized_keys` dosyasından yalnızca bu satırı silin. Kaynak host anahtarı henüz root `known_hosts` içinde değilse `--accept-new-host-key` ekleyin.

## Hızlı başlangıç

```bash
chmod 700 zimbra_dkim_migrate.sh
```

Yukarıdaki SSH adımlarını tamamlayın; gerçek içe aktarmadan önce `--dry-run` / `--verify-only` çalıştırın. Dry-run kaynak anahtarlarını dışa aktarıp doğrular ve hedefi inceler; LDAP’i değiştirmez.

Tek domain:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --domain example.com \
  --dry-run
```

Genel DNS’in kaynak anahtarla eşleşmesini zorunlu kılın:

```bash
./zimbra_dkim_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --strict-dns
```

## Komut satırı referansı

| Seçenek | Anlamı |
| --- | --- |
| `--old HOST` | Kaynak Zimbra hostname/IP; zorunlu |
| `--user USER` | Kaynak SSH kullanıcısı; varsayılan `zimbra` |
| `--port PORT` | Kaynak SSH portu; varsayılan `22` |
| `--identity FILE` | Root tarafından okunabilir SSH özel anahtarı; sembolik bağlantı reddedilir |
| `--dry-run`, `--verify-only` | Hedef LDAP’i değiştirmeden dışa aktar ve doğrula |
| `--strict-dns` | DNS TXT yoksa veya kaynak `p=` ile eşleşmiyorsa başarısız ol |
| `--skip-dns` | DNS doğrulamasını atla |
| `--no-replace` | Hedefte farklı DKIM varsa domain’i atla |
| `--fail-fast` | İlk domain hatasında dur |
| `--domain DOMAIN` | Yalnızca bu domain’i taşı; tekrarlanabilir |
| `--purge-source-export` | Tam başarılı çalışmadan sonra dışa aktarılan kaynak özel anahtarlarını sil |
| `--accept-new-host-key` | Daha önce görülmemiş kaynak SSH host anahtarını kabul et |
| `--verbose` | Ayrıntılı komut ilerlemesini konsolda da göster |
| `-h`, `--help` | Yardımı göster |

Varsayılan konsol sadedir: renkli özet, numaralı fazlar ve yalnızca gerekli başarı/uyarı/hata mesajları. Ayrıntılar log dosyasındadır. Sorun giderirken `--verbose` ekleyin. Renkleri kapatmak için `NO_COLOR=1` kullanın.

## Güvenlik ve işlem davranışı

- Non-blocking kilit, eşzamanlı iki DKIM migrasyonunu engeller.
- Her çalışma `/root/zimbra-dkim-migration` altında benzersiz özel dizin kullanır.
- Kaynak host anahtarı varsayılanı `StrictHostKeyChecking=yes` değeridir.
- SSH kimlik dosyası düzenli dosya olmalıdır; sembolik bağlantı reddedilir.
- Domain ve seçici değerleri SSH/LDAP kullanımından önce doğrulanır.
- LDAP filtrelerinde domain ve seçici kaçışlanır.
- LDAP StartTLS, dizin sertifikasını `/opt/zimbra/conf/ca` ile doğrular.
- Hedef DKIM, yalnızca yedek alındıktan ve içe aktarmadan hemen önce kaldırılır.
- İçe aktarma veya sonradan doğrulama başarısız olursa önceki hedef DKIM geri yüklenir.
- Script’in ürettiği log satırları terminal renk kaçış dizileri içermez.
- Script Zimbra servislerini restart etmez.

## Çalışma dizini

```text
/root/zimbra-dkim-migration/<timestamp>/
├── migration.log
├── report.tsv
├── summary.txt
├── source/                 # dışa aktarılan kaynak sorguları (özel anahtar içerir)
├── parsed/
├── target-before/          # değiştirme öncesi hedef DKIM
└── state/
```

Bu dosyalar DKIM özel anahtarı içerir. Dizini koruyun, politikaya göre saklayın ve gerek kalmadığında güvenli biçimde silin. `--purge-source-export` yalnızca başarılı, dry-run olmayan çalışmadan sonra kaynak dışa aktarımını siler.

## Ctrl+C ve sonlandırma

`Ctrl+C`, `SIGINT` gönderir ve `130` ile çıkar. `SIGTERM` çıkış kodu `143` olur. Etkin SSH veya Zimbra komut grubu durdurulur. İçe aktarma ortasında kesilen bir domain için çalışma dizinini ve `zmdkimkeyutil -q` çıktısını elle kontrol edin.

## Servis aktivasyonu ve doğrulama

LDAP hemen güncellenir; çalışan OpenDKIM/MTA süreçleri yeniden yüklenmez. İncelemeden sonra onaylı pencerede restart edin:

```bash
su - zimbra -c '/opt/zimbra/bin/zmcontrol restart'
su - zimbra -c '/opt/zimbra/libexec/zmdkimkeyutil -q -d example.com'
su - zimbra -c '/opt/zimbra/common/sbin/opendkim-testkey -d example.com -s SELECTOR -x /opt/zimbra/conf/opendkim.conf'
```

Ardından test ileti gönderip `DKIM-Signature` başlığını bağımsız doğrulayın.

## Test

```bash
./tests/test_dkim.sh
```

Paket; sözdizimi ve ShellCheck’i, CLI doğrulamasını, dry-run değişmezliğini, başarılı içe aktarmayı, zaten aynı olan yapılandırmayı ve sade SSH hatalarını kapsar. Canlı Zimbra sunucusu gerekmez.

Bu testler her Zimbra build’i, LDAP topolojisi veya DNS ortamıyla uyumluluğu kanıtlayamaz.

## Geliştirici

[Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/) tarafından geliştirilmekte ve sürdürülmektedir.

Kaynak depo: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## Lisans ve operasyonel sahiplik

Telif hakkı © 2026 Cuma Kurt.

Bu yazılım yalnızca **GNU Affero General Public License v3.0** (`AGPL-3.0-only`) ile lisanslanmıştır. Ayrıntılar için [LICENSE](LICENSE) dosyasına bakın.

Script’in kullanımıyla ilgili her kararın ve sonucun sahibi operatördür. Sıfır çıkış kodu operasyonel kabul testinin yerine geçmez.
