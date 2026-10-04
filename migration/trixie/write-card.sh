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

read -r -p "== 3/6 Cancello TUTTO /dev/$DISK e ci scrivo l'immagine. Scrivi SI per procedere: " ok
[ "$ok" = "SI" ] || die "annullato"

echo "== 4/6 smonto e scrivo su /dev/r$DISK"
diskutil unmountDisk "/dev/$DISK"
sudo dd if="$IMG" of="/dev/r$DISK" bs=4m status=progress
sync

echo "== 5/6 rileggo la scheda e la confronto con l'immagine"
# Non si puo' confrontare la scheda intera: appena dd chiude il disco, macOS
# monta da solo la partizione FAT e ci scrive (.fseventsd, .Spotlight-V100).
# Quindi: byte per byte tutto cio' che sta FUORI dalla partizione FAT
# (MBR, spazio iniziale, partizione Linux), file per file la partizione FAT.
# In MiB (blocchi da 1m: a 512 byte la rilettura del device sarebbe lentissima).
# Partizione FAT: settori 16384..1064959 (fdisk) = MiB 8..519.
FAT_START_MIB=8; FAT_END_MIB=520
[ $((IMG_BYTES % 1048576)) -eq 0 ] || die "immagine non allineata a 1 MiB"
IMG_MIB=$((IMG_BYTES / 1048576))
hash_ranges() {   # $1 = file o device; legge [0,FAT_START) e [FAT_END,fine immagine)
    { $2 dd if="$1" bs=1m count="$FAT_START_MIB" 2>/dev/null
      $2 dd if="$1" bs=1m skip="$FAT_END_MIB" count="$((IMG_MIB - FAT_END_MIB))" 2>/dev/null
    } | shasum -a 256 | cut -d' ' -f1
}
WANT=$(hash_ranges "$IMG" "")
GOT=$(hash_ranges "/dev/r$DISK" sudo)
[ "$GOT" = "$WANT" ] || die "MBR o partizione Linux sulla scheda NON corrispondono all'immagine"
echo "   ok: MBR e partizione Linux identici all'immagine, byte per byte"

diskutil mountDisk "/dev/$DISK" >/dev/null 2>&1 || true
sleep 3
mount | grep -q "^/dev/${DISK}s1 on /Volumes/bootfs " || die "partizione di avvio non montata su /Volumes/bootfs"
ATT=$(hdiutil attach -readonly -imagekey diskimage-class=CRawDiskImage "$IMG" 2>&1)
IMGDEV=$(echo "$ATT" | awk '/FDisk/{print $1}')
IMGMNT=$(echo "$ATT" | awk -F'\t' '/Windows_FAT_32/{gsub(/^[ \t]+|[ \t]+$/,"",$NF); print $NF}')
[ -n "$IMGMNT" ] && [ "$IMGMNT" != /Volumes/bootfs ] || { [ -n "$IMGDEV" ] && diskutil eject "$IMGDEV" >/dev/null; die "montaggio dell'immagine inatteso"; }
if diff -rq -x .Spotlight-V100 -x .fseventsd /Volumes/bootfs "$IMGMNT" >/dev/null 2>&1; then
    diskutil eject "$IMGDEV" >/dev/null
    echo "   ok: tutti i file della partizione di avvio identici all'immagine"
else
    diskutil eject "$IMGDEV" >/dev/null
    die "file della partizione di avvio diversi dall'immagine"
fi

echo "== 6/6 partizione di avvio montata su /Volumes/bootfs"
echo "FATTO. Se macOS dice che un disco non e' leggibile, e' la partizione Linux: premi Ignora."
