#
# Esegue l'escape dei metacaratteri delle basic regular expression, cosi' un valore
# arbitrario (es. l'alias di un'elettrovalvola) puo' essere incluso in sicurezza in un pattern grep
#
# $1	stringa da rendere sicura
#
function regex_escape {
	echo "$1" | $SED -e 's/[][\.^$*]/\\&/g'
}

#
# Elimina una tipoliga di schedulazione dal crontab dell'utente
# $1	tipologia del crontab
# $2	argomento della tipologia
#
function cron_del {

	local CRON_TYPE=$1
	local CRON_ARG=$2

	if [ -z "$CRON_TYPE" ]; then
		echo "Cron type is empty" >&2
		log_write "cron" "error" "Cron type is empty"
		return 1
	fi

	local CRON_ARG_RE=`regex_escape "$CRON_ARG"`

	lock

	$CRONTAB -l > "$TMP_CRON_FILE"
	local START=`$GREP -n "^# START cron $CRON_TYPE $CRON_ARG_RE$" "$TMP_CRON_FILE"| $CUT -d : -f 1`
	local END=`$GREP -n "^# END cron $CRON_TYPE $CRON_ARG_RE$" "$TMP_CRON_FILE"| $CUT -d : -f 1`
	local re='^[0-9]+$'

	if ! [[ "$START" =~ $re ]] && ! [[ "$END" =~ $re ]] ; then
		echo "$1 $2 cron is not present" >&2
		rm -f "$TMP_CRON_FILE"
		unlock
		return
	fi
	if ! [[ $START =~ $re ]] ; then
  		echo "Cron start don't find" >&2
  		log_write "cron" "error" "Cron start don't find"
		rm -f "$TMP_CRON_FILE"
		unlock
		return 1
	fi
	if ! [[ $END =~ $re ]] ; then
  		echo "Cron end cron don't find" >&2
  		log_write "cron" "error" "Cron end cron don't find"
		rm -f "$TMP_CRON_FILE"
		unlock
		return 1
	fi
	if [ "$START" -gt "$END" ]; then
  		echo "Wrong position for start and end in cron" >&2
  		log_write "cron" "error" "Wrong position for start and end in cron"
		rm -f "$TMP_CRON_FILE"
		unlock
		return 1
	fi

	trigger_event "cron_del_before" "$1" "$2"
	# 'cat -s' comprime solo le righe vuote consecutive lasciate dalla cancellazione del blocco,
	# senza toccare eventuali righe duplicate (non vuote) altrove nel crontab
	$SED "$START,${END}d" "$TMP_CRON_FILE" | cat -s | $CRONTAB -
	local rc=$?
	rm -f "$TMP_CRON_FILE"
	unlock
	if [ "$rc" -ne 0 ]; then
		echo "Failed to write crontab" >&2
		log_write "cron" "error" "Failed to write crontab while deleting $CRON_TYPE $CRON_ARG"
		return 1
	fi
	trigger_event "cron_del_after" "$1" "$2"

}

