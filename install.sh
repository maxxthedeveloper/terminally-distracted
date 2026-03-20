#!/bin/bash
# Install terminally-distracted LaunchDaemon

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$SCRIPT_DIR/com.terminally-distracted.plist"
PLIST_DEST="/Library/LaunchDaemons/com.terminally-distracted.plist"

# Make scripts executable
chmod +x \
  "$SCRIPT_DIR/block.sh" \
  "$SCRIPT_DIR/unblock.sh" \
  "$SCRIPT_DIR/nuke.sh"

# Need sudo for LaunchDaemon installation
if [ "$EUID" -ne 0 ]; then
  echo "Needs sudo to install the LaunchDaemon."
  exec sudo "$0" "$@"
fi

# --- Legacy cleanup ---

# Remove old com.maxx.blocksocial daemon
LEGACY_PLIST="/Library/LaunchDaemons/com.maxx.blocksocial.plist"
if [ -f "$LEGACY_PLIST" ]; then
  echo "Removing legacy com.maxx.blocksocial daemon..."
  launchctl unload "$LEGACY_PLIST" 2>/dev/null
  rm -f "$LEGACY_PLIST"
fi

# Delete old scripts
if [ -n "$SUDO_USER" ]; then
  REAL_HOME=$(eval echo "~$SUDO_USER")
else
  REAL_HOME="$HOME"
fi

for f in "$REAL_HOME/block-twitter.sh" "$REAL_HOME/unblock-twitter.sh"; do
  [ -f "$f" ] && rm -f "$f" && echo "Removed legacy $f"
done

# Clean pf anchors
rm -f /etc/pf.anchors/social-block
if [ -f /etc/pf.conf ] && grep -q 'social-block' /etc/pf.conf; then
  sed -i "" '/social-block/d' /etc/pf.conf
  echo "Cleaned pf.conf social-block references."
fi

# Clean legacy unmarked hosts entries (known domains from sites.txt) — single pass
if [ -f "$SCRIPT_DIR/sites.txt" ]; then
  SED_SCRIPT=""
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line// /}"
    [ -z "$line" ] && continue
    [[ ! "$line" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && continue
    SED_SCRIPT+="/^0\\.0\\.0\\.0 ${line}$/d;"
    SED_SCRIPT+="/^0\\.0\\.0\\.0 www\\.${line}$/d;"
  done < "$SCRIPT_DIR/sites.txt"
  SED_SCRIPT+='/^# Block [A-Z]/d;'
  SED_SCRIPT+='/^$/N;/^\n$/d'
  sed -i "" "$SED_SCRIPT" /etc/hosts
fi

# --- Install daemon ---

# Unload old daemon if present
launchctl unload "$PLIST_DEST" 2>/dev/null

# Substitute install path into plist and install
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$PLIST_SRC" > "$PLIST_DEST"
chown root:wheel "$PLIST_DEST"
chmod 644 "$PLIST_DEST"

# Load daemon
launchctl load "$PLIST_DEST"

# --- Shell aliases ---

ZSHRC="$REAL_HOME/.zshrc"
if [ -f "$ZSHRC" ]; then
  # Remove any existing marker block + stale individual aliases — single pass
  sed -i "" \
    -e '/# BEGIN terminally-distracted/,/# END terminally-distracted/d' \
    -e '/^# terminally-distracted commands$/d' \
    -e '/^# Site blocking.*terminally-distracted/d' \
    -e '/^# Site blocking$/d' \
    -e '/^alias block=.*terminally-distracted/d' \
    -e '/^alias unblock=.*terminally-distracted/d' \
    -e '/^alias nuke=.*terminally-distracted/d' \
    -e '/^alias testnuke=.*terminally-distracted/d' \
    -e '/^alias force-unblock=.*terminally-distracted/d' \
    -e '/^$/N;/^\n$/d' \
    "$ZSHRC"

  # Add marker-based block
  cat >> "$ZSHRC" << EOF

# BEGIN terminally-distracted
alias block="sudo $SCRIPT_DIR/block.sh"
alias unblock="sudo $SCRIPT_DIR/unblock.sh"
alias nuke="sudo $SCRIPT_DIR/nuke.sh"
alias testnuke="$SCRIPT_DIR/nuke.sh --testnuke"
alias force-unblock="sudo $SCRIPT_DIR/unblock.sh --force"
# END terminally-distracted
EOF
fi

echo "Installed."
echo ""
echo "  block.sh runs automatically at 9:00 AM on weekdays (as root)."
echo ""
echo "  Manual usage:"
echo "    sudo $SCRIPT_DIR/block.sh       # block now"
echo "    sudo $SCRIPT_DIR/unblock.sh     # unblock (with breathing exercise)"
echo "    sudo $SCRIPT_DIR/unblock.sh --force"
echo "                                   # bypass breathing; if nuked, pause enforcement for 10 min"
echo ""
echo "  Aliases: block, unblock, nuke, testnuke, force-unblock"
echo "  Run: source ~/.zshrc"
echo ""
echo "  Edit $SCRIPT_DIR/sites.txt to add/remove domains."
echo ""
echo "  To uninstall:"
echo "    sudo launchctl unload $PLIST_DEST"
echo "    sudo rm $PLIST_DEST"
