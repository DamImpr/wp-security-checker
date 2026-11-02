#!/usr/bin/env bash
#
# wp-security-check.sh — daily check for possible intrusions on a WordPress site (via WP-CLI)
#
# Usage:
#   wp-security-check.sh <wordpress-path> --env <file> [--init]
#
#   <wordpress-path>  (required) folder containing wp-includes; it is only read from this argument
#   --env <file>      (required) env file to load; the script stops if it is missing, not passed or unreadable
#   --init            (re)create the baselines: use ONLY when you are sure the site is clean
#
# Examples:
#   wp-security-check.sh /var/www/mysite --env /path/to/mysite.env
#   wp-security-check.sh /var/www/mysite --env /path/to/mysite.env --init
#
# Variables read from the env file (chmod 600):
#   TELEGRAM_BOT_TOKEN   bot token (created with @BotFather)
#   TELEGRAM_CHAT_ID     ID of the chat/group/channel that receives the alerts
# Optional variables (same file):
#   SEND_ALWAYS   1 = also send a message when there are no ALERTs (default: 1)
#   WP_BIN        path to wp-cli (default: wp)
#   RECENT_MIN    "recently modified files" window, in minutes (default: 1500, about 25 hours)
#
# Must be run by root or by the user owning the site files. WP-CLI always runs as the site owner
# (discovered from the owner of wp-includes; root is switched to the site owner, anyone else runs wp directly).
#
# Baselines and reports are written next to this script, one folder per site:
#   <script-dir>/baselines_reports/<site path with "/" replaced by "_">/
#
# Cron (every day at 03:15), as root:
#   15 3 * * * /path/to/script/wp-security-check.sh /var/www/mysite --env /path/to/mysite.env >/dev/null 2>&1
#
# Exit codes: 0 = no ALERT, 1 = at least one ALERT, 2 = configuration/execution error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE=""

# --help must work without --env
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,/^$/{/^$/!s/^# \{0,1\}//p}' "$0"; exit 0 ;;
  esac
done

# --env <file> is mandatory and must be read before anything else
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --env)   ENV_FILE="${args[i+1]:-}"
             [[ -n "$ENV_FILE" ]] || { echo "Error: --env requires a file." >&2; exit 2; } ;;
    --env=*) ENV_FILE="${args[i]#--env=}" ;;
  esac
done
[[ -n "$ENV_FILE" ]] || { echo "Error: --env <file> is required (see --help)." >&2; exit 2; }
[[ -r "$ENV_FILE" ]] || { echo "Error: env file not found or not readable ($ENV_FILE)." >&2; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"

WP_EXECUTABLE_PATH="${WP_EXECUTABLE_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH="$WP_EXECUTABLE_PATH:${PATH:-}"

WP_BIN="${WP_BIN:-wp}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
SEND_ALWAYS="${SEND_ALWAYS:-1}"
RECENT_MIN="${RECENT_MIN:-1500}"
INIT=0
WP_PATH=""   # only from the argument, never from the env

skip=0
for arg in "$@"; do
  if (( skip )); then skip=0; continue; fi
  case "$arg" in
    --init)    INIT=1 ;;
    --env)     skip=1 ;;
    --env=*)   ;;
    *)         WP_PATH="$arg" ;;
  esac
done

if [[ -z "$WP_PATH" || ! -d "$WP_PATH/wp-includes" ]]; then
  echo "Error: pass the WordPress path (the folder containing wp-includes) as an argument." >&2
  exit 2
fi
WP_PATH="$(cd "$WP_PATH" && pwd)"
command -v "$WP_BIN" >/dev/null 2>&1 || { echo "Error: wp-cli not found ($WP_BIN)." >&2; exit 2; }

# WP-CLI always runs as the owner of the site files (not configurable)
WP_USER="$(stat -c %U "$WP_PATH/wp-includes")"
if [[ "$WP_USER" == "UNKNOWN" || "$WP_USER" == "root" ]]; then
  echo "Error: invalid site owner ($WP_USER): wp commands must not be run as root." >&2
  exit 2
fi
if [[ $EUID -ne 0 && "$(id -un)" != "$WP_USER" ]]; then
  echo "Error: the script must be run by root or by the site owner ($WP_USER), not by $(id -un)." >&2
  exit 2
fi
# When started as root, a user switch is needed: require runuser or sudo
if [[ $EUID -eq 0 ]] && ! command -v runuser >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
  echo "Error: neither runuser nor sudo found: cannot run wp as $WP_USER." >&2
  exit 2
fi

