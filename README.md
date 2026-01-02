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
# Bash array syntax for multiple recipients
SMS_TO_NUMBERS=(+15550001111 +15550002222)
```

Defaults in `uploadwatcher.sh`:
- `WATCH_DIR="/volume1/Uploads"`
- `LOG_FILE="/var/log/uploadwatcher.log"`
- State + rate limit files under `state/` (relative to the script directory).
- Rate limit: 20 messages per 60 seconds.

Ensure the `state/` directory exists and is writable by the user running the script.

## Running manually
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

## Git hygiene
- `.gitignore` already excludes `.env`, logs, and common junk.
- `.gitattributes` enforces LF endings (important when editing over SMB).
- If Git complains about an "unsafe repository" on your SMB/UNC path, allow it explicitly: `git config --global --add safe.directory '%(prefix)///PierHouseFiles/scripts/uploadwatcher'` (adjust the path if yours differs).

## Troubleshooting
- No SMS: check `TEXTBELT_KEY` validity and quota; inspect log for `Raw Textbelt response`.
- Duplicate alerts: ensure `state/` persists and is writable.
- Permission issues: verify the service user can read `WATCH_DIR` and write log/state paths.
