# Zimbra SSL Migrasyonu

[English](README-SSL.md) · [Türkçe](README-SSL.tr.md) · [Index](README.tr.md)

`zimbra_ssl_migrate.sh`, eski bir Zimbra sunucusunda kullanımda olan ticari veya Let's Encrypt sertifika setini güvenli biçimde yeni Zimbra sunucusuna taşır. Hedefte değişiklik yapmadan önce sertifikayı, özel anahtarı, CA zincirini, geçerlilik zamanını, hostname eşleşmesini ve Zimbra uyumluluğunu doğrular.

Bu belge yalnızca `zimbra_ssl_migrate.sh` içindir. Diğer araçlar için [dokümantasyon dizinine](README.tr.md) bakın.

> **Kullanım riski ve tüm operasyonel sorumluluk aracı kullanan kişiye/kuruma aittir.** Bu script canlı TLS özel anahtarlarını işler; etkin Zimbra sertifika dosyalarını ve yapılandırmasını değiştirir. Yetkilendirme, anahtar güvenliği, SSH host doğrulaması, yedekleme, test, uyumluluk, değişiklik onayı, kesinti, geri dönüş, servis restart’ı, sertifika yenileme, mevzuata uyum ve istemcilere açık bütün servislerin doğrulanmasından yalnızca script’i çalıştıran kişi veya kurum sorumludur. Yazılım hiçbir garanti verilmeden sunulur; yürürlükteki hukukun izin verdiği azami ölçüde geliştirici ve katkıda bulunanlar veri kaybı, anahtar ifşası, kesinti, başarısız geri dönüş, güvenlik olayı veya doğrudan/dolaylı zarardan sorumlu tutulamaz. [LICENSE](LICENSE) dosyasına bakın.

## Kapsam

Script:

- yeni/hedef Zimbra sunucusunda `root` olarak çalışır;
- eski/kaynak sunucuya etkileşimsiz SSH ile bağlanır;
- kaynaktaki şu dosyaları okur:
  - `/opt/zimbra/ssl/zimbra/commercial/commercial.key`
  - `/opt/zimbra/ssl/zimbra/commercial/commercial.crt`
  - `/opt/zimbra/ssl/zimbra/commercial/commercial_ca.crt`
- deploy edilmiş `commercial.crt` eklenmiş CA zinciri içerebildiği için ilk sertifikayı leaf olarak ayırır;
- özel anahtarı, leaf sertifikayı, sunucu güven zincirini, güncel geçerliliği, hedef `zmhostname` değerini ve `zmcertmgr verifycrt` sonucunu doğrular;
- hedefi değiştirmeden hemen önce özel ve doğrulanmış bir yedek oluşturur;
- anahtarı Zimbra sürümüne uygun izinlerle kurar ve sertifikayı `zmcertmgr` ile deploy eder;
- deploy edilen sertifikanın parmak izini, zincirini, anahtar eşleşmesini ve `viewdeployedcrt` sonucunu doğrular;
- Zimbra servislerini **restart etmez**.

Sertifika üretmez/yenilemez, DNS değiştirmez, çok sunuculu kurulumun bütün node’larına otomatik kopyalama yapmaz ve restart sonrasında dışarıya sunulan TLS endpoint’ini test etmez.

## Gereksinimler

Hedef:

- `/opt/zimbra` altında standart bir Zimbra kurulumu;
- Bash ve `x509` komutunda `-checkhost` desteği bulunan OpenSSL;
- preflight sırasında kontrol edilen `ssh`, `scp`, `openssl`, `awk`, `grep`, `sed`, `sha256sum`, `tar`, `flock`, `setsid` ve diğer standart araçlar;
- `root` olarak çalıştırma;
- geçerli bir `zimbra` işletim sistemi kullanıcısı;
- mevcut SSL durumunu tutmak için `/root/zimbra-ssl-migration-backups` altında yeterli alan.

Kaynak:

