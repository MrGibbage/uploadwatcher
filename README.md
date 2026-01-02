# UploadWatcher

A tiny inotify-based watcher for Synology that texts you when new files land in a watched upload directory.

## What it does
- Watches a directory for `moved_to` events (Synology completes uploads with MOVED_TO).
- Logs activity to `/var/log/uploadwatcher.log`.
- Sends SMS via Textbelt with simple sliding-window rate limiting (default 20 msgs / 60s).
- Tracks processed files to avoid duplicate notifications across restarts.

## Requirements
- Synology (or any Linux) with `inotifywait` available (install `inotify-tools` if missing).
- `bash`, `curl`, and ability to reach https://textbelt.com.
- Writable paths for: `/var/log/uploadwatcher.log` and local `state/` directory.

## Configuration
Create a `.env` alongside the script. Example:

```bash
TEXTBELT_KEY=your_textbelt_key
ADMIN_NUMBER=+15551234567
# Comma-separated list for multiple recipients
SMS_TO_NUMBERS=+15550001111,+15550002222
```

Defaults in `uploadwatcher.sh`:
- `WATCH_DIR="/volume1/Uploads"`
- `LOG_FILE="/var/log/uploadwatcher.log"`
- Set `LOG_TO_STDOUT=1` in `.env` if you want logs echoed to the console in addition to the log file. Default is 0 to avoid double-logging when the service wraps the script with its own logging/tee.
 
 

```bash
bash uploadwatcher.sh
```
The watcher runs until stopped (Ctrl+C). Use `tail -f /var/log/uploadwatcher.log` to monitor.

## Service install (sketch)
Run under a service manager (systemd example):
1) Create a service file `/etc/systemd/system/uploadwatcher.service`:
   ```ini
   [Unit]
   Description=UploadWatcher
   After=network-online.target

   [Service]
   Type=simple
   WorkingDirectory=/path/to/uploadwatcher
   ExecStart=/bin/bash /path/to/uploadwatcher/uploadwatcher.sh
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   ```
2) `sudo systemctl daemon-reload`
3) `sudo systemctl enable --now uploadwatcher`

Adjust paths and user as needed for your Synology setup.

### Synology rc.d example
Place at `/usr/local/etc/rc.d/S99uploadwatcher.sh` (make executable):
```sh
#!/bin/sh

### BEGIN INIT INFO
# Provides:          uploadwatcher
# Required-Start:    $network
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Upload Watcher Service
### END INIT INFO

DAEMON="/volume1/scripts/uploadwatcher/uploadwatcher.sh"
WORKDIR="/volume1/scripts/uploadwatcher"
PIDFILE="/var/run/uploadwatcher.pid"
LOGFILE="/var/log/uploadwatcher.log"

start() {
   echo "Starting uploadwatcher..."

   if [ ! -d "$WORKDIR" ]; then
      echo "Workdir $WORKDIR not found" >&2
      exit 1
   fi

   cd "$WORKDIR" || exit 1
   mkdir -p "$(dirname "$PIDFILE")"
   mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
   : > "$LOGFILE"

   if [ -f "$PIDFILE" ]; then
      PGID=$(cat "$PIDFILE")
      if [ -n "$PGID" ] && kill -0 -"$PGID" 2>/dev/null; then
         echo "Already running."
         exit 0
      fi
   fi

   LOG_TO_STDOUT=0 nohup "$DAEMON" >> "$LOGFILE" 2>&1 &
   DAEMON_PID=$!
   PGID=$(ps -o pgid= "$DAEMON_PID" | tr -d ' ')
   echo "$PGID" > "$PIDFILE"
   echo "Started with PGID $PGID"
}

stop() {
   echo "Stopping uploadwatcher..."

   if [ -f "$PIDFILE" ]; then
      PGID=$(cat "$PIDFILE")
      if [ -n "$PGID" ]; then
         kill -TERM -"$PGID" 2>/dev/null
         sleep 1
         kill -KILL -"$PGID" 2>/dev/null
      fi
      rm -f "$PIDFILE"
      echo "Stopped."
   else
      echo "Not running."
   fi
}

status() {
   if [ -f "$PIDFILE" ]; then
      PGID=$(cat "$PIDFILE")
      if kill -0 -"$PGID" 2>/dev/null; then
         echo "uploadwatcher is running (PGID $PGID)"
         return
      fi
   fi
   echo "uploadwatcher is not running"
}

case "$1" in
   start) start ;;
   stop) stop ;;
   restart) stop; sleep 1; start ;;
   status) status ;;
   *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
```

## Git hygiene
- `.gitignore` already excludes `.env`, logs, and common junk.
- `.gitattributes` enforces LF endings (important when editing over SMB).
- If Git complains about an "unsafe repository" on your SMB/UNC path, allow it explicitly: `git config --global --add safe.directory '%(prefix)///PierHouseFiles/scripts/uploadwatcher'` (adjust the path if yours differs).

## Troubleshooting
- No SMS: check `TEXTBELT_KEY` validity and quota; inspect log for `Raw Textbelt response`.
- Duplicate alerts: ensure `state/` persists and is writable.
- Permission issues: verify the service user can read `WATCH_DIR` and write log/state paths.
