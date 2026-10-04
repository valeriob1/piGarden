#!/bin/bash
#
# Completa la partizione di avvio della scheda appena scritta (niente sudo):
# cloud-init (user-data con la chiave del Mac, meta-data), file "ssh",
# WiFi e Bluetooth integrati spenti come sul sistema vecchio.
# La WiFi (network-config) la scrive wifi-card.sh, a parte.
#
set -euo pipefail

BOOT=/Volumes/bootfs
DISK=disk4
PUBKEY_FILE="$HOME/.ssh/id_rsa.pub"
HERE="$(cd "$(dirname "$0")" && pwd)"

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
grep -q "^Raspberry Pi reference 2026-09-15" "$BOOT/issue.txt" || die "$BOOT non e' l'immagine del 2026-09-15"

PUBKEY=$(cat "$PUBKEY_FILE")
case "$PUBKEY" in ssh-rsa\ *|ssh-ed25519\ *) ;; *) die "chiave pubblica non riconosciuta in $PUBKEY_FILE";; esac

# user-data: la chiave va tra apici singoli YAML
SQ="'"
sed "s|__SSH_PUBKEY__|'${PUBKEY//$SQ/$SQ$SQ}'|" "$HERE/card/user-data" > "$BOOT/user-data"
grep -q "__SSH_PUBKEY__" "$BOOT/user-data" && die "chiave non inserita in user-data"
cp "$HERE/card/meta-data" "$BOOT/meta-data"
: > "$BOOT/ssh"

# config.txt: una sola volta
if ! grep -q "^# piGarden" "$BOOT/config.txt"; then
    cat >> "$BOOT/config.txt" <<'EOF'

# piGarden: rete solo dalla chiavetta USB AR9271, come sul sistema vecchio
dtoverlay=disable-wifi
dtoverlay=disable-bt
EOF
fi

echo "ok: user-data, meta-data, ssh, config.txt pronti su $BOOT"
ls -la "$BOOT/user-data" "$BOOT/meta-data" "$BOOT/ssh" "$BOOT/network-config"
tail -5 "$BOOT/config.txt"
