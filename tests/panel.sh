#!/bin/bash
# Test for the CWP admin page panel/restic_backups.php. Renders it with the php
# command line against made-up settings and status files; needs only php:
#   tests/panel.sh [/path/to/restic_backups.php]
# The page never runs a command, so nothing here needs restic or root.
set -u
cd "$(dirname "$0")/.."
PAGE="$(cd "$(dirname "${1:-panel/restic_backups.php}")" && pwd)/$(basename "${1:-panel/restic_backups.php}")"
PHP="${PHP:-php}"

T="$(mktemp -d /tmp/crb-panel.XXXXXX)"
trap 'rm -rf "$T"' EXIT
C="$T/conf"; S="$T/state"
export CWP_RESTIC_CONF_DIR="$C" CWP_RESTIC_STATE_DIR="$S" CWP_RESTIC_LOG="$T/log" \
    CWP_RESTIC_UNIT_DIR="$T/units" CWP_RESTIC_WAIT=0
FAILS=0
SNAP=bbbb222200

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ${2:-}"; FAILS=$((FAILS + 1)); }

ago() { "$PHP" -r 'echo gmdate("Y-m-d\TH:i:s", time() - (int)$argv[1]) . $argv[2];' -- "$1" "$2"; }
sha() { "$PHP" -r 'echo sha1($argv[1]);' -- "$1"; }

# snapshot <seconds ago> <short id> <path> — one snapshot as restic prints it.
snapshot() {
    printf '{"time":"%s","paths":["%s"],"hostname":"smoke","tags":["offsite"],"summary":{"backup_start":"%s","backup_end":"%s","data_added_packed":30212716,"total_files_processed":451926,"total_bytes_processed":70573862925},"id":"%s00","short_id":"%s"}' \
        "$(ago "$1" .411550809Z)" "$3" "$(ago "$1" .411550809Z)" "$(ago $(($1 - 45)) .813266115Z)" "$2" "$2"
}

timer_file() { printf '[Timer]\nOnCalendar=%s\n' "$2" >"$T/units/$1.timer"; }

# Fresh files for each case: two repositories, one good off-site backup two hours ago.
setup() {
    rm -rf "$C" "$S" "$T/log" "$T/units"
    mkdir -p "$C/repos" "$C/pre.d" "$S/queue" "$S/jobs" "$T/units"
    cat >"$C/config" <<EOF
# test settings
HOST_LABEL=smoke
MAILTO=test@example.org
MAIL_CMD=/usr/local/bin/mailer --quiet
PRUNE_AT=Sat *-*-* 06:00:00
CHECK_AT=*-*-01 07:00:00
EOF
    printf 'REPOSITORY=sftp:storagebox-backup:restic\nSCHEDULE=*-*-* 03:00:00\n' >"$C/repos/offsite.conf"
    printf 'REPOSITORY="/backup/restic"\nLATE_DAYS=8\n' >"$C/repos/local.conf"
    printf 'AWS_SECRET_ACCESS_KEY=env-s3cret\n' >"$C/repos/offsite.env"
    printf '# what to back up\n/home\n/etc\n' >"$C/include"
    printf '*.tmp\n' >"$C/exclude"
    echo "pass-s3cret" >"$C/password"
    printf '#!/bin/sh\n' >"$C/pre.d/10-mysql-dump.sh"; chmod +x "$C/pre.d/10-mysql-dump.sh"
    timer_file cwp-restic-backup-offsite "*-*-* 03:00:00"
    timer_file cwp-restic-prune "Sat *-*-* 06:00:00"
    timer_file cwp-restic-check "*-*-01 07:00:00"
    echo "$(ago 7200 +00:00) ok" >"$S/backup-offsite.last"
    echo "[$(snapshot 93600 aaaa1111 /home),$(snapshot 7200 bbbb2222 /home)]" >"$S/snapshots-offsite.json"
    echo '{"total_size":52751272173,"snapshots_count":2}' >"$S/stats-offsite.json"
    echo "2026-11-24T03:00:01+00:00 backup offsite done" >"$T/log"
}

