# Prepended to every script here. Runs inside a ProxySQL pod (sh + mysql client); the admin
# interface listens on 127.0.0.1:6032 only. Passwords are read in the pod and never leave it.
set -eu
adm() { mysql -h127.0.0.1 -P6032 -uadmin --password="$(cat /config/admin_password)" -N -B -e "$1" 2>/dev/null; }
var() { adm "SELECT variable_value FROM global_variables WHERE variable_name = '$1'"; }
on_host() { [ "$(adm "SELECT GROUP_CONCAT(hostname) FROM mysql_servers WHERE hostgroup_id = 10")" = "$1" ]; }
