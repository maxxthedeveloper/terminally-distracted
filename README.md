# focusblock

Block social media on macOS using `/etc/hosts` + the `pf` firewall. Unblocking requires a 90-second breathing exercise and confirmation.

## Requirements

- macOS
- `sudo` access

## Install

```bash
git clone https://github.com/yourusername/focusblock.git
cd focusblock
./install.sh
```

This installs a LaunchAgent that runs `block.sh` at 9:00 AM on weekdays.

## Configure

Edit `sites.txt` to add or remove domains (one per line, `#` for comments). Subdomains like `www.` are added automatically.

## Usage

```bash
sudo ./block.sh      # block sites now
sudo ./unblock.sh    # breathing exercise → confirm → unblock for 10 min
```

Unblocking gives you 10 minutes, then sites are automatically re-blocked.

## How it works

1. Adds `0.0.0.0` entries to `/etc/hosts` between `# BEGIN focusblock` / `# END focusblock` markers
2. Resolves domain IPs via `dig` and creates `pf` firewall rules (catches DNS-over-HTTPS)
3. Flushes DNS cache

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.focusblock.plist
rm ~/Library/LaunchAgents/com.focusblock.plist
sudo sed -i "" '/# BEGIN focusblock/,/# END focusblock/d' /etc/hosts
sudo sed -i "" '/social-block/d' /etc/pf.conf
```
