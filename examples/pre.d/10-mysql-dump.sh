#!/bin/bash
# cwp-restic pre.d script: dump every MySQL/MariaDB database to
# /var/backups/cwp-restic/mysql/<database>.sql.gz before each backup. The live
# files under /var/lib/mysql cannot be copied safely while the server runs;
# these dumps can be loaded back.
#
# To use: copy to /etc/cwp-restic/pre.d/, chmod 700, and keep
# /var/backups/cwp-restic in /etc/cwp-restic/include. It logs in the way
# "mysql" does for root on this server (on CWP: /root/.my.cnf).
#
# A database that fails to dump does not stop the others and keeps its last
# good dump; the script then exits 1 so the backup run is reported as failed.
set -u -o pipefail
export HOME="${HOME:-/root}"
OUT="${CWP_RESTIC_DUMP_DIR:-/var/backups/cwp-restic}/mysql"
MYSQL="$(command -v mariadb || command -v mysql)" || { echo "mysql-dump: no mysql client found"; exit 1; }
DUMP="$(command -v mariadb-dump || command -v mysqldump)" || { echo "mysql-dump: mysqldump not found"; exit 1; }
mkdir -p "$OUT" && chmod 700 "${OUT%/*}" "$OUT" || exit 1
failed=0

dbs="$("$MYSQL" -N -e 'show databases' | grep -Ev '^(information_schema|performance_schema|sys)$')" || {
    echo "mysql-dump: cannot list the databases"; exit 1; }

while IFS= read -r db; do
    if "$DUMP" --single-transaction --quick --routines --events --triggers "$db" \
        | gzip >"$OUT/.$db.tmp"; then
        mv "$OUT/.$db.tmp" "$OUT/$db.sql.gz"
    else
        echo "mysql-dump: dump of $db FAILED (the previous dump is kept)"
        rm -f "$OUT/.$db.tmp"
        failed=1
    fi
done <<<"$dbs"

# Drop dumps of databases that no longer exist.
for f in "$OUT"/*.sql.gz; do
    [ -e "$f" ] || continue
    name="${f##*/}"; name="${name%.sql.gz}"
    grep -qxF -- "$name" <<<"$dbs" || rm -f "$f"
done

exit $failed
