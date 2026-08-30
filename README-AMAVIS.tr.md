# Zimbra Amavis OpenSSL Otomatik Onarım

[English](README-AMAVIS.md) · [Türkçe](README-AMAVIS.tr.md)

`zimbra_amavis_openssl_autofix.sh`, Zimbra sunucusundaki belirli bir Amavis başlangıç hatasını teşhis eder: `Net::SSLeay`, Zimbra’nın `libssl.so.3` kütüphanesini işletim sisteminin `libcrypto.so.3` kütüphanesiyle birlikte yükler ve `OPENSSL_x.y.z not found` ile çıkar. Bu eşleşme tam olarak yeniden üretildiğinde script, `zmamavisdctl` içine idempotent bir `LD_LIBRARY_PATH` düzeltmesi ekler, sözdizimini doğrular ve **yalnızca Amavis’i** yeniden başlatır.

Bu belge yalnızca `zimbra_amavis_openssl_autofix.sh` içindir. Tenant/mailbox, SSL ve DKIM migrasyon script’lerinin dokümantasyonu ayrıdır.

> **Kullanım riski ve tüm operasyonel sorumluluk aracı kullanan kişiye/kuruma aittir.** Bu script bir Zimbra kontrol dosyasını değiştirir ve Amavis’i yeniden başlatabilir. Yetkilendirme, değişiklik onayı, yedekleme, test, uyumluluk, kesinti, geri dönüş, posta akışı doğrulaması ve kuyruk flush işleminden yalnızca script’i çalıştıran kişi veya kurum sorumludur. Yazılım hiçbir garanti verilmeden sunulur; yürürlükteki hukukun izin verdiği azami ölçüde geliştirici ve katkıda bulunanlar veri kaybı, kesinti, başarısız geri dönüş, güvenlik olayı veya doğrudan/dolaylı zarardan sorumlu tutulamaz. [LICENSE](LICENSE) dosyasına bakın.

## Kapsam

Script:

- Zimbra sunucusunda `root` olarak çalışır;
- başka bir sunucuya bağlanmaz ve SSH kimliği **gerekmez**;
- `LD_LIBRARY_PATH` kaldırılmış temiz bir Zimbra ortamında `Net::SSLeay` testini yeniden üretir;
- `/opt/zimbra/common/lib` öne alındığında aynı testin geçtiğini doğrular;
- hata metni OpenSSL / `libssl` / `libcrypto` / `Net::SSLeay` imzasıyla örtüşmezse yama yapmayı reddeder;
- değişiklikten önce `/opt/zimbra/bin/zmamavisdctl` için zaman damgalı yedek oluşturur;
- işaretli `export LD_LIBRARY_PATH=...` bloğunu tek başına duran `zmsetvars` satırının hemen ardına ekler;
- idempotent’tir; bloğu ikinci kez eklemez;
- düzenlemeden sonra `bash -n` çalıştırır, sözdizimi bozulursa yedeği geri yükler;
- onarım uygulandığında veya teşhis doğrulandıktan sonra Amavis kapalıysa yalnızca `zmamavisdctl restart` çalıştırır;
- `zmcontrol restart` **çalıştırmaz**.

Sertifika üretmez, DKIM veya DNS değiştirmez, Amavis politikasını yeniden yazmaz ve ilgisiz Amavis/Perl hatalarını onarmaz.

## Gereksinimler

- `/opt/zimbra` altında standart bir Zimbra kurulumu (OpenSSL 3 / `libssl.so.3` düzeni);
- Bash, Perl, `runuser`, `awk`, `grep`, `sed`, `flock`, `setsid`;
- `root` olarak çalıştırma;
- geçerli bir `zimbra` işletim sistemi kullanıcısı;
- `--fix` için yazılabilir `zmamavisdctl`;
- kilit ve kısa ömürlü çalışma dizini için `/root/zimbra-amavis-openssl-autofix` altında yeterli alan.

`ss` isteğe bağlıdır. Varsa, restart sonrası `10024` ve `10026` portları zorunludur. `postqueue` isteğe bağlıdır; yalnızca kuyruk özeti / `--flush-queue` için kullanılır.

## Önce teşhis

```bash
sudo ./zimbra_amavis_openssl_autofix.sh --check-only
```

`--verify-only`, `--check-only` ile aynıdır.

| Çıkış kodu | Anlam |
| --- | --- |
| `0` | Amavis sağlıklı veya kütüphane-yolu sorunu yok |
| `10` | Sorun tam olarak yeniden üretildi; onarım gerekir |
| `3` | Amavis kapalı, ancak OpenSSL kütüphane-yolu sorunu **yeniden üretilmedi** |
| `2` | Geçersiz komut satırı |
| `1` | Hata |

Check-only `zmamavisdctl` dosyasını değiştirmez ve hiçbir servisi restart etmez.

## Onarım

Check-only `10` ile çıktığında ve bakım pencereniz varsa:

```bash
sudo ./zimbra_amavis_openssl_autofix.sh --fix
```

`--fix` varsayılandır.

Başarılı onarımdan sonra Amavis `zmamavisdctl` ile yeniden başlatılmış olur. Diğer Zimbra servisleri olduğu gibi bırakılır. Kuyrukta posta varsa ve Postfix’in hemen denemesini açıkça istiyorsanız:

