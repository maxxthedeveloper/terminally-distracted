# terminally-distracted

Block social media on macOS using `/etc/hosts` + the `pf` firewall. Unblocking requires a 90-second breathing exercise and confirmation.

## Requirements

- macOS
- `sudo` access

## Quick start (Claude Code)

Clone the repo, open [Claude Code](https://claude.com/claude-code), and say **"set this up"**. Claude will run the installer and walk you through configuration.

## Install (manual)

```bash
git clone https://github.com/maxxthedeveloper/terminally-distracted.git
cd terminally-distracted
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

1. Adds `0.0.0.0` entries to `/etc/hosts` between `# BEGIN terminally-distracted` / `# END terminally-distracted` markers
2. Resolves domain IPs via `dig` and creates `pf` firewall rules (catches DNS-over-HTTPS)
3. Flushes DNS cache

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.terminally-distracted.plist
rm ~/Library/LaunchAgents/com.terminally-distracted.plist
sudo sed -i "" '/# BEGIN terminally-distracted/,/# END terminally-distracted/d' /etc/hosts
sudo sed -i "" '/social-block/d' /etc/pf.conf
```
