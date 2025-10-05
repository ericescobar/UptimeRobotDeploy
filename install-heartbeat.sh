#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'EOF'
install-heartbeat.sh — Create an UptimeRobot Heartbeat monitor and install cron (for the invoking user)

Usage:
  ./install-heartbeat.sh --api-key APIKEY --name "Friendly Name" --email EMAIL [options]

Required flags:
  --api-key           UptimeRobot Main API key
  --name              Friendly name for the new monitor
  --email             Email address of an existing alert contact to attach

Optional flags:
  --app-id ID         Add App (mobile push) alert contact by ID (fail if not found)
  --app-name NAME     Add App contact whose friendly_name contains NAME (case-insensitive; fail if not found)
  --interval SECONDS  Heartbeat interval in SECONDS (default: 60 if omitted)
  --grace SECONDS     Grace period in SECONDS (default: 300 if omitted)
  --list-contacts     Print available alert contacts (ID, type, friendly_name, value) and exit
  -h, --help          Show this help and exit

Notes:
  • For heartbeat monitors, INTERVAL and GRACE are specified in SECONDS.
  • If your plan enforces minimums (e.g., interval >= 30), pass a compliant value (e.g., --interval 60).
  • Cron will be installed for the user who launched the script. If run via sudo, it will target SUDO_USER.
EOF
}

# ---- defaults (SECONDS) ----
API_KEY=""; FRIENDLY_NAME=""; EMAIL_ADDR=""
APP_ID=""; APP_NAME=""
INTERVAL_SEC=""; GRACE_SEC=""
LIST_ONLY="0"

# ---- parse args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help; exit 0;;
    --list-contacts) LIST_ONLY="1"; shift ;;
    --api-key) API_KEY="$2"; shift 2;;
    --name) FRIENDLY_NAME="$2"; shift 2;;
    --email) EMAIL_ADDR="$2"; shift 2;;
    --app-id) APP_ID="$2"; shift 2;;
    --app-name) APP_NAME="$2"; shift 2;;
    --interval) INTERVAL_SEC="$2"; shift 2;;
    --grace) GRACE_SEC="$2"; shift 2;;
    *) echo "ERROR: Unknown flag $1" >&2; exit 2;;
  esac
done

# Fill defaults if not provided
: "${INTERVAL_SEC:=60}"
: "${GRACE_SEC:=300}"

if [[ -z "$API_KEY" || -z "$FRIENDLY_NAME" || -z "$EMAIL_ADDR" ]]; then
  echo "ERROR: --api-key, --name, and --email are required." >&2
  exit 2
fi
if [[ -n "$APP_ID" && -n "$APP_NAME" ]]; then
  echo "ERROR: Use only one of --app-id or --app-name (not both)." >&2
  exit 2
fi

# ---- target user detection (install cron for the invoking user) ----
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="${USER:-$(id -un)}"
fi
if [[ -z "${TARGET_USER}" ]]; then
  echo "ERROR: Could not determine target user for crontab." >&2
  exit 1
fi

# ---- prerequisites via apt ----
need_pkg() {
  local bin="$1" pkg="${2:-$1}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null
      sudo apt-get install -y "$pkg" >/dev/null
    else
      echo "ERROR: '$bin' not found and apt-get is unavailable. Please install '$pkg'." >&2
      exit 1
    fi
  fi
}
need_pkg curl curl
need_pkg jq jq
need_pkg crontab cron || true

# Ensure cron running
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable cron >/dev/null 2>&1 || sudo systemctl enable crond >/dev/null 2>&1 || true
  sudo systemctl start  cron  >/dev/null 2>&1 || sudo systemctl start  crond  >/dev/null 2>&1 || true
elif command -v service >/dev/null 2>&1; then
  sudo service cron start >/dev/null 2>&1 || true
fi

# ---- absolute curl path for cron ----
CURL_BIN="$(command -v curl || true)"
if [[ -z "$CURL_BIN" ]]; then
  echo "ERROR: curl not found on PATH" >&2
  exit 1
fi

# ---- API helpers (v2) ----
api_v2() {
  local endpoint="$1"; shift
  curl -sS -X POST "https://api.uptimerobot.com/v2/${endpoint}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "api_key=${API_KEY}" "$@"
}
err_if_not_ok() {
  local resp="$1"
  local stat; stat=$(echo "$resp" | jq -r '.stat? // .status? // empty')
  if [[ "$stat" != "ok" && "$stat" != "OK" ]]; then
    echo "ERROR: API call failed: $(echo "$resp" | jq -c .)" >&2
    exit 1
  fi
}

# ---- fetch alert contacts ----
contacts_json=$(api_v2 getAlertContacts --data-urlencode "format=json")
err_if_not_ok "$contacts_json"
contacts_list=$(echo "$contacts_json" | jq -c '(.alert_contacts // .data.alert_contacts // [])')

if [[ "$LIST_ONLY" == "1" ]]; then
  echo "Alert Contacts (available):"
  echo "$contacts_list" | jq -r '.[] | "\(.id)\t\(.type)\t\(.friendly_name // "")\t\(.value // "")"'
  exit 0
fi

