#!/bin/bash
# Install focusblock LaunchAgent

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$SCRIPT_DIR/com.focusblock.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.focusblock.plist"

# Make scripts executable
chmod +x "$SCRIPT_DIR/block.sh" "$SCRIPT_DIR/unblock.sh"

# Substitute install path into plist
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$PLIST_SRC" > "$PLIST_DEST"

# Unload old agent if present
launchctl unload "$PLIST_DEST" 2>/dev/null

# Load agent
launchctl load "$PLIST_DEST"

echo "Installed."
echo ""
echo "  block.sh runs automatically at 9:00 AM on weekdays."
echo ""
echo "  Manual usage:"
echo "    sudo $SCRIPT_DIR/block.sh       # block now"
echo "    sudo $SCRIPT_DIR/unblock.sh     # unblock (with breathing exercise)"
echo ""
echo "  Edit $SCRIPT_DIR/sites.txt to add/remove domains."
echo ""
echo "  To uninstall:"
echo "    launchctl unload $PLIST_DEST"
echo "    rm $PLIST_DEST"
