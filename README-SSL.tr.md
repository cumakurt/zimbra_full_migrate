# Zimbra SSL Migrasyonu

[English](README-SSL.md) · [Türkçe](README-SSL.tr.md)

`zimbra_ssl_migrate.sh`, eski bir Zimbra sunucusunda kullanımda olan ticari veya Let's Encrypt sertifika setini güvenli biçimde yeni Zimbra sunucusuna taşır. Hedefte değişiklik yapmadan önce sertifikayı, özel anahtarı, CA zincirini, geçerlilik zamanını, hostname eşleşmesini ve Zimbra uyumluluğunu doğrular.

Bu belge yalnızca `zimbra_ssl_migrate.sh` içindir. Tenant/mailbox migrasyon script’inin dokümantasyonu ayrıdır.

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

## Yeni sunucuda root olarak SSH anahtarı hazırlama

SSL migrasyonu **yeni sunucuda root olarak** çalıştığı için SSH anahtarı ve kaynak host kaydı hedefteki `zimbra` kullanıcısına değil, root’a ait olmalıdır. Aşağıdaki örnek yalnızca bu migrasyon için özel bir anahtar oluşturur. Komutları çalıştırmadan önce örnek hostname ve portu değiştirin.

**Önemli:** 1., 2., 4., 5. ve 6. adımlardaki `OLD_ZIMBRA`, `OLD_SSH_PORT` ve `SSL_MIGRATE_KEY` değişkenleri aynı root oturumunda geçerlidir. Yeni bir oturum açtıysanız, ilgili adımın başındaki değişken bloğunu tekrar çalıştırın. Değişkenler ayarlanmadan devam ederseniz `Saving key "" failed` hatası alırsınız.

### 1. Yeni sunucuda root olun ve bağlantıyı tanımlayın

**Yeni Zimbra sunucusunda** çalıştırın:

```bash
sudo -i

OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

printf 'Kaynak: %s:%s\nAnahtar: %s\n' \
  "$OLD_ZIMBRA" "$OLD_SSH_PORT" "$SSL_MIGRATE_KEY"
```

`OLD_ZIMBRA` değerinin gerçekten eski/kaynak Zimbra sunucusunu gösterdiğini doğrulayın. Tahmin edilen bir adresle devam etmeyin.

### 2. Yeni sunucuda özel bir Ed25519 anahtarı oluşturun

**Yeni sunucuda** root olarak devam edin. 1. adımı aynı oturumda çalıştırmadıysanız, aşağıdaki değişken bloğunu da çalıştırın:

```bash
# 1. adımı atladıysanız veya yeni bir root oturumu açtıysanız önce bunları ayarlayın:
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA boş; örnek hostname yerine gerçek kaynak adresini yazın.}"
: "${OLD_SSH_PORT:?OLD_SSH_PORT boş.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY boş; anahtar dosya yolunu ayarlayın.}"

install -d -o root -g root -m 0700 /root/.ssh

if [[ -e "$SSL_MIGRATE_KEY" || -e "${SSL_MIGRATE_KEY}.pub" ]]; then
  printf 'Anahtar zaten var; inceleyip yeniden kullanın veya başka yol seçin: %s\n' \
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

Migrasyon etkileşimsiz `BatchMode` kullandığı için `-N ''`, bu işe özel şifresiz anahtar üretir. Root hesabını ve anahtarı koruyun. `zimbra_ssl_migrate_ed25519` adlı özel dosyayı eski sunucuya hiçbir zaman kopyalamayın; eski sunucuda yalnızca `.pub` dosyasına yetki verilir.

### 3. Eski sunucunun fingerprint’ini alın ve bağımsız doğrulayın

**Eski sunucunun** güvenilir konsolunda/oturumunda root olarak çalıştırın:

```bash
sudo -i

for host_key in /etc/ssh/ssh_host_*_key.pub; do
  [[ -f "$host_key" ]] && ssh-keygen -lf "$host_key"
