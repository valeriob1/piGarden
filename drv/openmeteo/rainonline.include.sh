#
# Driver meteo Open-Meteo (https://open-meteo.com): gratuito, senza chiave api.
#
# Produce lo stesso last_weather_online degli altri driver meteo (formato
# storico wunderground letto da piGardenWeb), con il vento gia' in km/h e
# anche raffiche, temperatura percepita e punto di rugiada.
#

#
# Converte il codice meteo WMO di Open-Meteo nella descrizione usata da
# piGardenWeb (vedi resources/lang/*/pigarden.php) e nel nome dell'icona
#
# $1 codice WMO (current.weather_code)
#
# output: "<descrizione>|<icona>"
#
function drv_openmeteo_get_weather {

	case "$1" in
		0)		echo "Clear|clear" ;;
		1)		echo "Partly Cloudy|partlycloudy" ;;
		2)		echo "Scattered Clouds|partlycloudy" ;;
		3)		echo "Overcast|cloudy" ;;
		45)		echo "Fog|fog" ;;
		48)		echo "Freezing Fog|fog" ;;
		51|53|55)	echo "Drizzle|sleet" ;;
		56|57)		echo "Freezing Drizzle|sleet" ;;
		61|63|65|66|67)	echo "Rain|rain" ;;
		71|73|75)	echo "Snow|snow" ;;
		77)		echo "Snow Grains|snow" ;;
		80|81|82)	echo "Rain Showers|rain" ;;
		85|86)		echo "Snow Showers|snow" ;;
		95)		echo "Thunderstorm|tstorms" ;;
		96|99)		echo "Thunderstorms with Hail|tstorms" ;;
		*)		echo "|cloudy" ;;
	esac

}

#
# Ritorna lo stato delle condizioni meteo interrogando il servizio online
#
# $i 	identificativo gpio del sensore di pioggia
#
# return output:	0  - errore durante il recupero delle condizioni meteo
#			>0 - rilevato pioggia, timestamp del rilevamento
#			<0 - rilevato nessuna pioggia, timestamp del rilevamento
function drv_openmeteo_rain_online_get {

	local json="$TMP_PATH/check_rain_online.openmeteo.json"
	local url="https://api.open-meteo.com/v1/forecast?latitude=$OPENMETEO_LATITUDE&longitude=$OPENMETEO_LONGITUDE"
	url="$url&current=temperature_2m,relative_humidity_2m,apparent_temperature,dew_point_2m,is_day,weather_code,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m"
	url="$url&wind_speed_unit=kmh&timeformat=unixtime&timezone=${OPENMETEO_TZ:-auto}"

	if ! $CURL -sS --connect-timeout 5 --max-time 15 "$url" > "$json"; then
		echo "0"
		return
	fi

	# Un solo passaggio di jq per i campi che servono alla decisione
	local code is_day epoch wind_deg tz
	read -r code is_day epoch wind_deg tz < <($JQ -r '"\(.current.weather_code) \(.current.is_day) \(.current.time) \(.current.wind_direction_10m) \(.timezone)"' "$json" 2> /dev/null)

	# Risposta non valida (errore dell'api, json troncato): nessuna decisione
	if [[ ! "$code" =~ ^[0-9]+$ ]] || [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
		echo "0"
		return
	fi
	[[ "$wind_deg" =~ ^[0-9.]+$ ]] || wind_deg=0
	[ -n "$OPENMETEO_TZ" ] && tz="$OPENMETEO_TZ"

	local w=$(drv_openmeteo_get_weather "$code")
	local weather="${w%%|*}"
	local ico="${w##*|}"
	[ "$is_day" == "0" ] && ico="nt_$ico"
	ico="http://www.wunderground.com/static/i/c/k/$ico.gif"

	local current_observation
	current_observation=$($JQ -M \
		--arg city "$OPENMETEO_CITY" \
		--arg tz "$tz" \
		--arg weather "$weather" \
		--arg wind_dir "$(deg2dir $wind_deg)" \
		--arg ico "$ico" '
		def s(v): if v == null then "--" else (v | tostring) end;
		.current as $c | {
			display_location: { city: $city },
			observation_epoch: ($c.time | tostring),
			local_epoch: ($c.time | tostring),
			local_tz_long: $tz,
			weather: $weather,
			temp_c: s($c.temperature_2m),
			relative_humidity: (s($c.relative_humidity_2m) + "%"),
			wind_dir: $wind_dir,
			wind_degrees: s($c.wind_direction_10m),
			wind_kph: s($c.wind_speed_10m),
			wind_gust_kph: s($c.wind_gusts_10m),
			pressure_mb: s($c.pressure_msl),
			dewpoint_c: s($c.dew_point_2m),
			feelslike_c: s($c.apparent_temperature),
			icon_url: $ico
		}' "$json") || { echo "0"; return; }

	echo "$current_observation" > "$STATUS_DIR/last_weather_online"

	# Stessa regola degli altri driver meteo
	if 	[[ "$weather" == *"Rain"* ]] ||
		[[ "$weather" == *"Snow"* ]] ||
		[[ "$weather" == *"Hail"* ]] ||
		[[ "$weather" == *"Ice"* ]] ||
		[[ "$weather" == *"Thunderstorm"* ]] ||
		[[ "$weather" == *"Drizzle"* ]];
	then
		echo $epoch
	else
		echo "-$epoch"
	fi

}
