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
import colorsys
import math
import os
import select
import sys
import termios
import time
import tty
from functools import lru_cache

DURATION = 90.0
INHALE_1 = 2.0
INHALE_2 = 1.0
EXHALE = 6.0
CYCLE = INHALE_1 + INHALE_2 + EXHALE
FPS = 30
DOT_COUNT = 9
GRID_W = 32
GRID_H = 16
ASPECT_X = 0.45
MIN_RADIUS = 0.25
MID_RADIUS = 0.70
HALO_SCALE = 1.18

INHALE_CENTER_HSV = (0.50, 0.36, 0.98)
INHALE_EDGE_HSV = (0.45, 0.58, 0.78)
EXHALE_CENTER_HSV = (0.78, 0.18, 0.95)
EXHALE_EDGE_HSV = (0.10, 0.46, 0.86)


def clamp(value, lo=0.0, hi=1.0):
    return max(lo, min(hi, value))


def ease_sine(value):
    return (1.0 - math.cos(math.pi * clamp(value))) / 2.0


def smoothstep(value):
    value = clamp(value)
    return value * value * (3.0 - 2.0 * value)


def lerp(a, b, t):
    return a + (b - a) * t


def lerp_triplet(a, b, t):
    return tuple(lerp(x, y, t) for x, y in zip(a, b))


def scale_rgb(rgb, factor):
    return tuple(max(0, min(255, int(round(channel * factor)))) for channel in rgb)


def mix_rgb(rgb_a, rgb_b, t):
    return tuple(
        max(0, min(255, int(round(lerp(a, b, t)))))
        for a, b in zip(rgb_a, rgb_b)
    )


def hsv_to_rgb_bytes(hsv):
    r, g, b = colorsys.hsv_to_rgb(*hsv)
    return (int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))


def supports_truecolor():
    term_program = os.environ.get("TERM_PROGRAM", "")
    colorterm = os.environ.get("COLORTERM", "").lower()
    term = os.environ.get("TERM", "").lower()
    if term_program == "Apple_Terminal":
        return False
    return (
        "truecolor" in colorterm
        or "24bit" in colorterm
        or term.endswith("-direct")
        or "direct" in term
    )


@lru_cache(maxsize=None)
def rgb_to_256(r, g, b):
    if r == g == b:
        if r < 8:
            return 16
        if r > 248:
            return 231
        return round(((r - 8) / 247) * 24) + 232

    r_idx = round(r / 255 * 5)
    g_idx = round(g / 255 * 5)
    b_idx = round(b / 255 * 5)
    return 16 + 36 * r_idx + 6 * g_idx + b_idx


@lru_cache(maxsize=None)
def fg_escape(truecolor, r, g, b):
    if truecolor:
        return f"\033[38;2;{r};{g};{b}m"
    return f"\033[38;5;{rgb_to_256(r, g, b)}m"


