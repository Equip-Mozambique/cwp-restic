#!/bin/bash
# Test for bin/cwp-restic. Self-contained: scratch settings, local-directory
# repositories, mail captured to a file, systemctl replaced by a recorder.
# Needs Linux with restic and GNU tools:
#   tests/cli.sh [/path/to/cwp-restic]
# Runs as "nobody" when started as root so the unreadable-file case is real.
set -u
BIN="$(readlink -f "${1:-$(dirname "$0")/../bin/cwp-restic}")"
if [ "$(id -u)" = 0 ]; then
    exec runuser -u nobody -- "$(readlink -f "$0")" "$BIN"
fi
REAL_RESTIC="$(command -v restic)" || { echo "restic not found"; exit 1; }

T="$(mktemp -d /tmp/cwp-restic-test.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
# systemd runs the jobs without HOME, so the test does too.
unset HOME XDG_CACHE_HOME
export CWP_RESTIC_CONF_DIR="$T/conf" CWP_RESTIC_STATE_DIR="$T/state" CWP_RESTIC_LOG="$T/log" \
    CWP_RESTIC_LOCK_DIR="$T/run" CWP_RESTIC_CACHE_DIR="$T/cache" CWP_RESTIC_UNIT_DIR="$T/units" \
    CWP_RESTIC_INLINE_JOBS=1 RESTIC="$REAL_RESTIC" SYSTEMCTL="$T/systemctl"
FAILS=0
S="$T/state"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ${2:-}"; FAILS=$((FAILS + 1)); }

# Fresh scratch environment for each case: two repositories, "offsite" and "local".
setup() {
    chmod -R u+rwX "$T" 2>/dev/null
    rm -rf "$T"/{conf,run,src,repo-off,repo-local,repo-new,restore,restores,mail,log,vol,state,units,calls,pwned}
    mkdir -p "$T"/{conf/repos,conf/pre.d,run,src/site/sub,vol}
    echo "hello" >"$T/src/site/index.php"
    echo "odd" >"$T/src/site/we[i]rd *name.txt"
    head -c 200000 /dev/urandom >"$T/src/site/sub/photo.jpg"
    cat >"$T/conf/config" <<EOF
# test settings
HOST_LABEL=smoke
MAILTO=test@example.org
MAIL_CMD=tee -a $T/mail
RESTORE_DIR=$T/restores
RESTORE_MIN_FREE_GB=0
EOF
    echo "REPOSITORY=$T/repo-off" >"$T/conf/repos/offsite.conf"
    echo "REPOSITORY=$T/repo-local" >"$T/conf/repos/local.conf"
    echo "$T/src" >"$T/conf/include"
    echo "*.tmp" >"$T/conf/exclude"
    echo "test-password" >"$T/conf/password"
    : >"$T/mail"
    printf '#!/bin/bash\necho "$*" >>%s\n' "$T/calls" >"$T/systemctl"; chmod +x "$T/systemctl"
}

snapshots() { "$BIN" restic "$1" snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l; }
snap_id() { "$BIN" restic "$1" snapshots --json 2>/dev/null | grep -o '"short_id":"[a-f0-9]*"' | tail -n 1 | cut -d'"' -f4; }
# job <id suffix> <lines...> — queue a request the way the admin page does, then run the queue.
job() {
    local id="20260101-000000-$1"; shift
    mkdir -p "$S/queue"
    printf '%s\n' "$@" >"$S/queue/$id.job"
    "$BIN" jobs >/dev/null 2>&1
    JOB="$S/jobs/$id"
}
state() { sed -n 's/^state=//p' "$JOB/status" 2>/dev/null; }
message() { sed -n 's/^message=//p' "$JOB/status" 2>/dev/null; }

# ---------------------------------------------------------------- backups

# --- backup_restore
setup
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
"$BIN" restic offsite restore latest --target "$T/restore" >/dev/null 2>&1
if [ $rc = 0 ] && diff -r "$T/src" "$T/restore$T/src" >/dev/null 2>&1; then pass backup_restore; else fail backup_restore "rc=$rc"; fi

# --- unknown_repo (a name with no settings file is an error, not a silent no-op)
"$BIN" backup nope >/dev/null 2>&1; rc=$?
if [ $rc = 1 ]; then pass unknown_repo; else fail unknown_repo "rc=$rc"; fi

