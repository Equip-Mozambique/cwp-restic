# Design

This explains how cwp-restic is put together and why. The [README](../README.md) covers how to use it.

## The two parts

```
 CWP admin panel (PHP, root)                         systemd (root)
 ┌──────────────────────────┐                 ┌──────────────────────────┐
 │ panel/restic_backups.php │                 │ timers ──► cwp-restic    │
 │                          │  reads          │            backup <repo> │
 │  Status, Restore,        │◄─────────────── │            prune, check  │
 │  Settings, Requests      │  state files    │                          │
 │                          │                 │ path unit watches queue  │
 │                          │  writes         │   └─► cwp-restic jobs    │
 │                          │ ──────────────► │        └─► cwp-restic    │
 └──────────────────────────┘  queue/<id>.job │             job <id>     │
                                              └──────────────────────────┘
```

- `bin/cwp-restic` is one bash program. It is the only thing that runs restic, changes settings, or touches systemd.
- `panel/restic_backups.php` is one PHP file in the CWP admin modules folder. It has no `exec`, `system`, `shell_exec`, `proc_open`, or backticks in it. It reads files and writes request files.

## Why the page runs no commands

CWP admin modules run as root inside the panel's own PHP. The simplest page would call `restic` straight from PHP. That was rejected for three reasons:

1. **One place to get it right.** Every value that ends up in a command line is checked in the bash program, next to the command that uses it. A page that built its own command lines would need the same checks a second time, in a second language.
2. **Long work does not belong in a web request.** A restore can take an hour. The panel has request timeouts, and a closed browser tab should not end a restore. Requests are carried out by systemd units that live on their own.
3. **The page stays small and dull.** A PHP file that only reads and writes files in two folders is easy to review, and CWP's own PHP settings (`disable_functions` and the like) cannot break it.

The price is a short delay: a click becomes a file, systemd notices the file, and the work starts a moment later. The page waits up to 10 seconds for quick requests (a folder listing, a settings change) so they feel direct; anything slower is followed on the Requests tab.

## The file contract

The two parts share nothing but files. All paths below are defaults.

### Settings: `/etc/cwp-restic`

Described in the README. Two rules matter for the design:

- Settings files are **parsed, never sourced**. A line counts when it starts with `KEY=`; the last one wins; one pair of surrounding quotes is dropped. Nothing in a settings file can run code.
- Every value has a format check (`valid_value` in the program), and `check_settings` checks the whole set. Every command that does work refuses to run on settings that fail.

### State: `/var/lib/cwp-restic` (mode 700)

| Path | Written by | Holds |
| --- | --- | --- |
| `backup-<repo>.last`, `prune.last`, `check.last` | program | when the last run ended and how: one line, a time and `ok`, `warning`, `failed`, or `stopped` |
| `snapshots-<repo>.json`, `stats-<repo>.json` | program | restic's own JSON, refreshed after each run |
| `initialized-<repo>` | program | the address of the repository once it has been created |
| `queue/<id>.job` | page | a request waiting to be picked up |
| `jobs/<id>/request` | program | the request, moved out of the queue |
| `jobs/<id>/status` | program | `state=`, `action=`, `repo=`, `message=`, `target=`, `started=`, `finished=`, `pid=` |
| `jobs/<id>/output` | program | restic's output for the request (JSON progress lines for a restore) |
| `ls/<repo>/<snapshot>/<sha1 of path>.jsonl` | program | a cached folder listing |
| `csrf.key` | page | the key behind the form tokens |

A request id looks like `20261124-153000-a1b2c3`. States are `queued`, `running`, `done`, `failed`, and `skipped`.

### Requests

A request is a small text file of `key=value` lines:

| Action | Lines |
| --- | --- |
| `backup` | `repo=` |
| `ls` | `repo=`, `snapshot=`, `path=` |
| `restore` | `repo=`, `snapshot=`, one `path=` per ticked item (at most 500) |
| `settings` | `config.KEY=`, `repo.<name>.KEY=`, `repo.<name>.delete=1`, `include.set=1` with `include=` lines, `exclude.set=1` with `exclude=` lines |

The page writes the file under a hidden name and renames it to `<id>.job`, so the program never sees half a file.

### From click to work

1. `cwp-restic-jobs.path` has `PathExistsGlob=/var/lib/cwp-restic/queue/*.job`. A request file appearing starts `cwp-restic-jobs.service`.
2. `cwp-restic jobs` goes through the queue. Anything that is not a regular file with a valid id, or is larger than 1 MiB, is thrown away. Each good request is moved to `jobs/<id>/request` and gets its own unit, `cwp-restic-job@<id>.service`, started without waiting. A long restore therefore does not hold up a folder listing.
3. `cwp-restic job <id>` reads the request, checks every field, does the work, and writes `status` as it goes.
4. The page reads `status` and `output`.

`cwp-restic jobs` also tidies up on every pass: restored copies past `RESTORE_KEEP_DAYS`, requests older than 30 days, folder listings older than 7 days, and requests marked running whose process is gone (a reboot in the middle of a restore).

## What is checked, and where

Everything from a request is treated as untrusted when the program reads it:

