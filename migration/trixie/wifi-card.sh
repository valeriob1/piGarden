#!/bin/bash
#
# Scrive network-config sulla scheda: WiFi solo sulla chiavetta USB AR9271,
# riconosciuta dal MAC (la prenotazione DHCP di 192.168.20.9 e' legata a lui).
# Nome e password della rete si digitano qui e non compaiono a schermo.
#
set -euo pipefail

BOOT=/Volumes/bootfs
DISK=disk4
DONGLE_MAC="24:ec:99:a6:4c:d7"

die() { echo "STOP: $*" >&2; exit 1; }

if [ -n "${TEST_BOOT:-}" ]; then
    # solo per il collaudo a secco: una cartella qualsiasi, mai un volume
    case "$TEST_BOOT" in /Volumes/*) die "TEST_BOOT non puo' essere un volume";; esac
    BOOT="$TEST_BOOT"
else
    [ -d "$BOOT" ] || die "$BOOT non montata"
    WHOLE=$(diskutil info -plist "$BOOT" | /usr/libexec/PlistBuddy -c "Print :ParentWholeDisk" /dev/stdin)
    [ "$WHOLE" = "$DISK" ] || die "$BOOT sta su $WHOLE, non su $DISK"
fi

read -r -s -p "Nome della rete WiFi (SSID): " WIFI_SSID; echo
read -r -s -p "Password della rete WiFi: " WIFI_PSK; echo
read -r -s -p "Ripeti la password: " WIFI_PSK2; echo
[ -n "$WIFI_SSID" ] || die "SSID vuoto"
[ "$WIFI_PSK" = "$WIFI_PSK2" ] || die "le due password non coincidono"
unset WIFI_PSK2
n=${#WIFI_PSK}
if ! { [ "$n" -ge 8 ] && [ "$n" -le 63 ]; } && ! [[ "$WIFI_PSK" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    die "password WPA non valida (8-63 caratteri)"
fi

# YAML tra apici singoli: l'unico carattere da raddoppiare e' l'apice
q() { local sq="'"; printf "'%s'" "${1//$sq/$sq$sq}"; }

umask 077
cat > "$BOOT/network-config" <<EOF
network:
  version: 2
  wifis:
    dongle:
      match:
        macaddress: "$DONGLE_MAC"
      dhcp4: true
      optional: true
      regulatory-domain: "IT"
      access-points:
        $(q "$WIFI_SSID"):
          password: $(q "$WIFI_PSK")
EOF
unset WIFI_SSID WIFI_PSK
echo "ok: $BOOT/network-config scritto ($(wc -l < "$BOOT/network-config" | tr -d ' ') righe)."
echo "Puoi espellere la scheda: diskutil eject $DISK"
