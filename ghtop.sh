# make_ghtop_deb.sh
#!/usr/bin/env bash
set -euo pipefail

PKG="ghtop"
VER="${1:-0.1.0}"          # ./make_ghtop_deb.sh 0.1.1
ARCH="all"
WORKDIR="$(pwd)/${PKG}_${VER}"
DEBDIR="${WORKDIR}/DEBIAN"
BINDIR="${WORKDIR}/usr/bin"
LIBDIR="${WORKDIR}/usr/lib/${PKG}"
DEB="${PKG}_${VER}.deb"

green() { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
red()   { printf "\033[1;31m[!]\033[0m %s\n" "$*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || { red "Missing command: $1"; exit 1; }; }

# 0) Sanity
require_cmd apt-get
require_cmd dpkg-deb

green "Updating apt and installing build/runtime deps…"
sudo apt-get update -y
sudo apt-get install -y \
  python3 python3-psutil \
  dpkg-dev fakeroot

green "Preparing package tree: ${WORKDIR}"
rm -rf "${WORKDIR}"
mkdir -p "${DEBDIR}" "${BINDIR}" "${LIBDIR}"

green "Writing control file…"
cat > "${DEBDIR}/control" <<EOF
Package: ${PKG}
Version: ${VER}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: NaturalOS Team <contato@naturalos.org>
Depends: python3, python3-psutil
Description: Console-based system monitor with ASCII graphics
 ${PKG} is a lightweight, console-based system monitor that displays CPU, memory,
 and disk I/O usage using ASCII graphics in real time. It is written in Python
 and uses psutil for metrics.
EOF

green "Adding postinst/prerm…"
cat > "${DEBDIR}/postinst" <<'EOF'
#!/bin/sh
set -e
echo "ghtop installed. Run: ghtop"
exit 0
EOF
chmod 0755 "${DEBDIR}/postinst"

cat > "${DEBDIR}/prerm" <<'EOF'
#!/bin/sh
set -e
echo "Removing ghtop…"
exit 0
EOF
chmod 0755 "${DEBDIR}/prerm"

green "Writing /usr/lib/${PKG}/${PKG}.py (colored UI, better graphs)…"
cat > "${LIBDIR}/${PKG}.py" <<'PYCODE'
#!/usr/bin/env python3
# ghtop - console graphics for CPU/MEM/DISK I/O
# Theme: black + "orange" (yellow) + baby blue (cyan)
import curses, time, argparse
from collections import deque, defaultdict
import psutil

# ====== Config ======
DEFAULT_REFRESH = 1.0    # seconds
HIST_LEN = 60            # sparkline points (rightmost = most recent)
BAR_CHAR = "█"
SPARK_CHARS = "▁▂▃▄▅▆▇█"  # 8 levels
PANEL_SPACING = 1

# ====== helpers ======
def spark(values):
    if not values:
        return ""
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return SPARK_CHARS[0] * len(values)
    out, rng, steps = [], (hi - lo), (len(SPARK_CHARS) - 1)
    for v in values:
        idx = int((v - lo) / rng * steps)
        if idx < 0: idx = 0
        if idx > steps: idx = steps
        out.append(SPARK_CHARS[idx])
    return "".join(out)

def human(n):
    units = ["B","KB","MB","GB","TB","PB"]
    f = float(n); u = 0
    while f >= 1024.0 and u < len(units)-1:
        f /= 1024.0; u += 1
    return f"{f:.1f}{units[u]}" if f < 100 else f"{int(f)}{units[u]}"

def clamp(v, lo, hi): return lo if v < lo else (hi if v > hi else v)

# ====== drawing (safe) ======
def addstr_safe(win, y, x, text, attr=0):
    try:
        h, w = win.getmaxyx()
        if 0 <= y < h and x < w:
            maxw = max(0, w - x - 1)
            if maxw > 0 and text:
                win.addnstr(y, x, text, maxw, attr)
    except curses.error:
        pass

def draw_bar(win, y, x, pct, width, color_attr):
    """Draw a colored bar [████     ] safely."""
    try:
        h, w = win.getmaxyx()
        if width <= 0 or y < 0 or y >= h or x >= w: return
        width = min(width, max(1, w - x - 2))  # reserve closing bracket
        pct = clamp(pct, 0.0, 100.0)
        filled = int(round(pct/100.0 * width))
        addstr_safe(win, y, x, "[")
        if filled > 0:
            addstr_safe(win, y, x+1, BAR_CHAR*filled, color_attr | curses.A_BOLD)
        if filled < width:
            addstr_safe(win, y, x+1+filled, " "*(width-filled), curses.A_DIM)
        addstr_safe(win, y, x+1+width, "]")
    except curses.error:
        pass

def init_colors():
    pairs = {}
    try:
        curses.start_color()
        curses.use_default_colors()
    except curses.error:
        return pairs  # monochrome fallback

    FG = {
        "white": curses.COLOR_WHITE if curses.has_colors() else -1,
        "orange": curses.COLOR_YELLOW,   # "laranja"
        "babyblue": curses.COLOR_CYAN,   # "azul-bebê"
        "blue": curses.COLOR_BLUE,
        "black": curses.COLOR_BLACK
    }
    pid = 1
    def mk(name, fg, bg=-1):
        nonlocal pid
        try:
            curses.init_pair(pid, fg, bg)
            pairs[name] = curses.color_pair(pid)
            pid += 1
        except curses.error:
            pairs[name] = 0

    mk("text",  FG["white"], -1)
    mk("title", FG["orange"], -1)
    mk("cpu",   FG["babyblue"], -1)
    mk("mem",   FG["orange"], -1)
    mk("io",    FG["blue"], -1)
    mk("muted", FG["white"], -1)
    return pairs

# ====== main loop ======
def run(stdscr, refresh: float, duration: float, start_perdisk: bool):
    curses.curs_set(0)
    try:
        curses.use_default_colors()
    except curses.error:
        pass
    stdscr.nodelay(True)

    colors = init_colors()
    c_text  = colors.get("text", 0)
    c_title = colors.get("title", curses.A_BOLD)
    c_cpu   = colors.get("cpu", curses.A_BOLD)
    c_mem   = colors.get("mem", curses.A_BOLD)
    c_io    = colors.get("io", curses.A_BOLD)

    show_disks = start_perdisk

    # histories
    cpu_hist_total = deque(maxlen=HIST_LEN)
    cpu_hist_cores = defaultdict(lambda: deque(maxlen=HIST_LEN))
    mem_hist = deque(maxlen=HIST_LEN)
    io_hist_r = deque(maxlen=HIST_LEN)
    io_hist_w = deque(maxlen=HIST_LEN)

    # baseline I/O
    last_disk = psutil.disk_io_counters()
    last_time = time.time()
    started_at = time.time()

    # dynamic IO scale (EMA of peak)
    io_scale = 10 * 1024 * 1024  # start ~10 MiB/s
    ema_alpha = 0.2              # smoothing

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        inner_w = max(20, w - 36)

        # Title
        title = " ghtop — CPU • Memory • Disk I/O  (q: quit  +/-: refresh  d: per-disk) "
        addstr_safe(stdscr, 0, 0, title, c_title | curses.A_BOLD)

        # CPU
        cpu_total = psutil.cpu_percent(interval=None)
        cpu_per = psutil.cpu_percent(interval=None, percpu=True)
        cpu_hist_total.append(cpu_total)

        y = 2
        addstr_safe(stdscr, y, 0, "CPU", c_title | curses.A_BOLD); y += 1

        # CPU total
        lbl = f"Total {cpu_total:5.1f}% "
        addstr_safe(stdscr, y, 0, lbl, c_text)
        draw_bar(stdscr, y, len(lbl), cpu_total, inner_w, c_cpu)
        addstr_safe(stdscr, y, len(lbl)+inner_w+3, spark(cpu_hist_total), c_cpu); y += 1

        # CPU per-core (auto columns)
        cols = max(1, w // 34)
        colw = max(30, w // max(1, cols))
        col_i = 0
        for i, v in enumerate(cpu_per):
            x = (col_i % cols) * colw
            yy = y + (col_i // cols)
            line = f"Core {i:>2} {v:5.1f}% "
            addstr_safe(stdscr, yy, x, line, c_text)
            draw_bar(stdscr, yy, x+len(line), v, min(inner_w, colw-22), c_cpu)
            cpu_hist_cores[i].append(v)
            s = spark(cpu_hist_cores[i])
            addstr_safe(stdscr, yy, x+len(line)+min(inner_w, colw-22)+3, s[-12:], c_cpu)
            col_i += 1
            if yy >= h - 10:
                break
        y = y + (max(1, (col_i + cols - 1) // cols)) + PANEL_SPACING

        # Memory
        addstr_safe(stdscr, y, 0, "Memory", c_title | curses.A_BOLD); y += 1
        vm = psutil.virtual_memory()
        mem_pct = vm.percent
        mem_hist.append(mem_pct)
        lbl = f"Used {mem_pct:5.1f}%  {human(vm.used)}/{human(vm.total)} "
        addstr_safe(stdscr, y, 0, lbl, c_text)
        draw_bar(stdscr, y, len(lbl), mem_pct, inner_w, c_mem)
        addstr_safe(stdscr, y, len(lbl)+inner_w+3, spark(mem_hist), c_mem); y += 1

        # Disk FS usage (/)
        try:
            du = psutil.disk_usage("/")
            du_pct = du.percent
            lbl = f"FS '/' {du_pct:5.1f}%  {human(du.used)}/{human(du.total)} "
            addstr_safe(stdscr, y, 0, lbl, c_text)
            draw_bar(stdscr, y, len(lbl), du_pct, inner_w, c_io); y += 1
        except Exception:
            pass

        # Disk I/O with dynamic scale
        now_disk = psutil.disk_io_counters()
        now_time = time.time()
        dt = max(1e-6, now_time - last_time)
        rps = (now_disk.read_bytes - last_disk.read_bytes)/dt
        wps = (now_disk.write_bytes - last_disk.write_bytes)/dt
        last_disk = now_disk; last_time = now_time

        io_hist_r.append(rps); io_hist_w.append(wps)
        recent_peak = max(max(io_hist_r) if io_hist_r else 1, max(io_hist_w) if io_hist_w else 1, 1)
        # EMA toward recent peak, never below 1 MiB/s
        target_scale = max(recent_peak, 1*1024*1024)
        io_scale = (1-ema_alpha)*io_scale + ema_alpha*target_scale

        def io_pct(bps): 
            return clamp((bps / max(1.0, io_scale)) * 100.0, 0.0, 100.0)

        lbl = f"I/O Read  {human(rps)}/s "
        addstr_safe(stdscr, y, 0, lbl, c_text)
        draw_bar(stdscr, y, len(lbl), io_pct(rps), inner_w, c_io)
        addstr_safe(stdscr, y, len(lbl)+inner_w+3, spark(io_hist_r), c_io); y+=1

        lbl = f"I/O Write {human(wps)}/s "
        addstr_safe(stdscr, y, 0, lbl, c_text)
        draw_bar(stdscr, y, len(lbl), io_pct(wps), inner_w, c_io)
        addstr_safe(stdscr, y, len(lbl)+inner_w+3, spark(io_hist_w), c_io); y+=1

        # Per-disk
        if show_disks:
            y += 1
            addstr_safe(stdscr, y, 0, "Per-disk I/O (cumulative since boot):", c_title | curses.A_BOLD); y+=1
            try:
                for name, ioc in psutil.disk_io_counters(perdisk=True).items():
                    line = f"  {name:<12} R:{human(ioc.read_bytes)}  W:{human(ioc.write_bytes)}"
                    addstr_safe(stdscr, y, 0, line, c_text)
                    y += 1
                    if y >= h - 2: break
            except Exception:
                pass

        # Footer
        footer = f"Refresh: {refresh:.2f}s   Term: {w}x{h}   Scale(IO): ~{human(io_scale)}/s at 100%"
        addstr_safe(stdscr, h-1, 0, footer, c_title)

        stdscr.refresh()

        # input + wait
        waited = 0.0
        started_loop = time.time()
        while waited < refresh:
            try:
                ch = stdscr.getch()
            except curses.error:
                ch = -1
            if ch == ord('q'):
                return
            elif ch == ord('+'):
                refresh = max(0.05, refresh - 0.05)
            elif ch == ord('-'):
                refresh = min(5.0, refresh + 0.05)
            elif ch == ord('d'):
                show_disks = not show_disks
            time.sleep(0.05)
            waited = time.time() - started_loop

        if duration > 0 and (time.time() - started_at) >= duration:
            return

def parse_args():
    ap = argparse.ArgumentParser(description="ghtop - console graphics for CPU/MEM/DISK I/O")
    ap.add_argument("--interval", "-i", type=float, default=DEFAULT_REFRESH, help="refresh interval in seconds (default: 1.0)")
    ap.add_argument("--duration", "-t", type=float, default=0.0, help="run time in seconds (0 = infinite)")
    ap.add_argument("--per-disk", action="store_true", help="start with per-disk panel visible")
    ap.add_argument("--selftest", action="store_true", help="run for ~2 seconds and exit (for CI/packaging)")
    return ap.parse_args()

def main():
    args = parse_args()
    refresh = max(0.01, args.interval)
    duration = 2.0 if args.selftest else max(0.0, args.duration)
    curses.wrapper(lambda stdscr: run(stdscr, refresh, duration, args.per_disk))

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
PYCODE
chmod 0644 "${LIBDIR}/${PKG}.py"

green "Writing /usr/bin/${PKG} wrapper…"
cat > "${BINDIR}/${PKG}" <<EOF
#!/bin/sh
exec python3 /usr/lib/${PKG}/${PKG}.py "\$@"
EOF
chmod 0755 "${BINDIR}/${PKG}"

green "Building ${DEB}…"
fakeroot dpkg-deb --build "${WORKDIR}" "${DEB}"

green "Installing ${DEB}…"
sudo apt-get install -y "./${DEB}"

green "Running self-test (2s)…"
/usr/bin/${PKG} --selftest || true

green "Done!"
echo "Package: ${DEB}"
echo "Run:     ${PKG}"
echo "Remove:  sudo apt remove ${PKG}"
