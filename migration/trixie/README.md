# Migrazione del Pi di piGarden a Raspberry Pi OS trixie

Dal Raspbian 10 Buster (fuori supporto) a Raspberry Pi OS Lite 32-bit del
2026-09-15 (Debian 13 trixie), sullo stesso Pi Zero W, cambiando solo la microSD.
**Stesso codice di oggi** (lejubila `10045d5`): una cosa sola per volta. Il
passaggio al fork si valuta dopo qualche settimana.

La scheda vecchia non si tocca: resta accanto al Pi come rollback.

## File

| File | Dove gira | Cosa fa |
|---|---|---|
| `write-card.sh` | Mac, con sudo | scrive l'immagine **solo** su `/dev/rdisk4` dopo averne verificato identità e dimensione, poi rilegge e confronta l'impronta |
| `prepare-card.sh` | Mac | cloud-init (`user-data` con la chiave del Mac, `meta-data`), file `ssh`, WiFi e Bluetooth integrati spenti |
| `wifi-card.sh` | Mac | `network-config`: WiFi solo sulla chiavetta AR9271, nome e password digitati con `read -s` |
| `bundle-old.sh` | Pi vecchio | archivio con codice, stato, log corrente, `/etc/piGarden.conf`, crontab, chiavi SSH |
| `install.sh` | Pi nuovo | installazione a fasi con controlli: `prepare`, `check`, `relay-test`, `activate`, `verify` |
| `card/` | | modelli di `user-data` e `meta-data` |

Fuori dalla repo, in `~/pigarden-migration/` (0700): `wiringpi_3.20_armhf.deb` e,
il giorno dello scambio, il pacchetto con la configurazione. Il pacchetto contiene
credenziali: non va mai nella repo.

## Scelte e trappole verificate (4 ottobre 2026)

- **Rete dalla chiavetta USB AR9271**, riconosciuta dal MAC `24:ec:99:a6:4c:d7`
  (la prenotazione DHCP di .20.9 è legata a lei). WiFi integrata spenta con
  `dtoverlay=disable-wifi`, come oggi. Il firmware (`firmware-atheros`) è
  nell'immagine. Se al primo avvio la chiavetta non partisse, il Pi non ha rete:
  si rimette la scheda vecchia.
- **Dal Pi GitHub e deb.debian.org sono bloccati**; i repository Raspberry Pi
  (`raspbian.raspberrypi.com`, `archive.raspberrypi.com`) rispondono. WiringPi e il
  codice passano dal Mac.
- **WiringPi 3.20, difetto del pacchetto**: `libwiringPi.so` e `libwiringPiDev.so`
  sono link al percorso della macchina di build (`/home/evil/...`), e `gpio` li cerca
  proprio con quel nome. `install.sh prepare` li ricollega alla libreria vera.
- **`net-tools` serve**: il codice originale chiama `/sbin/ifconfig`
  (`send_identifier`); senza, ogni comando scrive un errore su stderr.
- **Un'apertura con `force` registra stato 2**, non 1 (piGardenWeb considera aperto
  ogni stato > 0).
- `/etc/piGarden.conf` resta identico: `/usr/local/bin/gpio` e `/usr/local/bin/jq`
  diventano link ai programmi di sistema.
- **Locale italiano**: sicuro per piGarden, le date usate nei calcoli e nel cron
  hanno sempre un formato esplicito. Cambiano solo le righe del log locale.
- L'ora arriva da NTP pubblico (`0.debian.pool.ntp.org`): `install.sh` controlla che
  sia sincronizzata, altrimenti il cron irrigherebbe all'ora sbagliata.
- Si portano solo il log corrente e lo stato: i 325 log ruotati (16 MB, dal 2021)
  restano sulla scheda vecchia. Il link del Pi va a ~15 KB/s.
- Nessun hook attivo in `events/` (solo `.gitignore`): niente da portare.
- `/etc/cron.d/php` è un residuo: non si porta.
- **Procedura guidata dell'utente** (`userconf-pi`, `userconfig.service`): è attiva
  nell'immagine e, se partisse, aspetterebbe su `tty8` una tastiera che non c'è.
  Non parte perché il modulo cloud-init di Raspberry Pi OS
  (`distros/raspberry_pi_os.py`, `add_user`) la maschera quando crea l'utente `pi`,
  e `userconfig` è ordinato dopo `cloud-config.service`. Per questo `user-data`
  deve continuare a dichiarare `users: [default]`.
- SSH: `sshswitch` lo accende se trova il file vuoto `ssh` sulla partizione di
  avvio; `user-data` lo abilita anche con `runcmd`.

## Collaudo a secco (fatto il 4 ottobre)

- `user-data` e `network-config` validati con cloud-init 26.1; `netplan generate`
  produce la connessione NetworkManager legata al MAC della chiavetta, anche con
  apostrofi e virgolette in SSID e password.
- `prepare-card.sh` e `wifi-card.sh` provati su una cartella finta (`TEST_BOOT`),
  con il bash 3.2 di macOS.
