#!/bin/bash
#
# Sul Pi (trixie), come utente pi: rende la WiFi capace di riprendersi da sola.
#
# Perche' (6 ottobre 2026, 11 giorni offline): con segnale a -87 dBm l'handshake
# WPA a volte non si chiude. wpa_supplicant lo segnala come possibile password
# sbagliata; NetworkManager chiede una chiave nuova, nessuno gliela da' (sistema
# senza schermo) e la connessione resta bloccata per sempre ("no-secrets"). Il
# vecchio wpa_supplicant del Buster invece riprovava all'infinito.
#
# Collaudato il 17/10/2026 in una VM Debian trixie (NetworkManager 1.52.1 e
# wpa_supplicant 2.10, come il Pi) con radio virtuali mac80211_hwsim:
#   - default: un tentativo, poi blocco permanente anche con l'AP di nuovo ok
#     (riprodotto il guasto del Pi);
#   - connection.auth-retries=0 / autoconnect-retries=0: NON servono, il blocco
#     arriva lo stesso, sia a connessione attiva sia in fase di attivazione;
#   - questo timer: ricollega entro un ciclo dal ritorno dell'AP.
#
#   1. ogni 5 minuti, SOLO se la chiavetta e' scollegata (non se collegata o in
#      connessione), "nmcli device connect". Non e' il watchdog di agosto:
#      quello forzava riconnessioni a link ancora associato.
#   2. giornale di sistema persistente (50 MB) per capire la prossima volta.
#
# Si puo' rilanciare: rimette gli stessi file.
#
set -euo pipefail

DONGLE_MAC="24:ec:99:a6:4c:d7"

echo "== 1/2 rete di sicurezza ogni 5 minuti"
# Da scollegato NetworkManager usa un MAC casuale per cercare le reti: la
# chiavetta si riconosce anche dal MAC permanente ("permaddr" in ip link).
sed "s/__DONGLE_MAC__/$DONGLE_MAC/g" <<'EOF' | sudo tee /usr/local/sbin/pigarden-wifi-kick >/dev/null
#!/bin/bash
# Se NetworkManager ha lasciato scollegata la chiavetta, la riattiva.
# Non fa nulla se e' collegata o sta gia' provando (stato >= 40).
MAC="__DONGLE_MAC__"
dev=$(ip -o link show | awk -v m="$MAC" '
    index($0, "link/ether " m " ") || index($0, "permaddr " m) { sub(/:$/, "", $2); print $2; exit }')
[ -n "$dev" ] || { echo "chiavetta $MAC non presente"; exit 0; }
state=$(nmcli -g GENERAL.STATE device show "$dev" 2>/dev/null | cut -d' ' -f1)
case "$state" in
    ''|*[!0-9]*) echo "stato di $dev illeggibile: '$state'"; exit 0 ;;
esac
if [ "$state" -lt 40 ]; then
    echo "$dev scollegata (stato $state): nmcli device connect"
    nmcli device connect "$dev" || true
fi
EOF
sudo chmod 755 /usr/local/sbin/pigarden-wifi-kick
sudo tee /etc/systemd/system/pigarden-wifi-kick.service >/dev/null <<'EOF'
[Unit]
Description=piGarden: riattiva la WiFi se NetworkManager l'ha lasciata scollegata
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pigarden-wifi-kick
EOF
sudo tee /etc/systemd/system/pigarden-wifi-kick.timer >/dev/null <<'EOF'
[Unit]
Description=piGarden: controllo WiFi ogni 5 minuti

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now pigarden-wifi-kick.timer
echo "   ok: $(systemctl is-active pigarden-wifi-kick.timer); $(systemctl list-timers pigarden-wifi-kick.timer --no-legend | awk '{print "prossimo controllo fra", $(NF-4), $(NF-3)}')"

echo "== 2/2 giornale di sistema sulla scheda (50 MB)"
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/pigarden.conf >/dev/null <<'EOF'
# piGarden: giornale salvato sulla scheda (SanDisk Endurance) per poter capire
# i guasti dopo un riavvio; tenuto piccolo. Prima era Storage=volatile.
[Journal]
Storage=persistent
SystemMaxUse=50M
RuntimeMaxUse=32M
EOF
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
sudo journalctl --flush
echo "   ok: $(sudo journalctl --disk-usage)"

echo
echo "== verifica"
nmcli -t -f DEVICE,STATE device | grep -v '^lo:' || true
/usr/local/sbin/pigarden-wifi-kick && echo "   rete di sicurezza eseguita a vuoto: ok"
