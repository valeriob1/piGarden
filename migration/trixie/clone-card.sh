#!/bin/bash
#
# Copia la scheda trixie da 16 GB sulla SanDisk Endurance da 32 GB passando dal
# Mac, che ha un solo lettore:
#
#   bash clone-card.sh read    scheda da 16 GB nel lettore -> immagine sul Mac
#   bash clone-card.sh write   Endurance nel lettore       -> scrive e verifica
#
# Ogni comando accetta solo la scheda attesa, riconosciuta dalla dimensione
# esatta, e si ferma se disk4 e' altro. L'immagine resta in ~/pigarden-migration
# anche come backup del sistema trixie. La partizione Linux resta grande come
# sulla 16 GB: si allarga poi sul Pi (vedi README).
#
set -euo pipefail

DISK=disk4
SRC_BYTES=15931539456          # microSD 16 GB con trixie (ex spioncino Tuya)
DST_BYTES=31914983424          # SanDisk High Endurance 32 GB
DIR="$HOME/pigarden-migration"
IMG="${IMG:-$DIR/pigarden-trixie-16gb.img}"

die() { echo "STOP: $*" >&2; exit 1; }

check_disk() {   # $1 = dimensione attesa, $2 = descrizione
    diskutil list external physical | grep -q "^/dev/$DISK " || die "/dev/$DISK non e' tra i dischi esterni fisici"
    local info; info=$(diskutil info -plist "$DISK")
    val() { plutil -extract "$1" raw - <<<"$info"; }
    [ "$(val Internal)" = false ]                    || die "$DISK risulta interno"
    [ "$(val RemovableMediaOrExternalDevice)" = true ] || die "$DISK non e' rimovibile/esterno"
    [ "$(val TotalSize)" = "$1" ] || die "$DISK e' di $(val TotalSize) byte: non e' $2 ($1 byte)"
    echo "   ok: $DISK e' $2"
}

# Partizione FAT (la prima) dalla tabella MBR dell'immagine, in settori da 512
fat_range() {
    # riga " 1: 0C ... [     16384 -    1048576] Win95 FAT32L": inizio e lunghezza
    fdisk "$IMG" 2>/dev/null | sed -nE 's/^ *1: .*\[ *([0-9]+) - *([0-9]+)\].*/\1 \2/p'
}

# Impronta di tutto cio' che sta FUORI dalla partizione FAT, per IMG_BYTES byte:
# macOS scrive nella FAT appena la monta, il resto deve restare identico.
hash_outside_fat() {   # $1 = file o device, $2 = "sudo" o ""
    local start size end
    read -r start size < <(fat_range)
    end=$((start + size))
    [ $((start % 2048)) -eq 0 ] && [ $((end % 2048)) -eq 0 ] || die "partizione FAT non allineata a 1 MiB"
    [ $((IMG_BYTES % 512)) -eq 0 ] || die "immagine non multipla di 512 byte"
    # Ci si ferma esattamente a IMG_BYTES senza tagliare la pipe: l'Endurance e'
    # piu' grande dell'immagine, e un dd interrotto da SIGPIPE con pipefail
    # fermerebbe lo script a meta' verifica. MiB interi, poi la coda in settori.
    local rest=$((IMG_BYTES / 512 - end))
    local mib=$((rest / 2048)) tail=$((rest % 2048))
    { $2 dd if="$1" bs=1m count=$((start / 2048)) 2>/dev/null
      $2 dd if="$1" bs=1m skip=$((end / 2048)) count=$mib 2>/dev/null
      $2 dd if="$1" bs=512 skip=$((end + mib * 2048)) count=$tail 2>/dev/null
    } | shasum -a 256 | cut -d' ' -f1
}

