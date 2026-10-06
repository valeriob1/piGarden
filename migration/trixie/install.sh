#!/bin/bash
#
# Sul Pi NUOVO (Raspberry Pi OS Lite trixie, utente pi): installa piGarden come
# era sul sistema vecchio, una fase alla volta. Ogni fase si puo' rilanciare.
#
#   bash install.sh prepare      pacchetti, WiringPi, ripristino di codice/conf/stato/chiavi
#   bash install.sh check        controlli senza toccare i rele'
#   bash install.sh relay-test   init + apre/chiude ogni zona (ACQUA CHIUSA A MONTE)
#   bash install.sh activate     socket server + crontab (da qui il Pi irriga davvero)
#   bash install.sh verify       dopo un riavvio: tutto e' ripartito da solo?
#
# File attesi in ~/migration (portati dal Mac):
#   pigarden-bundle.tgz, pigarden-bundle.tgz.sha256 (da bundle-old.sh)
#   wiringpi_3.20_armhf.deb
#
# Log di ogni esecuzione: ~/migration/install-<fase>-<data>.log
#
set -uo pipefail

MIG="${MIG:-$HOME/migration}"
BUNDLE="${BUNDLE:-$MIG/pigarden-bundle.tgz}"
DEB="$MIG/wiringpi_3.20_armhf.deb"
DEB_SHA256=77b66d85109374f82ed5e1da03f7e710b3ec419fd9c39db10c0d66ca1542c055
DONGLE_MAC="24:ec:99:a6:4c:d7"
EXPECTED_IP="192.168.20.9"
PG=/home/pi/piGarden
CONF=/etc/piGarden.conf
EXPECTED_CRON_LINES=25
# TEST_MODE=1 solo per il collaudo a secco in un container: salta i controlli
# di hardware/rete e accetta un gpio finto. Mai sul Pi.
TEST_MODE="${TEST_MODE:-0}"

PHASE="${1:-}"
mkdir -p "$MIG"
LOG="$MIG/install-${PHASE:-none}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

FAILS=0; WARNS=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
die()  { printf '  [STOP] %s\n' "$*"; exit 1; }
step() { printf '\n== %s\n' "$*"; }
summary() {
    printf '\n== Esito fase %s: %d errori, %d avvisi. Log: %s\n' "$PHASE" "$FAILS" "$WARNS" "$LOG"
    [ "$FAILS" -eq 0 ]
}
pg() { (cd "$PG" && ./piGarden.sh "$@"); }
cron_active() {
    if [ -d /run/systemd/system ]; then systemctl is-active --quiet cron; else pgrep -x cron >/dev/null; fi
}
confval() { bash -c "source $CONF >/dev/null 2>&1; eval echo \"\\\${$1}\""; }