- varsayılan olarak `zimbra` kullanıcısıyla SSH erişimi;
- anahtar tabanlı/etkileşimsiz kimlik doğrulama (`BatchMode=yes`);
- yukarıdaki üç commercial sertifika dosyasının boş olmaması ve okunabilmesi.

Kaynak sertifika ve özel anahtar SSH üzerinden taşınsa da son derece hassastır. Hedef log’unu, yedeği, root SSH anahtarını ve tutulması istenmiş staging dizinini koruyun.

## SSH anahtarı ve çalıştırma

Script **yeni sunucuda root olarak** çalışır ve eski sunucuya `zimbra` kullanıcısıyla bağlanır. Yeni sunucuda bir anahtar oluşturun, yalnızca açık anahtarı eski sunucuya ekleyin, sonra özel anahtar yolunu script’e verin. Özel anahtarı eski sunucuya kopyalamayın.

### 1. Yeni sunucuda root olarak anahtar oluşturun

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_zimbra
```

### 2. Açık anahtarı eski sunucuya ekleyin

**Yeni sunucuda** açık anahtarı görüntüleyin:

```bash
cat /root/.ssh/id_ed25519_zimbra.pub
```

**Eski sunucuda** root olarak bu **tek satırı** `/opt/zimbra/.ssh/authorized_keys` dosyasının sonuna ekleyin. Dizin yoksa oluşturun. Mevcut anahtarların üzerine yazmayın.

```bash
mkdir -p /opt/zimbra/.ssh
chmod 700 /opt/zimbra/.ssh
chown zimbra:zimbra /opt/zimbra/.ssh
vi /opt/zimbra/.ssh/authorized_keys
```

Ardından:

```bash
chown zimbra:zimbra /opt/zimbra/.ssh/authorized_keys
chmod 600 /opt/zimbra/.ssh/authorized_keys
```

### 3. Script’i yeni sunucuda root olarak çalıştırın

İsterseniz önce salt doğrulama:

```bash
./zimbra_ssl_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra \
  --verify-only
```

Sonra deploy:

```bash
./zimbra_ssl_migrate.sh \
  --old 10.1.0.20 \
  --identity /root/.ssh/id_ed25519_zimbra
