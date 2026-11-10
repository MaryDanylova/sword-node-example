# switch.sh <host>: the staged <host> replaces hostgroup 10 at once; the old backend drains (up to
# 30 s), then is removed. Saved to disk, so a restarted pod keeps the switch.
H="$1"
if on_host "$H"; then echo "already on $H"; exit 0; fi
[ "$(adm "SELECT COUNT(*) FROM mysql_servers WHERE hostgroup_id = 20 AND hostname = '$H'")" = 1 ] || { echo "$H is not staged"; exit 1; }
adm "UPDATE mysql_servers SET status = 'OFFLINE_SOFT' WHERE hostgroup_id = 10;
     UPDATE mysql_servers SET hostgroup_id = 10 WHERE hostgroup_id = 20;
     LOAD MYSQL SERVERS TO RUNTIME;"
i=0
while [ $i -lt 30 ] && [ "$(adm "SELECT IFNULL(SUM(ConnUsed), 0) FROM stats_mysql_connection_pool
                                 WHERE hostgroup = 10 AND srv_host <> '$H'")" != 0 ]; do
  i=$((i + 1)); sleep 1
done
adm "DELETE FROM mysql_servers WHERE hostgroup_id = 10 AND hostname <> '$H';
     LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"
echo "switched to $H"
