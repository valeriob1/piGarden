#!/bin/bash
#
# Sul Pi VECCHIO: raccoglie in un solo archivio cio' che va portato sul sistema
# nuovo. Non stampa mai il contenuto di /etc/piGarden.conf.
#
#   bash bundle-old.sh              -> /tmp/pigarden-bundle.tgz (+ .sha256), permessi 600
#   bash bundle-old.sh --sanitized  -> /tmp/pigarden-bundle-test.tgz, con i valori
#                                      segreti della configurazione sostituiti:
#                                      solo per il collaudo a secco
#
# Contenuto:
#   home/pi/piGarden/    codice (lejubila 10045d5), stato, log corrente, conf locali
#   etc/piGarden.conf    configurazione
#   meta/crontab.pi      crontab dell'utente pi
#   meta/authorized_keys chiavi SSH autorizzate
#   meta/manifest        riepilogo leggibile (niente segreti)
#
# Non porta /etc/cron.d/php (residuo) ne' nient'altro di sistema.
#
set -euo pipefail

MODE=real
[ "${1:-}" = "--sanitized" ] && MODE=sanitized
OUT=/tmp/pigarden-bundle.tgz
[ "$MODE" = sanitized ] && OUT=/tmp/pigarden-bundle-test.tgz

SECRET_RE='^[[:space:]]*([A-Z0-9_]*(PWD|PASS|PASSWORD|TOKEN|KEY|SECRET|USER|APIKEY)[A-Z0-9_]*)='

umask 077
W=$(mktemp -d /tmp/pgbundle.XXXXXX)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/pi" "$W/etc" "$W/meta"

# codice, stato, log corrente (permessi conservati). I log ruotati (*.gz, dal
# 2021) restano sulla scheda vecchia: sono quasi tutto il peso e il link e' lento.
tar -C /home/pi --exclude='piGarden/log/*.gz' -cpf - piGarden | tar -C "$W/home/pi" -xpf -
# configurazione: copiata, mai mostrata
sudo cat /etc/piGarden.conf > "$W/etc/piGarden.conf"
chmod 644 "$W/etc/piGarden.conf"
if [ "$MODE" = sanitized ]; then
    sed -E -i "s/${SECRET_RE}.*/\\1=\"REDACTED\"/" "$W/etc/piGarden.conf"
    for f in "$W/home/pi/piGarden/conf/piGarden.conf" "$W/home/pi/piGarden/conf/piGarden.conf.save"; do
        [ -f "$f" ] && sed -E -i "s/${SECRET_RE}.*/\\1=\"REDACTED\"/" "$f"
    done
fi
crontab -l > "$W/meta/crontab.pi"
cp /home/pi/.ssh/authorized_keys "$W/meta/authorized_keys"

{
    echo "creato:            $(date '+%F %T %Z') su $(hostname)"
    echo "modo:              $MODE"
    echo "sistema:           $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"'), kernel $(uname -r)"
    echo "piGarden HEAD:     $(git -C /home/pi/piGarden log --oneline -1)"
    echo "piGarden remote:   $(git -C /home/pi/piGarden remote get-url origin)"
    echo "file non tracciati: $(git -C /home/pi/piGarden status --porcelain | tr '\n' ' ')"
    echo "conf sha256:       $(sha256sum < /etc/piGarden.conf | cut -c1-16)…  (originale)"
    echo "conf chiavi segrete: $(grep -cE "$SECRET_RE" /etc/piGarden.conf)"
    echo "crontab righe piGarden: $(grep -c piGarden "$W/meta/crontab.pi")"
    echo "authorized_keys:   $(wc -l < "$W/meta/authorized_keys") chiave/i"
    echo "hook attivi:       $(find /home/pi/piGarden/events -mindepth 2 -maxdepth 2 ! -name .gitignore ! -path '*/scripts/*' | wc -l)"
    echo "log ruotati lasciati sulla scheda vecchia: $(ls /home/pi/piGarden/log/*.gz 2>/dev/null | wc -l) file, $(du -ch /home/pi/piGarden/log/*.gz 2>/dev/null | tail -1 | cut -f1)"
    echo "stato valvole:     $(cd /home/pi/piGarden && ./piGarden.sh ev_status_all 2>/dev/null | tr '\n' ' ')"
    echo "percorsi in conf:"
    grep -E '^[A-Z_]*(_FILE|_DIR|_PATH)=' /etc/piGarden.conf | sed 's/^/   /'
} > "$W/meta/manifest"

tar -C "$W" -czpf "$OUT" home etc meta
chmod 600 "$OUT"
sha256sum "$OUT" | sed "s|$OUT|$(basename "$OUT")|" > "$OUT.sha256"
chmod 600 "$OUT.sha256"

cat "$W/meta/manifest"
echo
ls -la "$OUT" "$OUT.sha256"
