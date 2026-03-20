# terminally-distracted

Block social media on macOS using `/etc/hosts`. Unblocking requires a 90-second breathing exercise.

## Setup

Run the installer (will prompt for sudo):

```bash
./install.sh
```

This installs a LaunchDaemon that auto-blocks sites as root at 9 AM on weekdays.

## Configuration

Edit `sites.txt` — one domain per line, `#` for comments. Subdomains like `www.` are added automatically.

## Usage

```bash
sudo ./block.sh      # block sites now
sudo ./unblock.sh    # breathing exercise → unblock for 10 min
sudo ./unblock.sh --force  # bypass breathing
sudo ./nuke.sh       # hard-block for 24h, no undo
```

Both scripts require `sudo`.

## Important behavior

- `unblock.sh` runs a 90-second breathing exercise in the terminal — don't interrupt it
- After unblocking, sites automatically re-block after 10 minutes
- Blocking modifies `/etc/hosts` between `# BEGIN/END terminally-distracted` markers

## Uninstall

```bash
sudo launchctl unload /Library/LaunchDaemons/com.terminally-distracted.plist
sudo rm /Library/LaunchDaemons/com.terminally-distracted.plist
sudo sed -i "" '/# BEGIN terminally-distracted/,/# END terminally-distracted/d' /etc/hosts
```
