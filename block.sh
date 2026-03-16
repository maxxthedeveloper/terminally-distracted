#!/bin/bash
# Block social media sites via /etc/hosts + pf firewall

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITES_FILE="$SCRIPT_DIR/sites.txt"

# Skip weekends (6=Saturday, 7=Sunday)
DAY=$(date +%u)
if [ "$DAY" -ge 6 ]; then
  exit 0
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
  DOMAINS+=("$line")
done < "$SITES_FILE"

if [ ${#DOMAINS[@]} -eq 0 ]; then
  echo "No domains found in $SITES_FILE."
  exit 1
fi

# --- /etc/hosts ---

# Remove old focusblock entries if present
sed -i "" '/# BEGIN focusblock/,/# END focusblock/d' /etc/hosts

# Build hosts block
HOSTS_BLOCK="# BEGIN focusblock"
for domain in "${DOMAINS[@]}"; do
  HOSTS_BLOCK+=$'\n'"0.0.0.0 $domain"
  HOSTS_BLOCK+=$'\n'"0.0.0.0 www.$domain"
done
HOSTS_BLOCK+=$'\n'"# END focusblock"

echo "$HOSTS_BLOCK" >> /etc/hosts

# Flush DNS
dscacheutil -flushcache
killall -HUP mDNSResponder

# --- pf firewall (catches DNS-over-HTTPS) ---

ALL_IPS=$(dig +short "${DOMAINS[@]}" | grep -E '^[0-9]')
PF_RULES="/etc/pf.anchors/social-block"

echo "# focusblock IP rules" > "$PF_RULES"
for ip in $ALL_IPS; do
  echo "block drop quick on en0 proto {tcp udp} to $ip" >> "$PF_RULES"
done

if ! grep -q "social-block" /etc/pf.conf; then
  echo 'anchor "social-block"' >> /etc/pf.conf
  echo 'load anchor "social-block" from "/etc/pf.anchors/social-block"' >> /etc/pf.conf
fi

pfctl -f /etc/pf.conf 2>/dev/null
pfctl -e 2>/dev/null

echo "Done. ${#DOMAINS[@]} domains blocked via hosts + firewall."