#
# Aggiunge una schedulazione nel crontab dell'utente
# $1	tipologia del crontab
# $2	minuto
# $3	ora
# $4	giorno del mese
# $5	mese
# $6	giorno della settimana
# $7	argomento della tipologia
# $8	secondo argomento della tipologia
#
function cron_add {

	local CRON_TYPE=$1
	local CRON_M=$2
	local CRON_H=$3
	local CRON_DOM=$4
	local CRON_MON=$5
	local CRON_DOW=$6
	local CRON_ARG=$7
	local CRON_ARG2=$8
	local CRON_COMMAND=""
	local CRON_DISABLED=""
	local PATH_SCRIPT=`$READLINK -f "$DIR_SCRIPT/$NAME_SCRIPT"`
	local TMP_CRON_FILE2="$TMP_CRON_FILE-2"

	if [ -z "$CRON_TYPE" ]; then
		echo "Cron type is empty" >&2
		log_write "cron" "error" "Cron type is empty"
		return 1
	fi

	local CRON_ARG_RE=`regex_escape "$CRON_ARG"`

	lock

	$CRONTAB -l > "$TMP_CRON_FILE"
	local START=`$GREP -n "^# START cron $CRON_TYPE $CRON_ARG_RE$" "$TMP_CRON_FILE"| $CUT -d : -f 1`
	local END=`$GREP -n "^# END cron $CRON_TYPE $CRON_ARG_RE$" "$TMP_CRON_FILE"| $CUT -d : -f 1`
	local re='^[0-9]+$'

	local NEW_CRON=0
	local PREVIOUS_CONTENT=""

	if ! [[ $START =~ $re ]] && ! [[ $END =~ $re ]] ; then
  		NEW_CRON=1
	else
		if ! [[ $START =~ $re ]] ; then
  			echo "Cron start don't find" >&2
  			log_write "cron" "error" "Cron start don't find"
			rm -f "$TMP_CRON_FILE"
			unlock
			return 1
		fi
		if ! [[ $END =~ $re ]] ; then
  			echo "Cron end cron don't find" >&2
  			log_write "cron" "error" "Cron end cron don't find"
			rm -f "$TMP_CRON_FILE"
			unlock
			return 1
		fi
		START=$(($START + 1))
		END=$(($END - 1))

		if [ "$START" -gt "$END" ]; then
  			echo "Wrong position for start and end in cron" >&2
  			log_write "cron" "error" "Wrong position for start and end in cron"
			rm -f "$TMP_CRON_FILE"
			unlock
			return 1
		fi

		PREVIOUS_CONTENT=`$SED -n "$START,${END}p" "$TMP_CRON_FILE"`

	fi

	case "$CRON_TYPE" in

		init)
			CRON_M="@reboot"
			CRON_H=""
			CRON_DOM=""
			CRON_MON=""
			CRON_DOW=""
			CRON_COMMAND="$PATH_SCRIPT init"
			;;

		start_socket_server)
			CRON_M="@reboot"
			CRON_H=""
			CRON_DOM=""
			CRON_MON=""
			CRON_DOW=""
			CRON_COMMAND="$PATH_SCRIPT start_socket_server force"
			;;

		check_rain_online)
			CRON_M="*/3"
			CRON_H="*"
			CRON_DOM="*"
			CRON_MON="*"
			CRON_DOW="*"
			CRON_COMMAND="$PATH_SCRIPT check_rain_online 2> /tmp/check_rain_online.err"
			;;

		check_rain_sensor)
			CRON_M="*"
			CRON_H="*"
			CRON_DOM="*"
			CRON_MON="*"
			CRON_DOW="*"
			CRON_COMMAND="$PATH_SCRIPT check_rain_sensor 2> /tmp/check_rain_sensor.err"
			;;

		close_all_for_rain)
			CRON_M="*/5"
			CRON_H="*"
			CRON_DOM="*"
			CRON_MON="*"
			CRON_DOW="*"
			CRON_COMMAND="$PATH_SCRIPT close_all_for_rain 2> /tmp/close_all_for_rain.err 1> /dev/null"
			;;

		open)
			CRON_COMMAND="$PATH_SCRIPT open $CRON_ARG"
			if [ "$CRON_ARG2" == "disabled" ]; then
				CRON_DISABLED="#"
			fi
			;;

		open_in)
			CRON_COMMAND="$PATH_SCRIPT open $CRON_ARG $CRON_ARG2"
			;;

		open_in_stop)
			CRON_COMMAND="$PATH_SCRIPT close $CRON_ARG"
			;;

		close)
			CRON_COMMAND="$PATH_SCRIPT close $CRON_ARG"
			if [ "$CRON_ARG2" == "disabled" ]; then
				CRON_DISABLED="#"
			fi
			;;

		*)
			echo "Wrong cron type: $CRON_TYPE" >&2
			log_write "cron" "error" "Wrong cron type: $CRON_TYPE"
			rm -f "$TMP_CRON_FILE"
			unlock
			return 1
			;;

	esac

	if [ "$NEW_CRON" -eq "0" ]; then
		START=$(($START - 1))
		END=$(($END + 1))
		$SED "$START,${END}d" "$TMP_CRON_FILE" > "$TMP_CRON_FILE2"
	else
		cat "$TMP_CRON_FILE" > "$TMP_CRON_FILE2"
	fi

	if [ "$NEW_CRON" -eq "1" ]; then
		echo "" >> "$TMP_CRON_FILE2"
	fi
	echo "# START cron $CRON_TYPE $CRON_ARG" >> "$TMP_CRON_FILE2"
	if [ "$NEW_CRON" -eq "0" ]; then
		echo "$PREVIOUS_CONTENT" >> "$TMP_CRON_FILE2"
	fi
	echo "$CRON_DISABLED$CRON_M $CRON_H $CRON_DOM $CRON_MON $CRON_DOW $CRON_COMMAND" >> "$TMP_CRON_FILE2"
	echo "# END cron $CRON_TYPE $CRON_ARG" >> "$TMP_CRON_FILE2"

	trigger_event "cron_add_before" "$CRON_TYPE" "$CRON_ARG" "$CRON_DISABLED$CRON_M $CRON_H $CRON_DOM $CRON_MON $CRON_DOW $CRON_COMMAND"
	$CRONTAB "$TMP_CRON_FILE2"
	local rc=$?
	rm -f "$TMP_CRON_FILE" "$TMP_CRON_FILE2"
	unlock
	if [ "$rc" -ne 0 ]; then
		echo "Failed to write crontab" >&2
		log_write "cron" "error" "Failed to write crontab for $CRON_TYPE $CRON_ARG"
		return 1
	fi
	trigger_event "cron_add_after" "$CRON_TYPE" "$CRON_ARG" "$CRON_DISABLED$CRON_M $CRON_H $CRON_DOM $CRON_MON $CRON_DOW $CRON_COMMAND"

}