# --- pre_fail_still_backs_up (a failing pre.d script is reported, the backup still happens)
setup
printf '#!/bin/bash\nexit 1\n' >"$T/conf/pre.d/10-fail.sh"; chmod +x "$T/conf/pre.d/10-fail.sh"
printf '#!/bin/bash\ntouch %s\n' "$T/src/site/from-hook" >"$T/conf/pre.d/20-ok.sh"; chmod +x "$T/conf/pre.d/20-ok.sh"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 1 ] && [ "$(snapshots offsite)" = 1 ] && [ -s "$T/mail" ] && [ -e "$T/src/site/from-hook" ]; then pass pre_fail_still_backs_up; else fail pre_fail_still_backs_up "rc=$rc snaps=$(snapshots offsite)"; fi

# --- repo_unreachable
setup
# Nothing listens on port 1, so SSH is refused at once, like a storage outage.
echo "REPOSITORY=sftp://nobody@127.0.0.1:1//repo" >"$T/conf/repos/offsite.conf"
start=$(date +%s)
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
took=$(( $(date +%s) - start ))
if [ $rc = 1 ] && [ -s "$T/mail" ] && [ $took -lt 60 ]; then pass repo_unreachable; else fail repo_unreachable "rc=$rc took=${took}s"; fi

# --- overlap
setup
"$BIN" backup offsite >/dev/null 2>&1
flock "$T/run/cwp-restic-offsite.lock" sleep 15 &
sleep 1
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
kill %1 2>/dev/null; wait 2>/dev/null
if [ $rc = 0 ] && grep -q "skipped, already running" "$T/log" && [ "$(snapshots offsite)" = 1 ]; then pass overlap; else fail overlap "rc=$rc snaps=$(snapshots offsite)"; fi

# --- not_mounted (MOUNT set but nothing mounted there: refuse, so the root disk cannot fill)
setup
echo "MOUNT=$T/vol" >>"$T/conf/repos/local.conf"
"$BIN" backup local >/dev/null 2>&1; rc=$?
if [ $rc = 1 ] && [ -s "$T/mail" ] && [ ! -e "$T/repo-local" ]; then pass not_mounted; else fail not_mounted "rc=$rc"; fi

# --- unreadable_file (restic exit 3 -> warning, snapshot kept)
setup
echo secret >"$T/src/site/locked"; chmod 000 "$T/src/site/locked"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 3 ] && [ "$(snapshots offsite)" = 1 ] && grep -q "^Subject:.*warning" "$T/mail"; then pass unreadable_file; else fail unreadable_file "rc=$rc snaps=$(snapshots offsite)"; fi

# --- prune_keeps (default retention)
setup
"$BIN" backup offsite >/dev/null 2>&1
"$BIN" prune >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && grep -q "forget --keep-daily 7 --keep-weekly 5 --keep-monthly 12" "$T/log"; then pass prune_keeps; else fail prune_keeps "rc=$rc"; fi

# --- prune_keeps_configured
setup
printf 'KEEP_DAILY=3\nKEEP_WEEKLY=0\nKEEP_MONTHLY=2\n' >>"$T/conf/config"
"$BIN" backup offsite >/dev/null 2>&1
"$BIN" prune >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && grep -q "forget --keep-daily 3 --keep-monthly 2 " "$T/log"; then pass prune_keeps_configured; else fail prune_keeps_configured "rc=$rc"; fi

# --- no_reinit (a repository that vanishes must alarm, not silently start again empty)
setup
"$BIN" backup offsite >/dev/null 2>&1
rm -rf "$T/repo-off"; : >"$T/mail"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 1 ] && [ -s "$T/mail" ] && [ ! -e "$T/repo-off" ]; then pass no_reinit; else fail no_reinit "rc=$rc"; fi

# --- new_address_inits (pointing the same name at a new address may start a new repository)
setup
"$BIN" backup offsite >/dev/null 2>&1
echo "REPOSITORY=$T/repo-new" >"$T/conf/repos/offsite.conf"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ -e "$T/repo-new/config" ]; then pass new_address_inits; else fail new_address_inits "rc=$rc"; fi

# --- outside_window (WINDOW set and now is outside it -> nothing runs, no mail)
setup
echo "WINDOW=$(date -d '+2 hours' +%H:%M)-$(date -d '+3 hours' +%H:%M)" >>"$T/conf/config"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && grep -q "outside the backup window" "$T/log" && [ ! -e "$T/repo-off" ] && [ ! -s "$T/mail" ]; then pass outside_window; else fail outside_window "rc=$rc"; fi

