#!/bin/bash
# Hard-block social media for 24 hours. No undo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NUKE_LOCK="/var/tmp/terminally-distracted-nuke.lock"
NUKE_PLIST="/Library/LaunchDaemons/com.terminally-distracted.nuke.plist"
REBLOCK_PID_FILE="/tmp/terminally-distracted-reblock.pid"
DURATION=86400

# --enforce mode: called by the LaunchDaemon every 60s
if [ "$1" = "--enforce" ]; then
  if [ -f "$NUKE_LOCK" ] && [ "$(date +%s)" -lt "$(cat "$NUKE_LOCK")" ]; then
    bash "$SCRIPT_DIR/block.sh" >/dev/null 2>&1
    exit 0
  fi
  # Expired or missing — clean up
  rm -f "$NUKE_LOCK"
  launchctl unload "$NUKE_PLIST" 2>/dev/null
  rm -f "$NUKE_PLIST"
  exit 0
fi

# --testnuke mode: animation only, no blocking
if [ "$1" = "--testnuke" ]; then
  EXPIRY=$(( $(date +%s) + 86400 ))
else
  # Interactive mode

  # Already nuked?
  if [ -f "$NUKE_LOCK" ]; then
    EXPIRY=$(cat "$NUKE_LOCK")
    NOW=$(date +%s)
    if [ "$NOW" -lt "$EXPIRY" ]; then
      HOURS=$(( (EXPIRY - NOW) / 3600 ))
      MINS=$(( ((EXPIRY - NOW) % 3600) / 60 ))
      echo "Already nuked. ${HOURS}h ${MINS}m remaining."
      exit 0
    fi
    rm -f "$NUKE_LOCK"
  fi

  # Require root
  if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
  fi

  # Kill any active unblock background process
  if [ -f "$REBLOCK_PID_FILE" ]; then
    read -r OLD_PID _ < "$REBLOCK_PID_FILE"
    if [ -n "$OLD_PID" ]; then
      kill "$OLD_PID" 2>/dev/null
    fi
    rm -f "$REBLOCK_PID_FILE"
  fi

  # Block everything now
  bash "$SCRIPT_DIR/block.sh"

  # Write lockfile with expiry timestamp
  EXPIRY=$(( $(date +%s) + DURATION ))
  echo "$EXPIRY" > "$NUKE_LOCK"

  # Install enforcement daemon (re-blocks every 60s)
  cat > "$NUKE_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.terminally-distracted.nuke</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/nuke.sh</string>
    <string>--enforce</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
  chown root:wheel "$NUKE_PLIST"
  chmod 644 "$NUKE_PLIST"
  launchctl load "$NUKE_PLIST"
fi

# Animated nuke sequence
EXPIRY_TIME=$(date -r "$EXPIRY" '+%H:%M')
TTY_STATE=$(stty -g </dev/tty 2>/dev/null)

python3 << 'NUKE_EOF'
import math
import os
import random
import select
import sys
import termios
import time
import tty
from functools import lru_cache

FPS = 30
TOTAL_DURATION = 13.0

# Timing constants
T_WARN = 0.0
T_FLASH = 2.0
T_PARTICLES = 2.1
T_WORDS = 2.4
T_SHOCK = 2.5
T_CLOUD = 3.5
T_EMBERS = 5.0
T_TEXT = 7.0
T_SUB = 8.2

CODE_GLYPHS = list('{}[]<>/\\#@$%!*=~^()&|;:')
BLOCK_GLYPHS = list('\u2588\u2593\u2592\u2591')
EMBER_GLYPHS = list('\u00b7.,:;')
SHOCKWAVE_GLYPHS = list('=-~\u00b7')

DISTRACTION_WORDS = [
    'brainrot', 'tiktok', 'algoslop', 'doomscroll', 'reels',
    'twitter', 'instagram', 'youtube', 'discord', 'reddit',
    'shorts', 'fyp', 'x.com', 'infinite scroll',
]