```bash
sudo ./zimbra_amavis_openssl_autofix.sh --fix --flush-queue
```

Konsolda komut çıktısını görmek için `--verbose` kullanın. Dosya log’larına ANSI renk yazılmaz. TTY olsa bile rengi kapatmak için `NO_COLOR=1` kullanın.

## Yama neye benzer

Script, `zmamavisdctl` içinde tam olarak bir adet tek başına `zmsetvars` satırı bekler. O satırın ardından şunu ekler:

```bash
# ZIMBRA_AMAVIS_OPENSSL_FIX_BEGIN
export LD_LIBRARY_PATH=/opt/zimbra/common/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# ZIMBRA_AMAVIS_OPENSSL_FIX_END
```

Yol `ZIMBRA_HOME` değerini izler (varsayılan `/opt/zimbra`). `zmamavisdctl` sahipliği ve kipi yedekten kopyalanır.

Yedek orijinal dosyanın yanına yazılır:

```text
/opt/zimbra/bin/zmamavisdctl.backup-YYYYMMDD-HHMMSS
```

Sözdizimi doğrulaması başarısız olursa bu yedek hemen geri yüklenir.

## Bu script’in yapmayacağı işler

- Temel `Net::SSLeay` testi zaten geçiyorsa yama yapmaz (uyumsuzluk yoktur)
- Geçici çözüm testi de başarısızsa yama yapmaz (farklı kök neden)
- Hata metni OpenSSL kütüphane-yolu imzasına benzemiyorsa yama yapmaz
- `zmamavisdctl` içinde tam olarak bir adet tek başına `zmsetvars` satırı yoksa yama yapmaz
- Tüm Zimbra yığınını restart etmez
- `--check-only` modunda Amavis’i restart etmez
- İşaretli yama zaten varsa ve Amavis ile dinleyicileri sağlıklıysa Amavis’i restart etmez

Başarılı onarımdan sonra etkileşimli `perl -MNet::SSLeay` hâlâ `LD_LIBRARY_PATH` olmadan başarısız olabilir. Bu kasıtlıdır: kalıcı düzeltme tüm Zimbra kabuklarına değil, Amavis başlangıcına kapsamlanmıştır.

## Ctrl+C ve sonlandırma

`Ctrl+C` `SIGINT` gönderir. Script etkin `runuser` / Amavis kontrol süreç grubunu durdurur ve `130` ile çıkar. `SIGTERM` `143` ile çıkar. Aynı anda ikinci bir çalıştırma, dosyayı iki kez yamalamak yerine kilit dosyasında başarısız olur.

Dosya değiştirildikten sonra keserseniz, Amavis’i yeniden başlatmadan önce zaman damgalı yedeği ve `zmamavisdctl` içeriğini inceleyin.

## Log ve kilit

Her çalıştırma benzersiz bir log yazar:

```text
/var/log/zimbra-amavis-openssl-autofix-YYYYMMDD_HHMMSS.XXXXXX.log
```

Özel kilit:

```text
/root/zimbra-amavis-openssl-autofix/.zimbra-amavis-openssl-autofix.lock
```

İzole testlerde `ZIMBRA_HOME`, `RUN_ROOT`, `LOG_ROOT`, `LOCK_FILE` ve `AMAVIS_RESTART_WAIT` ile kökler değiştirilebilir.

## Test

Depo testleri sahte `runuser`, `perl`, `ss` ve Zimbra komutları kullanır; canlı sunucu gerekmez:

```bash
./tests/test_amavis.sh
```

Paket sözdizimi ve ShellCheck, CLI doğrulama, check-only değişmezliği, başarılı onarım, mevcut yama atlama, sağlıklı ve ilgisiz-kapalı çıkışları, reddedilen imza, belirsiz `zmsetvars`, isteğe bağlı kuyruk flush, eşzamanlı kilit ve anında `Ctrl+C` kapsar.

Bu testler her Zimbra sürümü, özel `zmamavisdctl` veya işletim sistemi OpenSSL düzeni ile uyumluluğu kanıtlamaz. Hedef sunucuda `--check-only` çalıştırın, teşhisi doğrulayın ve posta akışı kabul edilene kadar yedeği saklayın.

## Geliştirici

Geliştiren ve sürdüren: [Cuma Kurt](https://www.linkedin.com/in/cuma-kurt-34414917/).

Kaynak deposu: [github.com/cumakurt/zimbra_full_migrate](https://github.com/cumakurt/zimbra_full_migrate)

## Lisans ve operasyonel sahiplik

Telif hakkı © 2026 Cuma Kurt.

Bu yazılım **GNU Affero General Public License v3.0 only** (`AGPL-3.0-only`) ile lisanslanmıştır. [LICENSE](LICENSE) dosyasına bakın. “only” ifadesi, lisansın sonraki AGPL sürümlerine kendiliğinden uzamadığı anlamına gelir.

Bu script’in kullanımına ilişkin her karar ve sonuç işleteni bağlar. Üretim kullanımından önce işleten; yetkiyi, Zimbra/sürüm uyumluluğunu, yedek geri dönüşünü, bakım etkisini, Amavis restart’ının gelen posta üzerindeki etkisini ve geri dönüş hazırlığını bağımsız olarak doğrulamalıdır. Sıfır çıkış kodu, operasyonel kabul testinin yerine geçmez.
