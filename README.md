# cwp-restic

[restic](https://restic.net) backups for a [CWP](https://control-webpanel.com) (Control Web Panel) server, with a page in the CWP admin panel to watch the backups, look inside them, restore files from them, and change the settings.

There are two parts:

- **`cwp-restic`**, one bash program. systemd timers run it to back up, remove old backups, and verify the repositories.
- **Restic Backups**, one PHP file that adds a page to the CWP admin panel.

The page never runs a command. It reads files that `cwp-restic` leaves behind, and when you ask for something it writes a small request file; `cwp-restic` checks the request and does the work. [docs/DESIGN.md](docs/DESIGN.md) explains why and how.

## Status

This is an early version. The test suite covers the program against real restic repositories, the page under PHP 7.2 and 8.3, both together, and the installer in an AlmaLinux 9 container. It has not been run on a live CWP server yet, so try it on a test server first and do a trial restore before you rely on it.

## What it does

- Backs up a list of folders to one or more restic repositories, each on its own schedule. A repository can be anything restic can reach: another machine over SSH, a second disk, S3, B2, a REST server, rclone.
- Runs your scripts before each backup, for example to dump the databases.
- Removes old backups (so many daily, weekly, and monthly ones are kept) and reads part of each repository back every month to verify it.
- Can keep to a time window, so an office line stays free during the day.
- Sends mail when something fails.
- In the CWP admin panel:
  - **Status**: every repository with its last backup, size, schedule, and whether it is OK, late, or failed; a "Back up now" button; the recent log.
  - **Restore**: open any backup, walk through its folders, tick files and folders, and have them copied to a separate folder on the server.
  - **Settings**: schedules, retention, mail address, the lists of what to back up and leave out, and the repositories.
  - **Requests**: what was asked for from the page and how it went, with progress for running restores.

## What it does not do

- It does not restore over live files. Restored copies go to a new folder (by default under `/home/restic-restore`); you look at them and move them into place yourself.
- It does not load database dumps back or rebuild a whole CWP account.
- It adds nothing to the CWP user panel. Only the server admin sees it.
- The repository password and storage keys cannot be seen or changed from the page. They are files on the server.
- All repositories get the same list of folders.

## Requirements

- A server with systemd and root access. The page needs CWP; without CWP the program and timers still work.
- bash, GNU coreutils, and util-linux, as on AlmaLinux, Rocky Linux, or CentOS (tested with bash 5.0 to 5.2).
- restic 0.17 or later in `/usr/local/bin`. The installer downloads restic 0.19.1 from the restic releases, and checks it against the published checksum, when the server has none.

## Install

On the server, as root:

```
git clone https://github.com/Equip-Mozambique/cwp-restic.git
cd cwp-restic
./install.sh
```

The installer:

- puts the program in `/usr/local/sbin/cwp-restic` and the examples in `/usr/local/share/cwp-restic/examples`;
- creates `/etc/cwp-restic` with sample settings and a new repository password, if they are not there yet;
- on a first install, when the server has MySQL or MariaDB, adds the script that dumps the databases before each backup;
- adds the page to the CWP admin panel (the module file plus one menu line in `include/3rdparty.php`);
- sets up log rotation and the systemd timers.

Run it again to update. It replaces the program and the page and leaves your settings, passwords, and repositories alone.

Then:

1. **Store the password somewhere else.** `/etc/cwp-restic/password` is the key to every backup. Without it the backups cannot be read, and the file is lost together with the server. Put a copy in a password manager now.
2. **Add a repository**, on the Settings tab or by copying one of the [examples](examples/repos) to `/etc/cwp-restic/repos/<name>.conf` and running `cwp-restic apply`.
3. **Make the first backup**: `cwp-restic backup <name>`, or "Back up now" on the page. The repository is created on the first run.
4. **Try a restore** from the Restore tab, so you know it works before you need it.

## Settings

Everything is in `/etc/cwp-restic`. The files are plain text and are never run as code. After changing them by hand, run `cwp-restic apply`; it checks every value and makes the timers match.

| File | What it holds |
| --- | --- |
| `config` | General settings, as `KEY=value` lines |
| `repos/<name>.conf` | One repository; the file name is its name (lowercase letters, digits, dashes) |
| `repos/<name>.env` | Optional: environment for restic for that repository, such as storage keys |
| `repos/<name>.password` | Optional: a password for that repository alone |
| `password` | The repository password for every repository without its own |
| `include` | What is backed up: one full path per line, `*` and `?` allowed, missing paths skipped |
| `exclude` | What is left out, as restic exclude patterns |
| `pre.d/` | Executable scripts run before every backup, in name order |

`config`:

| Key | Meaning | Default |
| --- | --- | --- |
| `HOST_LABEL` | Name of this server in the backups and in mail | short host name |
| `MAILTO` | Who is told about failures and finished restores; empty = no mail | empty |
| `WINDOW` | `HH:MM-HH:MM`: scheduled work and "Back up now" only run in these hours; a backup still running at the end stops and continues next time | any time |
| `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` | How many backups are kept | 7, 5, 12 |
| `PRUNE_AT` | When old backups are removed (systemd calendar time); empty = never | empty |
| `CHECK_AT` | When the repositories are verified; empty = never | empty |
| `RESTORE_DIR` | Where restored copies go | `/home/restic-restore` |
| `RESTORE_KEEP_DAYS` | Restored copies are removed after this many days; 0 = never | 7 |
| `RESTORE_MIN_FREE_GB` | A restore is refused when it would leave less free space than this | 5 |
| `CHECK_SUBSET` | How much stored data each verification reads back (file only) | `5%` |
| `MAIL_CMD` | The command mail is piped to (file only) | `/usr/sbin/sendmail -t` |

The sample `config` sets `PRUNE_AT` to Saturday 06:00 and `CHECK_AT` to the first of the month, 07:00.

`repos/<name>.conf`:

| Key | Meaning | Default |
| --- | --- | --- |
| `REPOSITORY` | The restic repository address, handed to restic as it is | required |
| `SCHEDULE` | When the backup runs (systemd calendar time, such as `*-*-* 03:00:00`); empty = only on request | empty |
| `MOUNT` | The disk a local repository is on; when it is not mounted, the backup is refused | none |
| `LIMIT_UPLOAD_KB` | Upload limit in KiB/s | none |
| `LATE_DAYS` | The page shows "Late" when the newest backup is older than this; 0 = never | 2 |

Times are server time. A run that was missed because the server was off is not caught up; the next one runs at its normal time.

## Restoring

**From the page.** Open the Restore tab, pick a backup, walk to the folder, tick what you want, and press "Restore what is ticked". The copies appear under `/home/restic-restore/<request id>/` with their full original path, owner, and permissions. Nothing live is touched. Check them, then move them into place. The folder is removed after `RESTORE_KEEP_DAYS` days. Restores are refused when the disk would get too full.

**From the shell.** `cwp-restic restic <name> ...` runs restic with the repository and password of that repository filled in:

```
cwp-restic status
cwp-restic restic offsite snapshots
cwp-restic restic offsite restore latest --target /home/restic-restore/manual --include /home/alice/public_html
cwp-restic restic offsite mount /mnt/restic
```

**A database.** With the dump script in place, each database is a file in the backup: restore `/var/backups/cwp-restic/mysql/<database>.sql.gz`, then load it with `gunzip < <database>.sql.gz | mysql <database>`.

**The whole server is gone.** You need three things that must exist outside the server: the repository address, the repository password, and whatever gives access to the storage (SSH key, storage keys). With those, any machine with restic can read the backups: `restic -r <address> snapshots`.

## Making it your own

The defaults fit a CWP server. Everything specific is a file you can change or add:

- **Where backups go**: one small file per repository in `repos/`. Add as many as you want; each gets its own schedule and its own timer. The [examples](examples/repos) cover SSH, a local disk, and S3; the S3 one shows how any other storage works.
- **What is backed up**: `include` and `exclude`, by hand or on the Settings tab.
- **What happens first**: scripts in `pre.d/`. They run as root before every backup, in name order, with `CWP_RESTIC_REPO` set to the repository being backed up. Their output goes to the log. When one fails, the backup still runs, and the run is reported as failed so you hear about it. Write what the script produces to a folder that is in `include`. The [examples](examples/pre.d) dump MySQL/MariaDB and PostgreSQL.
- **How mail is sent**: `MAIL_CMD`.

## Commands

```
cwp-restic backup <repo>             back up to one repository
cwp-restic prune                     apply the retention to every repository
cwp-restic check                     verify every repository
cwp-restic status                    list the snapshots in every repository
cwp-restic refresh                   rewrite the status files without backing up
cwp-restic apply                     check the settings and (re)create the systemd timers
cwp-restic restic <repo> <args...>   run restic against a repository
```

The log is `/var/log/cwp-restic.log`. `systemctl list-timers 'cwp-restic-*'` shows what runs when.

## Tests

| Test | Covers | Needs |
| --- | --- | --- |
| `tests/cli.sh` | the program, against real repositories in a scratch folder | Linux, restic |
| `tests/panel.sh` | the page, against made-up status files | php |
| `tests/e2e.sh` | the page and the program together | Linux, php, restic |
| `tests/hooks.sh` | the example `pre.d` scripts, with stand-ins for the database tools | bash, gzip |
| `tests/install.sh` | the installer; only runs in a throwaway container | docker, network |

None of them touch `/etc/cwp-restic` or a real repository, except `tests/install.sh` inside its container. To run the PHP tests against a given PHP version with docker, and the installer test:

```
docker run --rm -v "$PWD":/src:ro -v "$(command -v restic)":/usr/local/bin/restic:ro php:7.2-cli \
    bash -c 'cd /src && tests/panel.sh && tests/e2e.sh'
docker run --rm -v "$PWD":/src:ro almalinux:9 bash -c \
    'dnf -y -q install bzip2 hostname diffutils findutils >/dev/null && /src/tests/install.sh'
```

## Removing

```
systemctl disable --now cwp-restic-jobs.path 'cwp-restic-*.timer'
rm -f /etc/systemd/system/cwp-restic-*
systemctl daemon-reload
rm -f /usr/local/sbin/cwp-restic /etc/logrotate.d/cwp-restic
rm -rf /usr/local/share/cwp-restic /var/lib/cwp-restic /var/cache/cwp-restic
rm -f /usr/local/cwpsrv/htdocs/resources/admin/modules/restic_backups.php
```

Then take the "Restic Backups" line out of `/usr/local/cwpsrv/htdocs/resources/admin/include/3rdparty.php`. `/etc/cwp-restic` holds the repository password: keep a copy for as long as you keep the backups. The repositories themselves are never removed by any of this.

## License

MIT. See [LICENSE](LICENSE).