# render [query] [post body] [cookies] — the page as the panel includes it;
# PHP warnings count as failures.
render() {
    "$PHP" -d display_errors=1 -d error_reporting=-1 -r '
        $include_path = "x";
        parse_str($argv[2], $_GET); parse_str($argv[3], $_POST); parse_str($argv[4], $_COOKIE);
        $_SERVER["REQUEST_METHOD"] = $argv[3] === "" ? "GET" : "POST";
        include $argv[1];' -- "$PAGE" "${1:-}" "${2:-}" "${3:-}" 2>&1
}
clean() { ! grep -q -E "Warning:|Notice:|Deprecated:|Fatal error|Parse error" <<<"$1"; }
# row <html> <repository> — the summary row of one repository.
row() { tr '\n' ' ' <<<"$1" | grep -o "<tr><th>$2</th>.*</tr>" | sed 's|</tr>.*||'; }
token() { grep -o 'name="rb_token" value="[a-f0-9]*"' <<<"$1" | head -1 | sed 's/.*value="//; s/"//'; }
queued() { find "$S/queue" -name '*.job' 2>/dev/null | wc -l | tr -d ' '; }
request() { cat "$S"/queue/*.job 2>/dev/null; }
# post <query> <body> — a POST carrying a good token.
post() { render "$1" "$2&rb_token=$(token "$(render)")"; }

# mkjob <id> <state> <action> <message> [target] — a request the helper has seen.
mkjob() {
    mkdir -p "$S/jobs/$1"
    printf 'action=%s\nrepo=offsite\n' "$3" >"$S/jobs/$1/request"
    printf 'state=%s\naction=%s\nrepo=offsite\nmessage=%s\ntarget=%s\nstarted=%s\nfinished=\npid=1\n' \
        "$2" "$3" "$4" "${5:-}" "$(date +%s)" >"$S/jobs/$1/status"
}

# listing <folder> <lines...> — a folder listing as the helper caches it.
listing() {
    local dir="$S/ls/offsite/$SNAP" path="$1"; shift
    mkdir -p "$dir"
    {
        echo '{"time":"2026-11-24T03:00:00.1Z","id":"bbbb222200","short_id":"bbbb2222","struct_type":"snapshot","message_type":"snapshot"}'
        printf '%s\n' "$@"
    } >"$dir/$(sha "$path").jsonl"
}
home_listing() {
    listing /home \
        '{"name":"home","type":"dir","path":"/home","mtime":"2026-11-20T10:00:00.123456789Z","struct_type":"node","message_type":"node"}' \
        '{"name":"zeta.txt","type":"file","path":"/home/zeta.txt","size":2048,"mtime":"2026-11-20T10:00:00.123456789Z","struct_type":"node","message_type":"node"}' \
        '{"name":"<b>x</b>.txt","type":"file","path":"/home/<b>x</b>.txt","size":5,"mtime":"2026-11-20T10:00:00Z","struct_type":"node","message_type":"node"}' \
        '{"name":"alice","type":"dir","path":"/home/alice","mtime":"2026-11-20T10:00:00.123456789Z","struct_type":"node","message_type":"node"}'
}

# The settings form exactly as the browser sends it back when nothing was edited.
FORM='rb_action=settings&config[HOST_LABEL]=smoke&config[MAILTO]=test@example.org&config[WINDOW]=&config[KEEP_DAILY]=7&config[KEEP_WEEKLY]=5&config[KEEP_MONTHLY]=12&config[PRUNE_AT]=Sat+*-*-*+06:00:00&config[CHECK_AT]=*-*-01+07:00:00&config[RESTORE_DIR]=/home/restic-restore&config[RESTORE_KEEP_DAYS]=7&config[RESTORE_MIN_FREE_GB]=5&repo[offsite][REPOSITORY]=sftp:storagebox-backup:restic&repo[offsite][SCHEDULE]=*-*-*+03:00:00&repo[offsite][MOUNT]=&repo[offsite][LIMIT_UPLOAD_KB]=&repo[offsite][LATE_DAYS]=2&repo[local][REPOSITORY]=/backup/restic&repo[local][SCHEDULE]=&repo[local][MOUNT]=&repo[local][LIMIT_UPLOAD_KB]=&repo[local][LATE_DAYS]=8&new_repo[name]=&new_repo[REPOSITORY]=&new_repo[SCHEDULE]=&new_repo[MOUNT]=&new_repo[LIMIT_UPLOAD_KB]=&new_repo[LATE_DAYS]=&include=%23+what+to+back+up%0D%0A/home%0D%0A/etc%0D%0A&exclude=*.tmp%0D%0A'

# --- direct_access (opened outside the panel, the file must do nothing)
setup
out="$("$PHP" "$PAGE" 2>&1)"
if [ "$out" = "invalid access" ]; then pass direct_access; else fail direct_access "$(head -c 80 <<<"$out")"; fi

# --- shows_good_backup
setup
out="$(render)"
if clean "$out" && grep -q "Restic Backups" <<<"$out" && grep -q "smoke" <<<"$out" && grep -q "bbbb2222" <<<"$out" \
    && grep -q "aaaa1111" <<<"$out" && grep -q "65.7 GiB" <<<"$out" && grep -q "49.1 GiB" <<<"$out" \
    && grep -q "label-success" <<<"$(row "$out" offsite)" && grep -q "sftp:storagebox-backup:restic" <<<"$(row "$out" offsite)" \
    && grep -q "backup offsite done" <<<"$out"; then
    pass shows_good_backup; else fail shows_good_backup "$(grep -E "Warning|Notice|Fatal" <<<"$out" | head -3)"; fi

# --- newest_first
if [ "$(grep -o -E "aaaa1111|bbbb2222" <<<"$out" | head -1)" = bbbb2222 ]; then pass newest_first; else fail newest_first; fi

# --- repo_without_backups (the address in its settings file is quoted)
if grep -q "No backup yet" <<<"$(row "$out" local)" && grep -q "<code>/backup/restic</code>" <<<"$(row "$out" local)"; then
    pass repo_without_backups; else fail repo_without_backups; fi

# --- shows_failed
setup
echo "$(ago 600 +00:00) failed" >"$S/backup-offsite.last"
out="$(render)"
if clean "$out" && grep -q "label-danger" <<<"$(row "$out" offsite)" && grep -q "Failed" <<<"$(row "$out" offsite)"; then pass shows_failed; else fail shows_failed; fi

# --- shows_late (last run said ok, but the newest snapshot is five days old)
setup
echo "[$(snapshot 432000 cccc3333 /home)]" >"$S/snapshots-offsite.json"
out="$(render)"
if clean "$out" && grep -q "label-warning" <<<"$(row "$out" offsite)" && grep -q "Late" <<<"$(row "$out" offsite)"; then pass shows_late; else fail shows_late; fi

# --- late_days_setting (LATE_DAYS=8: five days is fine; 0: never late)
setup
echo "[$(snapshot 432000 cccc3333 /home)]" >"$S/snapshots-local.json"
out="$(render)"
echo "LATE_DAYS=0" >>"$C/repos/local.conf"
echo "[$(snapshot 43200000 cccc3333 /home)]" >"$S/snapshots-local.json"
out2="$(render)"
echo "LATE_DAYS=8" >>"$C/repos/local.conf"
out3="$(render)"
if grep -q "label-success" <<<"$(row "$out" local)" && grep -q "label-success" <<<"$(row "$out2" local)" \
    && grep -q "Late" <<<"$(row "$out3" local)"; then pass late_days_setting; else fail late_days_setting; fi

# --- not_set_up (no settings at all: every tab says so, and nothing can be requested)
rm -rf "$C" "$S" "$T/log" "$T/units"
ok=1
for tab in status restore settings jobs; do
    out="$(render "tab=$tab")"
    clean "$out" && grep -q "not set up" <<<"$out" || ok=0
done
render "" "rb_action=backup&repo=offsite" >/dev/null
[ "$(queued)" = 0 ] || ok=0
if [ $ok = 1 ]; then pass not_set_up; else fail not_set_up "$(head -c 200 <<<"$out")"; fi

# --- broken_files (a half-written or damaged file must not break the page)
setup
echo '[{"time": "garb' >"$S/snapshots-offsite.json"
echo 'not json' >"$S/stats-offsite.json"
echo 'nonsense' >"$S/backup-offsite.last"
mkdir -p "$S/jobs/20260101-000000-aaaaaa"; echo 'garbage' >"$S/jobs/20260101-000000-aaaaaa/status"
out="$(render)"; out2="$(render tab=jobs)"; out3="$(render tab=restore)"
if clean "$out$out2$out3" && grep -q "No backup yet" <<<"$(row "$out" offsite)"; then pass broken_files; else fail broken_files "$(grep -E "Warning|Notice|Fatal" <<<"$out$out2$out3" | head -3)"; fi

# --- timer_mismatch (settings edited by hand without running "cwp-restic apply")
setup
out="$(render)"
echo "SCHEDULE=*-*-* 01:00:00" >>"$C/repos/offsite.conf"
out2="$(render)"
if ! grep -q "cwp-restic apply" <<<"$out" && grep -q "cwp-restic apply" <<<"$out2" && grep -q "01:00:00" <<<"$(row "$out2" offsite)"; then
    pass timer_mismatch; else fail timer_mismatch; fi

# --- tabs
setup
ok=1
for tab in status restore settings jobs; do
    out="$(render "tab=$tab")"
    clean "$out" && grep -q "<li class=\"active\"><a href=\"index.php?module=restic_backups&amp;tab=$tab\"" <<<"$out" || ok=0
done
out="$(render "tab=%3Cscript%3Ealert(1)%3C/script%3E")"
clean "$out" && grep -q '<li class="active"><a href="index.php?module=restic_backups&amp;tab=status"' <<<"$out" && ! grep -q "<script>alert" <<<"$out" || ok=0
if [ $ok = 1 ]; then pass tabs; else fail tabs; fi

# --- post_needs_token (a request from another site, or another login, does nothing)
setup
tok="$(token "$(render "" "" "session=one")")"
out="$(render "" "rb_action=backup&repo=offsite")"
render "" "rb_action=backup&repo=offsite&rb_token=deadbeef" >/dev/null
render "" "rb_action=backup&repo=offsite&rb_token=$tok" "session=two" >/dev/null
render "rb_action=backup&repo=offsite&rb_token=$tok" "" "session=one" >/dev/null
n="$(queued)"
render "" "rb_action=backup&repo=offsite&rb_token=$tok" "session=one" >/dev/null
if [ ${#tok} -ge 32 ] && [ "$n" = 0 ] && [ "$(queued)" = 1 ] && grep -q "form has expired" <<<"$out" && clean "$out"; then
    pass post_needs_token; else fail post_needs_token "tok=${#tok} before=$n after=$(queued)"; fi

# --- backup_now (the request file is all the page leaves behind)
setup
out="$(post "" "rb_action=backup&repo=offsite")"
file="$(ls -A "$S/queue")"
if clean "$out" && grep -q "Backup requested" <<<"$out" && [[ "$file" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]{6}\.job$ ]] \
    && [ "$(request)" = "$(printf 'action=backup\nrepo=offsite')" ] \
    && [ "$(find "$S/queue" -name '*.job' -perm 600 | wc -l | tr -d ' ')" = 1 ]; then
    pass backup_now; else fail backup_now "$file: $(request | tr '\n' '|')"; fi

# --- backup_unknown_repo
setup
out="$(post "" "rb_action=backup&repo=nope")"
out2="$(post "" "rb_action=backup&repo=../offsite")"
out3="$(post "" "rb_action=reboot&repo=offsite")"
if clean "$out$out2$out3" && [ "$(queued)" = 0 ] && grep -q "Unknown repository" <<<"$out"; then pass backup_unknown_repo; else fail backup_unknown_repo; fi

# --- restore_lists_backups
setup
out="$(render tab=restore)"
if clean "$out" && grep -q "tab=restore&amp;repo=offsite&amp;snapshot=bbbb222200" <<<"$out" && grep -q "aaaa1111" <<<"$out" && [ "$(queued)" = 0 ]; then
    pass restore_lists_backups; else fail restore_lists_backups; fi

# --- browse_cached (folders first, the folder itself is not an entry, nothing is requested)
setup; home_listing
out="$(render "tab=restore&repo=offsite&snapshot=$SNAP&path=/home")"
flat="$(tr '\n' ' ' <<<"$out")"
if clean "$out" && [ "$(queued)" = 0 ] && grep -q 'name="paths\[\]" value="/home/alice"' <<<"$out" \
    && grep -q 'name="paths\[\]" value="/home/zeta.txt"' <<<"$out" && ! grep -q 'name="paths\[\]" value="/home"' <<<"$out" \
    && grep -q "snapshot=$SNAP&amp;path=%2Fhome%2Falice" <<<"$out" && grep -q "2.0 KiB" <<<"$out" \
    && grep -q 'value="/home/alice".*value="/home/zeta.txt"' <<<"$flat" \
    && grep -q "&lt;b&gt;x&lt;/b&gt;.txt" <<<"$out" && ! grep -q "<b>x</b>" <<<"$out"; then
    pass browse_cached; else fail browse_cached "$(grep -E "Warning|Notice|Fatal" <<<"$out" | head -3)"; fi

# --- browse_short_id (the short id from the status page works too)
out="$(render "tab=restore&repo=offsite&snapshot=bbbb2222&path=/home")"
if clean "$out" && [ "$(queued)" = 0 ] && grep -q 'value="/home/alice"' <<<"$out"; then pass browse_short_id; else fail browse_short_id; fi

# --- browse_queues_listing (asked once, however often the page is reloaded)
setup
out="$(render "tab=restore&repo=offsite&snapshot=$SNAP&path=/home/alice/")"
req="$(request)"
render "tab=restore&repo=offsite&snapshot=$SNAP&path=/home/alice" >/dev/null
n1="$(queued)"
id="$(basename "$(ls "$S"/queue/*.job)" .job)"
mkdir -p "$S/jobs/$id"; mv "$S/queue/$id.job" "$S/jobs/$id/request"
printf 'state=running\naction=ls\nrepo=offsite\nmessage=\ntarget=\nstarted=%s\nfinished=\npid=1\n' "$(date +%s)" >"$S/jobs/$id/status"
out2="$(render "tab=restore&repo=offsite&snapshot=$SNAP&path=/home/alice")"
n2="$(queued)"
printf 'state=failed\naction=ls\nrepo=offsite\nmessage=there is no such folder in this backup\ntarget=\nstarted=%s\nfinished=%s\npid=1\n' "$(date +%s)" "$(date +%s)" >"$S/jobs/$id/status"
out3="$(render "tab=restore&repo=offsite&snapshot=$SNAP&path=/home/alice")"
if clean "$out$out2$out3" && [ "$req" = "$(printf 'action=ls\nrepo=offsite\nsnapshot=%s\npath=/home/alice' "$SNAP")" ] \
    && [ "$n1" = 1 ] && [ "$n2" = 0 ] && [ "$(queued)" = 0 ] && grep -q "Reading the backup" <<<"$out" \
    && grep -q "Reading the backup" <<<"$out2" && grep -q "there is no such folder in this backup" <<<"$out3"; then
    pass browse_queues_listing; else fail browse_queues_listing "n1=$n1 n2=$n2 n3=$(queued) $(tr '\n' '|' <<<"$req")"; fi

# --- browse_rejects_bad_input
setup
out="$(render "tab=restore&repo=offsite&snapshot=ffff999900&path=/home")"
out2="$(render "tab=restore&repo=offsite&snapshot=$SNAP&path=home")"
out3="$(render "tab=restore&repo=offsite&snapshot=$SNAP&path=/home%0Aaction=settings")"
out4="$(render "tab=restore&repo=nope&snapshot=$SNAP&path=/home")"
out5="$(render "tab=restore&repo=offsite&snapshot=$SNAP&path=/home/../etc")"
out6="$(render "tab=restore&repo=offsite&snapshot[]=x&path[]=y")"
if clean "$out$out2$out3$out4$out5$out6" && [ "$(queued)" = 0 ] && grep -q "Unknown backup" <<<"$out" \
    && grep -q "not a valid folder" <<<"$out2" && grep -q "not a valid folder" <<<"$out3" && grep -q "Unknown repository" <<<"$out4"; then
    pass browse_rejects_bad_input; else fail browse_rejects_bad_input "queued=$(queued)"; fi

# --- restore_post
setup; home_listing
out="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$SNAP&paths[]=/home/alice&paths[]=/home/we+ird+%2Aname.txt")"
if clean "$out" && grep -q "Restore requested" <<<"$out" && grep -q "/home/restic-restore" <<<"$out" \
    && [ "$(request)" = "$(printf 'action=restore\nrepo=offsite\nsnapshot=%s\npath=/home/alice\npath=/home/we ird *name.txt' "$SNAP")" ]; then
    pass restore_post; else fail restore_post "$(request | tr '\n' '|')"; fi

# --- restore_post_rejects (nothing chosen, bad paths, unknown backup or repository, too many)
setup
many="$("$PHP" -r 'for ($i = 0; $i < 501; $i++) echo "&paths[]=/home/f$i";')"
out="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$SNAP")"
out2="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$SNAP&paths[]=home/alice")"
out3="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$SNAP&paths[]=/home/a%0Apath=/")"
out4="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=ffff999900&paths[]=/home")"
out5="$(post "tab=restore" "rb_action=restore&repo=nope&snapshot=$SNAP&paths[]=/home")"
out6="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$SNAP$many")"
out7="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$SNAP&paths=/home")"
out8="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$SNAP&paths[][]=/home")"
if clean "$out$out2$out3$out4$out5$out6$out7$out8" && [ "$(queued)" = 0 ] && grep -q "Nothing was chosen" <<<"$out" && grep -q "500" <<<"$out6"; then
    pass restore_post_rejects; else fail restore_post_rejects "queued=$(queued)"; fi

# --- settings_form (current values and defaults; secrets and hand-only settings are not editable)
setup
out="$(render tab=settings)"
if clean "$out" && grep -q 'name="config\[KEEP_DAILY\]" value="7"' <<<"$out" && grep -q 'name="config\[MAILTO\]" value="test@example.org"' <<<"$out" \
    && grep -q 'name="config\[RESTORE_DIR\]" value="/home/restic-restore"' <<<"$out" \
    && grep -q 'name="repo\[offsite\]\[SCHEDULE\]" value="\*-\*-\* 03:00:00"' <<<"$out" \
    && grep -q 'name="repo\[local\]\[REPOSITORY\]" value="/backup/restic"' <<<"$out" && grep -q 'name="repo\[local\]\[LATE_DAYS\]" value="8"' <<<"$out" \
    && grep -q "# what to back up" <<<"$out" && grep -q "/usr/local/bin/mailer --quiet" <<<"$out" && ! grep -q 'name="config\[MAIL_CMD\]"' <<<"$out" \
    && grep -q "10-mysql-dump.sh" <<<"$out" && grep -q "offsite.env" <<<"$out" && grep -q 'name="new_repo\[name\]"' <<<"$out"; then
    pass settings_form; else fail settings_form "$(grep -E "Warning|Notice|Fatal" <<<"$out" | head -3)"; fi

# --- secrets_never_shown (the repository password and back-end keys stay on the server)
ok=1
for tab in status restore settings jobs; do
    grep -q -E "pass-s3cret|env-s3cret" <<<"$(render "tab=$tab")" && ok=0
done
if [ $ok = 1 ]; then pass secrets_never_shown; else fail secrets_never_shown; fi

# --- settings_unchanged (saving an untouched form asks for nothing)
setup
out="$(post "tab=settings" "$FORM")"
if clean "$out" && [ "$(queued)" = 0 ] && grep -q "Nothing was changed" <<<"$out"; then pass settings_unchanged; else fail settings_unchanged "$(request | tr '\n' '|')"; fi

# --- settings_post (only what was edited is sent)
setup
out="$(post "tab=settings" "$FORM&config[KEEP_DAILY]=3&repo[offsite][SCHEDULE]=*-*-*+02:30:00&config[MAIL_CMD]=evil")"
if clean "$out" && grep -q "Settings sent" <<<"$out" \
    && [ "$(request)" = "$(printf 'action=settings\nconfig.KEEP_DAILY=3\nrepo.offsite.SCHEDULE=*-*-* 02:30:00')" ]; then
    pass settings_post; else fail settings_post "$(request | tr '\n' '|')"; fi

# --- settings_post_lists (an edited list is sent whole, comments included; the other list is left alone)
setup
out="$(post "tab=settings" "$FORM&include=%23+what+to+back+up%0D%0A/home%0D%0A%0D%0A/srv%0D%0A")"
want="$(printf 'action=settings\ninclude.set=1\ninclude=# what to back up\ninclude=/home\ninclude=/srv')"
if clean "$out" && [ "$(request)" = "$want" ]; then pass settings_post_lists; else fail settings_post_lists "$(request | tr '\n' '|')"; fi

# --- settings_post_repos (add one repository, remove another)
setup
out="$(post "tab=settings" "$FORM&new_repo[name]=third&new_repo[REPOSITORY]=s3:s3.example.com/bucket&new_repo[SCHEDULE]=*-*-*+04:00:00&new_repo[LATE_DAYS]=3&repo_delete[local]=1&repo[local][LATE_DAYS]=9")"
want="$(printf 'action=settings\nrepo.local.delete=1\nrepo.third.REPOSITORY=s3:s3.example.com/bucket\nrepo.third.SCHEDULE=*-*-* 04:00:00\nrepo.third.LATE_DAYS=3')"
if clean "$out" && [ "$(request)" = "$want" ]; then pass settings_post_repos; else fail settings_post_repos "$(request | tr '\n' '|')"; fi

# --- settings_post_rejects (line breaks, bad names, a new repository without an address)
setup
out="$(post "tab=settings" "$FORM&config[MAILTO]=a@b.c%0Aconfig.MAIL_CMD=touch+/tmp/x")"
out2="$(post "tab=settings" "$FORM&new_repo[name]=Bad+Name&new_repo[REPOSITORY]=/x")"
out3="$(post "tab=settings" "$FORM&new_repo[name]=a.b=c&new_repo[REPOSITORY]=/x")"
out4="$(post "tab=settings" "$FORM&new_repo[name]=offsite&new_repo[REPOSITORY]=/x")"
out5="$(post "tab=settings" "$FORM&new_repo[name]=third")"
out6="$(post "tab=settings" "$FORM&config[KEEP_DAILY][]=3&repo[offsite]=x&include[]=y")"
out7="$(post "tab=settings" "$FORM&repo_delete[nope]=1&repo[nope][REPOSITORY]=/x")"
if clean "$out$out2$out3$out4$out5$out6$out7" && [ "$(queued)" = 0 ] && grep -q "line break" <<<"$out" && grep -q "lowercase" <<<"$out2" \
    && grep -q "already" <<<"$out4" && grep -q "address" <<<"$out5"; then
    pass settings_post_rejects; else fail settings_post_rejects "queued=$(queued) $(request | tr '\n' '|')"; fi

# answer_jobs <state> <message> — stand in for the root helper: every request
# in the queue gets this result. Runs until killed.
answer_jobs() {
    local f id
    for _ in $(seq 100); do
        for f in "$S"/queue/*.job; do
            [ -e "$f" ] || continue
            id="$(basename "$f" .job)"; mkdir -p "$S/jobs/$id"; mv "$f" "$S/jobs/$id/request"
            printf 'state=%s\naction=settings\nrepo=\nmessage=%s\ntarget=\nstarted=1\nfinished=2\npid=1\n' "$1" "$2" >"$S/jobs/$id/status"
        done
        sleep 0.1
    done
}

# --- settings_result_shown (the page waits for the helper's verdict and shows it)
setup
answer_jobs failed 'nothing was changed: KEEP_DAILY: "x<y" is not valid (a whole number)' &
helper=$!
out="$(CWP_RESTIC_WAIT=8 post "tab=settings" "$FORM&config[KEEP_DAILY]=x%3Cy")"
kill $helper 2>/dev/null; wait $helper 2>/dev/null
if clean "$out" && grep -q "nothing was changed: KEEP_DAILY" <<<"$out" && grep -q "alert-danger" <<<"$out" && ! grep -q "x<y" <<<"$out" \
    && grep -q 'name="config\[KEEP_DAILY\]" value="x&lt;y"' <<<"$out"; then
    pass settings_result_shown; else fail settings_result_shown "$(grep -o 'alert-[a-z]*">[^<]*' <<<"$out" | head -3)"; fi

# --- settings_saved_timers_failed (a failure after saving is not reported as "not saved")
setup
answer_jobs failed 'the settings were saved, but the timers could not be updated: boom' &
helper=$!
out="$(CWP_RESTIC_WAIT=8 post "tab=settings" "$FORM&config[KEEP_DAILY]=9")"
kill $helper 2>/dev/null; wait $helper 2>/dev/null
if clean "$out" && grep -q "the settings were saved, but the timers could not be updated: boom" <<<"$out" \
    && grep -q "alert-danger" <<<"$out" && ! grep -q -i "not saved" <<<"$out"; then
    pass settings_saved_timers_failed; else fail settings_saved_timers_failed "$(grep -o 'alert-[a-z]*">[^<]*' <<<"$out" | head -3)"; fi

# --- jobs_tab (waiting, running with progress, finished and failed requests, newest first)
setup
mkjob 20261124-100000-aaaaaa done restore "12 items, 3.4 MiB restored" /home/restic-restore/20261124-100000-aaaaaa
mkjob 20261124-110000-bbbbbb failed backup "cannot open repository (restic exit 1)"
mkjob 20261124-120000-cccccc running restore "copying 900 items, 2.0 GiB" /home/restic-restore/20261124-120000-cccccc
printf '{"message_type":"status","percent_done":0.12}\n{"message_type":"status","seconds_elapsed":9,"percent_done":0.5312,"total_files":900}\n' >"$S/jobs/20261124-120000-cccccc/output"
printf 'action=backup\nrepo=offsite\n' >"$S/queue/20261124-130000-dddddd.job"
out="$(render tab=jobs)"
order="$(grep -o -E "20261124-1[0-3]0000" <<<"$out" | uniq | tr '\n' ' ')"
if clean "$out" && grep -q "12 items, 3.4 MiB restored" <<<"$out" && grep -q "/home/restic-restore/20261124-100000-aaaaaa" <<<"$out" \
    && grep -q "cannot open repository" <<<"$out" && grep -q "53%" <<<"$out" && grep -q -i "waiting" <<<"$out" \
    && [ "${order%% *}" = 20261124-130000 ] && grep -q "label-danger" <<<"$out" && grep -q "label-success" <<<"$out"; then
    pass jobs_tab; else fail jobs_tab "$order"; fi

# --- status_shows_running (a backup in progress is visible on the first page)
out="$(render)"
if clean "$out" && grep -q "tab=jobs" <<<"$out" && grep -q -i "in progress" <<<"$out"; then pass status_shows_running; else fail status_shows_running; fi

# --- escapes_html (names, settings, log lines and messages are shown as text, never as markup)
setup; home_listing
echo "[$(snapshot 7200 bbbb2222 '/home/<script>alert(1)</script>')]" >"$S/snapshots-offsite.json"
echo 'HOST_LABEL=<img src=x onerror=alert(2)>' >>"$C/config"
echo 'REPOSITORY=<script>alert(5)</script>' >>"$C/repos/local.conf"
echo '2026-11-24 <script>alert(3)</script>' >>"$T/log"
mkjob 20261124-100000-aaaaaa failed backup "<script>alert(4)</script>" "<script>alert(6)</script>"
all=""
for q in "" "tab=restore" "tab=restore&repo=offsite&snapshot=$SNAP&path=/home" "tab=settings" "tab=jobs" \
    "tab=restore&repo=%3Cscript%3Ealert(7)%3C/script%3E&snapshot=%3Cscript%3Ealert(7)%3C/script%3E&path=/%3Cscript%3Ealert(7)%3C/script%3E"; do
    all="$all$(render "$q")"
done
if clean "$all" && ! grep -q -E "<script>alert|<img src=x" <<<"$all" && grep -q "&lt;script&gt;alert(1)" <<<"$all" \
    && grep -q "&lt;script&gt;alert(3)" <<<"$all" && grep -q "&lt;script&gt;alert(4)" <<<"$all"; then pass escapes_html; else fail escapes_html "$(grep -o -E ".{30}<script>alert.{12}" <<<"$all" | head -3)"; fi

[ $FAILS = 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
exit $FAILS
