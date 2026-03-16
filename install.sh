#!/bin/bash
# Install terminally-distracted LaunchDaemon

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$SCRIPT_DIR/com.terminally-distracted.plist"
PLIST_DEST="/Library/LaunchDaemons/com.terminally-distracted.plist"

# Make scripts executable
chmod +x "$SCRIPT_DIR/block.sh" "$SCRIPT_DIR/unblock.sh"

# Need sudo for LaunchDaemon installation
if [ "$EUID" -ne 0 ]; then
  echo "Needs sudo to install the LaunchDaemon."
  exec sudo "$0" "$@"
fi

# Unload old daemon if present
launchctl unload "$PLIST_DEST" 2>/dev/null

# Substitute install path into plist and install
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$PLIST_SRC" > "$PLIST_DEST"
chown root:wheel "$PLIST_DEST"
chmod 644 "$PLIST_DEST"

# Load daemon
launchctl load "$PLIST_DEST"

echo "Installed."
echo ""
echo "  block.sh runs automatically at 9:00 AM on weekdays (as root)."
echo ""
echo "  Manual usage:"
echo "    sudo $SCRIPT_DIR/block.sh       # block now"
echo "    sudo $SCRIPT_DIR/unblock.sh     # unblock (with breathing exercise)"
echo ""
echo "  Edit $SCRIPT_DIR/sites.txt to add/remove domains."
echo ""
echo "  To uninstall:"
echo "    sudo launchctl unload $PLIST_DEST"
echo "    sudo rm $PLIST_DEST"