# Chiede "status" al socket server come fa piGardenWeb (utente, password, comando)
# e controlla che risponda JSON. Le credenziali non vengono stampate.
check_socket() {
    local port resp
    port=$(confval TCPSERVER_PORT)
    resp=$(timeout 20 bash -c '
        exec 3<>/dev/tcp/127.0.0.1/'"$port"' || exit 1
        { [ -n "$1" ] && [ -n "$2" ] && printf "%s\n%s\n" "$1" "$2"; printf "status\n"; } >&3
        cat <&3' _ "$(confval TCPSERVER_USER)" "$(confval TCPSERVER_PWD)" 2>/dev/null)
    if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
        fail "il socket sulla porta $port non risponde JSON: $(echo "$resp" | head -c 150)"
    elif echo "$resp" | grep -q "Bad socket server credentials"; then
        fail "il socket rifiuta le credenziali di $CONF"
    else
        ok "il socket risponde a 'status' come a piGardenWeb ($(echo "$resp" | jq -c 'keys' | head -c 120))"
    fi
}

# ---------------------------------------------------------------- controlli comuni

check_platform() {
    step "Piattaforma"
    [ "$(id -un)" = pi ] && ok "utente pi" || die "va eseguito come utente pi"
    sudo -n true 2>/dev/null && ok "sudo senza password" || die "sudo non disponibile senza password"
    . /etc/os-release
    [ "${VERSION_CODENAME:-}" = trixie ] && ok "$PRETTY_NAME" || fail "sistema $PRETTY_NAME, atteso trixie"
    if [ "$TEST_MODE" = 1 ]; then warn "TEST_MODE: salto modello, rete, ora"; return; fi
    local model; model=$(tr -d '\0' < /proc/device-tree/model)
    [[ "$model" == "Raspberry Pi Zero W"* ]] && ok "$model, kernel $(uname -r)" || die "modello inatteso: $model"
}

check_network() {
    [ "$TEST_MODE" = 1 ] && return
    step "Rete"
    local ifc
    ifc=$(for d in /sys/class/net/*; do [ "$(cat "$d/address" 2>/dev/null)" = "$DONGLE_MAC" ] && basename "$d"; done)
    [ -n "$ifc" ] && ok "chiavetta AR9271 = $ifc ($DONGLE_MAC)" || { fail "chiavetta $DONGLE_MAC non trovata"; return; }
    ip -4 -br addr show "$ifc" | grep -q "$EXPECTED_IP/" && ok "$ifc ha $EXPECTED_IP" \
        || fail "$ifc non ha $EXPECTED_IP: $(ip -4 -br addr show "$ifc")"
    ip route get 1.1.1.1 2>/dev/null | grep -q "dev $ifc" && ok "rotta di default su $ifc" || fail "rotta di default non su $ifc"
    local others; others=$(ls /sys/class/net | grep -E '^wlan' | grep -vx "$ifc" || true)
    [ -z "$others" ] && ok "nessun'altra interfaccia WiFi (integrata spenta)" || warn "altre interfacce WiFi presenti: $others"
    local sig; sig=$(awk -v i="$ifc:" '$1==i{print int($4)}' /proc/net/wireless)
    [ -n "$sig" ] && ok "segnale ${sig} dBm" || warn "segnale non leggibile"
    if command -v iw >/dev/null; then
        if iw dev "$ifc" get power_save 2>/dev/null | grep -q "on"; then
            sudo iw dev "$ifc" set power_save off && warn "power_save era acceso, spento ora (al prossimo avvio lo fa NetworkManager)"
        else ok "power_save spento"; fi
    fi
    if grep -qE '^\s+password:' /boot/firmware/network-config 2>/dev/null; then
        sudo sh -c 'printf "# La WiFi e'"'"' configurata in /etc/netplan (cloud-init, primo avvio).\n# Password tolta da qui dopo l'"'"'installazione di piGarden.\n" > /boot/firmware/network-config'
        ok "password WiFi tolta da /boot/firmware/network-config (leggibile da tutti)"
    fi
}

check_time() {
    [ "$TEST_MODE" = 1 ] && return
    step "Ora e lingua"
    local i
    for i in $(seq 12); do
        [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && break; sleep 5
    done
    [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && ok "ora sincronizzata: $(date '+%F %T %Z')" \
        || fail "ora NON sincronizzata via NTP: il cron irrigherebbe all'ora sbagliata ($(date))"
    [ "$(timedatectl show -p Timezone --value)" = Europe/Rome ] && ok "fuso Europe/Rome" || fail "fuso $(timedatectl show -p Timezone --value)"
    locale -a 2>/dev/null | grep -qi '^it_IT.utf' && ok "locale it_IT.UTF-8 presente" || warn "locale it_IT.UTF-8 non generato"
}

check_binaries() {
    step "Programmi indicati in $CONF"
    local line var path
    while IFS= read -r line; do
        var=${line%%=*}; path=$(confval "$var")
        if [ -x "$path" ]; then ok "$var=$path"
        elif [ "$var" = MOSQUITTO_PUB ]; then ok "$var=$path assente, come sul sistema vecchio (MQTT spento)"
        else fail "$var=$path non eseguibile"; fi
    done < <(grep -E '^[A-Z_]+="?/(usr/)?(local/)?s?bin/[^"]*"?' "$CONF")
}

check_gpio_tool() {
    step "WiringPi"
    local g; g=$(confval GPIO)
    [ -n "$g" ] || { fail "GPIO non definito in $CONF"; return; }
    "$g" -v 2>&1 | head -1 | grep -q "3.20" && ok "$("$g" -v 2>&1 | head -1)" || fail "gpio -v: $("$g" -v 2>&1 | head -2 | tr '\n' ' ')"
    if [ "$TEST_MODE" != 1 ]; then
        ldd /usr/bin/gpio | grep -q "not found" && fail "librerie mancanti: $(ldd /usr/bin/gpio | grep 'not found')" || ok "librerie di gpio risolte"
        [ "$(stat -c '%U %a' /usr/bin/gpio)" = "root 4755" ] && ok "/usr/bin/gpio setuid root" || warn "/usr/bin/gpio: $(stat -c '%U %a' /usr/bin/gpio)"
    fi
}

# ---------------------------------------------------------------- fasi

phase_prepare() {
    check_platform
    check_network
    check_time

    step "File portati dal Mac"
    [ -f "$BUNDLE" ] || die "manca $BUNDLE"
    (cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256" >/dev/null) \
        && ok "pacchetto integro ($(basename "$BUNDLE"))" || die "impronta del pacchetto errata"
    if [ "$TEST_MODE" != 1 ]; then
        [ -f "$DEB" ] || die "manca $DEB"
        echo "$DEB_SHA256  $DEB" | sha256sum -c - >/dev/null && ok "wiringpi_3.20_armhf.deb integro" || die "impronta del .deb errata"
    fi
    tar -xzOf "$BUNDLE" meta/manifest | sed 's/^/     /'

    step "Pacchetti"
    sudo apt-get update -q || die "apt-get update fallito"
    # net-tools: il codice originale chiama /sbin/ifconfig (send_identifier)
    local pkgs="ucspi-tcp jq curl git bc cron iw net-tools"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $pkgs || die "installazione pacchetti fallita"
    ok "installati: $pkgs"
    command -v tcpserver >/dev/null && ok "tcpserver: $(command -v tcpserver)" || fail "tcpserver mancante"

    step "WiringPi 3.20"
    if [ "$TEST_MODE" = 1 ]; then
        warn "TEST_MODE: uso il gpio finto gia' presente in /usr/bin/gpio"
    else
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$DEB" || die "installazione WiringPi fallita"
        # Il .deb 3.20 contiene libwiringPi.so e libwiringPiDev.so come link al
        # percorso della macchina di build (/home/evil/...). gpio li cerca proprio
        # con quel nome (SONAME), quindi devono puntare alla libreria vera.
        local l
        for l in libwiringPi libwiringPiDev; do
            if [ ! -e "/usr/lib/$l.so" ]; then
                sudo ln -sfn "$l.so.3.20" "/usr/lib/$l.so" && warn "/usr/lib/$l.so era un link rotto: corretto"
            else ok "/usr/lib/$l.so -> $(readlink "/usr/lib/$l.so")"; fi
        done
        sudo ldconfig
    fi
    # /etc/piGarden.conf resta com'era: GPIO e JQ puntano a /usr/local/bin
    sudo ln -sfn /usr/bin/gpio /usr/local/bin/gpio
    sudo ln -sfn /usr/bin/jq /usr/local/bin/jq
    ok "/usr/local/bin/gpio e /usr/local/bin/jq collegati ai programmi di sistema"

    step "Ripristino dal pacchetto"
    if [ -e "$PG" ]; then
        local prev="$PG.prev-$(date +%Y%m%d-%H%M%S)"
        mv "$PG" "$prev" && warn "$PG esisteva: spostato in $prev"
    fi
    tar -C / -xzpf "$BUNDLE" home/pi/piGarden && ok "codice, stato e log in $PG ($(git -C "$PG" log --oneline -1))"
    sudo tar -C / -xzpf "$BUNDLE" --no-same-owner etc/piGarden.conf \
        && sudo chown root:root "$CONF" && sudo chmod 644 "$CONF" && ok "$CONF ripristinato (root:root 644, come prima)"
    install -d -m 700 /home/pi/.ssh
    touch /home/pi/.ssh/authorized_keys
    tar -xzOf "$BUNDLE" meta/authorized_keys | while IFS= read -r k; do
        [ -n "$k" ] && ! grep -qxF "$k" /home/pi/.ssh/authorized_keys && echo "$k" >> /home/pi/.ssh/authorized_keys
    done
    chmod 600 /home/pi/.ssh/authorized_keys
    ok "authorized_keys: $(wc -l < /home/pi/.ssh/authorized_keys) chiave/i"
    tar -xzOf "$BUNDLE" meta/crontab.pi > "$MIG/crontab.pi"
    ok "crontab messo da parte in $MIG/crontab.pi ($(grep -c piGarden "$MIG/crontab.pi") righe piGarden), NON ancora attivo"

    check_binaries
    check_gpio_tool
    summary
}

phase_check() {
    check_platform
    check_network
    check_time
    check_binaries
    check_gpio_tool

    step "piGarden (nessun rele' toccato)"
    [ -f "$CONF" ] && ok "$CONF presente" || die "manca $CONF: prima 'prepare'"
    local out
    local err; err=$(pg ev_status_all 2>&1 >/dev/null)
    out=$(pg ev_status_all 2>/dev/null)
    [ -z "$err" ] && ok "ev_status_all: $(echo "$out" | tr '\n' ' ')" || fail "ev_status_all scrive errori: $err"
    out=$(pg json_status 2>&1)
    echo "$out" | jq -e . >/dev/null 2>&1 && ok "json_status e' JSON valido" || fail "json_status non valido: $(echo "$out" | head -c 200)"

    local rg rs v
    rg=$(confval RAIN_GPIO); rs=$(confval RAIN_GPIO_STATE)
    v=$("$(confval GPIO)" -g read "$rg" 2>&1)
    if [ "$v" = "$rs" ]; then warn "sensore pioggia GPIO $rg = $v -> 'sta piovendo' (RAIN_GPIO_STATE=$rs)"
    elif [ "$v" = 0 ] || [ "$v" = 1 ]; then ok "sensore pioggia GPIO $rg = $v -> asciutto (con il filo staccato resta fisso a 1: verificare sul posto)"
    else fail "lettura GPIO $rg: $v"; fi

    if [ "$TEST_MODE" != 1 ]; then
        out=$(pg check_rain_online 2>&1); ok "check_rain_online eseguito"
        [ -s "$(confval STATUS_DIR)/last_weather_online" ] \
            && find "$(confval STATUS_DIR)/last_weather_online" -mmin -5 | grep -q . \
            && ok "meteo aggiornato ora: $(jq -r '(.weather // "?") + ", " + (.temp_c // "?") + " °C"' "$(confval STATUS_DIR)/last_weather_online" 2>/dev/null)" \
            || fail "meteo online non aggiornato: $out"
        local url; url=$(confval LOG_URL)
        if [ -n "$url" ]; then
            local code; code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url")
            [ "$code" != 000 ] && ok "piGardenWeb raggiungibile per i log ($url -> HTTP $code)" || fail "piGardenWeb non raggiungibile: $url"
        fi
    fi
    summary
}

phase_relay_test() {
    check_platform
    check_gpio_tool
    [ "$FAILS" -eq 0 ] || die "correggere prima gli errori sopra"
    if [ "$TEST_MODE" != 1 ]; then
        read -r -p $'\nL\'acqua e\' CHIUSA A MONTE? Scrivi ACQUA CHIUSA per procedere: ' a
        [ "$a" = "ACQUA CHIUSA" ] || die "annullato"
    fi
    local g n i al gp v_open v_closed
    g=$(confval GPIO); n=$(confval EV_TOTAL)
    v_open=$(confval RELE_GPIO_CLOSE)   # rele' chiuso = valvola aperta
    v_closed=$(confval RELE_GPIO_OPEN)  # rele' aperto = valvola chiusa

    step "init (porta tutti i rele' su 'valvola chiusa')"
    pg init >/dev/null 2>&1; ok "init eseguito"
    for i in $(seq "$n"); do
        al=$(confval "EV${i}_ALIAS"); gp=$(confval "EV${i}_GPIO")
        [ "$("$g" -g read "$gp")" = "$v_closed" ] && ok "$al (GPIO $gp) chiusa dopo init" || fail "$al (GPIO $gp) non chiusa dopo init: $("$g" -g read "$gp")"
    done

    for i in $(seq "$n"); do
        al=$(confval "EV${i}_ALIAS"); gp=$(confval "EV${i}_GPIO")
        step "$al (GPIO $gp)"
        pg open "$al" force >/dev/null 2>&1
        [ "$("$g" -g read "$gp")" = "$v_open" ] && ok "aperta: GPIO $gp = $v_open (si deve sentire il rele')" || fail "open: GPIO $gp = $("$g" -g read "$gp")"
        # con "force" piGarden registra stato 2 (aperta forzando il blocco pioggia)
        [ "$(pg ev_status "$al" 2>/dev/null)" = 2 ] && ok "stato piGarden: aperta (2 = forzata)" || fail "stato piGarden: $(pg ev_status "$al" 2>/dev/null), atteso 2"
        [ "$TEST_MODE" = 1 ] || sleep 5
        pg close "$al" >/dev/null 2>&1
        [ "$("$g" -g read "$gp")" = "$v_closed" ] && ok "chiusa: GPIO $gp = $v_closed" || fail "close: GPIO $gp = $("$g" -g read "$gp")"
        [ "$(pg ev_status "$al" 2>/dev/null)" = 0 ] && ok "stato piGarden: chiusa" || fail "stato piGarden non aggiornato"
    done
    step "Riepilogo"; pg ev_status_all
    summary
}

phase_activate() {
    check_platform
    [ -f "$MIG/crontab.pi" ] || die "manca $MIG/crontab.pi: prima 'prepare'"
    step "Socket server"
    pg init >/dev/null 2>&1; ok "init (tutte chiuse)"
    pg start_socket_server force >/dev/null 2>&1
    sleep 3
    ss -ltn | grep -q ":$(confval TCPSERVER_PORT) " && ok "in ascolto sulla porta $(confval TCPSERVER_PORT)" || fail "socket server non in ascolto"
    check_socket
    step "Crontab"
    crontab "$MIG/crontab.pi" || die "crontab non installato"
    diff <(crontab -l) "$MIG/crontab.pi" >/dev/null && ok "crontab identico a quello del Pi vecchio" || fail "crontab diverso dal pacchetto"
    local c; c=$(crontab -l | grep -c piGarden)
    [ "$c" -eq "$EXPECTED_CRON_LINES" ] && ok "$c righe piGarden" || fail "$c righe piGarden, attese $EXPECTED_CRON_LINES"
    cron_active && ok "cron attivo" || fail "cron non attivo"
    summary
    echo "Ora: sudo reboot, poi 'bash install.sh verify'."
}

phase_verify() {
    check_platform
    check_network
    check_time
    step "Ripartenza da sola dopo il riavvio"
    local boot; boot=$(date -d "$(uptime -s)" +%s)
    ss -ltn | grep -q ":$(confval TCPSERVER_PORT) " && ok "socket server partito da @reboot" || fail "socket server non in ascolto"
    check_socket
    local lf; lf=$(confval LOG_FILE)
    grep -a "End initialize" "$lf" | tail -1 | grep -q . && ok "ultimo init: $(grep -a 'Run initialize' "$lf" | tail -1 | cut -f1)" || fail "nessun init nel log"
    [ "$(crontab -l | grep -c piGarden)" -eq "$EXPECTED_CRON_LINES" ] && ok "crontab presente" || fail "crontab incompleto"
    cron_active && ok "cron attivo" || fail "cron non attivo"
    sleep 1
    find "$(confval STATUS_DIR)/last_weather_online" -newermt "@$boot" 2>/dev/null | grep -q . \
        && ok "meteo aggiornato dal cron dopo l'avvio" || warn "meteo non ancora aggiornato dal cron (gira ogni 3 minuti)"
    pg ev_status_all
    summary
}

case "$PHASE" in
    prepare)    phase_prepare ;;
    check)      phase_check ;;
    relay-test) phase_relay_test ;;
    activate)   phase_activate ;;
    verify)     phase_verify ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
esac