```

İşlem kabul edildikten sonra eski sunucunun `authorized_keys` dosyasından yalnızca bu açık anahtar satırını silin. Kaynak host anahtarı henüz root `known_hosts` içinde değilse `--accept-new-host-key` ekleyin.

## Hızlı başlangıç

Gerekirse çalıştırma izni verin:

```bash
chmod 700 zimbra_ssl_migrate.sh
```

Yukarıdaki üç adımı tamamlayın; gerçek deploy’dan önce `--verify-only` çalıştırın. `--verify-only` hedef sertifikayı değiştirmez; kaynak özel anahtarını geçici olarak `0700` izinli staging dizinine indirir ve çıkışta siler.

Sertifika hedefin mevcut `zmhostname` değeriyle eşleşmelidir. Override seçeneğini yalnızca aşamalı hostname/DNS geçişi gibi, uyuşmazlığın kasıtlı ve bağımsız olarak incelendiği durumda kullanın:

```bash
./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --allow-hostname-mismatch
```

## Komut satırı referansı

| Seçenek | Anlamı |
| --- | --- |
| `--old HOST` | Kaynak Zimbra hostname/IP; zorunlu |
| `--user USER` | Kaynak SSH kullanıcısı; varsayılan `zimbra` |
| `--port PORT` | Kaynak SSH portu; varsayılan `22` |
| `--identity FILE` | Root tarafından okunabilir SSH özel anahtarı; sembolik bağlantı reddedilir |
| `--verify-only` | Hedef sertifikayı değiştirmeden aktar ve doğrula |
| `--allow-hostname-mismatch` | Hedef `zmhostname` eşleşme kapısını açıkça atla |
| `--accept-new-host-key` | Daha önce görülmemiş kaynak SSH host anahtarını kabul et |
| `--keep-stage` | Başarılı çalışmadan sonra gizli staging dizinini tut |
| `--verbose` | Ayrıntılı komut ilerlemesini/çıktısını konsolda da göster |
| `-h`, `--help` | Yardımı göster |

`--keep-stage`, taşınan özel anahtarın `zimbra` kullanıcısı tarafından okunabilen bir kopyasını bırakır. Yalnızca belirli bir teşhis ihtiyacında kullanın ve sonrasında dizini güvenli biçimde kaldırın.

Varsayılan konsol bilerek sadedir: renkli özet, numaralı fazlar ve yalnızca gerekli başarı/uyarı/hata mesajları gösterilir. Ayrıntılı zaman damgaları, sertifika metadatası, SSH teşhisleri ve `zmcertmgr` çıktısı ekranda belirtilen log dosyasında korunur. Sorun giderirken `--verbose` ekleyin. Terminal renklerini kapatmak için `NO_COLOR=1` kullanın:

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

## Güvenlik ve işlem davranışı

- Non-blocking kilit, eşzamanlı iki SSL migrasyonunu engeller.
- Her çalışma benzersiz özel staging dizini ve log dosyası kullanır.
- Sertifika/CA girdilerinden biri özel anahtar içeriği taşıyorsa işlem reddedilir.
- Kaynak `commercial.key` “other” tarafından okunabiliyorsa uyarı verilir; hedef anahtar yine sürüme uygun izinlerle kurulur.
- Kaynak CA dosyasında `zmcertmgr`’in istediği kök yoksa script zinciri hedefin güven deposundan tamamlar; süresi dolmuş CA sertifikalarını atlar.
- OpenSSL; X.509 yapısını, güncel güven zincirini, sunucu amacını, anahtar eşleşmesini, sona erme zamanını ve hostname’i doğrular.
- Hedefte ilk değişiklikten önce `zmcertmgr verifycrt` başarılı olmalıdır.
- Zimbra 8.7 öncesi sürümlerde `zmcertmgr` root kipinde ve anahtar `0740`; algılanan 8.7 ve yeni sürümlerde `zimbra` kullanıcısıyla ve anahtar `0640` kipinde kullanılır. Bu davranış Zimbra’nın sürüme özgü yönergesini izler.
- Deploy yalnızca `viewdeployedcrt`, sertifika SHA-256 parmak izi, güven zinciri ve anahtar eşleşmesi sonradan başarılıysa kabul edilir.
- Script’in ürettiği log satırları terminal renk kaçış dizileri içermez.

Script bilerek yerel node `zmcertmgr` akışını kullanır. Çok node’lu Zimbra kurulumlarında her node’u ayrı planlayıp doğrulayın.

## Yedek ve geri dönüş

İlk hedef değişikliğinden hemen önce şu yapı oluşturulur:

```text
/root/zimbra-ssl-migration-backups/<timestamp.random>/
├── zimbra-ssl-predeploy.tar.gz
├── zimbra-ssl-predeploy.tar.gz.sha256
├── archive-manifest.txt
├── absent-before-deploy.txt
├── migration-info.txt
└── rollback-verification.log   # önceki commercial set varsa
```

Arşiv `/opt/zimbra/ssl` ile sunucuda mevcut olan bilinen sertifika/keystore hedeflerini içerir. Script anahtarı değiştirmeden önce arşiv listesini okur ve checksum kaydeder.

Mutasyon başladıktan sonra hata veya kesinti olursa script:

1. kaydedilmiş hedef dosyalarını geri yükler;
2. önceki sertifika seti `verifycrt` kontrolünü geçiyorsa Zimbra sertifika yapılandırmasını/LDAP özniteliklerini geri almak için eski seti yeniden deploy eder;
3. tam dosya snapshot’ını yeniden uygular ve çalışma öncesinde bulunmayan bilinen deploy dosyalarını kaldırır;
4. servislerin çalışma durumunu değiştirmez; script hiçbir zaman restart yapmaz.

Önceki set süresi dolmuş veya geçersizse native geri dönüş kullanılamayabilir. Dosya snapshot’ı yine geri yüklenir ve Zimbra LDAP sertifika özniteliklerinin elle doğrulanması gerektiği uyarısı verilir. Geri dönüş herhangi bir hata bildirirse servisleri restart etmeyin; eski sunucuyu, log’u ve yedeği koruyup durumu elle çözün.

Yedekler özel anahtar içerir. Kısıtlı izinlerle oluşturulsalar da korunmalı, kurum politikasına göre saklanmalı ve gerek kalmadığında güvenli biçimde kaldırılmalıdır.

## Ctrl+C ve sonlandırma

`Ctrl+C`, `SIGINT` gönderir. Script etkin SSH, SCP, tar veya `zmcertmgr` süreç grubunu hemen sonlandırır ve `130` koduyla çıkar. `SIGTERM` çıkış kodu `143` olur. Hedef mutasyonu başlamışsa çıkıştan önce geri dönüş çalışır. Başarılı çalışmada açıkça `--keep-stage` kullanılmadıkça geçici gizli staging verisi silinir.

## Servis aktivasyonu ve doğrulama

Başarılı deploy dosyaları/yapılandırmayı değiştirir fakat çalışan servisleri yeniden yüklemez. Log, yedek, değişiklik onayı ve bakım penceresini inceledikten sonra elle restart edin:

```bash
su - zimbra -c '/opt/zimbra/bin/zmcontrol restart'
su - zimbra -c '/opt/zimbra/bin/zmcontrol status'
su - zimbra -c '/opt/zimbra/bin/zmcertmgr viewdeployedcrt'
```

Ardından etkin olan bütün dış/iç endpoint’leri — web/proxy, SMTP, IMAP, POP, LDAP ve mailboxd — bağımsız test edin; sunulan zinciri, SAN değerlerini, son kullanma tarihini ve istemci güvenini inceleyin. Script’in başarılı çıkması DNS’in, load balancer’ların, proxy’lerin, bütün cluster node’larının veya dış istemcilerin doğru olduğunu kanıtlamaz.

## Test

Depo düzeyindeki SSL testleri üretilen sertifikaları ve sahte SSH/Zimbra komutlarını kullanır; canlı sunucu gerekmez:

```bash
./tests/test_ssl.sh
```

Paket; sözdizimi ve ShellCheck’i, CLI doğrulamasını, verify-only değişmezliğini, başarılı deploy’u, yedek bütünlüğünü, deploy hatasında geri dönüşü, eşzamanlı çalışma kilidini, anında `Ctrl+C` sonlandırmasını ve deploy sırasında kesintide geri dönüşü kapsar.

Bu testler her Zimbra build’i, servis topolojisi, sertifika otoritesi, HSM, özel dosya sistemi düzeni veya işletim sistemiyle uyumluluğu kanıtlayamaz. Production öncesinde `--verify-only` çalıştırın, temsilî bir production dışı sistemde test edin ve bağımsız doğrulanmış kurtarma planı tutun.

## Geliştirici

[Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/) tarafından geliştirilmekte ve sürdürülmektedir.

Kaynak depo: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## Lisans ve operasyonel sahiplik

Telif hakkı © 2026 Cuma Kurt.

Bu yazılım yalnızca **GNU Affero General Public License v3.0** (`AGPL-3.0-only`) ile lisanslanmıştır. Ayrıntılar için [LICENSE](LICENSE) dosyasına bakın. “Only” tanımı, lisans izninin sonraki AGPL sürümlerine otomatik olarak genişlemediği anlamına gelir.

Script’in kullanımıyla ilgili her kararın ve sonucun sahibi operatördür. Operatör production kullanımından önce yetkiyi, sertifika/anahtar kaynağını, kaynak SSH kimliğini, yedeğin kurtarılabilirliğini, Zimbra/sürüm uyumluluğunu, bakım etkisini, restart prosedürünü, canlı endpoint davranışını, yenileme sorumluluğunu ve geri dönüş hazırlığını bağımsız olarak doğrulamalıdır. Sıfır çıkış kodu operasyonel kabul testinin yerine geçmez.