done
```

SSH’nin sunduğu host anahtarı algoritmasına ait fingerprint’i kaydedin. Bu değeri yeni sunucu bağlantısından bağımsız bir kanal üzerinden doğrulayın; örneğin eski sunucunun fiziksel/VM konsolu veya onaylı envanter kaydı.

Migrasyon script’inin varsayılanı `StrictHostKeyChecking=yes` değeridir. Gösterilen fingerprint bağımsız kaydedilen değerle birebir eşleşmeden yeni veya değişmiş host anahtarını kabul etmeyin.

### 4. Açık anahtarı eski sunucuya aktarın

Migrasyon script’i kaynak sunucuya `zimbra@` ile bağlanır; bu yüzden açık anahtarın eski sunucudaki `zimbra` kullanıcısının `authorized_keys` dosyasına eklenmesi gerekir. Birçok Zimbra kurulumunda `zimbra` parolası yoktur veya parola ile SSH kapalıdır; bu durumda `ssh-copy-id zimbra@...` **çalışmaz**.

**Önerilen yol:** Yeni sunucudan, zaten çalışan **root SSH erişiminizi** kullanarak açık anahtarı uzaktan kurun. Bu adımda root bağlantısı için mevcut root SSH kimliğiniz kullanılır; `SSL_MIGRATE_KEY` yalnızca kurulacak açık anahtar dosyasıdır ve sonraki `zimbra@` bağlantıları için kullanılır.

**Yeni sunucuda** root olarak:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA boş; örnek hostname/IP yerine gerçek kaynak adresini yazın.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY boş; anahtar dosya yolunu ayarlayın.}"
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

`OLD_ZIMBRA` için IP adresi de kullanılabilir (ör. `10.1.0.20`). Root oturumunda `yes` istemi görülürse, 3. adımda bağımsız doğruladığınız fingerprint ile eşleştiğinden emin olun. Komut yalnızca `.pub` satırını ekler; özel anahtarı asla eski sunucuya kopyalamayın. Komut tekrar çalıştırılırsa aynı satırı ikinci kez eklemez.

#### Alternatif: `zimbra` parolası varsa `ssh-copy-id`

Eski sunucuda `zimbra` için parola ile SSH açıksa:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA boş; örnek hostname yerine gerçek kaynak adresini yazın.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY boş; anahtar dosya yolunu ayarlayın.}"

ssh-copy-id \
  -i "${SSL_MIGRATE_KEY}.pub" \
  -p "$OLD_SSH_PORT" \
  "zimbra@${OLD_ZIMBRA}"
```

#### Alternatif: eski sunucu konsolundan elle kurulum

Yeni sunucudan root SSH mümkün değilse, **yeni sunucuda** açık anahtarı görüntüleyin:

```bash
SSL_MIGRATE_KEY="${SSL_MIGRATE_KEY:-/root/.ssh/zimbra_ssl_migrate_ed25519}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY boş; anahtar dosya yolunu ayarlayın.}"

cat "${SSL_MIGRATE_KEY}.pub"
```

Sonra **eski sunucunun** güvenilir root konsolunda gerçek Zimbra home dizinini belirleyip bu tek açık anahtar satırını elle ekleyin:

```bash
ZIMBRA_SSH_HOME="$(getent passwd zimbra | awk -F: '$1 == "zimbra" { print $6 }')"
test -n "$ZIMBRA_SSH_HOME"

install -d -o zimbra -g zimbra -m 0700 "$ZIMBRA_SSH_HOME/.ssh"
touch "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"
chown zimbra:zimbra "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"
chmod 0600 "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"

vi "$ZIMBRA_SSH_HOME/.ssh/authorized_keys"
```

Yalnızca `.pub` dosyasındaki tek satırı yapıştırın; özel anahtarı asla yapıştırmayın. Mevcut yetkili anahtarları koruyun. SELinux kullanılan sistemde komut varsa context’i düzeltin:

```bash
command -v restorecon >/dev/null 2>&1 && \
  restorecon -RF "$ZIMBRA_SSH_HOME/.ssh"
```

### 5. Yeni sunucudan gerçek etkileşimsiz bağlantıyı test edin

**Yeni sunucuda** root olarak çalıştırın:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA boş; örnek hostname yerine gerçek kaynak adresini yazın.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY boş; anahtar dosya yolunu ayarlayın.}"

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

