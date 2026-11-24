#!/bin/bash
# End-to-end test: the admin page and bin/cwp-restic working together against
# real restic repositories. The page leaves requests in the queue; a background
# loop stands in for the systemd path unit and lets cwp-restic carry them out.
# Needs Linux with php, restic and GNU tools:
#   tests/e2e.sh
set -u
cd "$(dirname "$0")/.."
BIN="$(readlink -f bin/cwp-restic)"
PAGE="$(readlink -f panel/restic_backups.php)"
PHP="${PHP:-php}"
REAL_RESTIC="$(command -v "${RESTIC:-restic}")" || { echo "restic not found"; exit 1; }
command -v "$PHP" >/dev/null || { echo "php not found"; exit 1; }

T="$(mktemp -d /tmp/crb-e2e.XXXXXX)"
C="$T/conf"; S="$T/state"
unset HOME XDG_CACHE_HOME
export CWP_RESTIC_CONF_DIR="$C" CWP_RESTIC_STATE_DIR="$S" CWP_RESTIC_LOG="$T/log" \
    CWP_RESTIC_LOCK_DIR="$T/run" CWP_RESTIC_CACHE_DIR="$T/cache" CWP_RESTIC_UNIT_DIR="$T/units" \
    CWP_RESTIC_INLINE_JOBS=1 CWP_RESTIC_WAIT=0 RESTIC="$REAL_RESTIC" SYSTEMCTL="$T/systemctl"
FAILS=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ${2:-}"; FAILS=$((FAILS + 1)); }

mkdir -p "$C/repos" "$T"/{run,units,src/site/sub}
echo "hello" >"$T/src/site/index.php"
echo "odd" >"$T/src/site/we[i]rd *name.txt"
head -c 200000 /dev/urandom >"$T/src/site/sub/photo.jpg"
cat >"$C/config" <<EOF
HOST_LABEL=e2e
MAILTO=test@example.org
MAIL_CMD=tee -a $T/mail
RESTORE_DIR=$T/restores
RESTORE_MIN_FREE_GB=0
EOF
echo "REPOSITORY=$T/repo-off" >"$C/repos/offsite.conf"
echo "REPOSITORY=$T/repo-local" >"$C/repos/local.conf"
echo "$T/src" >"$C/include"
echo "*.tmp" >"$C/exclude"
echo "test-password" >"$C/password"
: >"$T/mail"
printf '#!/bin/bash\necho "$*" >>%s\n' "$T/calls" >"$T/systemctl"; chmod +x "$T/systemctl"

(
    while :; do
        if compgen -G "$S/queue/*.job" >/dev/null; then "$BIN" jobs >/dev/null 2>&1; fi
        sleep 0.2
    done
) &
HELPER=$!
trap 'kill $HELPER 2>/dev/null; rm -rf "$T"' EXIT

# render [query] [post body] — the page as the panel includes it.
render() {
    "$PHP" -d display_errors=1 -d error_reporting=-1 -r '
        $include_path = "x";
        parse_str($argv[2], $_GET); parse_str($argv[3], $_POST);
        $_SERVER["REQUEST_METHOD"] = $argv[3] === "" ? "GET" : "POST";
        include $argv[1];' -- "$PAGE" "${1:-}" "${2:-}" 2>&1
}
clean() { ! grep -q -E "Warning:|Notice:|Deprecated:|Fatal error|Parse error" <<<"$1"; }
row() { tr '\n' ' ' <<<"$1" | grep -o "<tr><th>$2</th>.*</tr>" | sed 's|</tr>.*||'; }
token() { grep -o 'name="rb_token" value="[a-f0-9]*"' <<<"$1" | head -1 | sed 's/.*value="//; s/"//'; }
post() { render "$1" "$2&rb_token=$(token "$(render)")"; }
snapshots() { "$BIN" restic "$1" snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l; }
alerts() { grep -o 'alert-[a-z]*">[^<]*' <<<"$1" | head -3 | tr '\n' '|'; }

