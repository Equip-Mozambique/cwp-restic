<?php
if (!isset($include_path)) { echo "invalid access"; exit(); }
// Restic Backups — CWP admin page for cwp-restic.
//
// This page never runs a command. It reads the settings in /etc/cwp-restic and
// the status files cwp-restic leaves in /var/lib/cwp-restic, and it asks for
// work (a backup, a folder listing, a restore, a settings change) by writing a
// small request file into /var/lib/cwp-restic/queue. cwp-restic picks the
// request up, checks every value in it again, and does the work.
//
// Written for PHP 7.2 and later. Test: tests/panel.sh.

function rb_h($s) { return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

// A request value as a string; anything else (an array, nothing) is ''.
function rb_str($from, $key) { return isset($from[$key]) && is_string($from[$key]) ? $from[$key] : ''; }

function rb_url($c, $params = []) { return 'index.php?' . http_build_query(['module' => $c['module']] + $params); }

// restic writes nanoseconds, which strtotime does not accept.
function rb_time($s) {
    $t = is_string($s) ? strtotime(preg_replace('/\.\d+/', '', $s)) : false;
    return $t ?: null;
}

function rb_date($t) { return $t ? date('Y-m-d H:i', $t) : '—'; }

function rb_ago($t) {
    $d = time() - $t;
    if ($d < 5400) return max(1, (int)round($d / 60)) . ' min ago';
    if ($d < 172800) return (int)round($d / 3600) . ' hours ago';
    return (int)round($d / 86400) . ' days ago';
}

function rb_size($bytes) {
    if (!is_numeric($bytes)) return '—';
    if ($bytes >= 1073741824) return number_format($bytes / 1073741824, 1) . ' GiB';
    if ($bytes >= 1048576) return number_format($bytes / 1048576, 1) . ' MiB';
    if ($bytes >= 1024) return number_format($bytes / 1024, 1) . ' KiB';
    return (int)$bytes . ' B';
}

function rb_took($seconds) {
    if ($seconds === null) return '—';
    return $seconds < 90 ? $seconds . ' s' : (int)round($seconds / 60) . ' min';
}

function rb_lines($file) {
    $lines = is_file($file) && is_readable($file) ? file($file, FILE_IGNORE_NEW_LINES) : [];
    return $lines ?: [];
}

// The value of KEY in a settings file, read the way cwp-restic reads it: the
// last KEY=value line wins and one pair of surrounding quotes is dropped.
function rb_conf($file, $key, $default = '') {
    $value = '';
    foreach (rb_lines($file) as $line) {
        if (strpos($line, $key . '=') === 0) $value = substr($line, strlen($key) + 1);
    }
    $value = rtrim($value);
    $n = strlen($value);
    if ($n >= 2 && ($value[0] === '"' || $value[0] === "'") && $value[$n - 1] === $value[0]) $value = substr($value, 1, -1);
    return $value === '' ? $default : $value;
}

// The same defaults as default_for in cwp-restic.
function rb_default($key) {
    $defaults = ['KEEP_DAILY' => '7', 'KEEP_WEEKLY' => '5', 'KEEP_MONTHLY' => '12', 'RESTORE_DIR' => '/home/restic-restore',
        'RESTORE_KEEP_DAYS' => '7', 'RESTORE_MIN_FREE_GB' => '5', 'CHECK_SUBSET' => '5%', 'MAIL_CMD' => '/usr/sbin/sendmail -t',
        'LATE_DAYS' => '2'];
    if ($key === 'HOST_LABEL') return explode('.', (string)gethostname())[0];
    return isset($defaults[$key]) ? $defaults[$key] : '';
}

function rb_setting($c, $key) { return rb_conf($c['conf'] . '/config', $key, rb_default($key)); }

// The settings this page may change: key => [label, help]. cwp-restic holds the
// same list and refuses anything else.
function rb_config_fields() {
    return [
        'HOST_LABEL' => ['Server name', 'Used in the backups and in the subject of mails.'],
        'MAILTO' => ['Mail problems to', 'An email address, or several separated by commas. Empty: no mail.'],
        'WINDOW' => ['Backup window', 'HH:MM-HH:MM, for example 19:00-08:00. Scheduled work only runs in these hours and stops when they end. Empty: any time.'],
        'KEEP_DAILY' => ['Daily backups to keep', ''],
        'KEEP_WEEKLY' => ['Weekly backups to keep', ''],
        'KEEP_MONTHLY' => ['Monthly backups to keep', ''],
        'PRUNE_AT' => ['Remove old backups at', 'A systemd calendar time, for example Sat *-*-* 06:00:00. Empty: never.'],
        'CHECK_AT' => ['Verify the repositories at', 'A systemd calendar time, for example *-*-01 07:00:00. Empty: never.'],
        'RESTORE_DIR' => ['Folder for restored copies', 'Restores from this page go into a new folder here. It is left out of the backups.'],
        'RESTORE_KEEP_DAYS' => ['Days to keep restored copies', '0: keep them until someone removes them.'],
        'RESTORE_MIN_FREE_GB' => ['Free space to leave (GiB)', 'A restore is refused when it would leave less than this free.'],
    ];
}

function rb_repo_fields() {
    return [
        'REPOSITORY' => ['Address', 'Any restic repository address: /path, sftp:host:/path, s3:host/bucket, b2:bucket:path, rest:https://…'],
        'SCHEDULE' => ['Schedule', 'A systemd calendar time, for example *-*-* 03:00:00 for every night at 03:00. Empty: only on request.'],
        'MOUNT' => ['Must be mounted', 'For a repository on its own disk: the mount point. The backup refuses to run when it is not mounted.'],
        'LIMIT_UPLOAD_KB' => ['Upload limit (KiB/s)', 'Empty: no limit.'],
        'LATE_DAYS' => ['Late after (days)', 'The status says Late when the newest backup is older than this. 0: never.'],
    ];
}

function rb_valid_name($name) { return is_string($name) && preg_match('/^[a-z][a-z0-9-]{0,30}$/', $name) === 1; }
function rb_valid_job($id) { return is_string($id) && preg_match('/^[0-9]{8}-[0-9]{6}-[a-f0-9]{6}$/', $id) === 1; }
function rb_has_control($s) { return preg_match('/[\x00-\x1f\x7f]/', $s) === 1; }

// name => settings, for every repos/<name>.conf.
function rb_repos($c) {
    $out = [];
    foreach (glob($c['conf'] . '/repos/*.conf') ?: [] as $file) {
        $name = basename($file, '.conf');
        if (!rb_valid_name($name)) continue;
        foreach (array_keys(rb_repo_fields()) as $key) $out[$name][$key] = rb_conf($file, $key, rb_default($key));
    }
    ksort($out);
    return $out;
}

// When systemd runs a timer, as installed by "cwp-restic apply".
function rb_timer($c, $unit) {
    foreach (rb_lines($c['units'] . "/$unit.timer") as $line) {
        if (strpos($line, 'OnCalendar=') === 0) return trim(substr($line, 11));
    }
    return '';
}

function rb_json($file) {
    if (!is_readable($file)) return null;
    $data = json_decode((string)file_get_contents($file), true);
    return is_array($data) ? $data : null;
}

// key=value lines, the first of each key.
function rb_kv($file) {
    $out = [];
    foreach (rb_lines($file) as $line) {
        $p = strpos($line, '=');
        if ($p > 0 && !isset($out[substr($line, 0, $p)])) $out[substr($line, 0, $p)] = substr($line, $p + 1);
    }
    return $out;
}

// "2026-11-24T03:00:01+00:00 ok" -> [time, result]
function rb_last($file) {
    if (!is_readable($file)) return null;
    $parts = explode(' ', trim((string)file_get_contents($file)));
    $t = count($parts) == 2 ? rb_time($parts[0]) : null;
    if (!$t || !in_array($parts[1], ['ok', 'warning', 'failed', 'stopped'], true)) return null;
    return [$t, $parts[1]];
}

// The saved output of "restic snapshots --json", newest first.
function rb_snapshots($c, $repo) {
    $out = [];
    foreach (rb_json($c['state'] . "/snapshots-$repo.json") ?: [] as $s) {
        $t = is_array($s) ? rb_time(isset($s['time']) ? $s['time'] : null) : null;
        $id = $t && isset($s['id']) && is_string($s['id']) ? $s['id'] : '';
        if (!preg_match('/^[a-f0-9]{8,64}$/', $id)) continue;
        $sum = isset($s['summary']) && is_array($s['summary']) ? $s['summary'] : [];
        $start = rb_time(isset($sum['backup_start']) ? $sum['backup_start'] : null);
        $end = rb_time(isset($sum['backup_end']) ? $sum['backup_end'] : null);
        $out[] = [
            'time' => $t,
            'id' => $id,
            'short' => substr($id, 0, 8),
            'size' => isset($sum['total_bytes_processed']) ? $sum['total_bytes_processed'] : null,
            'added' => isset($sum['data_added_packed']) ? $sum['data_added_packed'] : null,
            'files' => isset($sum['total_files_processed']) ? $sum['total_files_processed'] : null,
            'took' => ($start && $end) ? $end - $start : null,
            'paths' => array_filter(isset($s['paths']) && is_array($s['paths']) ? $s['paths'] : [], 'is_string'),
        ];
    }
    usort($out, function ($a, $b) { return $b['time'] - $a['time']; });
    return $out;
}

// The snapshot with that id (full, or the first eight characters).
function rb_find_snapshot($snapshots, $id) {
    foreach ($snapshots as $s) {
        if ($id !== '' && ($s['id'] === $id || $s['short'] === $id)) return $s;
    }
    return null;
}

// [bootstrap label class, text] for one repository.
function rb_state($last, $snapshots, $late_days) {
    if ($last && $last[1] === 'failed') return ['danger', 'Failed'];
    if (!$snapshots) return ['default', 'No backup yet'];
    if ($late_days > 0 && time() - $snapshots[0]['time'] > $late_days * 86400) return ['warning', 'Late'];
    if ($last && $last[1] === 'warning') return ['warning', 'Warning'];
    return ['success', 'OK'];
}

function rb_run($last) {
    if (!$last) return '—';
    $words = ['ok' => 'finished', 'warning' => 'finished with warnings', 'failed' => 'failed',
        'stopped' => 'stopped when the backup window closed'];
    return rb_h(rb_date($last[0])) . ' — ' . $words[$last[1]];
}

function rb_tail($file, $count) {
    if (!is_file($file) || !is_readable($file) || !($size = filesize($file)) || !($fh = fopen($file, 'r'))) return [];
    fseek($fh, max(0, $size - 16384));
    $lines = explode("\n", rtrim((string)fread($fh, 16384), "\n"));
    fclose($fh);
    if ($size > 16384) array_shift($lines);
    return array_slice($lines, -$count);
}

// The secret behind the form tokens, made on first use and readable by root only.
function rb_key($c) {
    $file = $c['state'] . '/csrf.key';
    $key = is_readable($file) ? trim((string)file_get_contents($file)) : '';
    if (strlen($key) >= 64) return $key;
    if (!is_dir($c['state']) && !@mkdir($c['state'], 0700, true)) return '';
    $tmp = $file . '.' . getmypid();
    $old = umask(0077);
    $ok = @file_put_contents($tmp, bin2hex(random_bytes(32)) . "\n") !== false && @rename($tmp, $file);
    umask($old);
    return $ok ? trim((string)file_get_contents($file)) : '';
}

// Every form carries this token, and a request without it is ignored. It is
// tied to the admin's login, so a page on another site cannot make the browser
// ask for a backup, a restore or a settings change.
function rb_token($c) {
    $key = rb_key($c);
    if ($key === '') return '';
    $who = function_exists('session_status') && session_status() === PHP_SESSION_ACTIVE ? (string)session_id() : '';
    if ($who === '') {
        $cookies = $_COOKIE;
        ksort($cookies);
        $who = (string)json_encode($cookies);
    }
    return hash_hmac('sha256', $who, $key);
}

// Leave a request for cwp-restic: key=value lines in a new file in the queue,
// put in place in one step. Returns the request id, or null.
function rb_queue($c, $lines) {
    foreach ($lines as $line) {
        if (rb_has_control($line)) return null;
    }
    $dir = $c['state'] . '/queue';
    if (!is_dir($dir) && !@mkdir($dir, 0700, true)) return null;
    $id = date('Ymd-His') . '-' . bin2hex(random_bytes(3));
    $tmp = "$dir/.$id.tmp";
    $old = umask(0077);
    $ok = @file_put_contents($tmp, implode("\n", $lines) . "\n") !== false && @rename($tmp, "$dir/$id.job");
    umask($old);
    if (!$ok) { @unlink($tmp); return null; }
    return $id;
}

// One request: waiting (still in the queue), or as cwp-restic last described it.
function rb_job($c, $id) {
    $job = ['id' => $id, 'state' => 'unknown', 'action' => '', 'repo' => '', 'message' => '', 'target' => '',
        'finished' => 0, 'age' => 0, 'request' => ''];
    $dir = $c['state'] . "/jobs/$id";
    $waiting = $c['state'] . "/queue/$id.job";
    if (is_dir($dir)) {
        $job['request'] = "$dir/request";
        $status = rb_kv("$dir/status");
        foreach (['action', 'repo', 'message', 'target'] as $key) {
            if (isset($status[$key])) $job[$key] = $status[$key];
        }
        if (isset($status['state']) && in_array($status['state'], ['queued', 'running', 'done', 'failed', 'skipped'], true)) $job['state'] = $status['state'];
        if (isset($status['finished']) && ctype_digit($status['finished'])) $job['finished'] = (int)$status['finished'];
    } elseif (is_file($waiting)) {
        $job['request'] = $waiting;
        $job['state'] = 'waiting';
        $job['age'] = time() - (int)filemtime($waiting);
    } else {
        return null;
    }
    if ($job['action'] === '' || $job['repo'] === '') {
        $request = rb_kv($job['request']);
        foreach (['action', 'repo'] as $key) {
            if ($job[$key] === '' && isset($request[$key])) $job[$key] = $request[$key];
        }
    }
    return $job;
}

// The ids of all requests, newest first.
function rb_job_ids($c) {
    $ids = [];
    foreach (@scandir($c['state'] . '/jobs') ?: [] as $name) {
        if (rb_valid_job($name)) $ids[$name] = true;
    }
    foreach (@scandir($c['state'] . '/queue') ?: [] as $name) {
        if (substr($name, -4) === '.job' && rb_valid_job(substr($name, 0, -4))) $ids[substr($name, 0, -4)] = true;
    }
    $ids = array_map('strval', array_keys($ids));
    rsort($ids, SORT_STRING);
    return $ids;
}

// The newest requests. Folder listings are left out unless asked for: every
// folder opened on the Restore tab is one.
function rb_jobs($c, $limit, $with_listings) {
    $out = [];
    foreach (array_slice(rb_job_ids($c), 0, 500) as $id) {
        $job = rb_job($c, $id);
        if (!$job || (!$with_listings && $job['action'] === 'ls')) continue;
        $out[] = $job;
        if (count($out) >= $limit) break;
    }
    return $out;
}

function rb_busy($state) { return in_array($state, ['waiting', 'queued', 'running'], true); }

// The newest request for the listing of that folder, if there is one.
function rb_find_listing($c, $repo, $snapshot, $path) {
    $want = "action=ls\nrepo=$repo\nsnapshot=$snapshot\npath=$path\n";
    foreach (array_slice(rb_job_ids($c), 0, 200) as $id) {
        $job = rb_job($c, $id);
        if ($job && $job['action'] === 'ls' && @file_get_contents($job['request']) === $want) return $job;
    }
    return null;
}

// Wait a little for cwp-restic to finish a request, so the answer can be shown
// on the same page.
function rb_wait($c, $id, $file = null) {
    $deadline = microtime(true) + $c['wait'];
    while (true) {
        clearstatcache();
        $job = rb_job($c, $id);
        if ($file !== null && is_file($file)) return $job;
        if ($job && in_array($job['state'], ['done', 'failed', 'skipped'], true)) return $job;
        if (microtime(true) >= $deadline) return $job;
        usleep(200000);
    }
}

// A full path inside a backup, tidied; null when it is not one.
function rb_clean_path($path) {
    if (!is_string($path) || $path === '' || $path[0] !== '/' || rb_has_control($path)) return null;
    $parts = [];
    foreach (explode('/', $path) as $part) {
        if ($part === '') continue;
        if ($part === '.' || $part === '..') return null;
        $parts[] = $part;
    }
    return '/' . implode('/', $parts);
}

// The entries of a cached folder listing ("restic ls --json"): folders first.
// Returns [entries, how many there are in all].
function rb_listing($file, $path, $max) {
    $dirs = []; $files = []; $total = 0;
    if (!($fh = @fopen($file, 'r'))) return [[], 0];
    while (($line = fgets($fh)) !== false) {
        $n = json_decode($line, true);
        if (!is_array($n) || !isset($n['struct_type']) || $n['struct_type'] !== 'node') continue;
        if (!isset($n['path'], $n['name']) || !is_string($n['path']) || !is_string($n['name']) || $n['path'] === $path) continue;
        $total++;
        if ($total > $max) continue;
        $entry = ['name' => $n['name'], 'path' => $n['path'], 'type' => isset($n['type']) && is_string($n['type']) ? $n['type'] : 'file',
            'size' => isset($n['size']) ? $n['size'] : null, 'mtime' => rb_time(isset($n['mtime']) ? $n['mtime'] : null)];
        if ($entry['type'] === 'dir') $dirs[] = $entry; else $files[] = $entry;
    }
    fclose($fh);
    return [array_merge($dirs, $files), $total];
}

function rb_progress($file) {
    if (preg_match_all('/"percent_done":([0-9.]+)/', implode("\n", rb_tail($file, 20)), $m)) return (int)round((float)end($m[1]) * 100) . '%';
    return '';
}

function rb_alert($class, $html) { echo '<div class="alert alert-' . $class . '">' . $html . "</div>\n"; }

function rb_token_fields($c, $action) {
    return '<input type="hidden" name="rb_action" value="' . $action . '"><input type="hidden" name="rb_token" value="' . rb_h($c['token']) . '">';
}

// A page reload from the browser, for work that is still going on.
function rb_reload($url, $seconds) {
    echo '<script>setTimeout(function () { window.location.href = ' . json_encode($url, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT)
        . '; }, ' . (int)$seconds . "000);</script>\n";
}

// ---------------------------------------------------------------- requests (POST)

function rb_post_backup($c, $repos) {
    $repo = rb_str($_POST, 'repo');
    if (!isset($repos[$repo])) return ['danger', 'Unknown repository. Nothing was done.'];
    if (!rb_queue($c, ['action=backup', "repo=$repo"])) return ['danger', 'The request could not be written to ' . rb_h($c['state']) . '/queue.'];
    return ['success', 'Backup requested for <b>' . rb_h($repo) . '</b>. Follow it under <a href="' . rb_h(rb_url($c, ['tab' => 'jobs'])) . '">Requests</a>.'];
}

function rb_post_restore($c, $repos) {
    $repo = rb_str($_POST, 'repo');
    if (!isset($repos[$repo])) return ['danger', 'Unknown repository. Nothing was done.'];
    $snapshot = rb_find_snapshot(rb_snapshots($c, $repo), rb_str($_POST, 'snapshot'));
    if (!$snapshot) return ['danger', 'Unknown backup. Nothing was done.'];
    $paths = isset($_POST['paths']) && is_array($_POST['paths']) ? $_POST['paths'] : [];
    if (!$paths) return ['danger', 'Nothing was chosen to restore. Tick the files or folders first.'];
    if (count($paths) > 500) return ['danger', 'Too many items were chosen at once (the limit is 500). Choose the folder that holds them instead.'];
    $lines = ['action=restore', "repo=$repo", 'snapshot=' . $snapshot['id']];
    foreach ($paths as $path) {
        if (!is_string($path) || $path === '' || $path[0] !== '/' || rb_has_control($path)) {
            return ['danger', 'One of the chosen names cannot be asked for from this page. Choose the folder that holds it instead. Nothing was done.'];
        }
        $lines[] = "path=$path";
    }
    $id = rb_queue($c, array_values(array_unique($lines)));
    if (!$id) return ['danger', 'The request could not be written to ' . rb_h($c['state']) . '/queue.'];
    return ['success', 'Restore requested. The copies go to <code>' . rb_h(rb_setting($c, 'RESTORE_DIR') . '/' . $id)
        . '</code>; nothing that is live on the server is changed. Follow it under <a href="' . rb_h(rb_url($c, ['tab' => 'jobs'])) . '">Requests</a>.'];
}

// One posted settings value, trimmed; null (and an error) when it cannot be used.
function rb_field($value, $label, &$errors) {
    if (!is_string($value)) { $errors[] = "$label: that is not a value."; return null; }
    $value = trim($value);
    if (rb_has_control($value)) { $errors[] = "$label: a value cannot hold a line break or other control characters."; return null; }
    return $value;
}

function rb_list_lines($lines) {
    $out = [];
    foreach ($lines as $line) {
        $line = rtrim($line);
        if ($line !== '') $out[] = $line;
    }
    return $out;
}

// Only what was edited is sent. cwp-restic checks every value, and changes
// nothing at all when one of them is wrong. Returns [alert class, html,
// whether the form should show what was posted].
function rb_post_settings($c, $repos) {
    $errors = [];
    $lines = ['action=settings'];
    $config = isset($_POST['config']) && is_array($_POST['config']) ? $_POST['config'] : [];
    foreach (rb_config_fields() as $key => $field) {
        if (!array_key_exists($key, $config)) continue;
        $value = rb_field($config[$key], $field[0], $errors);
        if ($value !== null && $value !== rb_setting($c, $key)) $lines[] = "config.$key=$value";
    }
    $posted = isset($_POST['repo']) && is_array($_POST['repo']) ? $_POST['repo'] : [];
    $delete = isset($_POST['repo_delete']) && is_array($_POST['repo_delete']) ? $_POST['repo_delete'] : [];
    foreach ($repos as $name => $settings) {
        if (!empty($delete[$name])) { $lines[] = "repo.$name.delete=1"; continue; }
        if (!array_key_exists($name, $posted)) continue;
        if (!is_array($posted[$name])) { $errors[] = "Repository $name: that is not a value."; continue; }
        foreach (rb_repo_fields() as $key => $field) {
            if (!array_key_exists($key, $posted[$name])) continue;
            $value = rb_field($posted[$name][$key], "Repository $name, " . $field[0], $errors);
            if ($value !== null && $value !== $settings[$key]) $lines[] = "repo.$name.$key=$value";
        }
    }
    $new = isset($_POST['new_repo']) && is_array($_POST['new_repo']) ? $_POST['new_repo'] : [];
    $name = rb_field(isset($new['name']) ? $new['name'] : '', 'New repository, name', $errors);
    $values = [];
    foreach (rb_repo_fields() as $key => $field) {
        $value = rb_field(isset($new[$key]) ? $new[$key] : '', 'New repository, ' . $field[0], $errors);
        if ($value !== null && $value !== '') $values[$key] = $value;
    }
    if ($name === '' && $values) {
        $errors[] = 'The new repository needs a name.';
    } elseif ($name !== null && $name !== '') {
        if (!rb_valid_name($name)) $errors[] = 'The name of a repository must be lowercase letters, digits and dashes, starting with a letter.';
        elseif (isset($repos[$name])) $errors[] = "There is already a repository named $name.";
        elseif (!isset($values['REPOSITORY'])) $errors[] = 'The new repository needs an address.';
        else foreach ($values as $key => $value) $lines[] = "repo.$name.$key=$value";
    }
    foreach (['include' => 'What to back up', 'exclude' => 'What to leave out'] as $list => $label) {
        if (!array_key_exists($list, $_POST)) continue;
        if (!is_string($_POST[$list])) { $errors[] = "$label: that is not a list."; continue; }
        $wanted = rb_list_lines(preg_split('/\r\n|\r|\n/', $_POST[$list]));
        foreach ($wanted as $line) {
            if (rb_has_control($line)) { $errors[] = "$label: a line cannot hold control characters."; continue 2; }
        }
        if ($wanted === rb_list_lines(rb_lines($c['conf'] . "/$list"))) continue;
        $lines[] = "$list.set=1";
        foreach ($wanted as $line) $lines[] = "$list=$line";
    }

    if ($errors) return ['danger', 'Nothing was changed:<br>' . implode('<br>', array_map('rb_h', $errors)), true];
    if (count($lines) == 1) return ['info', 'Nothing was changed: the settings are as they were.', false];
    $id = rb_queue($c, $lines);
    if (!$id) return ['danger', 'The request could not be written to ' . rb_h($c['state']) . '/queue.', true];
    $job = rb_wait($c, $id);
    if ($job && $job['state'] === 'done') return ['success', 'Settings saved, and the timers updated.', false];
    if ($job && $job['state'] === 'failed') return ['danger', 'The request failed: ' . rb_h($job['message']), true];
    return ['info', 'Settings sent. The result will be under <a href="' . rb_h(rb_url($c, ['tab' => 'jobs'])) . '">Requests</a> in a moment.', true];
}

// ---------------------------------------------------------------- tabs

function rb_tab_status($c, $repos) {
    if (!$repos) {
        rb_alert('info', 'No repository is set up yet. Add one under <a href="' . rb_h(rb_url($c, ['tab' => 'settings'])) . '">Settings</a>.');
    }
    $busy = 0;
    foreach (rb_jobs($c, 20, false) as $job) {
        if (rb_busy($job['state'])) $busy++;
    }
    if ($busy) {
        rb_alert('info', $busy . ($busy == 1 ? ' request is' : ' requests are') . ' in progress: see <a href="' . rb_h(rb_url($c, ['tab' => 'jobs'])) . '">Requests</a>.');
    }
    $prune_at = rb_setting($c, 'PRUNE_AT');
    $check_at = rb_setting($c, 'CHECK_AT');
    $mismatch = $prune_at !== rb_timer($c, 'cwp-restic-prune') || $check_at !== rb_timer($c, 'cwp-restic-check');
    foreach ($repos as $name => $settings) {
        if ($settings['SCHEDULE'] !== rb_timer($c, "cwp-restic-backup-$name")) $mismatch = true;
    }
    if ($mismatch) {
        rb_alert('warning', 'The timers on this server do not match the settings below, so the times shown are not the times in use. '
            . 'Run <code>cwp-restic apply</code> as root to bring them in line.');
    }

    $all = [];
    if ($repos) {
        echo '<table class="table table-bordered">' . "\n";
        echo "<tr><th>Repository</th><th>Status</th><th>Newest backup</th><th>Last run</th><th>Backups kept</th><th>Server data</th>"
            . "<th>Stored</th><th>Schedule</th><th>Address</th><th></th></tr>\n";
    }
    foreach ($repos as $name => $settings) {
        $snaps = rb_snapshots($c, $name);
        $all[$name] = $snaps;
        $last = rb_last($c['state'] . "/backup-$name.last");
        $st = rb_state($last, $snaps, (int)$settings['LATE_DAYS']);
        $stats = rb_json($c['state'] . "/stats-$name.json");
        echo '<tr><th>' . rb_h($name) . '</th>';
        echo '<td><span class="label label-' . $st[0] . '">' . $st[1] . '</span></td>';
        echo '<td>' . ($snaps ? rb_h(rb_date($snaps[0]['time'])) . '<br><span class="rb-note">' . rb_ago($snaps[0]['time']) . '</span>' : '—') . '</td>';
        echo '<td>' . rb_run($last) . '</td>';
        echo '<td>' . count($snaps) . '</td>';
        echo '<td>' . ($snaps ? rb_size($snaps[0]['size']) : '—') . '</td>';
        echo '<td>' . rb_size(isset($stats['total_size']) ? $stats['total_size'] : null) . '</td>';
        echo '<td>' . ($settings['SCHEDULE'] !== '' ? '<code>' . rb_h($settings['SCHEDULE']) . '</code>' : '<span class="rb-note">only on request</span>') . '</td>';
        echo '<td><code>' . rb_h($settings['REPOSITORY']) . '</code></td>';
        echo '<td><form method="post" action="' . rb_h(rb_url($c)) . '">' . rb_token_fields($c, 'backup')
            . '<input type="hidden" name="repo" value="' . rb_h($name) . '"><button type="submit" class="btn btn-default btn-xs">Back up now</button></form></td></tr>' . "\n";
    }
    if ($repos) {
        echo "</table>\n";
        echo '<p>Removal of old backups (' . ($prune_at !== '' ? '<code>' . rb_h($prune_at) . '</code>' : 'not scheduled') . '): '
            . rb_run(rb_last($c['state'] . '/prune.last')) . '. Read-back check of ' . rb_h(rb_setting($c, 'CHECK_SUBSET')) . ' of the data ('
            . ($check_at !== '' ? '<code>' . rb_h($check_at) . '</code>' : 'not scheduled') . '): ' . rb_run(rb_last($c['state'] . '/check.last')) . ".</p>\n";
    }
    foreach ($all as $name => $snaps) {
        if (!$snaps) continue;
        echo '<h4>Backups in ' . rb_h($name) . "</h4>\n";
        echo '<table class="table table-bordered table-striped">' . "\n";
        echo "<tr><th>Date</th><th>ID</th><th>Server data</th><th>New data stored</th><th>Files</th><th>Took</th><th></th></tr>\n";
        foreach (array_slice($snaps, 0, 100) as $s) {
            echo '<tr><td>' . rb_h(rb_date($s['time'])) . '</td><td><code>' . rb_h($s['short']) . '</code></td>';
            echo '<td>' . rb_size($s['size']) . '</td><td>' . rb_size($s['added']) . '</td>';
            echo '<td>' . (is_numeric($s['files']) ? number_format($s['files']) : '—') . '</td>';
            echo '<td>' . rb_took($s['took']) . '</td>';
            echo '<td><a href="' . rb_h(rb_url($c, ['tab' => 'restore', 'repo' => $name, 'snapshot' => $s['id']])) . '">Browse</a></td></tr>' . "\n";
        }
        echo "</table>\n";
        if (count($snaps) > 100) echo '<p class="rb-note">Only the newest 100 of ' . count($snaps) . " are shown.</p>\n";
    }
    foreach ($all as $snaps) {
        if (!$snaps || !$snaps[0]['paths']) continue;
        echo "<h4>What is backed up</h4>\n<p>";
        foreach ($snaps[0]['paths'] as $p) echo '<code>' . rb_h($p) . '</code> ';
        echo "</p>\n";
        break;
    }
    $log = rb_tail($c['log'], 40);
    if ($log) echo "<h4>Recent log</h4>\n<pre>" . rb_h(implode("\n", $log)) . "</pre>\n";
}

function rb_tab_restore($c, $repos) {
    $repo = rb_str($_GET, 'repo');
    $id = rb_str($_GET, 'snapshot');
    if ($repo !== '' && !isset($repos[$repo])) { rb_alert('danger', 'Unknown repository.'); $repo = ''; }
    if ($repo !== '' && $id !== '') {
        $snapshot = rb_find_snapshot(rb_snapshots($c, $repo), $id);
        if ($snapshot) { rb_browse($c, $repo, $snapshot); return; }
        rb_alert('danger', 'Unknown backup: it is not in the list below. It may have been removed since the page was loaded.');
    }

    echo '<p>Choose a backup to look into. Files and folders you pick are copied into a new folder under <code>'
        . rb_h(rb_setting($c, 'RESTORE_DIR')) . '</code>; nothing that is live on the server is overwritten.';
    $days = (int)rb_setting($c, 'RESTORE_KEEP_DAYS');
    if ($days > 0) echo ' The copies are removed again after ' . $days . ($days == 1 ? ' day.' : ' days.');
    echo "</p>\n";
    $any = false;
    foreach ($repos as $name => $settings) {
        $snaps = rb_snapshots($c, $name);
        if (!$snaps) continue;
        $any = true;
        echo '<h4>Backups in ' . rb_h($name) . "</h4>\n";
        echo '<table class="table table-bordered table-striped">' . "\n<tr><th>Date</th><th>ID</th><th>Server data</th><th>Files</th><th></th></tr>\n";
        foreach (array_slice($snaps, 0, 100) as $s) {
            echo '<tr><td>' . rb_h(rb_date($s['time'])) . ' <span class="rb-note">' . rb_ago($s['time']) . '</span></td><td><code>' . rb_h($s['short']) . '</code></td>';
            echo '<td>' . rb_size($s['size']) . '</td><td>' . (is_numeric($s['files']) ? number_format($s['files']) : '—') . '</td>';
            echo '<td><a class="btn btn-default btn-xs" href="' . rb_h(rb_url($c, ['tab' => 'restore', 'repo' => $name, 'snapshot' => $s['id']])) . '">Browse</a></td></tr>' . "\n";
        }
        echo "</table>\n";
    }
    if (!$any) rb_alert('info', 'There is no backup to restore from yet.');
}

// One folder of one backup, with a box to tick for each thing in it.
function rb_browse($c, $repo, $snapshot) {
    $here = ['tab' => 'restore', 'repo' => $repo, 'snapshot' => $snapshot['id']];
    echo '<p><a href="' . rb_h(rb_url($c, ['tab' => 'restore'])) . '">All backups</a> › backup of <b>' . rb_h(rb_date($snapshot['time']))
        . '</b> (<code>' . rb_h($snapshot['short']) . '</code>) in <b>' . rb_h($repo) . "</b></p>\n";
    $path = rb_clean_path(isset($_GET['path']) ? $_GET['path'] : '/');
    if ($path === null) { rb_alert('danger', 'That is not a valid folder.'); return; }

    $file = $c['state'] . "/ls/$repo/" . $snapshot['id'] . '/' . sha1($path) . '.jsonl';
    if (!is_file($file)) {
        // Ask for the listing once; a failure is shown for a minute before a reload asks again.
        $job = rb_find_listing($c, $repo, $snapshot['id'], $path);
        $failed = $job && $job['state'] === 'failed' && time() - $job['finished'] < 60;
        if (!$job || (!rb_busy($job['state']) && !$failed)) {
            $id = rb_queue($c, ['action=ls', "repo=$repo", 'snapshot=' . $snapshot['id'], "path=$path"]);
            if (!$id) { rb_alert('danger', 'The request could not be written to ' . rb_h($c['state']) . '/queue.'); return; }
            $job = rb_wait($c, $id, $file);
        } elseif (!$failed) {
            $job = rb_wait($c, $job['id'], $file);
        }
        clearstatcache();
        if (!is_file($file)) {
            if ($job && $job['state'] === 'failed') {
                rb_alert('danger', 'This folder could not be read: ' . rb_h($job['message']) . '. Reload the page in a minute to try again.');
                return;
            }
            $hint = $job && $job['state'] === 'waiting' && $job['age'] > 30
                ? ' The request has not been picked up yet; if this stays, check <code>systemctl status cwp-restic-jobs.path</code> on the server.' : '';
            rb_alert('info', 'Reading the backup… this page reloads by itself.' . $hint);
            rb_reload(rb_url($c, $here + ['path' => $path]), 3);
            return;
        }
    }

    echo '<p>Folder: <a href="' . rb_h(rb_url($c, $here + ['path' => '/'])) . '">/</a>';
    $walk = '';
    foreach (array_filter(explode('/', $path), 'strlen') as $part) {
        $walk .= '/' . $part;
        echo ' <a href="' . rb_h(rb_url($c, $here + ['path' => $walk])) . '">' . rb_h($part) . '</a> /';
    }
    echo "</p>\n";
    list($entries, $total) = rb_listing($file, $path, 1000);
    if (!$entries) { echo '<p class="rb-note">Nothing is in this folder.</p>' . "\n"; return; }
    echo '<form method="post" action="' . rb_h(rb_url($c, $here + ['path' => $path])) . '">' . rb_token_fields($c, 'restore')
        . '<input type="hidden" name="repo" value="' . rb_h($repo) . '"><input type="hidden" name="snapshot" value="' . rb_h($snapshot['id']) . '">' . "\n";
    echo '<table class="table table-bordered table-striped">' . "\n";
    echo '<tr><th><input type="checkbox" title="All" onclick="var b = this.form.querySelectorAll(\'input[type=checkbox]:not([disabled])\'); for (var i = 0; i &lt; b.length; i++) b[i].checked = this.checked;"></th>'
        . "<th>Name</th><th>Size</th><th>Changed</th></tr>\n";
    foreach ($entries as $e) {
        // A name with a line break in it cannot be written into a request.
        $box = rb_has_control($e['path']) ? '<input type="checkbox" disabled title="Choose the folder that holds it instead">'
            : '<input type="checkbox" name="paths[]" value="' . rb_h($e['path']) . '">';
        $name = $e['type'] === 'dir' ? '<a href="' . rb_h(rb_url($c, $here + ['path' => $e['path']])) . '">' . rb_h($e['name']) . '/</a>'
            : rb_h($e['name']) . ($e['type'] === 'file' ? '' : ' <span class="rb-note">(' . rb_h($e['type']) . ')</span>');
        echo "<tr><td>$box</td><td>$name</td><td>" . ($e['type'] === 'file' ? rb_size($e['size']) : '') . '</td><td>' . rb_h(rb_date($e['mtime'])) . "</td></tr>\n";
    }
    echo "</table>\n";
    if ($total > count($entries)) {
        echo '<p class="rb-note">This folder holds ' . number_format($total) . ' items; the first ' . count($entries)
            . " are shown. To get one of the others, go up and restore this whole folder.</p>\n";
    }
    echo '<p><button type="submit" class="btn btn-primary">Restore what is ticked</button> <span class="rb-note">Copies go to a new folder under <code>'
        . rb_h(rb_setting($c, 'RESTORE_DIR')) . "</code>. Nothing that is live on the server is overwritten.</span></p>\n</form>\n";
}

function rb_input($name, $value, $size = 40) {
    return '<input type="text" class="form-control" size="' . $size . '" name="' . rb_h($name) . '" value="' . rb_h($value) . '">';
}

// The value to show in a form field: what was just posted when a save did not
// go through, otherwise what is in force.
function rb_shown($posted, $keys, $current) {
    foreach ($keys as $key) {
        if (!is_array($posted) || !isset($posted[$key])) return $current;
        $posted = $posted[$key];
    }
    return is_string($posted) ? $posted : $current;
}

function rb_tab_settings($c, $repos, $posted) {
    echo '<p class="rb-note">Saving checks every value first: when one is wrong, nothing is changed. The settings as they were before the last '
        . 'save are kept in <code>' . rb_h($c['conf']) . "/.previous</code>.</p>\n";
    echo '<form method="post" action="' . rb_h(rb_url($c, ['tab' => 'settings'])) . '">' . rb_token_fields($c, 'settings') . "\n";
    echo "<h4>General</h4>\n" . '<table class="table table-bordered">' . "\n";
    foreach (rb_config_fields() as $key => $field) {
        echo '<tr><th>' . rb_h($field[0]) . '</th><td>' . rb_input("config[$key]", rb_shown($posted, ['config', $key], rb_setting($c, $key)))
            . '</td><td class="rb-note">' . rb_h($field[1]) . "</td></tr>\n";
    }
    echo "</table>\n";

    foreach ($repos as $name => $settings) {
        echo '<h4>Repository ' . rb_h($name) . "</h4>\n" . '<table class="table table-bordered">' . "\n";
        foreach (rb_repo_fields() as $key => $field) {
            echo '<tr><th>' . rb_h($field[0]) . '</th><td>' . rb_input("repo[$name][$key]", rb_shown($posted, ['repo', $name, $key], $settings[$key]))
                . '</td><td class="rb-note">' . rb_h($field[1]) . "</td></tr>\n";
        }
        $extra = [];
        foreach (['env' => 'back-end settings', 'password' => 'its own password'] as $ext => $what) {
            if (is_file($c['conf'] . "/repos/$name.$ext")) $extra[] = "$what in <code>" . rb_h($c['conf'] . "/repos/$name.$ext") . '</code>';
        }
        echo '<tr><th>On the server</th><td colspan="2" class="rb-note">' . ($extra ? 'This repository has ' . implode(' and ', $extra) . '.' : 'No extra files.') . "</td></tr>\n";
        echo '<tr><th>Remove</th><td colspan="2"><label><input type="checkbox" name="repo_delete[' . rb_h($name) . ']" value="1"> Stop using this repository</label> '
            . '<span class="rb-note">Only its settings go; the backups in it are not touched.</span></td></tr>' . "\n</table>\n";
    }

    echo "<h4>Add a repository</h4>\n" . '<table class="table table-bordered">' . "\n";
    echo '<tr><th>Name</th><td>' . rb_input('new_repo[name]', rb_shown($posted, ['new_repo', 'name'], ''))
        . '</td><td class="rb-note">Lowercase letters, digits and dashes, for example offsite. Leave empty to add none.</td></tr>' . "\n";
    foreach (rb_repo_fields() as $key => $field) {
        echo '<tr><th>' . rb_h($field[0]) . '</th><td>' . rb_input("new_repo[$key]", rb_shown($posted, ['new_repo', $key], ''))
            . '</td><td class="rb-note">' . rb_h($field[1]) . "</td></tr>\n";
    }
    echo "</table>\n" . '<p class="rb-note">A repository that needs keys or other back-end settings (S3, B2, a REST server) reads them from <code>'
        . rb_h($c['conf']) . '/repos/NAME.env</code>, which is made on the server and never shown here.</p>' . "\n";

    $lists = ['include' => ['What to back up', 'One full path on each line; * and ? are allowed. Lines starting with # are notes.'],
        'exclude' => ['What to leave out', 'One restic exclude pattern on each line.']];
    foreach ($lists as $list => $text) {
        echo '<h4>' . $text[0] . "</h4>\n" . '<p class="rb-note">' . $text[1] . "</p>\n";
        echo '<textarea class="form-control" name="' . $list . '" rows="10" cols="80" spellcheck="false">'
            . rb_h(rb_shown($posted, [$list], implode("\n", rb_lines($c['conf'] . "/$list")))) . "</textarea>\n";
    }
    echo '<p style="margin-top: 15px"><button type="submit" class="btn btn-primary">Save the settings</button></p>' . "\n</form>\n";

    echo "<h4>Set on the server only</h4>\n" . '<table class="table table-bordered">' . "\n";
    echo '<tr><th>Repository password</th><td>' . (is_file($c['conf'] . '/password') && filesize($c['conf'] . '/password') > 0
        ? 'In <code>' . rb_h($c['conf']) . '/password</code>. Keep a copy somewhere else: without it the backups cannot be read.'
        : '<span class="label label-danger">Missing</span> There is no <code>' . rb_h($c['conf']) . '/password</code>.') . "</td></tr>\n";
    echo '<tr><th>Mail command</th><td><code>' . rb_h(rb_setting($c, 'MAIL_CMD')) . '</code> <span class="rb-note">(MAIL_CMD in <code>'
        . rb_h($c['conf']) . "/config</code>)</span></td></tr>\n";
    echo '<tr><th>Share read back by each check</th><td><code>' . rb_h(rb_setting($c, 'CHECK_SUBSET')) . '</code> <span class="rb-note">(CHECK_SUBSET)</span></td></tr>' . "\n";
    $hooks = [];
    foreach (glob($c['conf'] . '/pre.d/*') ?: [] as $hook) {
        if (is_file($hook)) $hooks[] = '<code>' . rb_h(basename($hook)) . '</code>' . (is_executable($hook) ? '' : ' (not executable, so it is skipped)');
    }
    echo '<tr><th>Scripts run before each backup</th><td>' . ($hooks ? implode(', ', $hooks) : 'None') . ' <span class="rb-note">(in <code>'
        . rb_h($c['conf']) . "/pre.d</code>, for example database dumps)</span></td></tr>\n</table>\n";
}

function rb_tab_jobs($c) {
    $all = rb_str($_GET, 'all') === '1';
    $jobs = rb_jobs($c, 50, $all);
    $labels = ['waiting' => 'default', 'queued' => 'default', 'running' => 'info', 'done' => 'success', 'failed' => 'danger',
        'skipped' => 'warning', 'unknown' => 'default'];
    $names = ['backup' => 'Backup', 'restore' => 'Restore', 'settings' => 'Settings change', 'ls' => 'Folder listing'];
    echo '<p class="rb-note">What was asked for from this page, newest first. Scheduled backups are not listed here: they are in the log on the Status tab. ';
    echo $all ? '<a href="' . rb_h(rb_url($c, ['tab' => 'jobs'])) . '">Hide folder listings</a>'
        : '<a href="' . rb_h(rb_url($c, ['tab' => 'jobs', 'all' => 1])) . '">Show folder listings too</a>';
    echo "</p>\n";
    if (!$jobs) { rb_alert('info', 'Nothing has been asked for yet.'); return; }
    $busy = false; $stuck = false;
    echo '<table class="table table-bordered table-striped">' . "\n<tr><th>Asked</th><th>What</th><th>State</th><th>Result</th></tr>\n";
    foreach ($jobs as $job) {
        if (rb_busy($job['state'])) $busy = true;
        if ($job['state'] === 'waiting' && $job['age'] > 30) $stuck = true;
        $when = substr($job['id'], 0, 4) . '-' . substr($job['id'], 4, 2) . '-' . substr($job['id'], 6, 2) . ' ' . substr($job['id'], 9, 2) . ':' . substr($job['id'], 11, 2);
        $what = (isset($names[$job['action']]) ? $names[$job['action']] : 'Unknown') . ($job['repo'] !== '' ? ', ' . rb_h($job['repo']) : '');
        $result = rb_h($job['message']);
        if ($job['state'] === 'running' && $job['action'] === 'restore') {
            $progress = rb_progress($c['state'] . '/jobs/' . $job['id'] . '/output');
            if ($progress !== '') $result .= " — <b>$progress</b>";
        }
        if ($job['target'] !== '') $result .= '<br>In <code>' . rb_h($job['target']) . '</code>';
        echo '<tr><td>' . rb_h($when) . '<br><span class="rb-note">' . rb_h($job['id']) . "</span></td><td>$what</td>";
        echo '<td><span class="label label-' . $labels[$job['state']] . '">' . $job['state'] . "</span></td><td>$result</td></tr>\n";
    }
    echo "</table>\n";
    if ($stuck) {
        rb_alert('warning', 'A request has been waiting for more than half a minute. Check on the server that the queue is watched: '
            . '<code>systemctl status cwp-restic-jobs.path</code> (running <code>cwp-restic apply</code> sets it up).');
    }
    if ($busy) rb_reload(rb_url($c, ['tab' => 'jobs'] + ($all ? ['all' => 1] : [])), 5);
}

// ---------------------------------------------------------------- the page

// Everything runs inside this function: the panel may include this file from
// inside one of its own, so nothing here counts on global variables.
function rb_main() {
    $wait = getenv('CWP_RESTIC_WAIT');
    $c = [
        'conf' => getenv('CWP_RESTIC_CONF_DIR') ?: '/etc/cwp-restic',
        'state' => getenv('CWP_RESTIC_STATE_DIR') ?: '/var/lib/cwp-restic',
        'log' => getenv('CWP_RESTIC_LOG') ?: '/var/log/cwp-restic.log',
        'units' => getenv('CWP_RESTIC_UNIT_DIR') ?: '/etc/systemd/system',
        // Seconds to wait for a folder listing or a settings change before showing "in progress".
        'wait' => $wait !== false && $wait !== '' ? (int)$wait : 10,
        // The module is known to the panel by the name of this file.
        'module' => basename(__FILE__, '.php'),
    ];
    $tabs = ['status' => 'Status', 'restore' => 'Restore', 'settings' => 'Settings', 'jobs' => 'Requests'];
    $tab = rb_str($_GET, 'tab');
    if (!isset($tabs[$tab])) $tab = 'status';
    $ready = is_readable($c['conf'] . '/config');

    echo '<div id="restic-backups">' . "\n";
    echo "<style>\n#restic-backups table { width: auto; min-width: 60%; background: #fff; }\n"
        . "#restic-backups th, #restic-backups td { padding: 6px 10px; vertical-align: top; }\n"
        . "#restic-backups pre { max-height: 420px; overflow: auto; font-size: 12px; }\n"
        . "#restic-backups form { margin: 0; }\n#restic-backups input.form-control { width: auto; display: inline-block; }\n"
        . "#restic-backups textarea { font-family: monospace; width: auto; max-width: 100%; }\n"
        . "#restic-backups .rb-note { color: #666; font-weight: normal; }\n</style>\n";
    echo '<h3>Restic Backups' . ($ready ? ' — ' . rb_h(rb_setting($c, 'HOST_LABEL')) : '') . "</h3>\n";
    if (!$ready) {
        rb_alert('info', 'cwp-restic is not set up on this server: there is no <code>' . rb_h($c['conf']) . '/config</code>. '
            . 'Run <code>install.sh</code> from the cwp-restic repository as root.');
        echo "</div>\n";
        return;
    }

    $c['token'] = rb_token($c);
    $repos = rb_repos($c);
    $notice = null;
    $posted = null;
    $method = isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET';
    if ($method === 'POST' && isset($_POST['rb_action'])) {
        $action = rb_str($_POST, 'rb_action');
        if ($c['token'] === '' || !hash_equals($c['token'], rb_str($_POST, 'rb_token'))) {
            $notice = ['danger', 'The form has expired. Nothing was done; please try again.'];
        } elseif ($action === 'backup') {
            $notice = rb_post_backup($c, $repos);
        } elseif ($action === 'restore') {
            $notice = rb_post_restore($c, $repos);
        } elseif ($action === 'settings') {
            $notice = rb_post_settings($c, $repos);
            if ($notice[2]) $posted = $_POST;
            $repos = rb_repos($c);
        } else {
            $notice = ['danger', 'Unknown request. Nothing was done.'];
        }
    }

    echo '<ul class="nav nav-tabs" style="margin-bottom: 15px">' . "\n";
    foreach ($tabs as $key => $title) {
        echo '<li' . ($key === $tab ? ' class="active"' : '') . '><a href="' . rb_h(rb_url($c, ['tab' => $key])) . '">' . $title . "</a></li>\n";
    }
    echo "</ul>\n";
    if ($notice) rb_alert($notice[0], $notice[1]);

    if ($tab === 'restore') rb_tab_restore($c, $repos);
    elseif ($tab === 'settings') rb_tab_settings($c, $repos, $posted);
    elseif ($tab === 'jobs') rb_tab_jobs($c);
    else rb_tab_status($c, $repos);

    echo '<p class="rb-note">Times are in ' . rb_h(date('T')) . ". Backups are made by <code>cwp-restic</code> (restic); they are separate from the CWP backup screens.</p>\n";
    echo "</div>\n";
}

rb_main();
