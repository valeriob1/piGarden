declare -a list_drv

#
# Funzione eseguita ad ogni avvio di piGarden.sh, si occupa includere tutti i file dei driver utilizzati e di lanciare
# la funzione di setup di ogni driver se esistente
#
function setup_drv { 

	#declare -a list_drv
	list_drv=()

        # Raccoglie i nomi dei driver utilizzati per le elettrovalvole
        for i in $(seq $EV_TOTAL)
        do
                local a=EV"$i"_GPIO
                local gpio="${!a}"
		if [[ "$gpio" == drv:* ]]; then
			local drv=`echo $gpio | $CUT -d':' -f2,2`
			if [[ ! " ${list_drv[@]} " =~ " ${drv} " ]]; then
				list_drv+=("$drv")
			fi
		fi
        done

	# Raccoglie i nomi dei driver utilizzati per gli altri gpio
	for gpio in "$SUPPLY_GPIO_1" "$SUPPLY_GPIO_2" "$RAIN_GPIO" "$WEATHER_SERVICE"
	do
		if [[ "$gpio" == drv:* ]]; then
			local drv=`echo $gpio | $CUT -d':' -f2,2`
			if [[ ! " ${list_drv[@]} " =~ " ${drv} " ]]; then
				list_drv+=("$drv")
			fi
		fi
	done

	#
	# Esegue l'unclusione dei file dei driver e per ognuno lancia l'eventuale funzione di setup
	#
	local file_drv
	for drv in "${list_drv[@]}"
	do
		for callback in config common init rele supply rainsensor rainonline setup
		do
			file_drv="$DIR_SCRIPT/drv/$drv/$callback.include.sh"
			if [ -f "$file_drv" ]; then
				#drv_avalible[$drv]="${drv_avalible[$drv]}#$callback#"
				#echo ${drv_avalible[$drv]}
				. "$file_drv"

				if [ $callback == "setup" ]; then
					local fnc="drv_${drv}_setup"
					echo "$(date) $fnc" >> "$LOG_OUTPUT_DRV_FILE"
					$fnc >> "$LOG_OUTPUT_DRV_FILE" 2>&1
				fi
			fi
		done
	done

}

#
# Restituisce in output il nome del driver callback function da richiamare per una specifica funzione
#
# $1 nome della funzione per il quale si vuore recuperare la callback
# $2 idetificativo del driver
function get_driver_callback {
	local fnc="$1"
	local idx="$2"
	local ret=""

	if [[ "$idx" == drv:* ]]; then
		local drv=`echo $idx | $CUT -d':' -f2,2`
		if [[ ! " ${list_drv[@]} " =~ " ${drv} " ]]; then
			ret="drvnotfound"
		else
			ret="drv_${drv}_${fnc}"
		fi
	fi
	echo "$ret"
}

#
# Risolve ed invoca, se presente, la callback del driver associata a "$idx" per la funzione "$1",
# occupandosi del logging comune a tutti i dispatch verso i driver.
#
# $1	nome della funzione per il quale si vuole recuperare/invocare la callback
# $2	identificativo (gpio o "drv:...") da passare alla callback
#
# return: 2 - nessun driver configurato per $2, il chiamante deve usare il fallback gpio raw
#	  1 - il driver configurato non e' stato trovato, oppure la callback del driver ha fallito
#	  0 - la callback del driver e' stata eseguita con successo
#
function drv_dispatch {
	local fnc=`get_driver_callback "$1" "$2"`

	if [ -z "$fnc" ]; then
		return 2
	elif [ "$fnc" == "drvnotfound" ]; then
	        log_write "drv" "error" "Driver not found: $2"
        	message_write "warning" "Driver not found: $2"
		return 1
	fi

	echo "$(date) $fnc arg:$2" >> "$LOG_OUTPUT_DRV_FILE"
	$fnc "$2" >> "$LOG_OUTPUT_DRV_FILE" 2>&1
	return $?
}

#
# Inizializza un relè e lo porta nello stato aperto
#
# $1	identificativo relè da inizializzare
#
function drv_rele_init {
	local idx="$1"
	drv_dispatch "rele_init" "$idx"

	# Nessun driver definito, esegue la chiusura del relè tramite gpio del raspberry
	if [ $? -eq 2 ]; then
                $GPIO -g write $idx $RELE_GPIO_OPEN   # chiude l'alimentazione all'elettrovalvole
                $GPIO -g mode $idx out                # setta il gpio nella modalita di scrittura
	fi
}