# settle — wait until everything the page asked for has been carried out.
settle() {
    local d busy
    for _ in $(seq 300); do
        busy=0
        compgen -G "$S/queue/*.job" >/dev/null && busy=1
        for d in "$S"/jobs/*/; do
            [ -d "$d" ] || continue
            grep -q -E '^state=(done|failed|skipped)$' "$d/status" 2>/dev/null || busy=1
        done
        [ $busy = 0 ] && return 0
        sleep 0.2
    done
    return 1
}

# --- status_after_backup (a backup made by the timer shows on the first page)
"$BIN" backup offsite >/dev/null 2>&1; rc=$?
snap="$(grep -o '"short_id":"[a-f0-9]*"' "$S/snapshots-offsite.json" 2>/dev/null | tail -n 1 | cut -d'"' -f4)"
out="$(render)"
if [ $rc = 0 ] && [ -n "$snap" ] && clean "$out" && grep -q "label-success" <<<"$(row "$out" offsite)" && grep -q "$snap" <<<"$out" \
    && grep -q -i "no backup yet" <<<"$(row "$out" local)"; then
    pass status_after_backup; else fail status_after_backup "rc=$rc snap=$snap"; fi

# --- backup_now (the button on the page ends in a real snapshot)
out="$(post "" "rb_action=backup&repo=local")"
settle
jobs="$(render tab=jobs)"
if clean "$out$jobs" && grep -q "alert-success" <<<"$out" && [ "$(snapshots local)" = 1 ] && grep -q "backup finished" <<<"$jobs" \
    && grep -q "label-success" <<<"$(row "$(render)" local)"; then
    pass backup_now; else fail backup_now "snapshots=$(snapshots local) $(alerts "$out")"; fi

# --- browse (opening a folder waits for the listing and shows what is in it)
out="$(CWP_RESTIC_WAIT=30 render "tab=restore&repo=offsite&snapshot=$snap&path=$T/src/site")"
if clean "$out" && grep -q "index.php" <<<"$out" && grep -q -F 'we[i]rd *name.txt' <<<"$out" && grep -q ">sub/</a>" <<<"$out" \
    && grep -q 'name="paths\[\]"' <<<"$out"; then
    pass browse; else fail browse "$(alerts "$out")"; fi

# --- browse_again_uses_cache (the second visit asks for nothing new)
before="$(ls "$S/jobs" | wc -l)"
out="$(render "tab=restore&repo=offsite&snapshot=$snap&path=$T/src/site")"
if clean "$out" && grep -q "index.php" <<<"$out" && [ "$(ls "$S/jobs" | wc -l)" = "$before" ] && [ -z "$(ls "$S/queue")" ]; then
    pass browse_again_uses_cache; else fail browse_again_uses_cache; fi

# --- browse_missing_folder (a folder that is not in the backup is said so)
out="$(CWP_RESTIC_WAIT=30 render "tab=restore&repo=offsite&snapshot=$snap&path=/no/such/folder")"
if clean "$out" && grep -q "there is no such folder in this backup" <<<"$out"; then
    pass browse_missing_folder; else fail browse_missing_folder "$(alerts "$out")"; fi

# --- restore (ticked items are copied to a new folder; nothing live is touched)
echo "changed since the backup" >"$T/src/site/index.php"
out="$(post "tab=restore" "rb_action=restore&repo=offsite&snapshot=$snap&paths[]=$T/src/site/we%5Bi%5Drd+%2Aname.txt&paths[]=$T/src/site/sub")"
R="$(grep -o "$T/restores/[0-9]*-[0-9]*-[a-f0-9]*" <<<"$out" | head -1)"
settle
jobs="$(render tab=jobs)"
if clean "$out$jobs" && [ -n "$R" ] && [ "$(cat "$R$T/src/site/we[i]rd *name.txt" 2>/dev/null)" = odd ] \
    && cmp -s "$R$T/src/site/sub/photo.jpg" "$T/src/site/sub/photo.jpg" && [ ! -e "$R$T/src/site/index.php" ] \
    && [ "$(cat "$T/src/site/index.php")" = "changed since the backup" ] \
    && grep -q "restored" <<<"$jobs" && grep -q "$R" <<<"$jobs" && grep -q "^Subject:.*restore" "$T/mail"; then
    pass restore; else fail restore "target=$R $(alerts "$out") $(sed -n 's/^message=//p' "$S"/jobs/*/status | tail -n 1)"; fi

# --- settings_saved (an edit on the page lands in the files and the timers follow)
out="$(CWP_RESTIC_WAIT=30 post "tab=settings" "rb_action=settings&config[KEEP_DAILY]=9&repo[offsite][SCHEDULE]=*-*-*+03:00:00&new_repo[name]=third&new_repo[REPOSITORY]=$T/repo-third")"
if clean "$out" && grep -q "alert-success" <<<"$out" && grep -q "^KEEP_DAILY=9$" "$C/config" \
    && grep -q "^OnCalendar=\*-\*-\* 03:00:00$" "$T/units/cwp-restic-backup-offsite.timer" 2>/dev/null \
    && grep -q "^REPOSITORY=$T/repo-third$" "$C/repos/third.conf" 2>/dev/null \
    && grep -q 'name="config\[KEEP_DAILY\]" value="9"' <<<"$out" && grep -q "daemon-reload" "$T/calls"; then
    pass settings_saved; else fail settings_saved "$(alerts "$out")"; fi

# --- settings_rejected (one bad value: nothing changes, and the page says why)
sum="$(cat "$C/config" "$C"/repos/*.conf | sha1sum)"
out="$(CWP_RESTIC_WAIT=30 post "tab=settings" "rb_action=settings&config[KEEP_DAILY]=many&config[KEEP_WEEKLY]=2")"
if clean "$out" && grep -q "alert-danger" <<<"$out" && grep -q "nothing was changed: KEEP_DAILY" <<<"$out" \
    && [ "$(cat "$C/config" "$C"/repos/*.conf | sha1sum)" = "$sum" ]; then
    pass settings_rejected; else fail settings_rejected "$(alerts "$out")"; fi

# --- repo_removed (removing a repository drops its settings and timer, never its backups)
out="$(CWP_RESTIC_WAIT=30 post "tab=settings" "rb_action=settings&repo_delete[offsite]=1")"
if clean "$out" && grep -q "alert-success" <<<"$out" && [ ! -e "$C/repos/offsite.conf" ] \
    && [ ! -e "$T/units/cwp-restic-backup-offsite.timer" ] && [ -f "$T/repo-off/config" ] \
    && [ -f "$C/.previous/repos/offsite.conf" ]; then
    pass repo_removed; else fail repo_removed "$(alerts "$out")"; fi

if [ $FAILS = 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; exit 1; fi
