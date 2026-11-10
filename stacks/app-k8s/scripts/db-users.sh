set -eu
{ read -r MU; read -r MP; } < /creds/master
{ read -r AU; read -r AP; } < /creds/app
{ read -r NU; read -r NP; } < /creds/monitor
# database generates [A-Za-z0-9] passwords and validates the names: safe to embed below.
case "$AU$AP$NU$NP" in *[!A-Za-z0-9_]*) echo "unexpected characters in a user secret" >&2; exit 1 ;; esac
export MYSQL_PWD="$MP"
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$MU" --ssl-mode=REQUIRED --connect-timeout=10 <<SQL
CREATE USER IF NOT EXISTS '$AU'@'%' IDENTIFIED BY '$AP' REQUIRE SSL;
ALTER USER '$AU'@'%' IDENTIFIED BY '$AP' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES,
      CREATE TEMPORARY TABLES, LOCK TABLES ON \`$DB_NAME\`.* TO '$AU'@'%';
CREATE USER IF NOT EXISTS '$NU'@'%' IDENTIFIED BY '$NP' REQUIRE SSL;
ALTER USER '$NU'@'%' IDENTIFIED BY '$NP' REQUIRE SSL;
SQL
echo "MySQL users in sync with their secrets: $AU (privileges on $DB_NAME only), $NU (USAGE only)"
