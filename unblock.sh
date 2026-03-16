#!/bin/bash
# Breathing exercise → confirm → unblock sites for 10 minutes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REBLOCK_PID_FILE="/tmp/terminally-distracted-reblock.pid"

if [ -f "$REBLOCK_PID_FILE" ]; then
  read -r OLD_PID OLD_UNTIL < "$REBLOCK_PID_FILE"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    if [ -n "$OLD_UNTIL" ] && REBLOCK_AT=$(date -r "$OLD_UNTIL" '+%H:%M' 2>/dev/null); then
      echo "Already unblocked. Auto-reblock at $REBLOCK_AT."
    else
      echo "Already unblocked."
    fi
    exit 0
  fi
  rm -f "$REBLOCK_PID_FILE"
fi

TTY_STATE=$(stty -g </dev/tty 2>/dev/null)

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
TOPUP_CENTER_HSV = (0.53, 0.42, 1.00)
TOPUP_EDGE_HSV = (0.55, 0.68, 0.90)
EXHALE_CENTER_HSV = (0.78, 0.18, 0.95)
EXHALE_EDGE_HSV = (0.10, 0.46, 0.86)
PHASE_ACCENT_HSV = {
    "inhale_1": (0.49, 0.56, 0.90),
    "inhale_2": (0.54, 0.62, 0.98),
    "exhale": (0.10, 0.48, 0.92),
}
PRELUDE_PHASES = (
    {"key": "inhale_1", "label": "inhale", "duration": 1.2},
    {"key": "inhale_2", "label": "inhale again", "duration": 0.8},
    {"key": "exhale", "label": "slow exhale", "duration": 1.6},
)
LIVE_PHASES = (
    {"key": "inhale_1", "label": "inhale", "duration": INHALE_1},
    {"key": "inhale_2", "label": "inhale again", "duration": INHALE_2},
    {"key": "exhale", "label": "slow exhale", "duration": EXHALE},
)
PRELUDE_DURATION = sum(phase["duration"] for phase in PRELUDE_PHASES)
RAIL_WEIGHTS = (2.0, 1.0, 6.0)


def clamp(value, lo=0.0, hi=1.0):
    return max(lo, min(hi, value))


def ease_sine(value):
    return (1.0 - math.cos(math.pi * clamp(value))) / 2.0


def bloom_curve(value):
    value = clamp(value)
    return 1.0 - math.pow(1.0 - value, 2.4)


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


def phase_accent_rgb(phase_key, highlight=0.0):
    return mix_rgb(hsv_to_rgb_bytes(PHASE_ACCENT_HSV[phase_key]), (255, 255, 255), highlight)


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


def style_text(text, rgb, truecolor, bold=False):
    prefix = fg_escape(truecolor, *rgb)
    if bold:
        prefix += "\033[1m"
    return f"{prefix}{text}\033[0m"


def terminal_size(fd):
    try:
        return os.get_terminal_size(fd)
    except OSError:
        return os.terminal_size((80, 24))


def check_cancel(fd):
    if select.select([fd], [], [], 0)[0]:
        os.read(fd, 1)
        return True
    return False


def phase_for_elapsed(elapsed, phases):
    cursor = 0.0
    for index, phase in enumerate(phases):
        upper = cursor + phase["duration"]
        if elapsed < upper:
            local_elapsed = elapsed - cursor
            progress = clamp(local_elapsed / phase["duration"]) if phase["duration"] else 1.0
            return index, phase, local_elapsed, progress
        cursor = upper
    phase = phases[-1]
    return len(phases) - 1, phase, phase["duration"], 1.0


def distribute_width(total, weights):
    raw = [total * weight / sum(weights) for weight in weights]
    widths = [max(1, int(value)) for value in raw]

    while sum(widths) > total:
        shrink = max(range(len(widths)), key=lambda idx: (widths[idx], raw[idx] - widths[idx]))
        if widths[shrink] == 1:
            break
        widths[shrink] -= 1

    while sum(widths) < total:
        grow = max(range(len(widths)), key=lambda idx: (raw[idx] - widths[idx], -idx))
        widths[grow] += 1

    return widths


def rail_width(columns):
    return max(12, min(48, columns - 12))


