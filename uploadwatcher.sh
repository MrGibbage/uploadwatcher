#!/bin/bash

#############################################
# Configuration
#############################################

BASE_DIR="$(dirname "$0")"
ENV_FILE="$BASE_DIR/.env"

if [[ ! -r "$ENV_FILE" ]]; then
    echo "Missing or unreadable .env at $ENV_FILE" >&2
    exit 1
fi

source "$ENV_FILE"

WATCH_DIR="/volume1/Uploads"
LOG_FILE="/var/log/uploadwatcher.log"
LOG_TO_STDOUT="${LOG_TO_STDOUT:-0}"

# Textbelt API
TEXTBELT_URL="https://textbelt.com/text"
TEXTBELT_KEY="$TEXTBELT_KEY"

# Recipients (comma-separated list in .env)
parse_recipients() {
    local raw="$SMS_TO_NUMBERS"
    SMS_RECIPIENTS=()

    if [[ -z "$raw" ]]; then
        log "WARN" "SMS_TO_NUMBERS is empty; no SMS will be sent"
        return
    fi

    IFS=',' read -ra SMS_RECIPIENTS <<< "$raw"

    # Trim whitespace and drop empties
    local cleaned=()
    for num in "${SMS_RECIPIENTS[@]}"; do
        # ltrim
        num="${num#${num%%[![:space:]]*}}"
        # rtrim
        num="${num%${num##*[![:space:]]}}"
        [[ -n "$num" ]] && cleaned+=("$num")
    done
    SMS_RECIPIENTS=("${cleaned[@]}")
}

# Admin number for alerts
ADMIN_NUMBER="$ADMIN_NUMBER"

# Rate limiting (sliding window)
RATE_LIMIT_MAX=20
RATE_LIMIT_WINDOW_SECONDS=60
RATE_LIMIT_STATE="$BASE_DIR/state/uploadwatcher.rate"

# State file to avoid duplicate notifications across restarts
STATE_FILE="$BASE_DIR/state/uploadwatcher.state"

#############################################
# Logging
#############################################

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$ts] [$level] $msg"
    echo "$line" >> "$LOG_FILE"
    if [[ "$LOG_TO_STDOUT" == "1" ]]; then
        echo "$line"
    fi
}

#############################################
# Ensure required files exist
#############################################

ensure_files() {
    mkdir -p "$(dirname "$STATE_FILE")"
    mkdir -p "$(dirname "$RATE_LIMIT_STATE")"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    touch "$STATE_FILE"
    touch "$LOG_FILE"
    touch "$RATE_LIMIT_STATE"
}

validate_config() {
    local missing=()

    [[ -z "$TEXTBELT_KEY" ]] && missing+=("TEXTBELT_KEY")
    [[ -z "$ADMIN_NUMBER" ]] && missing+=("ADMIN_NUMBER")
    [[ -z "$WATCH_DIR" ]] && missing+=("WATCH_DIR")

    if (( ${#missing[@]} > 0 )); then
        echo "Missing required config: ${missing[*]}" >&2
        exit 1
    fi
}

#############################################
# Rate limiting (sliding window)
#############################################

rate_allow() {
    local now count window_start
    now=$(date +%s)

    if [[ ! -s "$RATE_LIMIT_STATE" ]]; then
        echo "$now 1" > "$RATE_LIMIT_STATE"
        return 0
    fi

    read -r window_start count < "$RATE_LIMIT_STATE"

    if (( now - window_start >= RATE_LIMIT_WINDOW_SECONDS )); then
        echo "$now 1" > "$RATE_LIMIT_STATE"
        return 0
    fi

    if (( count < RATE_LIMIT_MAX )); then
        count=$((count + 1))
        echo "$window_start $count" > "$RATE_LIMIT_STATE"
        return 0
    fi

    return 1
}

#############################################
# State tracking
#############################################

has_been_processed() {
    local filepath="$1"
    grep -Fxq "$filepath" "$STATE_FILE"
}

mark_processed() {
    local filepath="$1"
    echo "$filepath" >> "$STATE_FILE"
    log "DEBUG" "Marked processed: $filepath"
}

#############################################
# Admin alert
#############################################

send_admin_alert() {
    local msg="$1"

    curl -s -X POST "$TEXTBELT_URL" \
        -d "phone=${ADMIN_NUMBER}" \
        -d "message=ADMIN ALERT: ${msg}" \
        -d "key=${TEXTBELT_KEY}" >/dev/null 2>&1

    log "WARN" "Admin alert sent: $msg"
}

#############################################
# SMS sending with JSON monitoring
#############################################

send_sms() {
    local message="$1"

    if (( ${#SMS_RECIPIENTS[@]} == 0 )); then
        log "WARN" "No recipients configured; skipping SMS send"
        return 0
    fi

    if ! rate_allow; then
        log "WARN" "Rate limit exceeded; skipping SMS: $message"
        return 0
    fi

    for number in "${SMS_RECIPIENTS[@]}"; do

        RESPONSE=$(curl -s -X POST "$TEXTBELT_URL" \
            --data-urlencode phone="$number" \
            --data-urlencode message="$message" \
            --data key="$TEXTBELT_KEY")

        log "DEBUG" "Raw Textbelt response: $RESPONSE"

        SUCCESS=$(echo "$RESPONSE" | sed -n 's/.*"success":[ ]*\([^,}]*\).*/\1/p' | tr -d ' ')
        QUOTA=$(echo "$RESPONSE" | sed -n 's/.*"quotaRemaining":[ ]*\([0-9]*\).*/\1/p')
        ERROR_MSG=$(echo "$RESPONSE" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')

        if [[ "$SUCCESS" == "true" ]]; then
            log "INFO" "SMS sent to $number (quota remaining: ${QUOTA:-unknown})"
        else
            log "ERROR" "SMS failure to $number: ${ERROR_MSG:-unknown}"
            send_admin_alert "SMS failure to $number: ${ERROR_MSG:-unknown}"
        fi
    done
}

#############################################
# Main watcher loop (event-driven)
#############################################

start_watcher() {
    if ! command -v inotifywait >/dev/null 2>&1; then
        echo "inotifywait is required but not found in PATH" >&2
        exit 1
    fi

    validate_config
    ensure_files
    parse_recipients
    log "INFO" "UploadWatcher started on $WATCH_DIR"

    # Use moved_to because Synology finalizes uploads with MOVED_TO
    inotifywait -m -e moved_to --format '%w%f' "$WATCH_DIR" | while read FILE
    do
        # Debounce: allow Synology to complete any double-move behavior
        sleep 0.5

        # Ignore Synology temp files if they somehow slip through
        if [[ "$FILE" == *".syno_tmp"* ]]; then
            continue
        fi

        [[ -f "$FILE" ]] || {
            continue
        }

        # Deduplicate: if we've already handled this file, bail out early
        if has_been_processed "$FILE"; then
            continue
        fi

        # Mark as processed BEFORE any logging/SMS to prevent duplicates
        mark_processed "$FILE"

        log "DEBUG" "inotify event received for: $FILE"

        BASENAME=$(basename "$FILE")
        UPLOADER=$(stat -c %U "$FILE" 2>/dev/null || echo "unknown")
        MESSAGE="New upload from ${UPLOADER}: ${BASENAME}"

        log "INFO" "Detected new file: $FILE (uploader: $UPLOADER)"

        send_sms "$MESSAGE"

    done
}

#############################################
# Entrypoint
#############################################

start_watcher