#
# Chiude un relè
#
# $1	identificativo relè da chiudere
#
function drv_rele_close {
	local idx="$1"
	drv_dispatch "rele_close" "$idx"
	local rc=$?

	# Nessun driver definito, esegue la chiusura del relè tramite gpio del raspberry
	if [ "$rc" -eq 2 ]; then
		$GPIO -g write $idx $RELE_GPIO_CLOSE
	elif [ "$rc" -eq 1 ]; then
		return 1
	fi
}

#
# Apre un relè
#
# $1	identificativo relè da aprire
#
function drv_rele_open {
	local idx="$1"
	drv_dispatch "rele_open" "$idx"
	local rc=$?

	# Nessun driver definito, esegue la chiusura del relè tramite gpio del raspberry
	if [ "$rc" -eq 2 ]; then
		$GPIO -g write $idx $RELE_GPIO_OPEN
	elif [ "$rc" -eq 1 ]; then
		return 1
	fi
}

#
# Inizializza i rele che gestiscono l'alimentazione per le valvole bistabili
#
# $1	identificativo relè 1
# $2	identificativo relè 2
#
function drv_supply_bistable_init {
	local idx
	for idx in "$1" "$2"; do
		drv_dispatch "supply_bistable_init" "$idx"
		# Nessun driver definito, esegue l'operazione tramite gpio del raspberry
		if [ $? -eq 2 ]; then
			$GPIO -g write $idx 0
			$GPIO -g mode $idx out
		fi
	done
}

#
# Imposta la tensine positiva per le elettrovalvole bistabili
#
# $1	identificativo rele 1
# $2	identificativo rele 2
#
function drv_supply_positive {
	local idx
	for idx in "$1" "$2"; do
		drv_dispatch "supply_positive" "$idx"
		# Nessun driver definito, esegue l'operazione tramite gpio del raspberry
		if [ $? -eq 2 ]; then
			$GPIO -g write $idx $SUPPLY_GPIO_POS
		fi
	done
}

#
# Imposta la tensine neagativa per le elettrovalvole bistabili
#
# $1	identificativo rele 1
# $2	identificativo rele 2
#
function drv_supply_negative {
	local idx
	for idx in "$1" "$2"; do
		drv_dispatch "supply_negative" "$idx"
		# Nessun driver definito, esegue l'operazione tramite gpio del raspberry
		if [ $? -eq 2 ]; then
			$GPIO -g write $idx $SUPPLY_GPIO_NEG
		fi
	done
}

#
# Inizializza il sensore della pioggia
#
# $1	identificativo gpio sensore pioggia
#
function drv_rain_sensor_init {
	local idx="$1"
	drv_dispatch "rain_sensor_init" "$idx"

	# Nessun driver definito, esegue la lettura del sensore tramite gpio del raspberry
	if [ $? -eq 2 ]; then
		$GPIO -g mode $idx in
	fi

}

#
# Legge lo stato del sensore della pioggia
#
# $1	identificativo gpio sensore pioggia
#
function drv_rain_sensor_get {
	local idx="$1"
	local fnc=`get_driver_callback "rain_sensor_get" "$idx"`
	local vret=""

	# Nessun driver definito, esegue la lettura del sensore tramite gpio del raspberry
	if [ -z "$fnc" ]; then
		vret=`$GPIO -g read $idx`
	# Il driver definito non è stato trovato
	elif [ "$fnc" == "drvnotfound" ]; then
	        log_write "drv" "error" "Driver not found: $idx"
        	message_write "warning" "Driver not found: $idx"
	else
		echo "$(date) $fnc arg:$idx" >> "$LOG_OUTPUT_DRV_FILE"
		vret=`$fnc "$idx"`
	fi

	echo "$vret"

}

#
# Legge lo stato le condizioni meteo dal servizio online
#
# $1	identificativo gpio sensore pioggia
#
function drv_rain_online_get {
	local idx="$1"
	local fnc=`get_driver_callback "rain_online_get" "$idx"`
	local vret=""

	# Non esiste un fallback raw gpio per il meteo online: nessun driver configurato o driver non trovato sono entrambi un errore
	if [ -z "$fnc" ] || [ "$fnc" == "drvnotfound" ]; then
	        log_write "drv" "error" "Driver not found: $idx"
        	message_write "warning" "Driver not found: $idx"
	else
		echo "$(date) $fnc arg:$idx" >> "$LOG_OUTPUT_DRV_FILE"
		vret=`$fnc "$idx"`
	fi

	echo "$vret"

}
