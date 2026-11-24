#!/bin/bash
# Test for the example pre.d scripts. The database tools are replaced by small
# stand-ins, so this needs only bash and gzip:
#   tests/hooks.sh
set -u
cd "$(dirname "$0")/.."
MYSQL_HOOK="$PWD/examples/pre.d/10-mysql-dump.sh"
PG_HOOK="$PWD/examples/pre.d/20-postgres-dump.sh"

T="$(mktemp -d /tmp/crb-hooks.XXXXXX)"
trap 'rm -rf "$T"' EXIT
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ${2:-}"; FAILS=$((FAILS + 1)); }

# Stand-ins: "mysql" lists the names in $T/dbs, "mysqldump" writes a line for
# the database and fails for names listed in $T/broken; the PostgreSQL ones
# work the same way.
mkdir -p "$T/bin"
cat >"$T/bin/mysql" <<EOF
#!/bin/bash
[ -f "$T/dbs" ] || exit 1
cat "$T/dbs"
EOF
cat >"$T/bin/mysqldump" <<EOF
#!/bin/bash
for db; do :; done
echo "dump of \$db, run \$(cat "$T/run")"
! grep -qxF "\$db" "$T/broken" 2>/dev/null
EOF
cat >"$T/bin/runuser" <<EOF
#!/bin/bash
echo "\$1 \$2" >"$T/ran-as"
shift 3
exec "\$@"
EOF
cat >"$T/bin/pg_dumpall" <<EOF
#!/bin/bash
echo "all databases, run \$(cat "$T/run")"
[ ! -e "$T/pg-broken" ]
EOF
chmod +x "$T/bin"/*
ln -s mysql "$T/bin/mariadb"; ln -s mysqldump "$T/bin/mariadb-dump"
export PATH="$T/bin:$PATH" CWP_RESTIC_DUMP_DIR="$T/out"
M="$T/out/mysql"; P="$T/out/pgsql"

dump() { gzip -dc "$1" 2>/dev/null; }
mode() { ls -ld "$1" | cut -c1-10; }

# --- mysql_dumps_every_database (one file each; the server's own schemas are left out)
printf 'information_schema\nshop\nblog_wp\nperformance_schema\nsys\nmysql\n' >"$T/dbs"
echo 1 >"$T/run"
"$MYSQL_HOOK" >"$T/log" 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(dump "$M/shop.sql.gz")" = "dump of shop, run 1" ] && [ "$(dump "$M/blog_wp.sql.gz")" = "dump of blog_wp, run 1" ] \
    && [ -f "$M/mysql.sql.gz" ] && [ "$(ls "$M" | wc -l | tr -d ' ')" = 3 ] && [ "$(mode "$M")" = "drwx------" ]; then
    pass mysql_dumps_every_database; else fail mysql_dumps_every_database "rc=$rc $(ls "$M" 2>/dev/null | tr '\n' ' ') $(cat "$T/log")"; fi

# --- mysql_failed_dump_keeps_the_last_good_one (and the others still run; the script reports it)
echo 2 >"$T/run"; echo shop >"$T/broken"
"$MYSQL_HOOK" >"$T/log" 2>&1; rc=$?
if [ $rc = 1 ] && [ "$(dump "$M/shop.sql.gz")" = "dump of shop, run 1" ] && [ "$(dump "$M/blog_wp.sql.gz")" = "dump of blog_wp, run 2" ] \
    && grep -q "shop" "$T/log" && [ "$(ls -A "$M" | wc -l | tr -d ' ')" = 3 ]; then
    pass mysql_failed_dump_keeps_the_last_good_one; else fail mysql_failed_dump_keeps_the_last_good_one "rc=$rc $(ls -A "$M" | tr '\n' ' ')"; fi
rm -f "$T/broken"

# --- mysql_dropped_database_is_removed
printf 'information_schema\nshop\nmysql\n' >"$T/dbs"
"$MYSQL_HOOK" >"$T/log" 2>&1; rc=$?
if [ $rc = 0 ] && [ ! -e "$M/blog_wp.sql.gz" ] && [ -f "$M/shop.sql.gz" ]; then
    pass mysql_dropped_database_is_removed; else fail mysql_dropped_database_is_removed "rc=$rc $(ls "$M" | tr '\n' ' ')"; fi

# --- mysql_server_down_keeps_everything (no list of databases: fail, and delete nothing)
rm -f "$T/dbs"
"$MYSQL_HOOK" >"$T/log" 2>&1; rc=$?
if [ $rc = 1 ] && [ -f "$M/shop.sql.gz" ] && [ -f "$M/mysql.sql.gz" ]; then
    pass mysql_server_down_keeps_everything; else fail mysql_server_down_keeps_everything "rc=$rc $(ls "$M" | tr '\n' ' ')"; fi

# --- postgres_dumps_all (as the postgres user)
echo 1 >"$T/run"
"$PG_HOOK" >"$T/log" 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(dump "$P/all.sql.gz")" = "all databases, run 1" ] && [ "$(cat "$T/ran-as")" = "-u postgres" ] \
    && [ "$(mode "$P")" = "drwx------" ]; then
    pass postgres_dumps_all; else fail postgres_dumps_all "rc=$rc $(cat "$T/log")"; fi

# --- postgres_failed_dump_keeps_the_last_good_one
echo 2 >"$T/run"; touch "$T/pg-broken"
"$PG_HOOK" >"$T/log" 2>&1; rc=$?
if [ $rc = 1 ] && [ "$(dump "$P/all.sql.gz")" = "all databases, run 1" ] && [ "$(ls -A "$P" | wc -l | tr -d ' ')" = 1 ]; then
    pass postgres_failed_dump_keeps_the_last_good_one; else fail postgres_failed_dump_keeps_the_last_good_one "rc=$rc $(ls -A "$P" | tr '\n' ' ')"; fi

if [ $FAILS = 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; exit 1; fi