#
# Legge una tipoliga di schedulazione dal crontab dell'utente
# $1	tipologia del crontab
# $2	argomento della tipologia
#
function cron_get {

	local CRON_TYPE=$1
	local CRON_ARG=$2

	if [ -z "$CRON_TYPE" ]; then
		echo "Cron type is empty" >&2
		log_write "cron" "error" "Cron type is empty"
		return 1
	fi

	local CRON_ARG_RE=`regex_escape "$CRON_ARG"`

	$CRONTAB -l > "$TMP_CRON_FILE"
	local START=`$GREP -n "^# START cron $CRON_TYPE $CRON_ARG_RE$" "$TMP_CRON_FILE"| $CUT -d : -f 1`
	local END=`$GREP -n "^# END cron $CRON_TYPE $CRON_ARG_RE$" "$TMP_CRON_FILE"| $CUT -d : -f 1`
	local re='^[0-9]+$'

	local PREVIOUS_CONTENT=""

	if ! [[ $START =~ $re ]] && ! [[ $END =~ $re ]] ; then
  		PREVIOUS_CONTENT=""
	else
		if ! [[ $START =~ $re ]] ; then
  			echo "Cron start don't find" >&2
  			log_write "cron" "error" "Cron start don't find"
			rm -f "$TMP_CRON_FILE"
			return 1
		fi
		if ! [[ $END =~ $re ]] ; then
  			echo "Cron end cron don't find" >&2
  			log_write "cron" "error" "Cron end cron don't find"
			rm -f "$TMP_CRON_FILE"
			return 1
		fi
		START=$(($START + 1))
		END=$(($END - 1))

		if [ "$START" -gt "$END" ]; then
  			echo "Wrong position for start and end in cron" >&2
  			log_write "cron" "error" "Wrong position for start and end in cron"
			rm -f "$TMP_CRON_FILE"
			return 1
		fi

		PREVIOUS_CONTENT=`$SED -n "$START,${END}p" "$TMP_CRON_FILE"`
	fi

	rm -f "$TMP_CRON_FILE"
	echo "$PREVIOUS_CONTENT"

}

#
# Imposta il cron di inizializzazione della centralina
#
function set_cron_init {

	cron_del "init" 2> /dev/null
	cron_add "init"

}

#
# Elimina il cron di inizializzazione della centralina
#
function del_cron_init {

	cron_del "init"

}

#
# Imposta il cron per l'avvio del socket server
#
function set_cron_start_socket_server {

	cron_del "start_socket_server" 2> /dev/null
	cron_add "start_socket_server"

}

#
# Elimina il cron per l'avvio del socket server
#
function del_cron_start_socket_server {

	cron_del "start_socket_server"
}

#
# Imposta il cron che esegue il controllo di presenza pioggia tramite sensore
#
function set_cron_check_rain_sensor {

	cron_del "check_rain_sensor" 2> /dev/null
	cron_add "check_rain_sensor"
}

#
# Elimina il cron che esegue il controllo di presenza pioggia tramite sensore
#
function del_cron_check_rain_sensor {

	cron_del "check_rain_sensor"

}

#
# Imposta il cron che esegue il controllo di presenza pioggia tramite servizio online
#
function set_cron_check_rain_online {

	cron_del "check_rain_online" 2> /dev/null
	cron_add "check_rain_online"
}

#
# Elimina il cron che esegue il controllo di presenza pioggia tramite servizio online
#
function del_cron_check_rain_online {

	cron_del "check_rain_online"

}

#
# Imposta il cron che gestisce la chiusura delle elettrovalvole in caso di pioggia
#
function set_cron_close_all_for_rain {

	cron_del "close_all_for_rain" 2> /dev/null
	cron_add "close_all_for_rain"
}

#
# Elimina il cron che gestisce la chiusura delle elettrovalvole in caso di pioggia
#
function del_cron_close_all_for_rain {

	cron_del "close_all_for_rain"

}

#
# Verifica che l'alias di un'elettrovalvola esista, altrimenti registra l'errore e ritorna 1
# $1	alias da verificare
#
function require_alias_exists {
	local exists=`alias_exists "$1"`
	if [ "$exists" != "TRUE" ]; then
		log_write "cron" "error" "Alias $1 not found"
		echo "Alias $1 not found" >&2
		return 1
	fi
}