COLOR_STOPS = [
    (0.00, (255, 255, 240)),
    (0.08, (255, 250, 180)),
    (0.20, (255, 210, 60)),
    (0.40, (255, 140, 20)),
    (0.60, (230, 70, 10)),
    (0.80, (180, 30, 5)),
    (1.00, (60, 10, 5)),
]

WARNING_TEXT = '\u26a0  TACTICAL NUKE INCOMING  \u26a0'
WARNING_SUB = "IT'S OVER."

# Big pixel font for "NUKED"
_N = ['\u2588   \u2588', '\u2588\u2588  \u2588', '\u2588 \u2588 \u2588', '\u2588  \u2588\u2588', '\u2588   \u2588']
_U = ['\u2588   \u2588', '\u2588   \u2588', '\u2588   \u2588', '\u2588   \u2588', ' \u2588\u2588\u2588 ']
_K = ['\u2588  \u2588 ', '\u2588 \u2588  ', '\u2588\u2588   ', '\u2588 \u2588  ', '\u2588  \u2588 ']
_E = ['\u2588\u2588\u2588\u2588\u2588', '\u2588    ', '\u2588\u2588\u2588\u2588 ', '\u2588    ', '\u2588\u2588\u2588\u2588\u2588']
_D = ['\u2588\u2588\u2588\u2588 ', '\u2588   \u2588', '\u2588   \u2588', '\u2588   \u2588', '\u2588\u2588\u2588\u2588 ']
NUKED_ART = ['  '.join(r) for r in zip(_N, _U, _K, _E, _D)]


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def smoothstep(v):
    v = clamp(v)
    return v * v * (3.0 - 2.0 * v)


def lerp(a, b, t):
    return a + (b - a) * t


def supports_truecolor():
    tp = os.environ.get("TERM_PROGRAM", "")
    ct = os.environ.get("COLORTERM", "").lower()
    tm = os.environ.get("TERM", "").lower()
    if tp == "Apple_Terminal":
        return False
    return "truecolor" in ct or "24bit" in ct or tm.endswith("-direct") or "direct" in tm


@lru_cache(maxsize=None)
def rgb_to_256(r, g, b):
    if r == g == b:
        if r < 8:
            return 16
        if r > 248:
            return 231
        return round(((r - 8) / 247) * 24) + 232
    return 16 + 36 * round(r / 255 * 5) + 6 * round(g / 255 * 5) + round(b / 255 * 5)


@lru_cache(maxsize=None)
def fg_escape(truecolor, r, g, b):
    if truecolor:
        return f"\033[38;2;{r};{g};{b}m"
    return f"\033[38;5;{rgb_to_256(r, g, b)}m"


def mix_rgb(a, b, t):
    return tuple(max(0, min(255, int(round(lerp(x, y, t))))) for x, y in zip(a, b))


def scale_rgb(rgb, f):
    return tuple(max(0, min(255, int(round(c * f)))) for c in rgb)


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


def explosion_color(t, offset=0.0):
    t = clamp(t + offset * 0.15)
    for i in range(len(COLOR_STOPS) - 1):
        t0, c0 = COLOR_STOPS[i]
        t1, c1 = COLOR_STOPS[i + 1]
        if t <= t1:
            lt = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            return mix_rgb(c0, c1, lt)
    return COLOR_STOPS[-1][1]


class Particle:
    __slots__ = ('x', 'y', 'vx', 'vy', 'ch', 'life', 'age', 'drag', 'grav', 'co')

    def __init__(self, x, y, vx, vy, ch, life, drag=0.96, grav=0.0, co=0.0):
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.ch = ch
        self.life = life
        self.age = 0.0
        self.drag = drag
        self.grav = grav
        self.co = co

    def tick(self, dt):
        self.age += dt
        df = self.drag ** (dt * 60)
        self.vx *= df
        self.vy *= df
        self.vy += self.grav * dt
        self.x += self.vx * dt
        self.y += self.vy * dt

    def alive(self):
        return self.age < self.life


