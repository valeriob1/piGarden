#!/bin/bash
#
# Backup della configurazione e dello stato di piGarden.
#
# Salva in un archivio datato le sole cose che NON stanno su git e che
# servono davvero per rimettere in piedi l'impianto dopo un guasto:
#
#   - /etc/piGarden.conf   la configurazione (zone, gpio, driver, credenziali)
#   - crontab dell'utente  ATTENZIONE: le schedulazioni di irrigazione vivono qui
#   - $STATUS_DIR          stato elettrovalvole, ultima pioggia, letture sensori
#
# Il codice non viene incluso: si recupera da git.
#
# Uso:
#   ./scripts/backup.sh
#
# Configurazione: variabili d'ambiente, oppure /etc/piGarden.backup.conf
#   BACKUP_DIR     directory locale degli archivi  (default: $HOME/pigarden-backup)
#   BACKUP_KEEP    quanti archivi conservare       (default: 14)
#   BACKUP_REMOTE  destinazione rsync opzionale    (es. "pi@nas:/volume1/backup/pigarden")
#
# Esempio di schedulazione (crontab -e), ogni notte alle 3:
#   0 3 * * * /home/pi/piGarden/scripts/backup.sh >> /home/pi/pigarden-backup/backup.log 2>&1
#
# RIPRISTINO su una SD/Raspberry nuovo:
#   1. Installa i pacchetti richiesti (vedi README) e clona il progetto:
#        git clone <url-del-repo> ~/piGarden
#        git -C ~/piGarden checkout $(cat git-commit.txt)   # stessa versione del backup
#   2. Scompatta l'archivio e rimetti a posto i pezzi:
#        tar xzf pigarden-AAAAMMGG-HHMMSS.tar.gz
#        sudo cp pigarden-*/piGarden.conf /etc/piGarden.conf
#        cp -a pigarden-*/state/. ~/piGarden/state/
#        crontab pigarden-*/crontab.txt        # ATTENZIONE: sovrascrive il crontab attuale
#   3. Verifica PRIMA di fidarti dell'automazione:
#        ~/piGarden/piGarden.sh ev_status_all
#        crontab -l                            # controlla che le schedulazioni ci siano
#        ~/piGarden/piGarden.sh start_socket_server force
#

set -u

DIR_SCRIPT=$(cd "$(dirname "$0")/.." && pwd)
# Sovrascrivibile solo per test; in esercizio resta /etc/piGarden.conf
CONFIG_ETC="${PIGARDEN_CONF:-/etc/piGarden.conf}"
BACKUP_CONF="/etc/piGarden.backup.conf"

# Configurazione opzionale del backup
if [ -f "$BACKUP_CONF" ]; then
    # shellcheck disable=SC1090
    . "$BACKUP_CONF"
fi

BACKUP_DIR="${BACKUP_DIR:-$HOME/pigarden-backup}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
BACKUP_REMOTE="${BACKUP_REMOTE:-}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
die() { log "ERRORE: $*"; exit 1; }

# Legge STATUS_DIR dalla configurazione di piGarden
STATUS_DIR=""
if [ -r "$CONFIG_ETC" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ETC"
else
    log "AVVISO: $CONFIG_ETC non leggibile, il backup non lo conterrà"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d) || die "impossibile creare la directory temporanea"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/pigarden-$STAMP"
mkdir -p "$STAGE" || die "impossibile preparare $STAGE"

# --- 1. Configurazione ---
if [ -r "$CONFIG_ETC" ]; then
    cp "$CONFIG_ETC" "$STAGE/piGarden.conf" && log "salvata configurazione"
fi

# --- 2. Crontab (le schedulazioni di irrigazione) ---
if crontab -l > "$STAGE/crontab.txt" 2>/dev/null; then
    log "salvato crontab ($(grep -c . "$STAGE/crontab.txt") righe)"
else
    log "AVVISO: nessun crontab per l'utente $(id -un)"
    rm -f "$STAGE/crontab.txt"
fi

# --- 3. Stato runtime ---
if [ -n "$STATUS_DIR" ] && [ -d "$STATUS_DIR" ]; then
    mkdir -p "$STAGE/state"
    cp -a "$STATUS_DIR/." "$STAGE/state/" 2>/dev/null && log "salvato stato da $STATUS_DIR"
else
    log "AVVISO: STATUS_DIR non trovata, stato non incluso"
fi

# --- 4. Riferimento della versione installata (per sapere a che commit tornare) ---
if command -v git >/dev/null 2>&1 && [ -d "$DIR_SCRIPT/.git" ]; then
    git -C "$DIR_SCRIPT" rev-parse HEAD > "$STAGE/git-commit.txt" 2>/dev/null \
        && log "annotato commit git $(cut -c1-8 < "$STAGE/git-commit.txt")"
fi

# --- 5. Archivio ---
mkdir -p "$BACKUP_DIR" || die "impossibile creare $BACKUP_DIR"
ARCHIVE="$BACKUP_DIR/pigarden-$STAMP.tar.gz"
tar czf "$ARCHIVE" -C "$WORK" "pigarden-$STAMP" || die "creazione archivio fallita"
# La configurazione può contenere password: leggibile solo dal proprietario
chmod 600 "$ARCHIVE"
log "creato $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# --- 6. Copia remota (NAS) ---
if [ -n "$BACKUP_REMOTE" ]; then
    if command -v rsync >/dev/null 2>&1; then
        if rsync -a "$ARCHIVE" "$BACKUP_REMOTE/"; then
            log "copiato su $BACKUP_REMOTE"
        else
            log "AVVISO: copia remota fallita (l'archivio locale resta disponibile)"
        fi
    else
        log "AVVISO: rsync non installato, copia remota saltata"
    fi
fi

# --- 7. Rotazione ---
if [ "$BACKUP_KEEP" -gt 0 ] 2>/dev/null; then
    # shellcheck disable=SC2012
    ls -1t "$BACKUP_DIR"/pigarden-*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
        rm -f "$old" && log "rimosso vecchio backup $(basename "$old")"
    done
fi

log "backup completato"
