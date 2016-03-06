#!/bin/bash -x
set -eo pipefail

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

DATADIR="$("$@" --verbose --help --log-bin-index=`mktemp -u` 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

if [[ ( -n "$MASTER_ENV_MYSQL_SLAVE_PASSWORD" || -n "$MASTER_ENV_MYSQL_RANDOM_SLAVE_PASSWORD" ) && ! -d "$DATADIR/mysql" ]]; then
	echo "Creating slave from master";
	echo -e "[mysqld]\nserver-id=2" >> /etc/mysql/conf.d/id.cnf
	nc $MASTER_PORT_3307_TCP_ADDR $MASTER_PORT_3307_TCP_PORT | xbstream -x -C /var/lib/mysql
	innobackupex --apply-log /var/lib/mysql

	chown -R mysql:mysql "$DATADIR"
	#--skip-networking
	
	if [ -n "$MASTER_ENV_MYSQL_RANDOM_SLAVE_PASSWORD" ]; then
		MYSQL_RANDOM_SLAVE_PASSWORD=$MASTER_ENV_MYSQL_RANDOM_SLAVE_PASSWORD
	fi

	if [ -n "MYSQL_RANDOM_SLAVE_PASSWORD" -a -n "$MASTER_ENV_MYSQL_ROOT_PASSWORD" ]; then
		MASTER_ENV_MYSQL_SLAVE_PASSWORD="$(pwgen -1 12)"
		SLAVE_USER="r${HOSTNAME}"
		mysql=( mysql --protocol=tcp -uroot -p$MASTER_ENV_MYSQL_ROOT_PASSWORD -hmaster)
		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			-- SET @@SESSION.SQL_LOG_BIN=0;
			GRANT REPLICATION SLAVE ON *.* TO '${SLAVE_USER}'@'%' IDENTIFIED BY '${MASTER_ENV_MYSQL_SLAVE_PASSWORD}';
			FLUSH PRIVILEGES ;
		EOSQL

		echo "GENERATED REPL PASSWORD: ${SLAVE_USER} : ${MASTER_ENV_MYSQL_SLAVE_PASSWORD}"
	fi
	
	"$@" &
	pid="$!"

	MYSQL_ROOT_PASSWORD="$MASTER_ENV_MYSQL_ROOT_PASSWORD"

	mysql=( mysql --protocol=socket -uroot )

	if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
		mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
	fi

	for i in {30..0}; do
		if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
			break
		fi
		echo 'MySQL init process in progress...'
		sleep 1
	done
	if [ "$i" = 0 ]; then
		echo >&2 'MySQL init process failed.'
		exit 1
	fi

	awk '{print "SET GLOBAL gtid_purged=\""$3"\";"}' /var/lib/mysql/xtrabackup_binlog_info | mysql -B -uroot -p$MASTER_ENV_MYSQL_ROOT_PASSWORD
	echo "CHANGE MASTER TO MASTER_HOST=\"master\", MASTER_USER=\"${SLAVE_USER}\", MASTER_PASSWORD=\"$MASTER_ENV_MYSQL_SLAVE_PASSWORD\", MASTER_AUTO_POSITION = 1;" | mysql -B -uroot -p$MYSQL_ROOT_PASSWORD
	echo "START SLAVE;" | mysql -B -uroot -p$MYSQL_ROOT_PASSWORD

	if ! kill -s TERM "$pid" || ! wait "$pid"; then
		echo >&2 'MySQL init process failed.'
		exit 1
	fi
fi


if [ "$1" = 'mysqld' ]; then
	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi

		mkdir -p "$DATADIR"
		chown -R mysql:mysql "$DATADIR"

		echo 'Initializing database'
		mysql_install_db --user=mysql --datadir="$DATADIR" --rpm
		echo 'Database initialized'

		"$@" --skip-networking &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			# sed is for https://bugs.mysql.com/bug.php?id=20545
			mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		fi

		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi

		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		if [ -n "$MYSQL_SLAVE_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				-- What's done in this file shouldn't be replicated
				--  or products like mysql-fabric won't work
				-- SET @@SESSION.SQL_LOG_BIN=0;
				CREATE USER '${SLAVE_USER}'@'%' IDENTIFIED BY '${MYSQL_SLAVE_PASSWORD}' ;
				GRANT REPLICATION SLAVE ON *.* TO '${SLAVE_USER}'@'%';
				FLUSH PRIVILEGES ;
			EOSQL
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi

	if [ -z "$MASTER_ENV_PERCONA_VERSION" ]; then
		echo "Master Starting";
		echo -e "[mysqld]\nserver-id=1" >> /etc/mysql/conf.d/id.cnf
		( while true; do
			sleep 5;
			nc -l -p 3307 -c "innobackupex --user=root --password=$MYSQL_ROOT_PASSWORD --stream=xbstream /tmp";
		done ) </dev/null 2>&1 &
	fi

	chown -R mysql:mysql "$DATADIR"
fi

exec "$@"