# --- window_stop (a run still going when the window closes stops quietly and resumes next time)
setup
"$BIN" backup offsite >/dev/null 2>&1
printf '#!/bin/bash\ncase " $* " in *" backup "*) sleep 30 ;; esac\nexec %s "$@"\n' "$REAL_RESTIC" >"$T/slow-restic"
chmod +x "$T/slow-restic"
echo "WINDOW=$(date -d '-1 hour' +%H:%M:%S)-$(date -d '+5 seconds' +%H:%M:%S)" >>"$T/conf/config"
start=$(date +%s)
RESTIC="$T/slow-restic" "$BIN" backup offsite >/dev/null 2>&1; rc=$?
took=$(( $(date +%s) - start ))
if [ $rc = 0 ] && [ $took -lt 20 ] && grep -q "backup window closed" "$T/log" && [ ! -s "$T/mail" ] && [ "$(snapshots offsite)" = 1 ]; then pass window_stop; else fail window_stop "rc=$rc took=${took}s"; fi

# --- settings_are_not_run (settings files are data: shell syntax in a value is never executed)
setup
echo "REPOSITORY=$T/repo-off\$(id>$T/pwned)" >"$T/conf/repos/offsite.conf"
printf 'MY_KEY=$(id>%s)\n' "$T/pwned" >"$T/conf/repos/offsite.env"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(snapshots offsite)" = 1 ] && [ ! -e "$T/pwned" ]; then pass settings_are_not_run; else fail settings_are_not_run "rc=$rc snaps=$(snapshots offsite)"; fi

# --- bad_settings_refused (a value that makes no sense stops the run with an alarm, before restic starts)
setup
echo "LIMIT_UPLOAD_KB=fast" >>"$T/conf/repos/offsite.conf"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 1 ] && grep -q "LIMIT_UPLOAD_KB" "$T/mail" && [ ! -e "$T/repo-off" ] && grep -q " failed$" "$S/backup-offsite.last" 2>/dev/null; then
    pass bad_settings_refused; else fail bad_settings_refused "rc=$rc"; fi

# --- repo_env (extra back-end settings in repos/<name>.env reach restic; other lines are ignored)
setup
printf 'MY_BACKEND_KEY=s3cret=x\nbad line\nlower=no\n' >"$T/conf/repos/offsite.env"
printf '#!/bin/bash\necho "$MY_BACKEND_KEY" >%s\nexec %s "$@"\n' "$T/seen-env" "$REAL_RESTIC" >"$T/env-restic"; chmod +x "$T/env-restic"
RESTIC="$T/env-restic" "$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(cat "$T/seen-env" 2>/dev/null)" = "s3cret=x" ]; then pass repo_env; else fail repo_env "rc=$rc"; fi

# --- restore_dir_not_backed_up (restored copies must not land in the next backup)
setup
sed -i "s|^RESTORE_DIR=.*|RESTORE_DIR=$T/src/restores|" "$T/conf/config"
mkdir -p "$T/src/restores/old"; echo big >"$T/src/restores/old/file"
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && "$BIN" restic offsite ls latest 2>/dev/null | grep -q "site/index.php" \
    && ! "$BIN" restic offsite ls latest 2>/dev/null | grep -q "restores/old"; then pass restore_dir_not_backed_up; else fail restore_dir_not_backed_up "rc=$rc"; fi

# ---------------------------------------------------------------- status files

# --- status_files (a finished run leaves its result, snapshot list and size for the admin page)
setup
"$BIN" backup offsite >/dev/null 2>&1
if grep -q " ok$" "$S/backup-offsite.last" 2>/dev/null && [ "$(grep -o '"short_id"' "$S/snapshots-offsite.json" 2>/dev/null | wc -l)" = 1 ] \
    && grep -q '"total_size"' "$S/stats-offsite.json" 2>/dev/null; then
    pass status_files; else fail status_files "$(ls "$S" 2>&1 | tr '\n' ' ')"; fi

# --- status_failed (a failed run is recorded as failed)
setup
echo "REPOSITORY=sftp://nobody@127.0.0.1:1//repo" >"$T/conf/repos/offsite.conf"
"$BIN" backup offsite >/dev/null 2>&1
if grep -q " failed$" "$S/backup-offsite.last" 2>/dev/null; then pass status_failed; else fail status_failed "$(cat "$S/backup-offsite.last" 2>&1)"; fi