def build_live_layout(columns, lines):
    chrome_lines = 6
    usable_cols = max(8, columns - 4)
    usable_lines = max(4, lines - chrome_lines)
    scale = min(usable_cols / GRID_W, usable_lines / GRID_H, 1.0)
    grid_w = max(8, min(usable_cols, int(GRID_W * scale)))
    grid_h = max(4, min(usable_lines, int(GRID_H * scale)))

    total_h = grid_h + chrome_lines
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
        "phase_words_y": top + 1,
        "phase_rail_y": top + 2,
        "orb_y": top + 4,
        "label_y": top + grid_h + 5,
        "rail_width": rail_width(columns),
        "distances": distances,
    }


def build_prelude_layout(columns, lines):
    top = max(0, (lines - 5) // 2)
    return {
        "columns": columns,
        "lines": lines,
        "headline_y": top,
        "rail_y": top + 2,
        "caption_y": top + 4,
        "rail_width": rail_width(columns),
    }


def live_phase_state(cycle_time):
    inhale_total = INHALE_1 + INHALE_2
    if cycle_time < INHALE_1:
        phase_progress = clamp(cycle_time / INHALE_1)
        radius = MIN_RADIUS + (MID_RADIUS - MIN_RADIUS) * ease_sine(phase_progress)
        return {
            "phase_key": "inhale_1",
            "phase_label": "inhale",
            "phase_index": 0,
            "phase_progress": phase_progress,
            "radius": radius,
            "center_hsv": INHALE_CENTER_HSV,
            "edge_hsv": INHALE_EDGE_HSV,
            "rim_boost": 0.06 * ease_sine(phase_progress),
        }
    if cycle_time < inhale_total:
        phase_progress = clamp((cycle_time - INHALE_1) / INHALE_2)
        accent_mix = ease_sine(phase_progress)
        radius = MID_RADIUS + (1.0 - MID_RADIUS) * bloom_curve(phase_progress)
        return {
            "phase_key": "inhale_2",
            "phase_label": "inhale again",
            "phase_index": 1,
            "phase_progress": phase_progress,
            "radius": radius,
            "center_hsv": lerp_triplet(INHALE_CENTER_HSV, TOPUP_CENTER_HSV, accent_mix),
            "edge_hsv": lerp_triplet(INHALE_EDGE_HSV, TOPUP_EDGE_HSV, accent_mix),
            "rim_boost": 0.18 + 0.42 * smoothstep(phase_progress),
        }
    phase_progress = clamp((cycle_time - inhale_total) / EXHALE)
    blend = ease_sine(phase_progress)
    radius = MIN_RADIUS + (1.0 - MIN_RADIUS) * (1.0 - ease_sine(phase_progress))
    return {
        "phase_key": "exhale",
        "phase_label": "slow exhale",
        "phase_index": 2,
        "phase_progress": phase_progress,
        "radius": radius,
        "center_hsv": lerp_triplet(TOPUP_CENTER_HSV, EXHALE_CENTER_HSV, blend),
        "edge_hsv": lerp_triplet(TOPUP_EDGE_HSV, EXHALE_EDGE_HSV, blend),
        "rim_boost": 0.12 * (1.0 - blend),
    }


def intensity_for(distance, radius, rim_boost):
    halo = radius * HALO_SCALE + 0.04
    if distance <= radius:
        t = distance / max(radius, 1e-6)
        intensity = 0.18 + 0.82 * (1.0 - smoothstep(t))
    elif distance <= halo:
        t = (distance - radius) / max(halo - radius, 1e-6)
        intensity = 0.16 * (1.0 - smoothstep(t))
    else:
        intensity = 0.0

    rim_distance = abs(distance - radius)
    rim_band = 0.09 + 0.05 * rim_boost
    if rim_band > 0:
        rim_highlight = clamp(1.0 - (rim_distance / rim_band))
        intensity += 0.22 * rim_boost * smoothstep(rim_highlight)

    return clamp(intensity)


def render_orb_row(distances, radius, center_hsv, edge_hsv, rim_boost, truecolor):
    parts = []
    current_escape = None
    radius_denom = max(radius, 1e-6)

    for distance in distances:
        intensity = intensity_for(distance, radius, rim_boost)
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
        rim_distance = abs(distance - radius)
        rim_band = 0.08 + 0.06 * rim_boost
        if rim_band > 0:
            rim_mix = clamp(1.0 - rim_distance / rim_band)
            rgb = mix_rgb(rgb, (255, 255, 255), rim_boost * 0.45 * smoothstep(rim_mix))
        rgb = scale_rgb(rgb, 0.12 + 0.88 * intensity)
        escape = fg_escape(truecolor, *rgb)

        if escape != current_escape:
            parts.append(escape)
            current_escape = escape
        parts.append("\u2588")

    if current_escape is not None:
        parts.append("\033[0m")
    return "".join(parts)


def render_phase_words_line(columns, active_index, truecolor):
    labels = [phase["label"] for phase in LIVE_PHASES]
    separator = "  " if columns >= 34 else " "
    visible_width = sum(len(label) for label in labels) + len(separator) * (len(labels) - 1)
    left = max(0, (columns - visible_width) // 2)
    separator_rgb = (100, 108, 116) if truecolor else (120, 120, 120)

    parts = [" " * left]
    for index, phase in enumerate(LIVE_PHASES):
        if index > 0:
            parts.append(style_text(separator, separator_rgb, truecolor))
        if index < active_index:
            rgb = scale_rgb(phase_accent_rgb(phase["key"], 0.08), 0.88)
            parts.append(style_text(phase["label"], rgb, truecolor))
        elif index == active_index:
            rgb = phase_accent_rgb(phase["key"], 0.30)
            parts.append(style_text(phase["label"], rgb, truecolor, bold=True))
        else:
            rgb = (120, 128, 136) if truecolor else (135, 135, 135)
            parts.append(style_text(phase["label"], rgb, truecolor))
    return "".join(parts)


def render_phase_rail(columns, rail_width_chars, active_index, active_progress, truecolor):
    segment_widths = distribute_width(rail_width_chars - (len(LIVE_PHASES) - 1), RAIL_WEIGHTS)
    left = max(0, (columns - rail_width_chars) // 2)
    upcoming_rgb = (86, 94, 102) if truecolor else (102, 102, 102)
    inactive_fill_rgb = (120, 128, 136) if truecolor else (138, 138, 138)

    parts = [" " * left]
    for index, phase in enumerate(LIVE_PHASES):
        width = segment_widths[index]
        if index > 0:
            parts.append(" ")

        if index < active_index:
            parts.append(style_text("█" * width, scale_rgb(phase_accent_rgb(phase["key"], 0.08), 0.90), truecolor))
            continue

        if index > active_index:
            parts.append(style_text("░" * width, upcoming_rgb, truecolor))
            continue

        fill = min(width, max(1, int(round(width * active_progress))))
        active_rgb = phase_accent_rgb(phase["key"], 0.22)
        parts.append(fg_escape(truecolor, *active_rgb))
        parts.append("█" * fill)
        if fill < width:
            parts.append(fg_escape(truecolor, *inactive_fill_rgb))
            parts.append("░" * (width - fill))
        parts.append("\033[0m")

    return "".join(parts)


def render_dots(elapsed, center_hsv, truecolor):
    filled = min(DOT_COUNT, int(elapsed / (DURATION / DOT_COUNT)))
    accent = mix_rgb(hsv_to_rgb_bytes(center_hsv), (255, 255, 255), 0.20)
    filled_dot = f"{fg_escape(truecolor, *accent)}\u25cf\033[0m"
    empty_rgb = (112, 120, 128) if truecolor else (135, 135, 135)
    empty_dot = f"{fg_escape(truecolor, *empty_rgb)}\u25cb\033[0m"
    return " ".join(filled_dot if idx < filled else empty_dot for idx in range(DOT_COUNT))


def render_prelude_frame(layout, elapsed, truecolor):
    active_index, phase, _, phase_progress = phase_for_elapsed(elapsed, PRELUDE_PHASES)
    caption_rgb = (118, 126, 134) if truecolor else (138, 138, 138)
    screen = [""] * layout["lines"]

    screen[layout["headline_y"]] = render_phase_words_line(layout["columns"], active_index, truecolor)
    screen[layout["rail_y"]] = render_phase_rail(
        layout["columns"],
        layout["rail_width"],
        active_index,
        phase_progress,
        truecolor,
    )
    caption = style_text("starting...", caption_rgb, truecolor)
    caption_left = max(0, (layout["columns"] - len("starting...")) // 2)
    screen[layout["caption_y"]] = (" " * caption_left) + caption

    parts = ["\033[H"]
    for index, line in enumerate(screen):
        parts.append(line)
        parts.append("\033[0m\033[K")
        if index < layout["lines"] - 1:
            parts.append("\n")
    return "".join(parts)


def render_live_frame(layout, elapsed, truecolor):
    phase_info = live_phase_state(elapsed % CYCLE)
    remaining = max(0, int(math.ceil(DURATION - elapsed)))

    screen = [""] * layout["lines"]

    dots_text = render_dots(elapsed, phase_info["center_hsv"], truecolor)
    dots_width = DOT_COUNT * 2 - 1
    dots_x = max(0, (layout["columns"] - dots_width) // 2)
    screen[layout["dots_y"]] = (" " * dots_x) + dots_text
    screen[layout["phase_words_y"]] = render_phase_words_line(
        layout["columns"],
        phase_info["phase_index"],
        truecolor,
    )
    screen[layout["phase_rail_y"]] = render_phase_rail(
        layout["columns"],
        layout["rail_width"],
        phase_info["phase_index"],
        phase_info["phase_progress"],
        truecolor,
    )

    for row_index, distances in enumerate(layout["distances"]):
        y = layout["orb_y"] + row_index
        if 0 <= y < layout["lines"]:
            orb_row = render_orb_row(
                distances,
                phase_info["radius"],
                phase_info["center_hsv"],
                phase_info["edge_hsv"],
                phase_info["rim_boost"],
                truecolor,
            )
            screen[y] = (" " * layout["left"]) + orb_row

    label = phase_info["phase_label"]
    timer = f"{remaining:>2}s"
    label_x = max(0, (layout["columns"] - len(label)) // 2)
    timer_x = max(label_x + len(label) + 2, layout["columns"] - len(timer) - 2)
    label_line = (" " * label_x) + style_text(
        label,
        phase_accent_rgb(phase_info["phase_key"], 0.24),
        truecolor,
        bold=True,
    )
    label_line += " " * max(1, timer_x - label_x - len(label))
    label_line += style_text(timer, scale_rgb(phase_accent_rgb(phase_info["phase_key"], 0.12), 0.92), truecolor)
    if 0 <= layout["label_y"] < layout["lines"]:
        screen[layout["label_y"]] = label_line

    parts = ["\033[H"]
    for idx, line in enumerate(screen):
        parts.append(line)
        parts.append("\033[0m\033[K")
        if idx < layout["lines"] - 1:
            parts.append("\n")
    return "".join(parts)


def run_scene(fd, duration, truecolor, layout_builder, renderer):
    start = time.monotonic()
    frame = 0
    last_size = None
    layout = None

    while True:
        elapsed = time.monotonic() - start
        if elapsed >= duration:
            return False

        if check_cancel(fd):
            return True

        size = terminal_size(fd)
        if size != last_size:
            layout = layout_builder(size.columns, size.lines)
            last_size = size

        sys.stdout.write(renderer(layout, elapsed, truecolor))
        sys.stdout.flush()

        frame += 1
        target = start + frame / FPS
        sleep_for = target - time.monotonic()
        if sleep_for > 0:
            time.sleep(sleep_for)


def main():
    tty_f = open("/dev/tty", "r+b", buffering=0)
    fd = tty_f.fileno()
    old = termios.tcgetattr(fd)
    cancelled = False
    truecolor = supports_truecolor()

    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?1049h\033[?25l\033[2J\033[H")
        sys.stdout.flush()

        cancelled = run_scene(fd, PRELUDE_DURATION, truecolor, build_prelude_layout, render_prelude_frame)
        if not cancelled:
            cancelled = run_scene(fd, DURATION, truecolor, build_live_layout, render_live_frame)
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

PY_EXIT=$?
if [ -n "$TTY_STATE" ]; then
  stty "$TTY_STATE" </dev/tty 2>/dev/null
else
  stty sane </dev/tty 2>/dev/null
fi

if [ $PY_EXIT -ne 0 ]; then
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
REBLOCK_UNTIL=$(($(date +%s) + 600))
(
  sleep 600
  bash "$SCRIPT_DIR/block.sh"
  rm -f "$REBLOCK_PID_FILE"
  osascript -e 'display notification "Social media blocked again." with title "10 minutes up"' 2>/dev/null
) &
printf '%s %s\n' "$!" "$REBLOCK_UNTIL" > "$REBLOCK_PID_FILE"
disown

echo "Done. Unblocked for 10 minutes — will auto-reblock at $(date -v+10M '+%H:%M')."
