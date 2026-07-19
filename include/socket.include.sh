#
# Avvia il socket server
#
function start_socket_server {

	rm -f "$TCPSERVER_PID_FILE"
	echo $TCPSERVER_PID_SCRIPT > "$TCPSERVER_PID_FILE"
	$TCPSERVER -v -RHl0 $TCPSERVER_IP $TCPSERVER_PORT $0 socket_server_command 

}

#
# Ferma il socket server
#
function stop_socket_server {

        if [ ! -f "$TCPSERVER_PID_FILE" ]; then
                echo "Daemon is not running"
                exit 1
        fi

	log_write "socket_server" "info" "stop socket server"

        kill -9 $(list_descendants `cat "$TCPSERVER_PID_FILE"`) 2> /dev/null
        kill -9 `cat "$TCPSERVER_PID_FILE"` 2> /dev/null
        rm -f "$TCPSERVER_PID_FILE"

}

#
# Esegue un comando ricevuto dal socket server
#
function socket_server_command {

	RUN_FROM_TCPSERVER=1

	local line=""

	if [ ! -z "$TCPSERVER_USER" ] || [ ! -z "$TCPSERVER_PWD" ]; then
		if [ -z "$TCPSERVER_USER" ] || [ -z "$TCPSERVER_PWD" ]; then
			log_write "socket_server" "error" "socket connection from: $TCPREMOTEIP - refused: only one of TCPSERVER_USER/TCPSERVER_PWD is configured"
			json_error 0 "Socket server misconfigured"
			return
		fi
		local user=""
		local password=""
		read -t 3 user
		read -t 3 password
		user=$(echo "$user" | $TR -d '\r')
		password=$(echo "$password" | $TR -d '\r')
		if [ "$user" != "$TCPSERVER_USER" ] || [ "$password" != "$TCPSERVER_PWD" ]; then
			log_write "socket_server" "warning" "socket connection from: $TCPREMOTEIP - Bad socket server credentials - user:$user"
			json_error 0 "Bad socket server credentials"
			return
		fi
	fi

	local arg1 arg2 arg3 arg4 arg5 arg6 arg7 arg8
	read line
	line=$(echo "$line " | $TR -d '\r')
	read -r arg1 arg2 arg3 arg4 arg5 arg6 arg7 arg8 <<< "$line"

	log_write "socket_server" "info" "socket connection from: $TCPREMOTEIP - command: $arg1 $arg2 $arg3 $arg4 $arg5 $arg6 $arg7 $arg8"

	case "$arg1" in
        	status)
			json_status $arg2 $arg3 $arg4 $arg5 $arg6 $arg7
			;;

		open)
	                if [ "empty$arg2" == "empty" ]; then
        	                json_error 0 "Alias solenoid not specified"
			else
                		ev_open "$arg2" "$arg3" &> /dev/null
				json_status "get_cron_open_in:$arg2"
			fi
			;;

		open_in)
			ev_open_in "$arg2" "$arg3" "$arg4" "$arg5" &> /dev/null
			json_status "get_cron_open_in:$arg4"
			;;

		close)
	                if [ "empty$arg2" == "empty" ]; then
        	                json_error 0 "Alias solenoid not specified"
			else
                		ev_close "$arg2" &> /dev/null
				json_status "get_cron_open_in:$arg2"
                	fi
			;;

		close_all)
			if [ "$arg2" == "disable_scheduling" ]; then
				cron_disable_all_open_close &> /dev/null
			fi
			close_all &> /dev/null
			if [ $? -ne 0 ]; then
				message_write "warning" "Some solenoids failed to close"
			else
				message_write "success" "All solenoid closed"
			fi
			json_status
			;;

		cron_enable_all_open_close)
			cron_enable_all_open_close &> /dev/null
			if [ $? -ne 0 ]; then
				message_write "warning" "Some solenoid schedules failed to enable"
			else
				message_write "success" "All solenoid enabled"
			fi
			json_status
			;;

		set_general_cron)
			local vret=""
			local failed=0
			for i in $arg2 $arg3 $arg4 $arg5 $arg6 $arg7
		        do
				local out=""
				if [ "$i" = "set_cron_init" ]; then
					out=$(set_cron_init 2>&1) || failed=1
				elif [ "$i" = "set_cron_start_socket_server" ]; then
					out=$(set_cron_start_socket_server 2>&1) || failed=1
				elif [ "$i" = "set_cron_check_rain_sensor" ]; then
					out=$(set_cron_check_rain_sensor 2>&1) || failed=1
				elif [ "$i" = "set_cron_check_rain_online" ]; then
					out=$(set_cron_check_rain_online 2>&1) || failed=1
				elif [ "$i" = "set_cron_close_all_for_rain" ]; then
					out=$(set_cron_close_all_for_rain 2>&1) || failed=1
				fi
				vret="$vret$out"
			done

			if [ "$failed" -ne 0 ]; then
				json_error 0 "Cron set failed"
				log_write "socket_server" "error" "Cron set failed: $vret"
			else
				message_write "success" "Cron set successfull"
				json_status
			fi

			;;

		del_cron_open)
			local vret=""

			vret=$(del_cron_open "$arg2" 2>&1)

			if [ $? -ne 0 ]; then
				json_error 0 "Cron set failed"
				log_write "socket_server" "error" "Cron del failed: $vret"
			else
				message_write "success" "Cron set successfull"
				json_status
			fi

			;;

		del_cron_open_in)
			local vret=""

			vret=$(del_cron_open_in "$arg2" 2>&1)

			if [ $? -ne 0 ]; then
				json_error 0 "Cron del failed"
				log_write "socket_server" "error" "Cron del failed: $vret"
			else
				message_write "success" "Scheduled start successfully deleted"
				json_status "get_cron_open_in:$arg2"
			fi

			;;


		del_cron_close)
			local vret=""

			vret=$(del_cron_close "$arg2" 2>&1)

			if [ $? -ne 0 ]; then
				json_error 0 "Cron set failed"
				log_write "socket_server" "error" "Cron set failed: $vret"
			else
				message_write "success" "Cron set successfull"
				json_status
			fi

			;;

		add_cron_open)
			local vret=""

			vret=$(add_cron_open "$arg2" "$arg3" "$arg4" "$arg5" "$arg6" "$arg7" "$arg8" 2>&1)

			if [ $? -ne 0 ]; then
				json_error 0 "Cron set failed"
				log_write "socket_server" "error" "Cron set failed: $vret"
			else
				message_write "success" "Cron set successfull"
				json_status
			fi

			;;

		add_cron_close)
			local vret=""

			vret=$(add_cron_close "$arg2" "$arg3" "$arg4" "$arg5" "$arg6" "$arg7" "$arg8" 2>&1)

			if [ $? -ne 0 ]; then
				json_error 0 "Cron set failed"
				log_write "socket_server" "error" "Cron set failed: $vret"
			else
				message_write "success" "Cron set successfull"
				json_status
			fi

			;;

		cmd_pigardensched)
			local vret=""

			vret=$(cmd_pigardensched "$arg2" "$arg3" "$arg4" "$arg5" "$arg6" 2>&1)

			if [ $? -ne 0 ]; then
				json_error 0 "piGardenSched command failed"
				log_write "socket_server" "error" "piGardenSched command failed: $vret"
			else
				message_write "success" "Schedule set successfull"
				json_status
			fi

			;;

		reboot)
			message_write "warning" "System reboot is started"
			json_status
			local PATH_SCRIPT=`$READLINK -f "$DIR_SCRIPT/$NAME_SCRIPT"`
			nohup $PATH_SCRIPT reboot > /dev/null 2>&1 &
			;;

		poweroff)
			message_write "warning" "System shutdown is started"
			json_status
			local PATH_SCRIPT=`$READLINK -f "$DIR_SCRIPT/$NAME_SCRIPT"`
			nohup $PATH_SCRIPT poweroff > /dev/null 2>&1 &
			;;

		reset_last_rain_sensor_timestamp)
			reset_last_rain_sensor_timestamp
			message_write "success" "Timestamp of last sensor rain successfull reset"
			json_status
			;;

		reset_last_rain_online_timestamp)
			reset_last_rain_online_timestamp
			message_write "success" "Timestamp of last online rain successfull reset"
			json_status
			;;

		sensor_status_set)
	                if [ "empty$arg2" == "empty" ]; then
        	                json_error 0 "Alias sensor not specified"
			else
                		sensor_status_set "$arg2" "$arg3" "$arg4" &> /dev/null
				json_status
			fi
			;;

		*)
			json_error 0 "invalid command"
			;;

	esac

}


