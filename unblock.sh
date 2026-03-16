#!/bin/bash
# Breathing exercise → confirm → unblock sites for 10 minutes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REBLOCK_PID_FILE="/tmp/terminally-distracted-reblock.pid"

# Kill any existing reblock timer from a previous unblock
if [ -f "$REBLOCK_PID_FILE" ]; then
  OLD_PID=$(cat "$REBLOCK_PID_FILE")
  kill "$OLD_PID" 2>/dev/null
  rm -f "$REBLOCK_PID_FILE"
fi

python3 << 'BREATHE_EOF'
import sys, math, time, select, termios, tty

DURATION = 90
# Physiological sigh: double inhale (nose) + long exhale (mouth)
INHALE_1 = 2.0   # deep inhale
INHALE_2 = 1.0   # short top-up inhale
EXHALE   = 6.0   # long slow exhale
CYCLE = INHALE_1 + INHALE_2 + EXHALE
BAR_MAX = 48
FPS = 30

BLOCKS = " \u258f\u258e\u258d\u258c\u258b\u258a\u2589\u2588"

def render_bar(width_float):
    if width_float <= 0:
        return ""
    full = int(width_float)
    frac = width_float - full
    frac_idx = int(frac * 8)
    parts = []
    for i in range(full):
        parts.append("\u2588")
    if frac_idx > 0 and full < BAR_MAX:
        parts.append(BLOCKS[frac_idx])
    return "".join(parts)

def main():
    tty_f = open("/dev/tty", "r+b", buffering=0)
    fd = tty_f.fileno()
    old = termios.tcgetattr(fd)
    cancelled = False
    try:
        tty.setcbreak(fd)
        w = sys.stdout.write
        f = sys.stdout.flush
        w("\033[?25l")  # hide cursor
        w("\n  physiological sigh \u2014 double inhale, long exhale\n\n\n")
        f()
        start = time.monotonic()
        frame = 0
        while True:
            now = time.monotonic()
            elapsed = now - start
            if elapsed >= DURATION:
                break
            if select.select([tty_f], [], [], 0)[0]:
                tty_f.read(1)
                cancelled = True
                break
            ct = elapsed % CYCLE
            if ct < INHALE_1:
                phase = "inhale"
                phase_dur = INHALE_1
                phase_elapsed = ct
                pt = ct / INHALE_1
                # Expand from 0 to ~0.7
                progress = (1 - math.cos(pt * math.pi)) / 2 * 0.7
            elif ct < INHALE_1 + INHALE_2:
                phase = "inhale +"
                phase_dur = INHALE_2
                phase_elapsed = ct - INHALE_1
                pt = phase_elapsed / INHALE_2
                # Quick top-up from 0.7 to 1.0
                progress = 0.7 + (1 - math.cos(pt * math.pi)) / 2 * 0.3
            else:
                phase = "exhale"
                phase_dur = EXHALE
                phase_elapsed = ct - INHALE_1 - INHALE_2
                pt = phase_elapsed / EXHALE
                # Long slow release from 1.0 to 0
                progress = (1 + math.cos(pt * math.pi)) / 2
            bar_w = progress * BAR_MAX
            bar = render_bar(bar_w)
            remaining = int(DURATION - elapsed)
            phase_remaining = math.ceil(phase_dur - phase_elapsed)
            label = f"{phase}   {phase_remaining}s"
            w(f"\r\033[2A\033[K  {label}\033[{50}G{remaining:>3}s\n\033[K\n\033[K  {bar}\r")
            f()
            frame += 1
            target = start + frame / FPS
            sl = target - time.monotonic()
            if sl > 0:
                time.sleep(sl)
        w("\r\033[2A\033[K\n\033[K\n\033[K\r")
        w("\033[?25h")
        f()
        if cancelled:
            w("\n  Cancelled. Sites remain blocked.\n")
            f()
    except (KeyboardInterrupt, SystemExit):
        cancelled = True
        sys.stdout.write("\033[?25h\n\n  Cancelled. Sites remain blocked.\n")
        sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        tty_f.close()
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()
    sys.exit(1 if cancelled else 0)

main()
BREATHE_EOF

if [ $? -ne 0 ]; then
  exit 0
fi

# Backup hosts file before modifying
cp /etc/hosts /etc/hosts.bak

# Remove terminally-distracted entries from /etc/hosts
sed -i "" '/# BEGIN terminally-distracted/,/# END terminally-distracted/d' /etc/hosts

# Remove blank lines left behind (collapse multiple empty lines to one)
sed -i "" '/^$/N;/^\n$/d' /etc/hosts

# Clear pf firewall rules
PF_RULES="/etc/pf.anchors/social-block"
echo "# No blocks" > "$PF_RULES"

# Remove anchor from pf.conf
sed -i "" '/social-block/d' /etc/pf.conf

# Reload firewall
pfctl -f /etc/pf.conf 2>/dev/null

# Flush DNS
dscacheutil -flushcache
killall -HUP mDNSResponder

# Schedule re-block in 10 minutes
(
  sleep 600
  bash "$SCRIPT_DIR/block.sh"
  rm -f "$REBLOCK_PID_FILE"
  osascript -e 'display notification "Social media blocked again." with title "10 minutes up"' 2>/dev/null
) &
echo "$!" > "$REBLOCK_PID_FILE"
disown

echo "Done. Unblocked for 10 minutes — will auto-reblock at $(date -v+10M '+%H:%M')."
