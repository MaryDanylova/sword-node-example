# stage.sh <host> <port>: put <host> in hostgroup 20 (no traffic) and wait until the monitor pings
# it cleanly. Only pings that started after staging count: the log keeps old results for a host
# that was a backend before (a rollback target), and those must not pass for a host that is down now.
H="$1"; P="$2"
if on_host "$H"; then echo "already on $H"; exit 0; fi
T0="$(date +%s)000000"
adm "DELETE FROM mysql_servers WHERE hostgroup_id = 20;
     INSERT INTO mysql_servers (hostgroup_id, hostname, port, use_ssl, max_connections)
       SELECT 20, '$H', $P, 1, max_connections FROM mysql_servers WHERE hostgroup_id = 10 LIMIT 1;
     LOAD MYSQL SERVERS TO RUNTIME;"
i=0
while [ $i -lt 30 ]; do
  E="$(adm "SELECT IFNULL(ping_error, 'ok') FROM monitor.mysql_server_ping_log
            WHERE hostname = '$H' AND port = $P AND time_start_us > $T0 ORDER BY time_start_us DESC LIMIT 1")"
  [ "$E" = ok ] && { echo "monitor: $H healthy"; exit 0; }
  i=$((i + 1)); sleep 2
done
echo "monitor: $H not healthy (${E:-no ping yet})"; exit 1
