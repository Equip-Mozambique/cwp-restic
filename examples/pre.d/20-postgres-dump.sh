#!/bin/bash
# cwp-restic pre.d script: dump all PostgreSQL databases, with their roles, to
# /var/backups/cwp-restic/pgsql/all.sql.gz before each backup.
#
# To use: copy to /etc/cwp-restic/pre.d/, chmod 700, and keep
# /var/backups/cwp-restic in /etc/cwp-restic/include.
#
# A failed dump keeps the last good one; the script then exits 1 so the backup
# run is reported as failed.
set -u -o pipefail
OUT="${CWP_RESTIC_DUMP_DIR:-/var/backups/cwp-restic}/pgsql"
# The PGDG packages keep the tools outside PATH (/usr/pgsql-17/bin).
PG_DUMPALL="$(command -v pg_dumpall || ls /usr/pgsql-*/bin/pg_dumpall 2>/dev/null | sort -V | tail -n 1)"
[ -n "$PG_DUMPALL" ] || { echo "postgres-dump: pg_dumpall not found"; exit 1; }
mkdir -p "$OUT" && chmod 700 "${OUT%/*}" "$OUT" || exit 1

if runuser -u postgres -- "$PG_DUMPALL" | gzip >"$OUT/.all.tmp"; then
    mv "$OUT/.all.tmp" "$OUT/all.sql.gz"
else
    echo "postgres-dump: pg_dumpall FAILED (the previous dump is kept)"
    rm -f "$OUT/.all.tmp"
    exit 1
fi
