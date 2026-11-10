# check.sh <host> <port> <database>: the app and monitor users log in to <host> over verified TLS,
# and the app database exists there. Changes nothing.
H="$1"; P="$2"; D="$3"
TAB="$(printf '\t')"
L="$(adm "SELECT username, password FROM mysql_users WHERE active = 1 ORDER BY username LIMIT 1")"
AU="${L%%"$TAB"*}"; AP="${L#*"$TAB"}"
try() { MYSQL_PWD="$2" mysql -h "$H" -P "$P" -u "$1" --ssl-ca=/config/rds-ca.pem --ssl-verify-server-cert --connect-timeout=10 -N -B -e "$3"; }
try "$(var mysql-monitor_username)" "$(var mysql-monitor_password)" "SELECT 1" >/dev/null || { echo "monitor user cannot log in to $H"; exit 1; }
N="$(try "$AU" "$AP" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$D'")" || { echo "app user $AU cannot log in to $H"; exit 1; }
[ "$N" = 1 ] || { echo "database $D not found on $H"; exit 1; }
echo "app user $AU and the monitor log in to $H over verified TLS, database $D is there"
