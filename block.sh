#!/bin/bash
# Block social media sites via /etc/hosts + pf firewall

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITES_FILE="$SCRIPT_DIR/sites.txt"
REBLOCK_PID_FILE="/tmp/terminally-distracted-reblock.pid"

# Manual blocking ends any active unblock window.
if [ -f "$REBLOCK_PID_FILE" ]; then
  read -r OLD_PID _ < "$REBLOCK_PID_FILE"
  if [ -n "$OLD_PID" ]; then
    kill "$OLD_PID" 2>/dev/null
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

# --- pf firewall (catches DNS-over-HTTPS) ---

ALL_IPS=$(dig +short "${DOMAINS[@]}" | grep -E '^[0-9]')
PF_RULES="/etc/pf.anchors/social-block"

echo "# terminally-distracted IP rules" > "$PF_RULES"
for ip in $ALL_IPS; do
  echo "block drop quick proto {tcp udp} to $ip" >> "$PF_RULES"
done

if ! grep -q "social-block" /etc/pf.conf; then
  echo 'anchor "social-block"' >> /etc/pf.conf
  echo 'load anchor "social-block" from "/etc/pf.anchors/social-block"' >> /etc/pf.conf
fi

pfctl -f /etc/pf.conf 2>/dev/null
pfctl -e 2>/dev/null

echo "Done. ${#DOMAINS[@]} domains blocked via hosts + firewall."