compare_fat_files() {
    diskutil mountDisk "/dev/$DISK" >/dev/null 2>&1 || true
    sleep 3
    local mnt; mnt=$(mount | awk -v d="/dev/${DISK}s1" '$1==d {sub(/^[^ ]+ on /,""); sub(/ \(.*$/,""); print}')
    [ -n "$mnt" ] || die "partizione di avvio della scheda non montata"
    local att dev imgmnt
    att=$(hdiutil attach -readonly -imagekey diskimage-class=CRawDiskImage "$IMG" 2>&1)
    dev=$(echo "$att" | awk '/FDisk/{print $1}')
    imgmnt=$(echo "$att" | awk -F'\t' '/Windows_FAT_32/{gsub(/^[ \t]+|[ \t]+$/,"",$NF); print $NF}')
    if [ -z "$imgmnt" ] || [ "$imgmnt" = "$mnt" ]; then
        [ -n "$dev" ] && diskutil eject "$dev" >/dev/null
        die "montaggio dell'immagine inatteso"
    fi
    if diff -rq -x .Spotlight-V100 -x .fseventsd -x .Trashes "$mnt" "$imgmnt" >/dev/null 2>&1; then
        diskutil eject "$dev" >/dev/null
        echo "   ok: file della partizione di avvio identici all'immagine"
    else
        diskutil eject "$dev" >/dev/null
        die "file della partizione di avvio diversi dall'immagine"
    fi
}

case "${1:-}" in
read)
    echo "== 1/3 controllo la scheda"
    check_disk "$SRC_BYTES" "la microSD da 16 GB con trixie"
    [ -e "$IMG" ] && die "$IMG esiste gia': spostalo o cancellalo prima"
    mkdir -p "$DIR"; chmod 700 "$DIR"
    echo "== 2/3 leggo la scheda in $IMG"
    diskutil unmountDisk "/dev/$DISK"
    umask 077
    sudo dd if="/dev/r$DISK" bs=4m status=progress | tee "$IMG" | shasum -a 256 | cut -d' ' -f1 > "$IMG.sha256"
    [ "$(stat -f %z "$IMG")" = "$SRC_BYTES" ] || die "immagine di $(stat -f %z "$IMG") byte invece di $SRC_BYTES"
    echo "== 3/3 immagine: $SRC_BYTES byte, sha256 $(cat "$IMG.sha256")"
    diskutil eject "$DISK" >/dev/null && echo "Scheda espulsa: inserisci l'Endurance e lancia: bash $0 write"
    ;;
write)
    echo "== 1/5 controllo l'immagine"
    [ -f "$IMG" ] && [ -f "$IMG.sha256" ] || die "manca $IMG: prima 'read'"
    IMG_BYTES=$(stat -f %z "$IMG")
    [ "$IMG_BYTES" = "$SRC_BYTES" ] || die "immagine di $IMG_BYTES byte invece di $SRC_BYTES"
    echo "$(cat "$IMG.sha256")  $IMG" | shasum -a 256 -c - >/dev/null || die "impronta dell'immagine diversa da quella letta"
    echo "   ok: immagine integra"
    echo "== 2/5 controllo la scheda"
    check_disk "$DST_BYTES" "la SanDisk Endurance da 32 GB"
    diskutil list "$DISK"
    read -r -p "== 3/5 Cancello TUTTO /dev/$DISK (l'Endurance con Buster: l'immagine di rollback e' in $DIR) e ci copio trixie. Scrivi SI: " ok
    [ "$ok" = SI ] || die "annullato"
    echo "== 4/5 scrivo"
    diskutil unmountDisk "/dev/$DISK"
    sudo dd if="$IMG" of="/dev/r$DISK" bs=4m status=progress
    sync
    echo "== 5/5 verifico"
    WANT=$(hash_outside_fat "$IMG" "")
    GOT=$(hash_outside_fat "/dev/r$DISK" sudo)
    [ "$GOT" = "$WANT" ] || die "MBR o partizione Linux sull'Endurance NON corrispondono all'immagine"
    echo "   ok: MBR e partizione Linux identici all'immagine, byte per byte"
    compare_fat_files
    diskutil eject "$DISK" >/dev/null && echo "FATTO. Endurance espulsa: rimettila nel Pi e riaccendilo."
    ;;
*)
    sed -n '2,13p' "$0"; exit 2 ;;
esac