Beklenen çıktıda `zimbra`, eski Zimbra hostname’i ve `SSL_FILES_OK` bulunur. Parola/passphrase veya host anahtarı istemi görülmesi etkileşimsiz kurulumun tamamlanmadığını gösterir.

Gizli içeriği göstermeden kaynak izinlerini de inceleyebilirsiniz:

```bash
ssh \
  -i "$SSL_MIGRATE_KEY" \
  -p "$OLD_SSH_PORT" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  "zimbra@${OLD_ZIMBRA}" \
  'stat -c "%a %U:%G %n" /opt/zimbra/ssl/zimbra/commercial/commercial.*'
```

Script “other” kullanıcıların erişebildiği kaynak `commercial.key` dosyasını reddeder. Tipik Zimbra anahtar izinleri 8.7 öncesinde `0740`, 8.7 ve yeni sürümlerde `0640` değeridir.

### 6. Önce verify-only, sonra onaylı deploy çalıştırın

**Yeni sunucudaki** depo dizininde root olarak:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA boş; örnek hostname yerine gerçek kaynak adresini yazın.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY boş; anahtar dosya yolunu ayarlayın.}"

./zimbra_ssl_migrate.sh \
  --old "$OLD_ZIMBRA" \
  --port "$OLD_SSH_PORT" \
  --identity "$SSL_MIGRATE_KEY" \
  --verify-only
```

Verify-only sonucunu inceledikten sonra gerçek deploy’u yalnızca onaylı bakım penceresinde çalıştırın:

```bash
OLD_ZIMBRA="oldmail.example.com"
OLD_SSH_PORT="22"
SSL_MIGRATE_KEY="/root/.ssh/zimbra_ssl_migrate_ed25519"

: "${OLD_ZIMBRA:?OLD_ZIMBRA boş; örnek hostname yerine gerçek kaynak adresini yazın.}"
: "${SSL_MIGRATE_KEY:?SSL_MIGRATE_KEY boş; anahtar dosya yolunu ayarlayın.}"

./zimbra_ssl_migrate.sh \
  --old "$OLD_ZIMBRA" \
  --port "$OLD_SSH_PORT" \
  --identity "$SSL_MIGRATE_KEY"
```

### 7. Kabul tamamlanınca geçici SSH yetkisini kaldırın

Deploy, elle Zimbra restart’ı, endpoint doğrulaması ve rollback/kabul penceresi tamamlanmadan erişimi kaldırmayın. Sonrasında eski sunucunun `authorized_keys` dosyasından yalnızca bu işe özel `zimbra-ssl-migrate@...` açık anahtar satırını kaldırın; ilgisiz anahtarları koruyun. Yeni sunucudaki özel/açık anahtar çiftini kurumun anahtar saklama politikasına göre silin veya arşivleyin.

Kontrollü ilk bağlantı önceden hazırlanamıyorsa `--accept-new-host-key`, OpenSSH `accept-new` kipini açar. Bu seçenek görülmemiş anahtarı kabul eder, değişmiş anahtarı reddeder; yukarıdaki bağımsız fingerprint sürecinden daha düşük güvenlik sağlar.

## Hızlı başlangıç

Gerekirse çalıştırma izni verin:

```bash
chmod 700 zimbra_ssl_migrate.sh
```

Önce salt doğrulama çalıştırın. Bu kip hedef sertifikayı değiştirmez; ancak kaynak özel anahtarını geçici olarak `0700` izinli staging dizinine indirir ve çıkışta siler:

```bash
./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519 \
  --verify-only
```

Ardından onaylı değişiklik penceresinde deploy edin:

```bash
./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519
```

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
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519 \
  --verify-only \
  --verbose

NO_COLOR=1 ./zimbra_ssl_migrate.sh \
  --old oldmail.example.com \
  --identity /root/.ssh/zimbra_ssl_migrate_ed25519 \
  --verify-only
```

## Güvenlik ve işlem davranışı

- Non-blocking kilit, eşzamanlı iki SSL migrasyonunu engeller.
- Her çalışma benzersiz özel staging dizini ve log dosyası kullanır.
- Sertifika/CA girdilerinden biri özel anahtar içeriği taşıyorsa işlem reddedilir.
- Kaynak `commercial.key`, “other” kullanıcılar tarafından erişilebiliyorsa işlem reddedilir.
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
