#!/bin/bash
# Test for install.sh. It really installs — into /etc, /usr/local and /var —
# so it refuses to run anywhere but in a throwaway container:
#   docker run --rm -v "$PWD":/src:ro almalinux:9 bash -c \
#       'dnf -y -q install bzip2 hostname diffutils findutils >/dev/null && /src/tests/install.sh'
# systemctl and the MySQL tools are replaced by stand-ins and a CWP admin
# folder is made up; restic is really downloaded, so it needs the network.
set -u
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "refusing to run outside a container"; exit 1; }
cd "$(dirname "$0")/.."
INSTALL="$PWD/install.sh"
CONF=/etc/cwp-restic
ADMIN=/usr/local/cwpsrv/htdocs/resources/admin
LINE='module=restic_backups'
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ${2:-}"; FAILS=$((FAILS + 1)); }
mode() { stat -c %a "$1" 2>/dev/null; }

mkdir -p /opt/fake "$ADMIN/modules" "$ADMIN/include"
printf '#!/bin/bash\necho "$*" >>/tmp/systemctl-calls\n' >/opt/fake/systemctl
printf '#!/bin/bash\nprintf "information_schema\\nshop\\n"\n' >/opt/fake/mysql
printf '#!/bin/bash\nfor db; do :; done\necho "dump of $db"\n' >/opt/fake/mysqldump
chmod +x /opt/fake/*
export PATH="/opt/fake:$PATH"
# A menu file that another module already uses, without a line break at the end.
printf '<li>other module</li>' >"$ADMIN/include/3rdparty.php"

# --- first_install
out="$("$INSTALL" 2>&1)"; rc=$?
if [ $rc = 0 ]; then pass first_install; else fail first_install "rc=$rc $(tail -n 5 <<<"$out")"; fi

# --- restic_downloaded (the release binary, checked against its published checksum)
if /usr/local/bin/restic version 2>/dev/null | grep -q '^restic [0-9]'; then pass restic_downloaded; else fail restic_downloaded; fi

# --- command_installed
if [ -x /usr/local/sbin/cwp-restic ] && cmp -s bin/cwp-restic /usr/local/sbin/cwp-restic; then pass command_installed; else fail command_installed; fi

# --- settings_created (private, with a new repository password and a loud note about it)
if [ "$(mode $CONF)" = 700 ] && [ "$(mode $CONF/config)" = 600 ] && [ "$(mode $CONF/include)" = 600 ] && [ "$(mode $CONF/exclude)" = 600 ] \
    && [ "$(mode $CONF/password)" = 600 ] && [ "$(wc -c <$CONF/password)" -ge 32 ] && [ -d $CONF/repos ] \
    && [ "$(mode /var/lib/cwp-restic)" = 700 ] && grep -q -i "password" <<<"$out" && grep -q -i "copy" <<<"$out"; then
    pass settings_created; else fail settings_created "$(ls -la $CONF 2>&1 | tr '\n' ' ')"; fi

# --- mysql_hook_installed (a server with MySQL gets the dump script from the start)
if [ -x $CONF/pre.d/10-mysql-dump.sh ] && [ "$(mode $CONF/pre.d/10-mysql-dump.sh)" = 700 ]; then pass mysql_hook_installed; else fail mysql_hook_installed; fi

# --- timers_applied (the sample settings are valid; the queue watcher is switched on)
if [ -f /etc/systemd/system/cwp-restic-jobs.path ] && [ -f /etc/systemd/system/cwp-restic-prune.timer ] \
    && grep -q "daemon-reload" /tmp/systemctl-calls 2>/dev/null && grep -q "enable --now cwp-restic-jobs.path" /tmp/systemctl-calls; then
    pass timers_applied; else fail timers_applied "$(cat /tmp/systemctl-calls 2>&1 | tr '\n' '|')"; fi

# --- page_installed (module in place; one menu line on its own line, the other module's kept)
menu="$(cat "$ADMIN/include/3rdparty.php")"
if [ "$(mode "$ADMIN/modules/restic_backups.php")" = 640 ] && cmp -s panel/restic_backups.php "$ADMIN/modules/restic_backups.php" \
    && [ "$(grep -c "$LINE" <<<"$menu")" = 1 ] && [ "$(sed -n 1p <<<"$menu")" = '<li>other module</li>' ] \
    && [ "$(wc -l <<<"$menu")" = 2 ]; then
    pass page_installed; else fail page_installed "$menu"; fi

# --- logrotate_installed
if grep -q "/var/log/cwp-restic.log" /etc/logrotate.d/cwp-restic 2>/dev/null; then pass logrotate_installed; else fail logrotate_installed; fi

# --- first_backup (the sample include and exclude lists work with restic, and the dump lands in the backup)
printf 'REPOSITORY=/tmp/repo\n' >$CONF/repos/local.conf
/usr/local/sbin/cwp-restic backup local >/tmp/backup.out 2>&1; rc=$?
if [ $rc = 0 ] && /usr/local/sbin/cwp-restic restic local ls latest 2>/dev/null | grep -q "/var/backups/cwp-restic/mysql/shop.sql.gz" \
    && /usr/local/sbin/cwp-restic restic local ls latest 2>/dev/null | grep -q "^/etc/hostname$\|^/etc/passwd$"; then
    pass first_backup; else fail first_backup "rc=$rc $(tail -n 5 /var/log/cwp-restic.log 2>&1)"; fi

# --- rerun_keeps_what_is_there (settings, password and choices made since are not replaced)
echo "KEEP_DAILY=3" >>$CONF/config
echo "my-own-password" >$CONF/password
echo "/srv" >>$CONF/include
rm -f $CONF/pre.d/10-mysql-dump.sh
out="$("$INSTALL" 2>&1)"; rc=$?
if [ $rc = 0 ] && grep -q "^KEEP_DAILY=3$" $CONF/config && [ "$(cat $CONF/password)" = "my-own-password" ] && grep -q "^/srv$" $CONF/include \
    && [ ! -e $CONF/pre.d/10-mysql-dump.sh ] && [ -f $CONF/repos/local.conf ] \
    && [ "$(grep -c "$LINE" "$ADMIN/include/3rdparty.php")" = 1 ] && ! grep -q -i "new repository password" <<<"$out"; then
    pass rerun_keeps_what_is_there; else fail rerun_keeps_what_is_there "rc=$rc $(tail -n 5 <<<"$out")"; fi

# --- rerun_updates_the_program (a newer checkout replaces the command and the page)
echo "# old" >>/usr/local/sbin/cwp-restic; echo "old" >"$ADMIN/modules/restic_backups.php"
"$INSTALL" >/dev/null 2>&1
if cmp -s bin/cwp-restic /usr/local/sbin/cwp-restic && cmp -s panel/restic_backups.php "$ADMIN/modules/restic_backups.php"; then
    pass rerun_updates_the_program; else fail rerun_updates_the_program; fi

# --- bad_settings_do_not_break_the_update (the program is updated; the admin is told what to fix)
cp $CONF/config /tmp/config.good
echo "KEEP_DAILY=lots" >>$CONF/config
echo "# old" >>/usr/local/sbin/cwp-restic
out="$("$INSTALL" 2>&1)"; rc=$?
if cmp -s bin/cwp-restic /usr/local/sbin/cwp-restic && grep -q "KEEP_DAILY" <<<"$out" && grep -q "cwp-restic apply" <<<"$out"; then
    pass bad_settings_do_not_break_the_update; else fail bad_settings_do_not_break_the_update "rc=$rc $(tail -n 5 <<<"$out")"; fi
cp /tmp/config.good $CONF/config

# --- works_without_cwp (no panel: the command and timers only, and no panel folders appear)
rm -rf /usr/local/cwpsrv
out="$("$INSTALL" 2>&1)"; rc=$?
if [ $rc = 0 ] && [ ! -e /usr/local/cwpsrv ]; then pass works_without_cwp; else fail works_without_cwp "rc=$rc $(tail -n 5 <<<"$out")"; fi

# --- old_restic_is_refused (too old to work with: say so, replace nothing)
cp /usr/local/bin/restic /tmp/restic.real
printf '#!/bin/bash\necho "restic 0.12.1 compiled with go1.16 on linux/amd64"\n' >/usr/local/bin/restic
out="$("$INSTALL" 2>&1)"; rc=$?
if [ $rc != 0 ] && grep -q "0.12.1" <<<"$out" && grep -q "0.12.1" /usr/local/bin/restic; then
    pass old_restic_is_refused; else fail old_restic_is_refused "rc=$rc $(tail -n 3 <<<"$out")"; fi

# --- must_be_root
if command -v runuser >/dev/null 2>&1; then
    out="$(runuser -u nobody -- "$INSTALL" 2>&1)"; rc=$?
    if [ $rc != 0 ] && grep -q -i "root" <<<"$out"; then pass must_be_root; else fail must_be_root "rc=$rc $out"; fi
else
    echo "SKIP must_be_root (no runuser here)"
fi

if [ $FAILS = 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; exit 1; fi