# --- State (baselines and reports) ---------------------------------------------
# Baselines and reports are centralized next to the script, one subfolder per site:
#   <script-dir>/baselines_reports/<site path with "/" -> "_">/
STATE_DIR="$SCRIPT_DIR/baselines_reports/${WP_PATH//\//_}"
mkdir -p "$STATE_DIR/reports" 2>/dev/null && [[ -w "$STATE_DIR" && -w "$STATE_DIR/reports" ]] \
  || { echo "Error: no write permission on $STATE_DIR (user: $(id -un))." >&2; exit 2; }

exec 9>"$STATE_DIR/lock" || { echo "Error: cannot create $STATE_DIR/lock." >&2; exit 2; }
flock -n 9 || { echo "Another instance is already running." >&2; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Helper ------------------------------------------------------------------
# WP-CLI runs as the site user (never as root) and with --skip-plugins/--skip-themes,
# so the checks do not execute code from potentially compromised plugins or themes.
wp_() {
  local -a cmd=("$WP_BIN" "--path=$WP_PATH" --skip-plugins --skip-themes --no-color "$@")
  if [[ $EUID -eq 0 ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$WP_USER" -- "${cmd[@]}"
    else
      sudo -u "$WP_USER" -- "${cmd[@]}"
    fi
  else
    "${cmd[@]}"
  fi
}

# The site owner must be able to run wp
wp_out="$(wp_ cli version 2>&1)" \
  || { echo "Error: user $WP_USER cannot run $WP_BIN: $wp_out" >&2; exit 2; }

ALERTS=(); NOTICES=(); INFOS=()
alert()  { ALERTS+=("$1"); }
notice() { NOTICES+=("$1"); }
info()   { INFOS+=("$1"); }

# Compare $WORK/<name>.txt with the baseline; any difference is reported.
baseline_diff() {
  local name="$1" sev="$2" label="$3"
  local cur="$WORK/$name.txt" base="$STATE_DIR/$name.base" d rc
  if [[ ! -f "$base" || $INIT -eq 1 ]]; then
    cp "$cur" "$base"
    info "Baseline created/updated: $label"
    return
  fi
  d="$(diff -u --label baseline --label current "$base" "$cur")"; rc=$?
  if (( rc == 1 )); then
    if [[ $sev == ALERT ]]; then alert "$label: changed compared to the baseline
$d"
    else notice "$label: changed compared to the baseline
$d"; fi
  fi
}

# Same as above, but reports only NEW lines (the current file must be sorted with sort -u).
baseline_new() {
  local name="$1" sev="$2" label="$3"
  local cur="$WORK/$name.txt" base="$STATE_DIR/$name.base" new
  if [[ ! -f "$base" || $INIT -eq 1 ]]; then
    cp "$cur" "$base"
    if [[ -s "$cur" ]]; then
      notice "$label: $(wc -l <"$cur") items present on first run (saved in the baseline). Review them manually:
$(head -n 30 "$cur")"
    else
      info "Baseline created: $label (no items)"
    fi
    return
  fi
  new="$(comm -13 "$base" "$cur")"
  if [[ -n "$new" ]]; then
    if [[ $sev == ALERT ]]; then alert "$label: new items
$(head -n 50 <<<"$new")"
    else notice "$label: new items
$(head -n 50 <<<"$new")"; fi
  fi
}

# --- Checks -----------------------------------------------------------------
check_core() {
  local out rc details
  out="$(wp_ core verify-checksums 2>&1)"; rc=$?
  if (( rc != 0 )); then
    details="$(grep -Ei "doesn't verify|should not exist|was added|doesn't exist" <<<"$out" | head -n 50)"
    [[ -z "$details" ]] && details="$(head -n 10 <<<"$out")"
    alert "WordPress core: checksum verification failed (modified/added files, or error)
$details"
  fi
}

check_plugin_checksums() {
  local out rc details
  out="$(wp_ plugin verify-checksums --all 2>&1)"; rc=$?
  details="$(grep -Ei "doesn't verify|should not exist|was added|doesn't exist" <<<"$out" | head -n 50)"
  if [[ -n "$details" ]]; then
    alert "Plugins: files differ from the official wordpress.org version
$details"
  elif (( rc != 0 )); then
    notice "Plugins: checksums cannot be verified for some plugins (premium/custom or not on wordpress.org)
$(head -n 10 <<<"$out")"
  fi
}

check_php_in_uploads() {
  local found
  found="$(find "$UPLOADS_DIR" -type f \( -iname '*.php' -o -iname '*.php[0-9]' -o -iname '*.phtml' -o -iname '*.phar' -o -iname '*.pht' \) 2>/dev/null | head -n 100)"
  [[ -n "$found" ]] && alert "Executable PHP files inside uploads (there should be none):
$found"
}

check_suspicious_code() {
  grep -rIlE --include='*.php' \
    -e 'eval[[:space:]]*\([[:space:]]*(base64_decode|gzinflate|gzuncompress|str_rot13)' \
    -e 'base64_decode[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)' \
    -e 'assert[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST)' \
    -e '(system|shell_exec|passthru|exec)[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)' \
    -e 'FilesMan|c99shell|r57shell' \
    "$CONTENT_DIR" "$WP_PATH/wp-includes" "$WP_PATH/wp-admin" 2>/dev/null | sort -u >"$WORK/suspicious.txt"
  baseline_new suspicious ALERT "PHP files with typical web shell/obfuscation patterns"
}

check_recent_php() {
  local recent
  recent="$(find "$WP_PATH" -type f -name '*.php' -mmin "-$RECENT_MIN" -not -path '*/cache/*' 2>/dev/null | sort | head -n 100)"
  [[ -n "$recent" ]] && notice "PHP files modified in the last $((RECENT_MIN / 60)) hours (normal after an update, suspicious otherwise):
$recent"
}

check_world_writable() {
  local ww
  ww="$(find "$WP_PATH" -type f -perm -0002 2>/dev/null | head -n 50)"
  [[ -n "$ww" ]] && notice "World-writable files (permissions 666/777):
$ww"
}

check_critical_hashes() {
  {
    local f
    for f in "$CONFIG_PATH" "$WP_PATH/.htaccess" "$WP_PATH/index.php" "$WP_PATH/.user.ini" \
             "$CONTENT_DIR/index.php" "$CONTENT_DIR/advanced-cache.php" "$CONTENT_DIR/db.php" "$CONTENT_DIR/object-cache.php"; do
      [[ -n "$f" && -f "$f" ]] && sha256sum "$f"
    done
    [[ -d "$CONTENT_DIR/mu-plugins" ]] && find "$CONTENT_DIR/mu-plugins" -type f -exec sha256sum {} +
  } 2>/dev/null | sort -k2 >"$WORK/hashes.txt"
  baseline_diff hashes ALERT "Critical files (wp-config, .htaccess, index.php, mu-plugins, drop-ins)"
}

check_admins() {
  wp_ user list --role=administrator --fields=ID,user_login,user_email --format=csv 2>/dev/null | sort >"$WORK/admins.txt"
  if [[ ! -s "$WORK/admins.txt" ]]; then
    notice "Unable to read the list of administrators."
    return
  fi
  baseline_diff admins ALERT "Administrator users"
}

check_options() {
  local o
  {
    for o in siteurl home admin_email users_can_register default_role; do
      printf '%s=%s\n' "$o" "$(wp_ option get "$o" 2>/dev/null)"
    done
  } >"$WORK/options.txt"
  baseline_diff options ALERT "Critical options (siteurl, home, admin_email, registration, default role)"
}

check_cron() {
  wp_ cron event list --fields=hook --format=csv 2>/dev/null | sort -u >"$WORK/cron.txt"
  [[ -s "$WORK/cron.txt" ]] && baseline_diff cron NOTICE "WordPress cron events (hooks)"
}

check_inventory() {
  {
    wp_ plugin list --fields=name,status,version --format=csv 2>/dev/null | sed 's/^/plugin,/'
    wp_ theme list --fields=name,status,version --format=csv 2>/dev/null | sed 's/^/theme,/'
  } | sort >"$WORK/inventory.txt"
  [[ -s "$WORK/inventory.txt" ]] && baseline_diff inventory NOTICE "Installed plugins and themes (name, status, version)"
}

check_updates() {
  local core plugins themes msg=""
  core="$(wp_ core check-update --format=csv 2>/dev/null | grep -v '^Success')"
  plugins="$(wp_ plugin list --update=available --fields=name,version,update_version --format=csv 2>/dev/null)"
  themes="$(wp_ theme list --update=available --fields=name,version,update_version --format=csv 2>/dev/null)"
  [[ -n "$core" ]]    && msg+="Core:
$core
"
  [[ -n "$plugins" ]] && msg+="Plugins:
$plugins
"
  [[ -n "$themes" ]]  && msg+="Themes:
$themes
"
  [[ -n "$msg" ]] && notice "Updates available (known vulnerabilities are the main cause of intrusions):
$msg"
}

check_db_injection() {
  local prefix
  prefix="$(wp_ db prefix 2>/dev/null)"
  if [[ -z "$prefix" ]]; then
    notice "Database content check skipped: unable to read the prefix or connect."
    return
  fi
  wp_ db query "SELECT ID FROM ${prefix}posts WHERE post_type <> 'revision' AND post_status IN ('publish','draft','private') AND post_content REGEXP '<script|<iframe|document[.]write|base64_decode|eval[(]' ORDER BY ID" \
    --skip-column-names 2>/dev/null | sort -u >"$WORK/dbinject.txt"
  baseline_new dbinject ALERT "Posts containing <script>/<iframe>/suspicious code (IDs)"
}

# --- Execution --------------------------------------------------------------
SITE_URL="$(wp_ option get siteurl 2>&1)"
if (( $? != 0 )); then
  alert "WP-CLI cannot read the site (database unreachable, wp-config tampered with, or PHP error):
$(head -n 10 <<<"$SITE_URL")"
  SITE_URL="(unknown)"
else
  CONTENT_DIR="$(wp_ eval 'echo WP_CONTENT_DIR;' 2>/dev/null | tail -n 1)"
  [[ -d "$CONTENT_DIR" ]] || CONTENT_DIR="$WP_PATH/wp-content"
  UPLOADS_DIR="$CONTENT_DIR/uploads"
  CONFIG_PATH="$(wp_ config path 2>/dev/null | tail -n 1)"

  check_core
  check_plugin_checksums
  check_php_in_uploads
  check_suspicious_code
  check_critical_hashes
  check_admins
  check_options
  check_db_injection
  check_cron
  check_inventory
  check_updates
  check_recent_php
  check_world_writable
fi

# --- Report ------------------------------------------------------------------
REPORT="$STATE_DIR/reports/$(date +%F_%H%M).txt"
{
  echo "WordPress security check: $SITE_URL"
  echo "Host: $(hostname) | Date: $(date '+%F %T %Z') | Path: $WP_PATH"
  echo "Result: ${#ALERTS[@]} ALERT, ${#NOTICES[@]} NOTICE"
  echo
  if (( ${#ALERTS[@]} )); then
    echo "=== ALERT (check immediately) ==="
    for m in "${ALERTS[@]}"; do printf -- '- %s\n\n' "$m"; done
  fi
  if (( ${#NOTICES[@]} )); then
    echo "=== NOTICE (to review) ==="
    for m in "${NOTICES[@]}"; do printf -- '- %s\n\n' "$m"; done
  fi
  if (( ${#INFOS[@]} )); then
    echo "=== INFO ==="
    for m in "${INFOS[@]}"; do printf -- '- %s\n' "$m"; done
  fi
  if (( ! ${#ALERTS[@]} && ! ${#NOTICES[@]} )); then
    echo "No anomalies detected."
  fi
} >"$REPORT"

cat "$REPORT"
find "$STATE_DIR/reports" -name '*.txt' -mtime +30 -delete 2>/dev/null

# Telegram API call. The token goes through stdin (curl -K -), so it does not show up in `ps`.
tg_api() {
  local method="$1" resp; shift
  resp="$(curl -sS --max-time 30 -K - "$@" <<<"url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${method}\"" 2>&1)"
  if [[ "$resp" != *'"ok":true'* ]]; then
    echo "Telegram ($method) failed: $resp" >&2
    return 1
  fi
}

send_telegram() {
  local text="$1" attach="${2:-}"
  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] || ! command -v curl >/dev/null 2>&1; then
    echo "Telegram not configured (token/chat id/curl missing): report saved in $REPORT" >&2
    return 1
  fi
  text="${text:0:3900}"   # Telegram limit: 4096 characters
  tg_api sendMessage --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$text" || return 1
  if [[ -n "$attach" ]]; then
    tg_api sendDocument -F "chat_id=$TELEGRAM_CHAT_ID" -F "document=@$attach" -F "caption=Full report" || true
  fi
}

alert_summary() {
  local m
  printf '🚨 WordPress %s\nHost: %s\n%s ALERT, %s NOTICE\n\n' "$SITE_URL" "$(hostname)" "${#ALERTS[@]}" "${#NOTICES[@]}"
  for m in "${ALERTS[@]:0:10}"; do printf -- '• %s\n' "${m%%$'\n'*}"; done
  (( ${#ALERTS[@]} > 10 )) && printf '…and %s more\n' "$(( ${#ALERTS[@]} - 10 ))"
  printf '\nDetails in the attached file.'
}

if (( ${#ALERTS[@]} )); then
  send_telegram "$(alert_summary)" "$REPORT"
  exit 1
elif [[ "$SEND_ALWAYS" == "1" ]]; then
  send_telegram "✅ WordPress ${SITE_URL} on $(hostname): ${#NOTICES[@]} NOTICE, no ALERT."
fi
exit 0