#
# Aggiunge una schedulazione cron per aprire una elettrovalvola
# $1	alias elettrovalvola
# $2	minuto cron
# $3	ora cron
# $4	giorno del mese cron
# $5	mese cron
# $6	giorno della settimana cron
# $7	disabled
#
function add_cron_open {

	require_alias_exists "$1" || return 1

	cron_add "open" "$2" "$3" "$4" "$5" "$6" "$1" "$7"

}

#
# Cancella tutte le schedulazioni cron per aprire una elettrovalvola
# $1	alias elettrovalvola
#
function del_cron_open {

	require_alias_exists "$1" || return 1

	cron_del "open" "$1"

}

#
# Legge tutte le schedulazioni cron per aprire una elettrovalvola
# $1	alias elettrovalvola
#
function get_cron_open {

	require_alias_exists "$1" || return 1

	cron_get "open" "$1"

}

#
# Cancella tutte le schedulazioni cron per aprire/chiudere una elettrovalvola in modo ritardato
# $1	alias elettrovalvola
#
function del_cron_open_in {

	require_alias_exists "$1" || return 1

	cron_del "open_in" "$1"
	cron_del "open_in_stop" "$1"

}

#
# Legge tutte le schedulazioni cron per chiudere una elettrovalvola
# $1	alias elettrovalvola
#
function get_cron_close {

	require_alias_exists "$1" || return 1

	cron_get "close" "$1"

}

#
# Aggiunge una schedulazione cron per chiudere una elettrovalvola
# $1	alias elettrovalvola
# $2	minuto cron
# $3	ora cron
# $4	giorno del mese cron
# $5	mese cron
# $6	giorno della settimana cron
# $7	disabled
#
function add_cron_close {

	require_alias_exists "$1" || return 1

	cron_add "close" "$2" "$3" "$4" "$5" "$6" "$1" "$7"

}

#
# Cancella tutte le schedulazioni cron per chiudere una elettrovalvola
# $1	alias elettrovalvola
#
function del_cron_close {

	require_alias_exists "$1" || return 1

	cron_del "close" "$1"

}

#
# Disabilita o riattiva tutte le schedulazioni di apertura e chiusura elettrovalvole
# $1	"disabled" per disabilitare le schedulazioni, stringa vuota per riattivarle
#
function cron_set_all_open_close_enabled {

	local disabled_flag="$1"
	local a=""
	local al=""
	local cron=""
	local failed=0
	local IFS=$'\n'	# make newlines the only separator for splitting "$crons" below

	#
	# Schedulazioni di apertura
	#
        for i in $(seq $EV_TOTAL)
        do
                a=EV"$i"_ALIAS
                al=${!a}
                local crons=`get_cron_open $al`
		if [[ ! -z "$crons" ]]; then
			del_cron_open $al || failed=1
			for cron in $crons
			do
				local CRON_M=`echo $cron | $CUT -d' ' -f1,1`
				local CRON_H=`echo $cron | $CUT -d' ' -f2,2`
				local CRON_DOM=`echo $cron | $CUT -d' ' -f3,3`
				local CRON_MON=`echo $cron | $CUT -d' ' -f4,4`
				local CRON_DOW=`echo $cron | $CUT -d' ' -f5,5`

				if [[ ${CRON_M:0:1} == "#" ]]; then
					CRON_M=${CRON_M:1:${#CRON_M}}
				fi

				add_cron_open $al "$CRON_M" "$CRON_H" "$CRON_DOM" "$CRON_MON" "$CRON_DOW" "$disabled_flag" || failed=1
			done
		fi

        done


	#
	# Schedulazioni di chiusura
	#
        for i in $(seq $EV_TOTAL)
        do
                a=EV"$i"_ALIAS
                al=${!a}
                local crons=`get_cron_close $al`
		if [[ ! -z "$crons" ]]; then
			del_cron_close $al || failed=1
			for cron in $crons
			do
				local CRON_M=`echo $cron | $CUT -d' ' -f1,1`
				local CRON_H=`echo $cron | $CUT -d' ' -f2,2`
				local CRON_DOM=`echo $cron | $CUT -d' ' -f3,3`
				local CRON_MON=`echo $cron | $CUT -d' ' -f4,4`
				local CRON_DOW=`echo $cron | $CUT -d' ' -f5,5`

				if [[ ${CRON_M:0:1} == "#" ]]; then
					CRON_M=${CRON_M:1:${#CRON_M}}
				fi

				add_cron_close $al "$CRON_M" "$CRON_H" "$CRON_DOM" "$CRON_MON" "$CRON_DOW" "$disabled_flag" || failed=1
			done
		fi

        done

	return $failed
}

#
# Disabilita tutte le schedulazioni di apertura e chiusura elettrovalvole
#
function cron_disable_all_open_close {
	cron_set_all_open_close_enabled "disabled"
}

#
# Attiva tutte le schedulazioni di apertura e chiusura elettrovalvole
#
function cron_enable_all_open_close {
	cron_set_all_open_close_enabled ""
}
