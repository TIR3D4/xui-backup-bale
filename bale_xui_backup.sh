#!/usr/bin/env bash

set -euo pipefail

INSTALL_PATH="/usr/local/bin/bale_xui_backup.sh"
CONFIG_FILE="/etc/bale_xui_backup.conf"
LOCK_FILE="/tmp/bale_xui_backup.lock"
LOG_FILE="/tmp/bale_xui_backup.log"

FILES=(
  "/etc/x-ui/x-ui.db"
  "/usr/local/x-ui/x-ui.db"
  "/etc/3x-ui/x-ui.db"
  "/usr/local/3x-ui/x-ui.db"
  "/opt/x-ui/x-ui.db"
  "/opt/3x-ui/x-ui.db"
)

line() {
  printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '-'
}

title() {
  clear 2>/dev/null || true
  line
  echo " Bale X-UI Backup Sender"
  line
  echo
}

info() {
  echo "[INFO] $1"
}

ok() {
  echo "[OK] $1"
}

warn() {
  echo "[WARN] $1"
}

error() {
  echo "[ERROR] $1"
}

pause_screen() {
  echo
  read -rp "Press Enter to continue..."
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Command not found: $1"
    error "This script does not install packages automatically."
    exit 1
  fi
}

read_required() {
  local prompt="$1"
  local value=""

  while true; do
    read -rp "$prompt" value
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
    warn "This field cannot be empty."
  done
}

read_backup_name() {
  local value=""

  while true; do
    read -rp "Enter backup file name, example xui_backup: " value

    if [ -z "$value" ]; then
      warn "This field cannot be empty."
      continue
    fi

    if [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
      printf '%s' "$value"
      return 0
    fi

    warn "Use only English letters, numbers, dot, dash or underscore."
  done
}

read_interval() {
  local value=""

  while true; do
    read -rp "Run every how many minutes? [1-59]: " value

    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 59 ]; then
      printf '%s' "$value"
      return 0
    fi

    warn "Please enter a number between 1 and 59."
  done
}

install_self() {
  local current_source=""

  if [ "$(id -u)" -ne 0 ]; then
    error "Please run this script as root or with sudo."
    exit 1
  fi

  current_source="${BASH_SOURCE[0]}"

  if [ -f "$current_source" ]; then
    if [ "$(readlink -f "$current_source" 2>/dev/null || echo "$current_source")" != "$INSTALL_PATH" ]; then
      cat "$current_source" > "$INSTALL_PATH"
      chmod +x "$INSTALL_PATH"
      ok "Script installed to: $INSTALL_PATH"
    else
      chmod +x "$INSTALL_PATH"
    fi
  else
    error "Cannot detect script source."
    error "Please save this script as a file and run it again."
    exit 1
  fi
}

save_config() {
  local bot_token="$1"
  local chat_id="$2"
  local backup_name="$3"

  cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN='$bot_token'
CHAT_ID='$chat_id'
BACKUP_NAME='$backup_name'
EOF

  chmod 600 "$CONFIG_FILE"
}

show_config() {
  title

  if [ ! -f "$CONFIG_FILE" ]; then
    warn "Config file not found."
    echo
    echo "Run setup first."
    return 0
  fi

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  echo "Current configuration:"
  echo
  echo "Bot token   : ${BOT_TOKEN:0:8}********"
  echo "Chat ID     : $CHAT_ID"
  echo "Backup name : $BACKUP_NAME"
  echo "Config file : $CONFIG_FILE"
  echo "Log file    : $LOG_FILE"
  echo "Run file    : $INSTALL_PATH"
}

install_cron() {
  require_command crontab
  require_command zip
  require_command curl
  require_command flock

  title

  echo "Setup wizard"
  echo
  echo "This wizard will ask for:"
  echo "  1) Bale bot token"
  echo "  2) Destination chat ID"
  echo "  3) Backup file name"
  echo "  4) Cron interval in minutes"
  echo

  BOT_TOKEN="$(read_required "Enter Bale bot token: ")"
  echo
  CHAT_ID="$(read_required "Enter destination CHAT_ID: ")"
  echo
  BACKUP_NAME="$(read_backup_name)"
  echo
  INTERVAL_MINUTES="$(read_interval)"
  echo

  install_self
  save_config "$BOT_TOKEN" "$CHAT_ID" "$BACKUP_NAME"

  if [ "$INTERVAL_MINUTES" -eq 1 ]; then
    CRON_TIME="* * * * *"
  else
    CRON_TIME="*/${INTERVAL_MINUTES} * * * *"
  fi

  CRON_LINE="${CRON_TIME} /usr/bin/env bash ${INSTALL_PATH} --run >${LOG_FILE} 2>&1"
  CURRENT_CRON="$(crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | grep -v "bale_xui_backup.sh" || true)"

  {
    echo "$CURRENT_CRON"
    echo "$CRON_LINE"
  } | crontab -

  ok "Cron job has been enabled."
  echo
  echo "Interval    : every $INTERVAL_MINUTES minute(s)"
  echo "Config file : $CONFIG_FILE"
  echo "Log file    : $LOG_FILE"
  echo "Run file    : $INSTALL_PATH"
  echo
}