# --- status_skip_keeps (a run that did nothing leaves the last real result alone)
setup
"$BIN" backup offsite >/dev/null 2>&1
before="$(cat "$S/backup-offsite.last" 2>/dev/null)"
echo "WINDOW=$(date -d '+2 hours' +%H:%M)-$(date -d '+3 hours' +%H:%M)" >>"$T/conf/config"
sleep 1
"$BIN" backup offsite >/dev/null 2>&1
if [ -n "$before" ] && [ "$(cat "$S/backup-offsite.last")" = "$before" ]; then pass status_skip_keeps; else fail status_skip_keeps; fi

# --- refresh (rebuilds the snapshot lists without making a backup)
setup
"$BIN" backup offsite >/dev/null 2>&1
rm -f "$S"/snapshots-* "$S"/stats-*
"$BIN" refresh >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(snapshots offsite)" = 1 ] && grep -q '"short_id"' "$S/snapshots-offsite.json" 2>/dev/null; then pass refresh; else fail refresh "rc=$rc"; fi

# ---------------------------------------------------------------- timers

# --- apply_timers (schedules in the settings become systemd timers; the job runner is set up)
setup
echo "SCHEDULE=*-*-* 03:00:00" >>"$T/conf/repos/offsite.conf"
echo "PRUNE_AT=Sat *-*-* 06:00:00" >>"$T/conf/config"
"$BIN" apply >/dev/null 2>&1; rc=$?
U="$T/units"
if [ $rc = 0 ] && grep -q "^OnCalendar=\*-\*-\* 03:00:00$" "$U/cwp-restic-backup-offsite.timer" 2>/dev/null \
    && grep -q "cwp-restic backup offsite$" "$U/cwp-restic-backup-offsite.service" 2>/dev/null \
    && grep -q "^OnCalendar=Sat" "$U/cwp-restic-prune.timer" 2>/dev/null \
    && [ ! -e "$U/cwp-restic-backup-local.timer" ] && [ ! -e "$U/cwp-restic-check.timer" ] \
    && grep -q "queue" "$U/cwp-restic-jobs.path" 2>/dev/null && [ -e "$U/cwp-restic-job@.service" ] \
    && grep -q "daemon-reload" "$T/calls" && grep -q "enable --now cwp-restic-backup-offsite.timer" "$T/calls"; then
    pass apply_timers; else fail apply_timers "rc=$rc $(ls "$U" 2>&1 | tr '\n' ' ')"; fi

# --- apply_removes_timers (a schedule or repository that is gone takes its timer with it)
sed -i '/^SCHEDULE=/d' "$T/conf/repos/offsite.conf"
echo "SCHEDULE=daily" >>"$T/conf/repos/local.conf"
"$BIN" apply >/dev/null 2>&1
rm -f "$T/conf/repos/local.conf"
"$BIN" apply >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ ! -e "$U/cwp-restic-backup-offsite.timer" ] && [ ! -e "$U/cwp-restic-backup-local.timer" ] \
    && [ ! -e "$U/cwp-restic-backup-local.service" ] && grep -q "disable --now cwp-restic-backup-local.timer" "$T/calls"; then
    pass apply_removes_timers; else fail apply_removes_timers "rc=$rc $(ls "$U" 2>&1 | tr '\n' ' ')"; fi

# --- apply_rejects_bad (a schedule systemd cannot read is refused and nothing is written)
setup
echo "SCHEDULE=every blue moon" >>"$T/conf/repos/offsite.conf"
out="$("$BIN" apply 2>&1)"; rc=$?
if [ $rc = 1 ] && grep -q "SCHEDULE" <<<"$out" && [ ! -e "$T/units/cwp-restic-backup-offsite.timer" ]; then pass apply_rejects_bad; else fail apply_rejects_bad "rc=$rc $out"; fi

# ---------------------------------------------------------------- jobs from the admin page

# --- job_backup
setup
job aaaaaa action=backup repo=offsite
if [ "$(state)" = done ] && [ "$(snapshots offsite)" = 1 ] && [ ! -e "$S/queue/20260101-000000-aaaaaa.job" ] \
    && grep -q " ok$" "$S/backup-offsite.last"; then pass job_backup; else fail job_backup "state=$(state) $(message)"; fi