def build_layout(columns, lines):
    usable_cols = max(8, columns - 4)
    usable_lines = max(4, lines - 4)
    scale = min(usable_cols / GRID_W, usable_lines / GRID_H, 1.0)
    grid_w = max(8, min(usable_cols, int(GRID_W * scale)))
    grid_h = max(4, min(usable_lines, int(GRID_H * scale)))

    total_h = grid_h + 4
    top = max(0, (lines - total_h) // 2)
    left = max(0, (columns - grid_w) // 2)

    cx = (grid_w - 1) / 2.0
    cy = (grid_h - 1) / 2.0
    x_norm = max(1.0, cx * ASPECT_X)
    y_norm = max(1.0, cy)

    distances = []
    for y in range(grid_h):
        row = []
        for x in range(grid_w):
            dx = ((x - cx) * ASPECT_X) / x_norm
            dy = (y - cy) / y_norm
            row.append(math.hypot(dx, dy))
        distances.append(row)

    return {
        "columns": columns,
        "lines": lines,
        "grid_w": grid_w,
        "grid_h": grid_h,
        "left": left,
        "dots_y": top,
        "orb_y": top + 2,
        "label_y": top + grid_h + 3,
        "distances": distances,
    }


def phase_state(cycle_time):
    inhale_total = INHALE_1 + INHALE_2
    if cycle_time < INHALE_1:
        progress = MIN_RADIUS + (MID_RADIUS - MIN_RADIUS) * ease_sine(cycle_time / INHALE_1)
        return progress, "breathe in"
    if cycle_time < inhale_total:
        top_up = cycle_time - INHALE_1
        progress = MID_RADIUS + (1.0 - MID_RADIUS) * ease_sine(top_up / INHALE_2)
        return progress, "breathe in"
    release = cycle_time - inhale_total
    progress = MIN_RADIUS + (1.0 - MIN_RADIUS) * (1.0 - ease_sine(release / EXHALE))
    return progress, "breathe out"


def phase_palette(cycle_time):
    inhale_total = INHALE_1 + INHALE_2
    if cycle_time < inhale_total:
        blend = 1.0 - ease_sine(cycle_time / inhale_total)
    else:
        blend = ease_sine((cycle_time - inhale_total) / EXHALE)
    center_hsv = lerp_triplet(INHALE_CENTER_HSV, EXHALE_CENTER_HSV, blend)
    edge_hsv = lerp_triplet(INHALE_EDGE_HSV, EXHALE_EDGE_HSV, blend)
    return center_hsv, edge_hsv


def intensity_for(distance, radius):
    if distance <= radius:
        t = distance / max(radius, 1e-6)
        return 0.18 + 0.82 * (1.0 - smoothstep(t))
    halo = radius * HALO_SCALE + 0.04
    if distance <= halo:
        t = (distance - radius) / max(halo - radius, 1e-6)
        return 0.16 * (1.0 - smoothstep(t))
    return 0.0


def render_orb_row(distances, radius, center_hsv, edge_hsv, truecolor):
    parts = []
    current_escape = None
    radius_denom = max(radius, 1e-6)

    for distance in distances:
        intensity = intensity_for(distance, radius)
        if intensity < 0.045:
            if current_escape is not None:
                parts.append("\033[0m")
                current_escape = None
            parts.append(" ")
            continue

        color_t = clamp(distance / radius_denom)
        hsv = lerp_triplet(center_hsv, edge_hsv, color_t)
        rgb = hsv_to_rgb_bytes(hsv)
        center_boost = 1.0 - smoothstep(min(1.0, distance / radius_denom))
        rgb = mix_rgb(rgb, (255, 255, 255), 0.30 * center_boost)
        rgb = scale_rgb(rgb, 0.12 + 0.88 * intensity)
        escape = fg_escape(truecolor, *rgb)

        if escape != current_escape:
            parts.append(escape)
            current_escape = escape
        parts.append("\u2588")

    if current_escape is not None:
        parts.append("\033[0m")
    return "".join(parts)


def render_dots(elapsed, center_hsv, truecolor):
    filled = min(DOT_COUNT, int(elapsed / (DURATION / DOT_COUNT)))
    accent = mix_rgb(hsv_to_rgb_bytes(center_hsv), (255, 255, 255), 0.20)
    filled_dot = f"{fg_escape(truecolor, *accent)}\u25cf\033[0m"
    empty_rgb = (112, 120, 128) if truecolor else (135, 135, 135)
    empty_dot = f"{fg_escape(truecolor, *empty_rgb)}\u25cb\033[0m"
    return " ".join(filled_dot if idx < filled else empty_dot for idx in range(DOT_COUNT))


def render_frame(layout, elapsed, truecolor):
    cycle_time = elapsed % CYCLE
    radius, phase_label = phase_state(cycle_time)
    center_hsv, edge_hsv = phase_palette(cycle_time)
    remaining = max(0, int(math.ceil(DURATION - elapsed)))

    screen = [""] * layout["lines"]

    dots_text = render_dots(elapsed, center_hsv, truecolor)
    dots_width = DOT_COUNT * 2 - 1
    dots_x = max(0, (layout["columns"] - dots_width) // 2)
    screen[layout["dots_y"]] = (" " * dots_x) + dots_text

    for row_index, distances in enumerate(layout["distances"]):
        y = layout["orb_y"] + row_index
        if 0 <= y < layout["lines"]:
            orb_row = render_orb_row(distances, radius, center_hsv, edge_hsv, truecolor)
            screen[y] = (" " * layout["left"]) + orb_row

    label = phase_label
    timer = f"{remaining:>2}s"
    label_x = max(0, (layout["columns"] - len(label)) // 2)
    timer_x = max(label_x + len(label) + 2, layout["columns"] - len(timer) - 2)
    label_line = (" " * label_x) + label
    label_line += " " * max(1, timer_x - label_x - len(label))
    label_line += timer
    if 0 <= layout["label_y"] < layout["lines"]:
        screen[layout["label_y"]] = label_line

    parts = ["\033[H"]
    for idx, line in enumerate(screen):
        parts.append(line)
        parts.append("\033[0m\033[K")
        if idx < layout["lines"] - 1:
            parts.append("\n")
    return "".join(parts)


def main():
    tty_f = open("/dev/tty", "r+b", buffering=0)
    fd = tty_f.fileno()
    old = termios.tcgetattr(fd)
    cancelled = False
    truecolor = supports_truecolor()
    layout = None
    last_size = None

    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?1049h\033[?25l\033[2J\033[H")
        sys.stdout.flush()

        start = time.monotonic()
        frame = 0

        while True:
            now = time.monotonic()
            elapsed = now - start
            if elapsed >= DURATION:
                break

            if select.select([fd], [], [], 0)[0]:
                os.read(fd, 1)
                cancelled = True
                break

            try:
                size = os.get_terminal_size(fd)
            except OSError:
                size = os.terminal_size((80, 24))

            if size != last_size:
                layout = build_layout(size.columns, size.lines)
                last_size = size

            sys.stdout.write(render_frame(layout, elapsed, truecolor))
            sys.stdout.flush()

            frame += 1
            target = start + frame / FPS
            sleep_for = target - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)
    except (KeyboardInterrupt, SystemExit):
        cancelled = True
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        tty_f.close()
        sys.stdout.write("\033[0m\033[?25h\033[?1049l")
        sys.stdout.flush()

    if cancelled:
        sys.stdout.write("\n  Cancelled. Sites remain blocked.\n")
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