run_backup() {
  require_command zip
  require_command curl
  require_command flock

  if [ ! -f "$CONFIG_FILE" ]; then
    error "Config file not found. Run setup first with --install."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  exec 200>"$LOCK_FILE"
  flock -n 200 || {
    warn "Another backup process is already running."
    exit 0
  }

  BACKUP_DIR="/tmp"
  NOW="$(date '+%Y-%m-%d %H:%M:%S')"
  SAFE_DATE="$(date '+%Y-%m-%d_%H-%M-%S')"
  ZIP_FILE="${BACKUP_DIR}/${BACKUP_NAME}_${SAFE_DATE}.zip"

  EXISTING_FILES=()

  for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
      EXISTING_FILES+=("$file")
    fi
  done

  if [ "${#EXISTING_FILES[@]}" -eq 0 ]; then
    error "No x-ui.db files found."
    exit 1
  fi

  info "Creating zip file..."
  zip -j "$ZIP_FILE" "${EXISTING_FILES[@]}" >/dev/null

  CAPTION="Backup file: ${BACKUP_NAME}
Date: ${NOW}"

  info "Uploading backup to Bale..."

  RESPONSE="$(curl -s -X POST "https://tapi.bale.ai/bot${BOT_TOKEN}/sendDocument" \
    -F "chat_id=${CHAT_ID}" \
    -F "document=@${ZIP_FILE}" \
    -F "caption=${CAPTION}")"

  echo "$RESPONSE"

  if echo "$RESPONSE" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    rm -f "$ZIP_FILE"
    ok "Upload successful."
    ok "Zip file removed: $ZIP_FILE"
  else
    error "Upload failed."
    warn "Zip file was not removed: $ZIP_FILE"
    exit 1
  fi
}

uninstall_cron() {
  require_command crontab

  title

  CURRENT_CRON="$(crontab -l 2>/dev/null | grep -v "$INSTALL_PATH" | grep -v "bale_xui_backup.sh" || true)"
  echo "$CURRENT_CRON" | crontab -

  ok "Cron job has been removed."
}

show_menu() {
  while true; do
    title

    echo "Choose an option:"
    echo
    echo "  1) Setup or update cron job"
    echo "  2) Run backup now"
    echo "  3) Show current config"
    echo "  4) Show last log"
    echo "  5) Remove cron job"
    echo "  0) Exit"
    echo

    read -rp "Select option: " choice

    case "$choice" in
      1)
        install_cron
        pause_screen
        ;;
      2)
        title
        run_backup
        pause_screen
        ;;
      3)
        show_config
        pause_screen
        ;;
      4)
        title
        if [ -f "$LOG_FILE" ]; then
          cat "$LOG_FILE"
        else
          warn "Log file not found."
        fi
        pause_screen
        ;;
      5)
        uninstall_cron
        pause_screen
        ;;
      0)
        echo "Bye."
        exit 0
        ;;
      *)
        warn "Invalid option."
        pause_screen
        ;;
    esac
  done
}

case "${1:-}" in
  --install)
    install_cron
    ;;
  --run)
    run_backup
    ;;
  --uninstall)
    uninstall_cron
    ;;
  --config)
    show_config
    ;;
  --menu|"")
    show_menu
    ;;
  *)
    echo "Usage:"
    echo "  $0              Open menu"
    echo "  $0 --menu       Open menu"
    echo "  $0 --install    Setup or update cron job"
    echo "  $0 --run        Run backup manually"
    echo "  $0 --config     Show current config"
    echo "  $0 --uninstall  Remove cron job"
    exit 1
    ;;
esac