- Repository names, request ids, and snapshot ids must match fixed patterns before they are used in a file name or a command line.
- A repository must exist as `repos/<name>.conf`. A request cannot name a repository address, only a configured repository.
- Paths for a restore are passed to restic as `--include` patterns with the pattern characters escaped, so a file called `we[i]rd *name.txt` restores that file and nothing else.
- Settings changes are limited to a list of keys the page may change (`CONFIG_KEYS`, `REPO_KEYS`). `MAIL_CMD`, which is a command, is not on the list, and neither are passwords or `.env` files.
- A settings request is applied to a staged copy and checked as a whole. One wrong value and nothing changes. The settings that were replaced are kept in `/etc/cwp-restic/.previous`.
- All arguments to restic are passed as an array, never through `eval` or a shell string. The one exception is `MAIL_CMD`, which is split into words; it can only be set by editing the file on the server.

## Who this protects against

It is worth being plain about this: **a CWP admin is root.** The admin panel already has a terminal and a file manager. Nothing here stops a logged-in admin from doing harm, and it does not try to.

The checks are there for other reasons:

- **Mistakes.** A typo in a schedule or a path should give a message, not a broken timer or a restore into the wrong place.
- **Cross-site requests.** Every form carries a token: an HMAC of the admin's session with a key kept in the state folder. A page on another site cannot make a logged-in admin's browser start a restore or change a setting.
- **A bug in the page.** If the page were ever tricked into writing an odd request file, the worst a request can do is one of the four actions above, on a configured repository, with checked values. It cannot run a command of its choosing.

Secrets are kept away from the page on purpose: it checks that the password files and `.env` files exist and never opens them, so a display bug cannot leak them.

One more limit: the installer checks the downloaded restic binary against the `SHA256SUMS` file from the same release. That catches a damaged download. It does not protect against a compromised release, since both files come from the same place.

## Restores

A restore from the page always goes to a new folder, `RESTORE_DIR/<request id>`, mode 700, and files keep their full original path under it. Writing over live files was left out on purpose: it is the one action here that can destroy data, and "copy it out, look, then move it" is a safe habit even for people who know what they are doing.

Before copying, the program asks restic for a dry run to learn the size, and refuses when the disk would be left with less than `RESTORE_MIN_FREE_GB`. The folder carries a marker file, `.cwp-restic-restore`; cleanup only ever removes folders that have a valid request id as their name and that marker inside. `RESTORE_DIR` is always excluded from backups.

## Backups

- **One repository, one file, one timer.** `repos/<name>.conf` holds what is specific to a destination; `apply` turns each `SCHEDULE` into `cwp-restic-backup-<name>.timer`. Adding a destination means adding a file. The address is handed to restic as it is, so any back end restic supports works, with its credentials in `repos/<name>.env`.
- **Snapshots are tagged with the repository name and the host label**, and retention is applied with `--group-by host,tags`, so in a repository shared by several servers each server's backups are counted on their own. Servers that share a repository should use the same `KEEP_*` numbers: whichever one prunes applies its numbers to every group.
- **A repository is created on first use and then remembered** (`initialized-<repo>`). If a remembered repository is later missing, the backup fails with an alarm; it is not quietly created again. An unmounted disk or a wrong address should not look like a fresh, healthy start.
- **`MOUNT`** covers the classic local-disk accident: the backup disk is not mounted and the backup fills the root file system instead.
- **`pre.d` scripts** run before the file list is built. A failing script does not stop the backup (yesterday's dump and today's files are better than nothing), and the run is reported as failed so someone looks.
- **`WINDOW`** is enforced with `timeout`: a backup that reaches the end of the window is interrupted, and restic continues from what was already uploaded on the next run. Scheduled work and "Back up now" keep to the window. Looking into a backup and restoring do not, since nobody wants to wait until evening for a file they need now.
- **Timers have no `Persistent=`.** A server that was off at 03:00 does not start a backup the moment it boots, in the middle of whatever caused the reboot. The Status tab shows "Late" instead.
- **Locks** are per repository (`flock` on a file in `/run`), so two repositories can be backed up at once and one repository never gets two runs.

## Choices that may look odd

- **Bash.** A CWP server always has it, the work is mostly running restic with the right arguments, and one readable file is easy to audit. The parts where bash is risky (quoting, parsing) are kept small and tested.
- **A single PHP file with everything in one function scope and PHP 7.2 syntax.** That is what a CWP admin module is: the panel includes the file in the middle of its own page. CWP's panel PHP has been 7.x for years and is 8.x on current versions, so the page is tested on both.
- **Polling instead of a socket.** The page reloads to see progress. There is nothing to keep running between requests.
- **The same folder list for every repository.** One list keeps "what is backed up" a question with one answer. Separate lists per repository can be added later without changing the file layout (`repos/<name>.include`).

## Tests

The tests are shell scripts with no framework. Each one builds a scratch world under `/tmp` by pointing the `CWP_RESTIC_*` variables at it, so nothing real is touched.

- `tests/cli.sh` runs the program against real restic repositories on local disk.
- `tests/panel.sh` renders the page from made-up state files and checks the HTML and the request files it writes.
- `tests/e2e.sh` puts the two together: the page writes requests, a loop stands in for the systemd path unit, and the program carries them out with real restic.
- `tests/hooks.sh` runs the example `pre.d` scripts with stand-ins for the database tools.
- `tests/install.sh` runs the installer in a throwaway container, including the real restic download and a first backup.

What the tests cannot cover is listed in the README under Status: they do not start a real CWP panel or a real systemd.
