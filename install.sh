#!/bin/bash
# Install or update cwp-restic on this server. Run as root from a checkout:
#   ./install.sh
# Safe to rerun: the program and the admin page are replaced, while settings,
# passwords and repositories that are already there are left alone.
# Test: tests/install.sh (in a throwaway container).
set -eu
cd "$(dirname "$0")"
RESTIC_VERSION="${RESTIC_VERSION:-0.19.1}"   # installed when the server has no restic
RESTIC_MIN=0.17.0                            # older ones lack what cwp-restic uses
CONF=/etc/cwp-restic
SHARE=/usr/local/share/cwp-restic
CWP_ADMIN=/usr/local/cwpsrv/htdocs/resources/admin

[ "$(id -u)" = 0 ] || { echo "install.sh must be run as root" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "cwp-restic needs systemd (systemctl was not found)" >&2; exit 1; }

have="$(/usr/local/bin/restic version 2>/dev/null | awk '{print $2}')" || true
if [ -z "$have" ]; then
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) echo "no restic download for $(uname -m); put restic $RESTIC_MIN or later in /usr/local/bin and run this again" >&2; exit 1 ;;
    esac
    for tool in curl bunzip2 sha256sum; do
        command -v "$tool" >/dev/null || { echo "$tool is needed to download restic; install it and run this again" >&2; exit 1; }
    done
    W="$(mktemp -d)"
    f="restic_${RESTIC_VERSION}_linux_${arch}.bz2"
    base="https://github.com/restic/restic/releases/download/v$RESTIC_VERSION"
    echo "downloading restic $RESTIC_VERSION"
    curl -fsSL -o "$W/$f" "$base/$f"
    curl -fsSL -o "$W/SHA256SUMS" "$base/SHA256SUMS"
    (cd "$W" && grep " $f\$" SHA256SUMS | sha256sum -c - >/dev/null)
    bunzip2 "$W/$f"
    install -m 755 "$W/${f%.bz2}" /usr/local/bin/restic
    rm -rf "$W"
elif [ "$(printf '%s\n' "$RESTIC_MIN" "$have" | sort -V | head -n 1)" != "$RESTIC_MIN" ]; then
    echo "/usr/local/bin/restic is version $have, and cwp-restic needs $RESTIC_MIN or later." >&2
    echo "Update it (restic self-update) and run this again. Nothing was installed." >&2
    exit 1
fi

install -m 755 bin/cwp-restic /usr/local/sbin/cwp-restic
rm -rf "$SHARE/examples"
install -d -m 755 "$SHARE"
cp -R examples "$SHARE/examples"

# Settings are only ever created, never replaced.
first=0; [ -e "$CONF/config" ] || first=1
install -d -m 700 "$CONF" "$CONF/repos" "$CONF/pre.d" /var/lib/cwp-restic
for file in config include exclude; do
    [ -e "$CONF/$file" ] || install -m 600 "examples/$file" "$CONF/$file"
done
new_password=0
if [ ! -e "$CONF/password" ]; then
    (umask 077; head -c 36 /dev/urandom | base64 >"$CONF/password")
    new_password=1
fi
# A backup of a web server without its databases is a trap, so a server with
# MySQL or MariaDB starts out with the dump script. Removing it is respected.
if [ $first = 1 ] && { command -v mariadb-dump >/dev/null || command -v mysqldump >/dev/null; }; then
    install -m 700 examples/pre.d/10-mysql-dump.sh "$CONF/pre.d/10-mysql-dump.sh"
fi

cat >/etc/logrotate.d/cwp-restic <<'EOF'
/var/log/cwp-restic.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
}
EOF

# The admin page, where there is a CWP. Third-party menu lines live in
# 3rdparty.php, which CWP updates leave alone.
page=""
if [ -d "$CWP_ADMIN/modules" ]; then
    install -m 640 panel/restic_backups.php "$CWP_ADMIN/modules/restic_backups.php"
    menu="$CWP_ADMIN/include/3rdparty.php"
    if ! grep -q 'module=restic_backups' "$menu" 2>/dev/null; then
        [ -f "$menu" ] || install -m 640 /dev/null "$menu"
        { if [ -n "$(tail -c1 "$menu")" ]; then echo; fi; cat panel/menu.html; } >>"$menu"
    fi
    page="index.php?module=restic_backups"
fi

applied=1
/usr/local/sbin/cwp-restic apply || applied=0

echo
echo "cwp-restic is installed ($(/usr/local/bin/restic version | cut -d' ' -f1-2))."
echo "  Settings:    $CONF"
echo "  Examples:    $SHARE/examples"
if [ -n "$page" ]; then
    echo "  Admin page:  Restic Backups in the CWP admin menu ($page)"
else
    echo "  Admin page:  not installed, there is no CWP on this server"
fi
if [ $new_password = 1 ]; then
    echo
    echo "A new repository password was written to $CONF/password."
    echo "KEEP A COPY OF IT SOMEWHERE ELSE, for example in a password manager."
    echo "Without it the backups cannot be read, and this file is lost with the server."
fi
if [ $applied = 0 ]; then
    echo
    echo "The settings in $CONF need attention (see above), so the timers were not"
    echo "updated. Correct them, then run: cwp-restic apply"
elif [ -z "$(ls "$CONF/repos" 2>/dev/null | grep '\.conf$')" ]; then
    echo
    echo "Next: say where the backups go. Add a repository on the admin page under"
    echo "Settings, or copy one of $SHARE/examples/repos/*.conf to"
    echo "$CONF/repos/<name>.conf and run: cwp-restic apply"
fi