# ---- resolve required email contact ----
EMAIL_ID=$(
  echo "$contacts_list" | jq -r --arg em "$EMAIL_ADDR" '
    map(select(.value == $em)) | .[0].id // empty'
)
if [[ -z "$EMAIL_ID" ]]; then
  echo "ERROR: Email alert contact '$EMAIL_ADDR' not found. Create it in UptimeRobot first." >&2
  exit 1
fi

# ---- resolve optional App contact ----
ATTACH_APP_ID=""
if [[ -n "$APP_ID" ]]; then
  found=$(
    echo "$contacts_list" | jq -r --arg id "$APP_ID" '
      map(select((.id|tostring) == $id)) | length'
  )
  if [[ "$found" == "0" ]]; then
    echo "ERROR: --app-id '$APP_ID' not found in alert contacts." >&2
    exit 1
  fi
  ATTACH_APP_ID="$APP_ID"
elif [[ -n "$APP_NAME" ]]; then
  ATTACH_APP_ID=$(
    echo "$contacts_list" | jq -r --arg n "$APP_NAME" '
      map(select((.friendly_name // "") | ascii_downcase | contains($n|ascii_downcase))) | .[0].id // empty'
  )
  if [[ -z "$ATTACH_APP_ID" ]]; then
    echo "ERROR: --app-name '$APP_NAME' did not match any alert contact friendly_name." >&2
    exit 1
  fi
fi

# ---- build alert_contacts param ----
ALERT_CONTACTS="${EMAIL_ID}_0_0"
if [[ -n "$ATTACH_APP_ID" ]]; then
  ALERT_CONTACTS="${ALERT_CONTACTS}-${ATTACH_APP_ID}_0_0"
fi

# ---- create new heartbeat monitor (interval/grace in SECONDS) ----
create_resp=$(
  api_v2 newMonitor \
    --data-urlencode "type=5" \
    --data-urlencode "friendly_name=${FRIENDLY_NAME}" \
    --data-urlencode "interval=${INTERVAL_SEC}" \
    --data-urlencode "grace=${GRACE_SEC}" \
    --data-urlencode "alert_contacts=${ALERT_CONTACTS}" \
    --data-urlencode "format=json"
)
err_if_not_ok "$create_resp"

MONITOR_ID=$(echo "$create_resp" | jq -r '.monitor.id // .data.monitor.id // .id // empty')
if [[ -z "$MONITOR_ID" ]]; then
  echo "ERROR: Could not read new monitor ID from API response: $(echo "$create_resp" | jq -c .)" >&2
  exit 1
fi

# ---- fetch the heartbeat URL for this monitor ----
mon_resp=$(
  api_v2 getMonitors \
    --data-urlencode "monitors=${MONITOR_ID}" \
    --data-urlencode "format=json"
)
err_if_not_ok "$mon_resp"

HEARTBEAT_URL=$(
  echo "$mon_resp" | jq -r '
    (.monitors // .data.monitors // []) | .[0] | (.heartbeat_url // .url // "")' \
  | grep -Eo 'https?://heartbeat\.uptimerobot\.com/[A-Za-z0-9-]+' | head -n1
)
if [[ -z "$HEARTBEAT_URL" ]]; then
  echo "ERROR: Could not determine the heartbeat URL for monitor ${MONITOR_ID}." >&2
  exit 1
fi

# ---- initial ping after 5 seconds ----
sleep 5
"${CURL_BIN}" -fsS --max-time 10 "${HEARTBEAT_URL}" >/dev/null || {
  echo "ERROR: Initial heartbeat ping failed for ${HEARTBEAT_URL}" >&2
  exit 1
}

# ---- install cron for the invoking user (robust, no pipefail issues) ----
TAG="# UptimeRobot Heartbeat (${MONITOR_ID})"
CRON_LINE="* * * * * ${CURL_BIN} -fsS --retry 2 --max-time 10 \"${HEARTBEAT_URL}\" >/dev/null 2>&1 ${TAG}"

# Decide which crontab command to use
CRON_LIST_CMD=()
CRON_INSTALL_CMD=()
if [[ "$(id -u)" -eq 0 ]]; then
  # running as root -> can write to SUDO_USER (or USER if no sudo used)
  CRON_LIST_CMD=(crontab -u "$TARGET_USER" -l)
  CRON_INSTALL_CMD=(crontab -u "$TARGET_USER" -)
else
  # running as normal user -> must use own crontab (no -u)
  CRON_LIST_CMD=(crontab -l)
  CRON_INSTALL_CMD=(crontab -)
fi

# Read existing (or empty if none), filter old tag, append new, install
existing="$("${CRON_LIST_CMD[@]}" 2>/dev/null || true)"
{
  printf "%s\n" "$existing" | grep -vF "$TAG" || true
  printf "%s\n" "$CRON_LINE"
} | "${CRON_INSTALL_CMD[@]}"

# ---- concise success output ----
if [[ -n "$ATTACH_APP_ID" ]]; then
  echo "Attached contacts: email(${EMAIL_ID}), app(${ATTACH_APP_ID})"
else
  echo "Attached contacts: email(${EMAIL_ID})"
fi
echo "Monitor created: ${MONITOR_ID}"
echo "Heartbeat URL: ${HEARTBEAT_URL}"
echo "Interval (s): ${INTERVAL_SEC} | Grace (s): ${GRACE_SEC}"
echo "Cron installed for user: ${TARGET_USER}"
echo "Heartbeat installed"
