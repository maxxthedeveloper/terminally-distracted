#!/bin/bash
# Block social media sites via /etc/hosts

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITES_FILE="$SCRIPT_DIR/sites.txt"
REBLOCK_PID_FILE="/tmp/terminally-distracted-reblock.pid"

# If an unblock window is active (reblock timer alive), don't re-block
if [ -f "$REBLOCK_PID_FILE" ]; then
  read -r OLD_PID _ < "$REBLOCK_PID_FILE"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Skipping: unblock window active." >&2
    exit 0
  fi
  rm -f "$REBLOCK_PID_FILE"
fi

# Skip weekends (6=Saturday, 7=Sunday) — unless nuked
NUKE_LOCK="/var/tmp/terminally-distracted-nuke.lock"
DAY=$(date +%u)
if [ "$DAY" -ge 6 ]; then
  if [ -f "$NUKE_LOCK" ] && [ "$(date +%s)" -lt "$(cat "$NUKE_LOCK")" ]; then
    : # nuke active — block even on weekends
  else
    exit 0
  fi
fi

if [ ! -f "$SITES_FILE" ]; then
  echo "Error: $SITES_FILE not found."
  exit 1
fi

# Read domains from sites.txt (skip comments and blank lines)
DOMAINS=()
while IFS= read -r line; do
  line="${line%%#*}"        # strip inline comments
  line="${line// /}"        # strip spaces
  [ -z "$line" ] && continue
  # Validate domain format (alphanumeric, dots, hyphens only)
  if [[ ! "$line" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo "Invalid domain, skipping: $line" >&2
    continue
  fi
  DOMAINS+=("$line")
done < "$SITES_FILE"

if [ ${#DOMAINS[@]} -eq 0 ]; then
  echo "No domains found in $SITES_FILE."
  exit 1
fi

# --- /etc/hosts ---

# Backup hosts file before modifying
cp /etc/hosts /etc/hosts.bak

# Remove old terminally-distracted entries if present
sed -i "" '/# BEGIN terminally-distracted/,/# END terminally-distracted/d' /etc/hosts

# Build hosts block
HOSTS_BLOCK="# BEGIN terminally-distracted"
for domain in "${DOMAINS[@]}"; do
  HOSTS_BLOCK+=$'\n'"0.0.0.0 $domain"
  HOSTS_BLOCK+=$'\n'"0.0.0.0 www.$domain"
done
HOSTS_BLOCK+=$'\n'"# END terminally-distracted"

echo "$HOSTS_BLOCK" >> /etc/hosts

# Flush DNS
dscacheutil -flushcache
killall -HUP mDNSResponder

echo "Done. ${#DOMAINS[@]} domains blocked via /etc/hosts."
