# Wordpress Security Checker

A single Bash script that checks one or more WordPress sites for signs of intrusion, using
[WP-CLI](https://wp-cli.org/). It compares the current state of each site with a stored
**baseline**, writes a **report**, and optionally sends a **Telegram** alert.

One copy of the script can monitor any number of sites: baselines and reports are kept in a
separate folder per site, all in one central place next to the script.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [The env file](#the-env-file)
- [Who can run the script](#who-can-run-the-script)
- [What is checked](#what-is-checked)
- [State directory layout](#state-directory-layout)
- [Reports](#reports)
- [First run and `--init`](#first-run-and---init)
- [Telegram notifications](#telegram-notifications)
- [Running from cron](#running-from-cron)
- [Exit codes](#exit-codes)
- [Error messages](#error-messages)
- [Security notes](#security-notes)
- [Roadmap (`todo.md`)](#roadmap-todomd)

## Requirements

- Linux with Bash 4+ and the usual GNU tools (`find`, `grep`, `sort`, `comm`, `diff`, `stat`, `sha256sum`)
- [WP-CLI](https://wp-cli.org/) installed and runnable by the site owner
- `flock` (util-linux), to prevent two runs on the same site at the same time
- `runuser` (or `sudo`), only when the script is started as root
- `curl`, only for Telegram notifications

## Installation

The script can live in **any** directory. Everything it writes is created next to it.

```bash
mkdir -p /opt/wp-security-check
cp wp-security-check.sh /opt/wp-security-check/
chmod 755 /opt/wp-security-check/wp-security-check.sh
```

Create an env file (see [The env file](#the-env-file)); it can be anywhere, for example next to the script:

```bash
cp mysite.env /opt/wp-security-check/mysite.env   # example file shipped with the script; edit the values
chmod 600 /opt/wp-security-check/mysite.env
```

If the script is reached through a symlink (for example `/usr/local/bin/wp-security-check`), the
state directory is created next to the **real** file, not next to the link.

## Usage

```
wp-security-check.sh <wordpress-path> --env <file> [--init]
```

| Argument           | Required | Description |
|--------------------|----------|-------------|
| `<wordpress-path>` | yes      | The folder that contains `wp-includes`. It is read **only** from this argument, never from the env file or the environment. |
| `--env <file>`     | yes      | The env file to load (`--env=<file>` also works). There is no default: the script refuses to run without it. |
| `--init`           | no       | (Re)create all baselines from the current state. Use **only** when you are sure the site is clean. |
| `-h`, `--help`     | no       | Print the usage text. |

### Examples

Normal run:

```bash
/opt/wp-security-check/wp-security-check.sh /var/www/site1 --env /opt/wp-security-check/mysite.env
```

Create (or recreate) the baselines of a site you know is clean:

```bash
/opt/wp-security-check/wp-security-check.sh /var/www/site1 --env /opt/wp-security-check/mysite.env --init
```

Several sites with the same credentials:

```bash
for site in /var/www/site1 /var/www/site2 /var/www/site3; do
  /opt/wp-security-check/wp-security-check.sh "$site" --env /opt/wp-security-check/common.env
done
```

Several sites with different Telegram chats (one env file per site):

```bash
/opt/wp-security-check/wp-security-check.sh /var/www/site1 --env /opt/wp-security-check/site1.env
/opt/wp-security-check/wp-security-check.sh /var/www/site2 --env /opt/wp-security-check/site2.env
```

Relative paths and a different working directory are fine; the site path is resolved to an
absolute path before anything else happens.

## The env file

The env file is a plain shell file that is `source`d, so **values must be quoted**.

```bash
TELEGRAM_BOT_TOKEN="123456:ABC-your-bot-token"
TELEGRAM_CHAT_ID="123456789"
```

| Variable             | Default | Description |
|----------------------|---------|-------------|
| `TELEGRAM_BOT_TOKEN` | empty   | Bot token created with [@BotFather](https://t.me/BotFather). |
| `TELEGRAM_CHAT_ID`   | empty   | ID of the chat, group or channel that receives the messages. |
| `SEND_ALWAYS`        | `1`     | `1` = also send a short message when there are no ALERTs. `0` = send only when there is at least one ALERT. |
| `WP_BIN`             | `wp`    | Path of the WP-CLI executable. |
| `WP_EXECUTABLE_PATH` | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` | Colon-separated list of directories that is prepended to `PATH` by the script. Needed when the environment is reduced, for example in a crontab, where `wp`, `php` and the other tools may not be found. See below. |
| `RECENT_MIN`         | `1500`  | Window, in minutes, for the "recently modified PHP files" check (1500 = 25 hours, see below). |

**`WP_EXECUTABLE_PATH` and reduced environments.** Programs started by cron (and by other
schedulers or services) get a minimal environment, usually with a very short `PATH` such as
`/usr/bin:/bin`. In that case WP-CLI (`wp`), `php` or other tools may live in a directory that is not
searched. After loading the env file, the script prepends `WP_EXECUTABLE_PATH` to `PATH`
(`PATH="$WP_EXECUTABLE_PATH:$PATH"`), so the directories listed there are searched first and the
original `PATH` is still kept as a fallback. Set it in the env file (or in the environment) to
the directories that contain the executables you need, for example:

```bash
WP_EXECUTABLE_PATH="/usr/local/bin:/opt/php/bin:/home/siteuser/bin"
```

If you do not set it, the standard system directories shown in the table are used. If WP-CLI
is installed somewhere else, either add its directory to `WP_EXECUTABLE_PATH` or set `WP_BIN` to its
full path.

**Why `RECENT_MIN` defaults to 1500 (25 hours).** The default is meant for a script run once a day from cron. The window must be **at least 24 hours**, otherwise files modified in the gap between two runs would never be reported (with a 20-hour window, a file changed 22 hours before the next run is missed by every run). The extra hour is a safety margin: cron does not start at the exact same second every day and a run takes some minutes, so a window of exactly 1440 minutes could still leave a small gap. The cost is that a file modified in the hour before the previous run can be reported twice; this check is only a NOTICE, so the noise is small. If you run the script at a different frequency, set `RECENT_MIN` in the env file to the interval between runs plus a small margin (for example `70` for an hourly run).

If the Telegram variables are empty, the script still works: reports are written to disk and
printed to standard output, and a note is written to standard error.

The WordPress path, the user that runs WP-CLI and the location of the state directory are
**not** configurable from the env file.

Keep the file private, since it contains the bot token: `chmod 600`.

## Who can run the script

The script must be started by **root** or by the **user that owns the site files**. Any other
user is rejected.

WP-CLI is always executed as the owner of the site. The script finds that user itself, from the
owner of `<wordpress-path>/wp-includes`; it cannot be configured.

| Started by       | How WP-CLI is run |
|------------------|-------------------|
| root             | Switched to the site owner (`runuser -u <owner>`, or `sudo -u <owner>` if `runuser` is missing). |
| the site owner   | Directly, with no user switch. |
| anyone else      | The script stops with an error. |

Further rules:

- If the site owner is `root` (or the owner cannot be resolved), the script stops: WP-CLI must never run as root.
- Before doing any check, the script runs `wp cli version` as the site owner. If the owner cannot run WP-CLI (`WP_BIN`), the script stops with an error.
- The user running the script must have **write permission** on the state directory. If it does not, the script stops; it never falls back to another location.

## What is checked

Every check runs WP-CLI with `--skip-plugins --skip-themes`, so no code from a possibly
compromised plugin or theme is executed.

Findings have two levels. **ALERT** means "check immediately" and triggers the Telegram alert and
exit code 1. **NOTICE** means "review when you can".

| Check | Level | What it does |
|-------|-------|--------------|
| WP-CLI can read the site | ALERT | `wp option get siteurl` must work. If not (database unreachable, tampered `wp-config.php`, PHP error), this is reported and the remaining checks are skipped. |
| Core checksums | ALERT | `wp core verify-checksums`: modified, added or missing core files. |
| Plugin checksums | ALERT / NOTICE | `wp plugin verify-checksums --all`: files that differ from the wordpress.org version are an ALERT. Plugins that cannot be verified (premium, custom) are a NOTICE. |
| PHP in uploads | ALERT | Executable files (`.php`, `.php5`, `.phtml`, `.phar`, `.pht`) inside `wp-content/uploads`. |
| Web shell patterns | ALERT | Files in `wp-content`, `wp-includes` and `wp-admin` matching typical web shell and obfuscation patterns (`eval(base64_decode(...))`, `assert($_POST...)`, `FilesMan`, `c99shell`, ...). Only files **new** compared to the baseline are reported. |
| Critical file hashes | ALERT | SHA-256 of `wp-config.php`, `.htaccess`, `index.php`, `.user.ini`, `wp-content/index.php`, the drop-ins (`advanced-cache.php`, `db.php`, `object-cache.php`) and everything in `mu-plugins`, compared with the baseline. |
| Administrators | ALERT | The list of administrator users, compared with the baseline. |
| Critical options | ALERT | `siteurl`, `home`, `admin_email`, `users_can_register`, `default_role`, compared with the baseline. |
| Database injection | ALERT | IDs of posts whose content contains `<script`, `<iframe`, `document.write`, `base64_decode` or `eval(`. Only **new** IDs compared to the baseline are reported. |
| Cron events | NOTICE | The list of WordPress cron hooks, compared with the baseline. |
| Plugin/theme inventory | NOTICE | Installed plugins and themes with status and version, compared with the baseline. |
| Available updates | NOTICE | Pending core, plugin and theme updates. |
| Recently modified PHP files | NOTICE | PHP files changed in the last `RECENT_MIN` minutes (normal after an update, suspicious otherwise). |
| World-writable files | NOTICE | Files with permissions `666`/`777`. |

## State directory layout

Baselines and reports are stored in a folder called `baselines_reports`, created **at the same
level as the script**. Inside it there is one subfolder per site, named after the site path
passed on the command line (resolved to an absolute path) with every `/` replaced by `_`.

If the script is installed in `/opt/wp-security-check/` and you monitor two sites:

```bash
/opt/wp-security-check/wp-security-check.sh /var/www/site1 --env /opt/wp-security-check/mysite.env
/opt/wp-security-check/wp-security-check.sh /var/www/site2 --env /opt/wp-security-check/mysite.env
```

the result is:

```
/opt/wp-security-check/
├── wp-security-check.sh
├── mysite.env
└── baselines_reports/
    ├── _var_www_site1/    <- /var/www/site1
    │   ├── admins.base
    │   ├── cron.base
    │   ├── dbinject.base
    │   ├── hashes.base
    │   ├── inventory.base
    │   ├── lock
    │   ├── options.base
    │   ├── suspicious.base
    │   └── reports/
    │       ├── 2026-10-30_0315.txt
    │       ├── 2026-10-31_0315.txt
    │       └── 2026-11-01_0315.txt
    └── _var_www_site2/    <- /var/www/site2
        ├── admins.base
        ├── ...
        └── reports/
            └── 2026-10-30_0330.txt
```

The script can be installed in any directory; only the position of the script matters.
If it is in `/srv/tools/wpcheck/`, the folder is `/srv/tools/wpcheck/baselines_reports/`.

| File | Content |
|------|---------|
| `admins.base` | Administrator users (`ID,user_login,user_email`). |
| `options.base` | The critical options as `name=value` lines. |
| `hashes.base` | SHA-256 hashes of the critical files. |
| `suspicious.base` | Files already known to match the web shell patterns. |
| `dbinject.base` | IDs of posts already known to contain suspicious content. |
| `cron.base` | WordPress cron hooks. Only created when the site has cron events. |
| `inventory.base` | Plugins and themes as `plugin,<name>,<status>,<version>` / `theme,...`. Only created when the list is not empty. |
| `lock` | Lock file used by `flock`. Prevents two simultaneous runs on the same site. |
| `reports/` | One text report per run. Reports older than 30 days are deleted automatically. |

Notes:

- Different sites never share files, so they can run at the same time. A second run on the *same* site while one is in progress exits quietly with code 0.
- The name of the folder is the full site path, so `/a/b_c` and `/a_b/c` would map to the same folder. This is unlikely for real sites, but keep it in mind.
- The folder must be writable by whoever runs the script (root, or the site owner). If you run the same site sometimes as root and sometimes as the owner, make sure both can write there (`chown -R` to the user you use).

## Reports

Each run writes `reports/<YYYY-MM-DD_HHMM>.txt`, prints it to standard output, and (if
configured) sends it through Telegram.

Clean site:

```
WordPress security check: https://www.example.com
Host: web01 | Date: 2026-11-01 03:15:07 CET | Path: /var/www/site1
Result: 0 ALERT, 0 NOTICE

No anomalies detected.
```

Site with findings:

```
WordPress security check: https://www.example.com
Host: web01 | Date: 2026-11-01 03:15:09 CET | Path: /var/www/site1
Result: 2 ALERT, 2 NOTICE

=== ALERT (check immediately) ===
- Executable PHP files inside uploads (there should be none):
/var/www/site1/wp-content/uploads/2026/10/cache.php

- Administrator users: changed compared to the baseline
--- baseline
+++ current
@@ -1,2 +1,3 @@
 1,admin,admin@example.com
 2,editor,editor@example.com
+7,support22,support22@mailinator.com

=== NOTICE (to review) ===
- Updates available (known vulnerabilities are the main cause of intrusions):
Plugins:
name,version,update_version
contact-form-7,5.9.3,5.9.8

- PHP files modified in the last 25 hours (normal after an update, suspicious otherwise):
/var/www/site1/wp-content/plugins/contact-form-7/wp-contact-form-7.php

=== INFO ===
- Baseline created/updated: Administrator users
```

Sections:

- **ALERT**: needs immediate attention.
- **NOTICE**: should be reviewed.
- **INFO**: informational (for example, a baseline was created).

## First run and `--init`

A baseline is created automatically the first time a check runs without one:

- For checks that compare the full state (administrators, options, critical hashes, cron, inventory), the baseline is stored and an **INFO** line is added. Nothing is reported as a change.
- For checks that report only new items (web shell patterns, database injection), the baseline is stored, and if it is not empty the items are listed as a **NOTICE** (up to 30) that you should review by hand: anything already on the site at that moment becomes "accepted".

Because of this, **run the first execution only on a site you trust to be clean**.

Use `--init` to rebuild every baseline from the current state. Do this deliberately, for example
after you legitimately added an administrator, changed `wp-config.php` or installed a plugin
you want to accept:

```bash
/opt/wp-security-check/wp-security-check.sh /var/www/site1 --env /opt/wp-security-check/mysite.env --init
```

Without `--init`, a legitimate change is reported on every run until you rebuild the baseline.

## Telegram notifications

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy the token.
2. Send a message to the bot (or add it to a group/channel) and find the chat ID.
3. Put both values in the env file.

Behavior:

- **At least one ALERT**: a summary message is sent (site URL, host, counts, the first 10 ALERT titles), followed by the full report as an attached document. The script then exits with code 1.
- **No ALERT**: a one-line message is sent only if `SEND_ALWAYS` is `1` (the default):
  `✅ WordPress https://www.example.com on web01: 2 NOTICE, no ALERT.`
- Messages are cut at 3900 characters (Telegram's limit is 4096).
- The token is passed to `curl` through standard input, so it never appears in the process list.
- If Telegram is not configured or a call fails, the error goes to standard error and the report on disk is not affected.

Example alert message:

```
🚨 WordPress https://www.example.com
Host: web01
2 ALERT, 2 NOTICE

• Executable PHP files inside uploads (there should be none):
• Administrator users: changed compared to the baseline

Details in the attached file.
```

## Running from cron

Cron has a minimal environment, so use absolute paths. The script finds its own location, so
the working directory does not matter. Because `PATH` is also reduced under cron, set
[`WP_EXECUTABLE_PATH`](#the-env-file) in the env file if `wp` or `php` are installed in a
non-standard directory (or set `WP_BIN` to the full path of WP-CLI).

Run as root (recommended: one crontab, many sites, WP-CLI automatically runs as each site owner):

```cron
# every day at 03:15 and 03:30
15 3 * * * /opt/wp-security-check/wp-security-check.sh /var/www/site1 --env /opt/wp-security-check/mysite.env >/dev/null 2>&1
30 3 * * * /opt/wp-security-check/wp-security-check.sh /var/www/site2 --env /opt/wp-security-check/mysite.env >/dev/null 2>&1
```

Stagger the start times to avoid running many checks at the same moment.

Run as the site owner (`crontab -e` for that user): the script must then live somewhere the user
can write next to, because `baselines_reports/` is created beside it.

Output is discarded with `>/dev/null 2>&1` because reports are saved on disk and sent through
Telegram. If you prefer cron to email you, remove the redirection.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | No ALERT (there may be NOTICEs). Also used when another run on the same site is already in progress. |
| `1`  | At least one ALERT. |
| `2`  | Configuration or execution error (missing `--env`, invalid path, wrong user, no write permission, WP-CLI unusable, ...). |

This makes it easy to use the script in other tools:

```bash
if ! /opt/wp-security-check/wp-security-check.sh /var/www/site2 --env /opt/wp-security-check/mysite.env >/dev/null; then
  echo "problem on /var/www/site2 (exit code $?)"
fi
```

## Error messages

All of these exit with code 2.

| Message | Cause and fix |
|---------|---------------|
| `Error: --env <file> is required (see --help).` | `--env` was not passed. |
| `Error: --env requires a file.` | `--env` was passed without a value. |
| `Error: env file not found or not readable (<path>).` | Wrong path or permissions on the env file. |
| `Error: pass the WordPress path (the folder containing wp-includes) as an argument.` | Missing argument, or the folder does not contain `wp-includes`. |
| `Error: wp-cli not found (<WP_BIN>).` | Install WP-CLI or set `WP_BIN` in the env file. |
| `Error: invalid site owner (root): wp commands must not be run as root.` | The files of the site belong to `root`. Change the owner to the real site user. |
| `Error: the script must be run by root or by the site owner (<user>), not by <other>.` | Run it as root or as `<user>`. |
| `Error: neither runuser nor sudo found: cannot run wp as <user>.` | The script was started as root but neither `runuser` nor `sudo` is available, so it cannot switch to the site owner. Install one of them, or make sure its directory is in `WP_EXECUTABLE_PATH`. |
| `Error: no write permission on <dir> (user: <user>).` | The user running the script cannot write in `baselines_reports/`. Fix ownership or permissions. |
| `Error: user <user> cannot run <WP_BIN>: ...` | The site owner cannot execute WP-CLI (path, permissions, PHP). The WP-CLI output is shown. |

## Security notes

- Keep the env file readable only by the user that runs the script (`chmod 600`).
- Run `--init` only on a site you know is clean; an infected site would be accepted as the "normal" state.
- The baselines are as trustworthy as the machine that holds them. An attacker with write access to `baselines_reports/` could edit them, so do not make that folder writable by the site user if you run the script as root, or copy the reports off the server.
- WP-CLI never runs as root and never loads plugins or themes, so the checks do not execute code from a compromised site.
- This script detects suspicious changes; it does not clean or fix anything.

## Roadmap (`todo.md`)

[`todo.md`](todo.md) lists the work planned for the project: features that are not implemented
yet and improvements to existing behavior. It is a plain checklist (`- [ ]` = to do,
`- [x]` = done). It describes intentions only; nothing in it is available in the script until it is
moved to done and documented in this README.

Currently planned:

- more notification channels besides the Telegram bot (email and others);
- log rotation for the files in `reports/`.