- `bundle-old.sh --sanitized` eseguito sul Pi vecchio vero.
- `install.sh` eseguito per intero in un container `debian:trixie-slim` con un
  `gpio` finto e il pacchetto sanificato: 0 errori in tutte le fasi; socket server
  verificato con `status` (JSON) e con credenziali sbagliate (rifiutate).
- **Non provabile a secco**: WiringPi sull'hardware, la chiavetta, il riavvio vero,
  l'NTP. Si verificano sul Pi con `check`, `relay-test` e `verify`.

## Oggi: preparare la scheda

```bash
bash ~/Documents/GitHub/piGarden/migration/trixie/write-card.sh <percorso>/2026-09-15-raspios-trixie-armhf-lite.img
bash ~/Documents/GitHub/piGarden/migration/trixie/prepare-card.sh
bash ~/Documents/GitHub/piGarden/migration/trixie/wifi-card.sh
diskutil eject disk4
```

## Il giorno dello scambio

**Prima di spegnere il Pi vecchio** (da remoto):

```bash
# 1. chiudere tutto e fare il pacchetto
ssh pi@192.168.20.9 'cd ~/piGarden && ./piGarden.sh close_all force && ./piGarden.sh ev_status_all'
scp migration/trixie/bundle-old.sh pi@192.168.20.9:/tmp/
ssh pi@192.168.20.9 'bash /tmp/bundle-old.sh'
scp pi@192.168.20.9:/tmp/pigarden-bundle.tgz pi@192.168.20.9:/tmp/pigarden-bundle.tgz.sha256 ~/pigarden-migration/
(cd ~/pigarden-migration && shasum -a 256 -c pigarden-bundle.tgz.sha256)
# 2. spegnimento pulito
ssh pi@192.168.20.9 'sudo poweroff'
```

**Sul posto**: chiudere l'acqua a monte, cambiare la scheda, riaccendere. Il primo
avvio di trixie sul Zero è lento (espansione del disco, cloud-init, locale):
contare qualche minuto.

**Da remoto, sul Pi nuovo:**

```bash
ssh-keygen -R 192.168.20.9           # il Pi nuovo ha una chiave host nuova
ssh pi@192.168.20.9 'mkdir -p ~/migration'
scp ~/pigarden-migration/pigarden-bundle.tgz* ~/pigarden-migration/wiringpi_3.20_armhf.deb \
    migration/trixie/install.sh pi@192.168.20.9:migration/
ssh pi@192.168.20.9 'bash ~/migration/install.sh prepare'
ssh pi@192.168.20.9 'bash ~/migration/install.sh check'
ssh -t pi@192.168.20.9 'bash ~/migration/install.sh relay-test'   # acqua chiusa, si ascoltano i rele'
ssh pi@192.168.20.9 'bash ~/migration/install.sh activate'
ssh pi@192.168.20.9 'sudo reboot'
ssh pi@192.168.20.9 'bash ~/migration/install.sh verify'
```

Poi: dashboard di piGardenWeb (`http://192.168.99.95`) mostra le zone e il meteo;
sul posto, controllare il sensore di pioggia (il GPIO 7 resta fisso a 1, "asciutto",
anche con il filo staccato). Riaprire l'acqua a monte.

## Passaggio alla SanDisk Endurance (dopo lo scambio)

trixie gira sulla microSD da 16 GB riciclata dallo spioncino (non Endurance). Per
portarlo sull'Endurance da 32 GB, che fino ad allora tiene Buster come rollback
(immagine verificata in `~/pigarden-migration/pigarden-buster-endurance-20261006.img.gz`),
il Mac ha un solo lettore, quindi si passa da un file:

```bash
ssh pi@192.168.20.9 'cd ~/piGarden && ./piGarden.sh close_all force && sudo poweroff'
# scheda da 16 GB nel Mac
bash migration/trixie/clone-card.sh read      # -> ~/pigarden-migration/pigarden-trixie-16gb.img
# Endurance nel Mac
bash migration/trixie/clone-card.sh write     # scrive e verifica, poi espelle
# Endurance nel Pi, riaccendere; poi allargare la partizione Linux a 32 GB
ssh pi@192.168.20.9 'sudo raspi-config nonint do_expand_rootfs && sudo reboot'
ssh pi@192.168.20.9 'bash ~/migration/install.sh verify'
```

`clone-card.sh` accetta solo la scheda attesa (dimensione esatta) e verifica come
`write-card.sh`: byte per byte fuori dalla FAT, file per file dentro. L'immagine della
16 GB resta come backup di trixie; la 16 GB diventa il rollback.

**Rollback**: spegnere, rimettere la scheda vecchia, riaccendere, e sul Mac
`ssh-keygen -R 192.168.20.9` (torna la chiave host vecchia).

**Dopo**: cancellare `~/pigarden-migration/pigarden-bundle.tgz*` dal Mac e
`~/migration/pigarden-bundle.tgz*` dal Pi (contengono le credenziali).