# --- job_rejects_unknown (unknown actions and repositories fail; odd file names are thrown away)
job bbbbbb action=reboot
s1="$(state)"
job cccccc action=backup repo=nope
s2="$(state)"
echo "action=backup" >"$S/queue/evil;name.job"
"$BIN" jobs >/dev/null 2>&1
if [ "$s1" = failed ] && [ "$s2" = failed ] && [ -z "$(ls "$S/queue")" ] && [ "$(ls "$S/jobs" | wc -l)" = 3 ] && [ "$(snapshots offsite)" = 1 ]; then
    pass job_rejects_unknown; else fail job_rejects_unknown "s1=$s1 s2=$s2 $(ls "$S/queue" "$S/jobs" | tr '\n' ' ')"; fi

# --- job_ls (lists one folder of a snapshot into the cache the admin page reads)
snap="$(snap_id offsite)"
job dddddd action=ls repo=offsite "snapshot=$snap" "path=$T/src/site"
list="$S/ls/offsite/$snap/$(printf '%s' "$T/src/site" | sha1sum | cut -c1-40).jsonl"
if [ "$(state)" = done ] && grep -q '"name":"index.php"' "$list" 2>/dev/null && grep -q '"name":"sub"' "$list" \
    && ! grep -q 'photo.jpg' "$list"; then pass job_ls; else fail job_ls "state=$(state) $(message)"; fi

# --- job_restore (chosen files go to a new folder under RESTORE_DIR; nothing live is touched)
echo "changed since the backup" >"$T/src/site/index.php"
: >"$T/mail"
job eeeeee action=restore repo=offsite "snapshot=$snap" "path=$T/src/site/we[i]rd *name.txt" "path=$T/src/site/sub"
R="$T/restores/20260101-000000-eeeeee"
if [ "$(state)" = done ] && [ "$(cat "$R$T/src/site/we[i]rd *name.txt" 2>/dev/null)" = odd ] \
    && cmp -s "$R$T/src/site/sub/photo.jpg" "$T/src/site/sub/photo.jpg" && [ ! -e "$R$T/src/site/index.php" ] \
    && [ "$(cat "$T/src/site/index.php")" = "changed since the backup" ] && [ -e "$R/.cwp-restic-restore" ] \
    && grep -q "^target=$R$" "$JOB/status" && [ "$(stat -c %a "$R")" = 700 ] && grep -q "^Subject:.*restore" "$T/mail"; then
    pass job_restore; else fail job_restore "state=$(state) $(message)"; fi

# --- restore_needs_space (refuses when the copy would not leave the configured free space)
sed -i 's/^RESTORE_MIN_FREE_GB=.*/RESTORE_MIN_FREE_GB=9999/' "$T/conf/config"
job ffffff action=restore repo=offsite "snapshot=$snap" "path=$T/src/site/sub"
if [ "$(state)" = failed ] && grep -q -i "space" <<<"$(message)" && [ ! -e "$T/restores/20260101-000000-ffffff" ]; then
    pass restore_needs_space; else fail restore_needs_space "state=$(state) $(message)"; fi
sed -i 's/^RESTORE_MIN_FREE_GB=.*/RESTORE_MIN_FREE_GB=0/' "$T/conf/config"

# --- restore_rejects_bad_input
job a00001 action=restore repo=offsite "snapshot=$snap" "path=relative/path"
s1="$(state)"
job a00002 action=restore repo=offsite "snapshot=latest --target /" "path=$T/src"
s2="$(state)"
job a00003 action=restore repo=offsite "snapshot=$snap"
s3="$(state)"
job a00004 action=restore repo=offsite "snapshot=$snap" "path=/no/such/folder"
s4="$(state)"
if [ "$s1$s2$s3$s4" = failedfailedfailedfailed ] && [ "$(ls "$T/restores" | wc -l)" = 1 ]; then pass restore_rejects_bad_input; else fail restore_rejects_bad_input "$s1 $s2 $s3 $s4 $(ls "$T/restores" | tr '\n' ' ')"; fi

