#
# Funzioni comuni utilizzate dal driver
#

#
# Esegue un comando su un pigarden remoto tramite socket
#
# $1	identificativo pigarden remoto
# $2	comando da eseguire
#
function drv_remote_command {

	local remote="$1"
	local command="$2"

	local remote_ip_var=$remote"_IP"
	local remote_port_var=$remote"_PORT"
	local remote_user_var=$remote"_USER"
	local remote_pwd_var=$remote"_PWD"

	local remote_ip="${!remote_ip_var}"
	local remote_port="${!remote_port_var}"
	local remote_user="${!remote_user_var}"
	local remote_pwd="${!remote_pwd_var}"

	if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/$remote_ip/$remote_port" 2>/dev/null; then
		log_write "drv_remote" "error" "Remote '$remote' unreachable at $remote_ip:$remote_port"
		message_write "warning" "Remote '$remote' unreachable"
		return 1
	fi

	exec 5<>/dev/tcp/$remote_ip/$remote_port

	if [[ ! -z $remote_user ]] && [[ ! -z $remote_pwd ]]; then
		command="$remote_user\n$remote_pwd\n$command"
	fi

	echo -e "$command" >&5

	cat <&5

}


