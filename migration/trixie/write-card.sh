#!/bin/bash
#
# Scrive l'immagine di Raspberry Pi OS sulla microSD nel Mac.
# Scrive SOLO su /dev/rdisk4, e solo se disk4 e' ancora la scheda verificata:
# esterna, rimovibile, 15.931.539.456 byte. Altrimenti si ferma senza toccare nulla.
#
# Uso:  bash write-card.sh <immagine .img decompressa>
# Chiede la password di amministratore (sudo) per dd.
#
set -euo pipefail

DISK=disk4
EXPECTED_BYTES=15931539456
IMG_SHA256=f6154846c674d27f61f2d91704783f105f2a8d1e40944126ca6d7f60d10644f1
IMG="${1:?indicare il percorso del file .img}"

die() { echo "STOP: $*" >&2; exit 1; }

[ -f "$IMG" ] || die "immagine non trovata: $IMG"

echo "== 1/6 controllo la scheda ($DISK)"
diskutil list external physical | grep -q "^/dev/$DISK " \
    || die "/dev/$DISK non e' tra i dischi esterni fisici"
INFO=$(diskutil info -plist "$DISK") || die "diskutil info $DISK fallito"
val() { /usr/libexec/PlistBuddy -c "Print :$1" /dev/stdin <<<"$INFO" 2>/dev/null; }
[ "$(val TotalSize)" = "$EXPECTED_BYTES" ] || die "dimensione $(val TotalSize) invece di $EXPECTED_BYTES"
[ "$(val Internal)" = "false" ]            || die "$DISK risulta interno"
[ "$(val RemovableMediaOrExternalDevice)" = "true" ] || die "$DISK non risulta rimovibile/esterno"
[ "$(val VirtualOrPhysical)" = "Physical" ] || die "$DISK non e' un disco fisico"
echo "   ok: esterno, rimovibile, fisico, $(val TotalSize) byte"
diskutil list "$DISK"

echo "== 2/6 verifico l'immagine (sha256)"
IMG_BYTES=$(stat -f %z "$IMG")
echo "$IMG_SHA256  $IMG" | shasum -a 256 -c - >/dev/null || die "impronta dell'immagine diversa da quella attesa"
echo "   ok: $IMG_BYTES byte, impronta corretta"
[ $((IMG_BYTES % 4194304)) -eq 0 ] || die "dimensione immagine non multipla di 4 MiB, la rilettura non sarebbe esatta"
BLOCKS=$((IMG_BYTES / 4194304))

read -r -p "== 3/6 Cancello TUTTO /dev/$DISK e ci scrivo l'immagine. Scrivi SI per procedere: " ok
[ "$ok" = "SI" ] || die "annullato"

echo "== 4/6 smonto e scrivo su /dev/r$DISK"
diskutil unmountDisk "/dev/$DISK"
sudo dd if="$IMG" of="/dev/r$DISK" bs=4m status=progress
sync

echo "== 5/6 rileggo la scheda e confronto l'impronta"
GOT=$(sudo dd if="/dev/r$DISK" bs=4m count="$BLOCKS" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
[ "$GOT" = "$IMG_SHA256" ] || die "la scheda riletta NON corrisponde ($GOT)"
echo "   ok: la scheda contiene esattamente l'immagine"

echo "== 6/6 rimonto la partizione di avvio"
diskutil mountDisk "/dev/$DISK" || true
sleep 2
mount | grep -q " /Volumes/bootfs " && echo "   ok: /Volumes/bootfs montata" \
    || echo "   attenzione: /Volumes/bootfs non montata, provare 'diskutil mountDisk $DISK'"
echo "FATTO. Se macOS dice che un disco non e' leggibile, e' la partizione Linux: premi Ignora."