# --- cleanup_expires (restore folders past RESTORE_KEEP_DAYS go; anything we did not make stays)
echo "RESTORE_KEEP_DAYS=7" >>"$T/conf/config"
touch -d '10 days ago' "$R/.cwp-restic-restore"
mkdir -p "$T/restores/20250101-000000-abcdef" "$T/restores/keep-me"
touch -d '10 days ago' "$T/restores/20250101-000000-abcdef" "$T/restores/keep-me"
job a00005 action=ls repo=offsite "snapshot=$snap" "path=$T/src"
if [ "$(state)" = done ] && [ ! -e "$R" ] && [ -d "$T/restores/20250101-000000-abcdef" ] && [ -d "$T/restores/keep-me" ]; then pass cleanup_expires; else fail cleanup_expires "$(ls "$T/restores" | tr '\n' ' ')"; fi

# --- job_settings (a valid change is written, hand-made lines survive, timers follow, the old settings are kept)
setup
job b00001 action=settings config.KEEP_DAILY=3 config.MAILTO=new@example.org "config.PRUNE_AT=Sun *-*-* 05:00:00" \
    "repo.offsite.SCHEDULE=*-*-* 04:00:00" repo.third.REPOSITORY=/mnt/disk/restic repo.third.LATE_DAYS=8 \
    include.set=1 "include=$T/src" include=/etc exclude.set=1
C="$T/conf"
if [ "$(state)" = done ] && grep -q "^KEEP_DAILY=3$" "$C/config" && grep -q "^MAILTO=new@example.org$" "$C/config" \
    && grep -q "^MAIL_CMD=tee -a" "$C/config" && grep -q "^# test settings$" "$C/config" \
    && grep -q "^REPOSITORY=$T/repo-off$" "$C/repos/offsite.conf" && grep -q "^SCHEDULE=\*-\*-\* 04:00:00$" "$C/repos/offsite.conf" \
    && grep -q "^REPOSITORY=/mnt/disk/restic$" "$C/repos/third.conf" && grep -q "^LATE_DAYS=8$" "$C/repos/third.conf" \
    && [ "$(cat "$C/include")" = "$T/src"$'\n'"/etc" ] && [ ! -s "$C/exclude" ] \
    && grep -q "^OnCalendar=\*-\*-\* 04:00:00$" "$T/units/cwp-restic-backup-offsite.timer" 2>/dev/null \
    && grep -q "^OnCalendar=Sun" "$T/units/cwp-restic-prune.timer" 2>/dev/null \
    && grep -q "^MAILTO=test@example.org$" "$C/.previous/config" && [ "$(stat -c %a "$C/config")" = 600 ]; then
    pass job_settings; else fail job_settings "state=$(state) $(message)"; fi

# --- settings_all_or_nothing (one bad value and nothing at all is changed)
setup
cp -r "$T/conf" "$T/conf.before"
job b00002 action=settings config.KEEP_MONTHLY=24 config.KEEP_DAILY=lots
s1="$(state)"; m1="$(message)"
job b00003 action=settings "config.MAIL_CMD=touch $T/pwned"
s2="$(state)"
job b00004 action=settings "repo.Bad Name.REPOSITORY=/x"
s3="$(state)"
job b00005 action=settings include.set=1
s4="$(state)"
job b00006 action=settings include.set=1 include=relative/path
s5="$(state)"
job b00007 action=settings repo.empty.SCHEDULE=daily
s6="$(state)"
job b00008 action=settings "repo.offsite.SCHEDULE=never ever"
s7="$(state)"
if [ "$s1$s2$s3$s4$s5$s6$s7" = failedfailedfailedfailedfailedfailedfailed ] && grep -q "KEEP_DAILY" <<<"$m1" \
    && diff -r "$T/conf.before" "$T/conf" >/dev/null && [ ! -e "$T/units" ] && [ ! -e "$T/pwned" ]; then
    pass settings_all_or_nothing; else fail settings_all_or_nothing "$s1 $s2 $s3 $s4 $s5 $s6 $s7 | $m1 | $(diff -r "$T/conf.before" "$T/conf" | head -3)"; fi
rm -rf "$T/conf.before"

# --- settings_delete_repo (removing a repository from the settings never touches its data)
setup
"$BIN" backup local >/dev/null 2>&1
job b00009 action=settings repo.local.delete=1
if [ "$(state)" = done ] && [ ! -e "$T/conf/repos/local.conf" ] && [ -e "$T/repo-local/config" ] && [ -e "$T/conf/repos/offsite.conf" ]; then
    pass settings_delete_repo; else fail settings_delete_repo "state=$(state) $(message)"; fi

[ $FAILS = 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
exit $FAILS