class WordFrag:
    __slots__ = ('txt', 'x', 'y', 'vx', 'vy', 'shatter_t', 'done', 'letters')

    def __init__(self, txt, x, y, vx, vy, shatter_t):
        self.txt = txt
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.shatter_t = shatter_t
        self.done = False
        self.letters = []

    def tick(self, dt, t):
        if not self.done and t >= self.shatter_t:
            self.done = True
            for i, c in enumerate(self.txt):
                a = random.uniform(0, math.tau)
                s = random.uniform(5, 15)
                self.letters.append(Particle(
                    self.x + i - len(self.txt) // 2, self.y,
                    math.cos(a) * s * 2, math.sin(a) * s,
                    c, random.uniform(1.5, 3.0), 0.94, 3.0, random.uniform(-0.2, 0.2)
                ))
        if not self.done:
            self.x += self.vx * dt
            self.y += self.vy * dt
        else:
            for letter in self.letters:
                letter.tick(dt)
            self.letters = [l for l in self.letters if l.alive()]


def cloud_density(nx, ny, ct):
    d = 0.0
    # Cap — massive ellipse that rises and expands
    ccy = -0.50 - 0.20 * ct
    crx = 0.52 + 0.15 * smoothstep(ct)
    cry = 0.24 + 0.08 * ct
    cdx = nx / crx
    cdy = (ny - ccy) / cry
    cd = math.sqrt(cdx * cdx + cdy * cdy)
    if cd < 1.0:
        d = max(d, (1.0 - cd) ** 0.45)
    # Inner hot core — tighter, much brighter
    core_rx = crx * 0.45
    core_ry = cry * 0.55
    core_dx = nx / core_rx
    core_dy = (ny - ccy) / core_ry
    core_d = math.sqrt(core_dx * core_dx + core_dy * core_dy)
    if core_d < 1.0:
        d = max(d, (1.0 - core_d) ** 0.3 * 1.5)
    # Stem — wider column with flared edges
    sw = 0.12 + 0.04 * ct
    s_top = ccy + cry * 0.7
    s_bot = 0.0
    if s_top < ny < s_bot and abs(nx) < sw:
        stem_f = (1.0 - abs(nx) / sw) ** 0.7
        base_near = clamp((ny - s_bot + 0.15) / 0.15)
        stem_f *= lerp(1.0, 1.4, base_near)
        d = max(d, stem_f * 0.7)
    # Base ring — wider toroidal bulge
    bcy = 0.0
    brx = 0.32 + 0.12 * ct
    bry = 0.13
    bdx = nx / brx
    bdy = (ny - bcy) / bry
    bd = math.sqrt(bdx * bdx + bdy * bdy)
    if bd < 1.0:
        d = max(d, (1.0 - bd) ** 0.7 * 0.65)
    return clamp(d)


