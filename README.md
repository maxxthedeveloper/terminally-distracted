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

This installs a LaunchDaemon that runs `block.sh` as root at 9:00 AM on weekdays. The installer will prompt for sudo.

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
sudo launchctl unload /Library/LaunchDaemons/com.terminally-distracted.plist
sudo rm /Library/LaunchDaemons/com.terminally-distracted.plist
sudo sed -i "" '/# BEGIN terminally-distracted/,/# END terminally-distracted/d' /etc/hosts
sudo sed -i "" '/social-block/d' /etc/pf.conf
```