def main():
    tty_f = open("/dev/tty", "r+b", buffering=0)
    fd = tty_f.fileno()
    old_attr = termios.tcgetattr(fd)
    truecolor = supports_truecolor()

    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?1049h\033[?25l\033[2J\033[H")
        sys.stdout.flush()

        sz = terminal_size(fd)
        cols, rows = sz.columns, sz.lines
        cx, cy = cols // 2, rows // 2

        # Pre-spawn detonation particles (won't move until T_PARTICLES)
        particles = []
        for _ in range(400):
            a = random.uniform(0, math.tau)
            s = random.uniform(25, 100)
            particles.append(Particle(
                cx, cy,
                math.cos(a) * s * 2, math.sin(a) * s,
                random.choice(CODE_GLYPHS),
                random.uniform(1.5, 5.0),
                drag=0.93, grav=1.5,
                co=random.uniform(-0.3, 0.3)
            ))
        for _ in range(150):
            a = random.uniform(0, math.tau)
            s = random.uniform(10, 40)
            particles.append(Particle(
                cx, cy,
                math.cos(a) * s * 2, math.sin(a) * s,
                random.choice(BLOCK_GLYPHS),
                random.uniform(0.8, 3.5),
                drag=0.91, grav=3.0,
                co=random.uniform(-0.5, -0.1)
            ))
        for _ in range(100):
            a = random.uniform(0, math.tau)
            s = random.uniform(60, 140)
            particles.append(Particle(
                cx, cy,
                math.cos(a) * s * 2, math.sin(a) * s,
                random.choice(['*', '+', '\u00b7', '\u2022', '\u2605']),
                random.uniform(0.3, 1.5),
                drag=0.96, grav=0.0,
                co=random.uniform(-0.6, -0.3)
            ))

        # Spawn distraction words
        words = []
        for i, w in enumerate(DISTRACTION_WORDS):
            a = (i / len(DISTRACTION_WORDS)) * math.tau + random.uniform(-0.3, 0.3)
            s = random.uniform(8, 20)
            words.append(WordFrag(
                w, cx, cy,
                math.cos(a) * s * 2, math.sin(a) * s,
                T_WORDS + 0.5 + random.uniform(0, 0.5)
            ))

        embers = []
        start = time.monotonic()
        frame_num = 0

        while True:
            t = time.monotonic() - start
            if t >= TOTAL_DURATION:
                break
            if check_cancel(fd):
                break

            new_sz = terminal_size(fd)
            if new_sz.columns != cols or new_sz.lines != rows:
                cols, rows = new_sz.columns, new_sz.lines
                cx, cy = cols // 2, rows // 2

            dt = 1.0 / FPS
            scr = {}

            # Screen shake during explosion
            shake_x, shake_y = 0, 0
            if T_FLASH <= t < T_FLASH + 3.5:
                si = (1.0 - (t - T_FLASH) / 3.5) ** 2
                shake_x = int(random.uniform(-5, 5) * si)
                shake_y = int(random.uniform(-3, 3) * si)

            # ============================================================
            # WARNING COUNTDOWN (0.0 - 2.0) — COD Nuketown vibes
            # ============================================================
            if t < T_FLASH:
                progress = t / T_FLASH
                flash_rate = 3 + progress * 10
                is_on = math.sin(t * flash_rate) > -0.2

                if is_on:
                    pulse = 0.6 + 0.4 * math.sin(t * 14)
                    wr = int(255 * pulse)
                    wg = int(40 * pulse)
                    wb = int(25 * pulse)

                    # Warning text
                    wx = cx - len(WARNING_TEXT) // 2
                    wy = cy - 4
                    for i, ch in enumerate(WARNING_TEXT):
                        sc = wx + i
                        if 0 <= sc < cols and 0 <= wy < rows:
                            scr[(sc, wy)] = (ch, wr, wg, wb)

                    # "IT'S OVER."
                    sx = cx - len(WARNING_SUB) // 2
                    sy = cy - 2
                    for i, ch in enumerate(WARNING_SUB):
                        sc = sx + i
                        if 0 <= sc < cols and 0 <= sy < rows:
                            scr[(sc, sy)] = (ch, int(wr * 0.7), int(wg * 0.5), wb)

                # Big countdown number
                countdown = max(1, 4 - int(progress * 3 + 1))
                if progress < 0.95:
                    count_str = str(countdown)
                    count_y = cy + 1
                    if 0 <= cx < cols and 0 <= count_y < rows:
                        cb = int(255 * (0.5 + 0.5 * abs(math.sin(t * 8))))
                        scr[(cx, count_y)] = (count_str, cb, cb, int(cb * 0.3))

                # Pulsing red border
                border_r = int(80 * (0.5 + 0.5 * math.sin(t * 8)))
                for row in range(rows):
                    for col in [0, 1, cols - 2, cols - 1]:
                        if 0 <= col < cols:
                            scr[(col, row)] = ('\u2502', border_r, 0, 0)
                for col in range(cols):
                    for row in [0, rows - 1]:
                        scr[(col, row)] = ('\u2500', border_r, 0, 0)

                # Static noise increasing near the end
                if progress > 0.6:
                    noise = (progress - 0.6) / 0.4
                    n_static = int(noise * noise * 120)
                    for _ in range(n_static):
                        nc = random.randint(0, cols - 1)
                        nr = random.randint(0, rows - 1)
                        if (nc, nr) not in scr:
                            nv = random.randint(15, 70)
                            scr[(nc, nr)] = (random.choice('\u2591\u2592\u2593'), nv, nv // 3, nv // 5)

            # ============================================================
            # WHITE FLASH (2.0 - 2.5)
            # ============================================================
            if T_FLASH <= t < T_FLASH + 0.5:
                ft = (t - T_FLASH) / 0.5
                fi = 1.0 - smoothstep(ft)
                fill = fi * 0.98
                phase = smoothstep(ft)
                for row in range(rows):
                    for col in range(cols):
                        if random.random() < fill:
                            if phase < 0.25:
                                r, g, b = 255, 255, int(255 * (1.0 - phase * 1.2))
                            elif phase < 0.5:
                                p2 = (phase - 0.25) / 0.25
                                r = 255
                                g = int(255 * (1.0 - p2 * 0.35))
                                b = int(190 * (1.0 - p2 * 0.8))
                            else:
                                p3 = (phase - 0.5) / 0.5
                                r = int(255 * (1.0 - p3 * 0.15))
                                g = int(166 * (1.0 - p3 * 0.55))
                                b = int(38 * (1.0 - p3 * 0.9))
                            bright = fi * fi
                            scr[(col, row)] = (random.choice(BLOCK_GLYPHS), int(r * bright), int(g * bright), int(b * bright))

            # ============================================================
            # DETONATION PARTICLES
            # ============================================================
            if t >= T_PARTICLES:
                for p in particles:
                    p.tick(dt)
                particles = [p for p in particles if p.alive()]
                for p in particles:
                    pc, pr = int(round(p.x)), int(round(p.y))
                    if 0 <= pc < cols and 0 <= pr < rows:
                        af = p.age / p.life
                        rgb = scale_rgb(explosion_color(af, p.co), 1.0 - smoothstep(af))
                        scr[(pc, pr)] = (p.ch, *rgb)

            # ============================================================
            # DISTRACTION WORDS
            # ============================================================
            if t >= T_WORDS:
                for wf in words:
                    wf.tick(dt, t)
                for wf in words:
                    if not wf.done:
                        for i, ch in enumerate(wf.txt):
                            wc = int(round(wf.x)) + i - len(wf.txt) // 2
                            wr = int(round(wf.y))
                            if 0 <= wc < cols and 0 <= wr < rows:
                                scr[(wc, wr)] = (ch, 255, 100, 30)
                    else:
                        for lt in wf.letters:
                            lc, lr = int(round(lt.x)), int(round(lt.y))
                            if 0 <= lc < cols and 0 <= lr < rows:
                                af = lt.age / lt.life
                                rgb = scale_rgb(explosion_color(af, lt.co), 1.0 - smoothstep(af))
                                scr[(lc, lr)] = (lt.ch, *rgb)

            # ============================================================
            # SHOCKWAVES (3 cascading rings)
            # ============================================================
            for wave_off, wave_speed, wave_bright in [(0, 1.0, 1.0), (0.25, 0.85, 0.8), (0.55, 0.65, 0.55)]:
                ws = T_SHOCK + wave_off
                we = ws + 1.5
                if ws <= t < we:
                    rt = (t - ws) / (we - ws)
                    rr = rt * min(cols / 2, rows) * wave_speed
                    opacity = (1.0 - rt) * wave_bright
                    n_pts = max(40, int(rr * 10))
                    for i in range(n_pts):
                        a = (i / n_pts) * math.tau
                        for thickness in range(4):
                            r_off = rr + (thickness - 1.5) * 0.5
                            sc = int(cx + math.cos(a) * r_off * 2)
                            sr = int(cy + math.sin(a) * r_off)
                            if 0 <= sc < cols and 0 <= sr < rows:
                                bv = int(250 * opacity * (1.0 - thickness * 0.2))
                                scr[(sc, sr)] = (SHOCKWAVE_GLYPHS[i % len(SHOCKWAVE_GLYPHS)], bv, int(bv * 0.8), int(bv * 0.35))

            # ============================================================
            # MUSHROOM CLOUD — psychedelic fire
            # ============================================================
            if t >= T_CLOUD and cols >= 40:
                cloud_t = smoothstep(clamp((t - T_CLOUD) / 1.5))
                cloud_fade = 1.0
                if t >= T_TEXT:
                    cloud_fade = lerp(1.0, 0.10, clamp((t - T_TEXT) / 1.0))

                # Psychedelic color cycling
                hue_shift = math.sin(frame_num * 0.08) * 0.2
                hue_shift2 = math.cos(frame_num * 0.05 + 1.3) * 0.15

                cl_w = int(cols * 0.94)
                cl_h = max(1, int(rows * 0.92))
                cl_top = int(rows * 0.03)
                cl_left = (cols - cl_w) // 2

                for row in range(cl_h):
                    sr = cl_top + row
                    if sr < 0 or sr >= rows:
                        continue
                    ny = -1.0 + row / max(1, cl_h - 1)
                    for col in range(cl_w):
                        sc = cl_left + col
                        if sc < 0 or sc >= cols:
                            continue
                        nx = -1.0 + (col / max(1, cl_w - 1)) * 2.0

                        dens = cloud_density(nx, ny, cloud_t)
                        # Triple-layer turbulence for organic churning
                        turb1 = math.sin(nx * 8 + frame_num * 0.3) * math.cos(ny * 6 + frame_num * 0.25)
                        turb2 = math.sin(nx * 14 + frame_num * 0.5 + 1.7) * math.cos(ny * 11 + frame_num * 0.4)
                        turb3 = math.sin(nx * 3 + frame_num * 0.15 + 3.1) * math.cos(ny * 4 + frame_num * 0.1)
                        dens = clamp(dens + turb1 * 0.14 + turb2 * 0.07 + turb3 * 0.09)
                        if dens < 0.03:
                            continue

                        dens *= cloud_fade

                        # Glyph by density
                        h = ((col * 7 + row * 13 + frame_num * 3) % 17) / 17.0
                        if dens > 0.85:
                            glyph = BLOCK_GLYPHS[0]
                        elif dens > 0.55:
                            glyph = BLOCK_GLYPHS[int(h * 2) % 2]
                        elif dens > 0.25:
                            glyph = CODE_GLYPHS[int(h * len(CODE_GLYPHS)) % len(CODE_GLYPHS)]
                        else:
                            glyph = EMBER_GLYPHS[int(h * len(EMBER_GLYPHS)) % len(EMBER_GLYPHS)]

                        # Hot white core → yellow → orange → red
                        if dens > 0.95:
                            # Blazing white-hot core
                            core_b = clamp((dens - 0.95) / 0.05)
                            rgb = mix_rgb((255, 230, 100), (255, 255, 235), core_b)
                            # Psychedelic shift
                            r, g, b = rgb
                            g = max(0, min(255, g + int(hue_shift * 50)))
                            b = max(0, min(255, b + int(hue_shift2 * 40)))
                            rgb = (r, g, b)
                            rgb = scale_rgb(rgb, cloud_fade)
                        elif dens > 0.7:
                            # Bright yellow-white
                            hot_t = (dens - 0.7) / 0.25
                            rgb = mix_rgb((255, 160, 30), (255, 230, 100), hot_t)
                            r, g, b = rgb
                            r = max(0, min(255, r + int(hue_shift * 30)))
                            rgb = (r, g, b)
                            rgb = scale_rgb(rgb, dens * cloud_fade)
                        elif dens > 0.4:
                            # Orange fire
                            hot_t = (dens - 0.4) / 0.3
                            rgb = mix_rgb((220, 60, 10), (255, 160, 30), hot_t)
                            r, g, b = rgb
                            g = max(0, min(255, g + int(hue_shift2 * 25)))
                            rgb = (r, g, b)
                            rgb = scale_rgb(rgb, dens * 1.2 * cloud_fade)
                        else:
                            # Deep red outer glow
                            color_t = 0.45 + 0.35 * (1.0 - dens / 0.4) + hue_shift * 0.3
                            rgb = scale_rgb(explosion_color(clamp(color_t)), dens * 1.5 * cloud_fade)

                        if (sc, sr) not in scr:
                            scr[(sc, sr)] = (glyph, *rgb)

            # ============================================================
            # GROUND FIRE — spreading along bottom
            # ============================================================
            if T_FLASH + 0.5 <= t < T_TEXT + 2.5:
                fire_spread = clamp((t - T_FLASH - 0.5) / 2.0)
                fire_fade = 1.0
                if t >= T_TEXT:
                    fire_fade = max(0, 1.0 - (t - T_TEXT) / 2.5)
                fire_width = int(cols * fire_spread * 0.85)
                fire_left = cx - fire_width // 2
                for col in range(fire_width):
                    fc = fire_left + col
                    if fc < 0 or fc >= cols:
                        continue
                    for row_off in range(min(5, rows)):
                        fr = rows - 1 - row_off
                        if fr < 0 or fr >= rows:
                            continue
                        intensity = (1.0 - row_off / 5.0) * fire_fade
                        if random.random() < 0.5 * intensity:
                            fr_r = random.randint(180, 255)
                            fr_g = random.randint(30, int(80 + 60 * (1.0 - row_off / 5.0)))
                            fr_b = random.randint(0, 20)
                            scr[(fc, fr)] = (random.choice(BLOCK_GLYPHS[:3]), fr_r, fr_g, fr_b)

            # ============================================================
            # EMBER RAIN
            # ============================================================
            if t >= T_EMBERS:
                if len(embers) < 250:
                    for _ in range(8):
                        ex = cx + random.uniform(-cols * 0.45, cols * 0.45)
                        ey = random.uniform(rows * 0.03, rows * 0.3)
                        embers.append(Particle(
                            ex, ey,
                            random.uniform(-3, 3), random.uniform(2, 9),
                            random.choice(EMBER_GLYPHS + BLOCK_GLYPHS[2:]),
                            random.uniform(2.0, 5.0),
                            drag=0.98, grav=2.0,
                            co=random.uniform(0.1, 0.5)
                        ))
                for e in embers:
                    e.tick(dt)
                embers = [e for e in embers if e.alive()]
                for e in embers:
                    ec, er = int(round(e.x)), int(round(e.y))
                    if 0 <= ec < cols and 0 <= er < rows:
                        af = e.age / e.life
                        rgb = scale_rgb(explosion_color(0.35 + af * 0.55, e.co), (1.0 - smoothstep(af)) * 0.85)
                        scr[(ec, er)] = (e.ch, *rgb)

            # ============================================================
            # AMBIENT RED GLOW during peak explosion
            # ============================================================
            if T_FLASH + 0.5 <= t < T_CLOUD + 1.5:
                glow = clamp(1.0 - (t - T_FLASH - 0.5) / (T_CLOUD + 1.5 - T_FLASH - 0.5)) * 0.4
                n_glow = int(glow * 300)
                for _ in range(n_glow):
                    gc = random.randint(0, cols - 1)
                    gr = random.randint(0, rows - 1)
                    if (gc, gr) not in scr:
                        rv = int(55 * glow * random.random())
                        if rv > 3:
                            scr[(gc, gr)] = (' ', rv, rv // 5, 0)

            # ============================================================
            # BIG "NUKED" TEXT + SUBTITLES
            # ============================================================
            if t >= T_TEXT:
                art_w = len(NUKED_ART[0])
                art_h = len(NUKED_ART)
                art_y = cy - art_h // 2 - 1
                art_x = cx - art_w // 2

                # Clear zone — dim cloud behind text
                clear_w = art_w + 10
                clear_h = art_h + 10
                clear_left = cx - clear_w // 2
                clear_top = art_y - 4
                clear_fade = clamp((t - T_TEXT) / 0.6)
                for row in range(clear_top, clear_top + clear_h):
                    for col in range(clear_left, clear_left + clear_w):
                        if 0 <= col < cols and 0 <= row < rows and (col, row) in scr:
                            ch, r, g, b = scr[(col, row)]
                            dim = 1.0 - clear_fade * 0.92
                            scr[(col, row)] = (ch, int(r * dim), int(g * dim), int(b * dim))

                # Big NUKED — blazing reveal from center
                reveal = clamp((t - T_TEXT) / 0.7)
                pulse = 0.5 + 0.5 * math.sin((t - T_TEXT) * 6)
                mid_col = art_w // 2

                for row_i, row_str in enumerate(NUKED_ART):
                    sy = art_y + row_i
                    if sy < 0 or sy >= rows:
                        continue
                    for col_i, ch in enumerate(row_str):
                        if ch == ' ':
                            continue
                        dist = abs(col_i - mid_col) / max(mid_col, 1)
                        if reveal >= dist:
                            sc = art_x + col_i
                            if 0 <= sc < cols:
                                tr = 255
                                tg = int(lerp(200, 255, pulse))
                                tb = int(lerp(80, 180, pulse))
                                scr[(sc, sy)] = (ch, tr, tg, tb)

                # Subtitles
                sub1 = "YOUR DISTRACTIONS HAVE BEEN ELIMINATED."
                sub2 = "All social media blocked for 24 hours."
                sub3 = "No breathing exercise will save you."

                fade1 = clamp((t - T_SUB) / 0.6)
                fade2 = clamp((t - T_SUB - 0.3) / 0.6)
                fade3 = clamp((t - T_SUB - 0.6) / 0.6)

                sub_y = art_y + art_h + 2
                for sub, fade, dy in [(sub1, fade1, 0), (sub2, fade2, 2), (sub3, fade3, 3)]:
                    if fade <= 0:
                        continue
                    sx = cx - len(sub) // 2
                    sy = sub_y + dy
                    for i, ch in enumerate(sub):
                        sc = sx + i
                        if 0 <= sc < cols and 0 <= sy < rows:
                            if dy == 0:
                                # Red tint for elimination text
                                bv = int(240 * fade)
                                scr[(sc, sy)] = (ch, bv, int(bv * 0.35), int(bv * 0.25))
                            else:
                                bv = int(180 * fade)
                                scr[(sc, sy)] = (ch, bv, bv, bv)

            # ============================================================
            # RENDER — with screen shake + CRT scanlines
            # ============================================================
            buf = ["\033[H"]
            for row in range(rows):
                scanline = 0.72 if row % 2 == 0 else 1.0
                last_esc = None
                for col in range(cols):
                    # Apply screen shake at read time
                    src_col = col - shake_x
                    src_row = row - shake_y
                    cell = scr.get((src_col, src_row))
                    if cell:
                        ch, r, g, b = cell
                        r = int(r * scanline)
                        g = int(g * scanline)
                        b = int(b * scanline)
                        esc = fg_escape(truecolor, r, g, b)
                        if esc != last_esc:
                            buf.append(esc)
                            last_esc = esc
                        buf.append(ch)
                    else:
                        if last_esc is not None:
                            buf.append("\033[0m")
                            last_esc = None
                        buf.append(' ')
                if last_esc is not None:
                    buf.append("\033[0m")
                buf.append("\033[K")
                if row < rows - 1:
                    buf.append("\n")

            sys.stdout.write("".join(buf))
            sys.stdout.flush()

            frame_num += 1
            target = start + frame_num / FPS
            sleep_for = target - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)

    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_attr)
        tty_f.close()
        sys.stdout.write("\033[0m\033[?25h\033[?1049l")
        sys.stdout.flush()


main()
NUKE_EOF

if [ -n "$TTY_STATE" ]; then
  stty "$TTY_STATE" </dev/tty 2>/dev/null
else
  stty sane </dev/tty 2>/dev/null
fi

# Static confirmation (visible in scrollback after animation)
printf '\033[1;31m'
echo "  ================================================"
echo "     NUKED. All social media blocked for 24 hours."
echo "     No breathing exercise will save you."
echo "  ================================================"
printf '\033[0m\n'
echo "  Expires at $EXPIRY_TIME tomorrow."
echo ""
