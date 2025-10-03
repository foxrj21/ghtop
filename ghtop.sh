# make_ghtop_deb.sh
#!/usr/bin/env bash
set -euo pipefail

PKG="ghtop"
VER="${1:-0.1.0}"          # permite passar versão: ./make_ghtop_deb.sh 0.1.1
ARCH="all"
WORKDIR="$(pwd)/${PKG}_${VER}"
DEBDIR="${WORKDIR}/DEBIAN"
BINDIR="${WORKDIR}/usr/bin"
LIBDIR="${WORKDIR}/usr/lib/${PKG}"
DEB="${PKG}_${VER}.deb"

green() { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
red()   { printf "\033[1;31m[!]\033[0m %s\n" "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing command: $1"; exit 1; }
}

# 0) sanity
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

green "Adding postinst/prerm (optional clean messages)…"
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

green "Writing /usr/lib/${PKG}/${PKG}.py…"
cat > "${LIBDIR}/${PKG}.py" <<'PYCODE'
#!/usr/bin/env python3
import curses, time, argparse
from collections import deque, defaultdict
import psutil

# ====== Config ======
DEFAULT_REFRESH = 1.0   # seconds
HIST_LEN = 60           # sparkline points
BAR_CHAR = "█"
SPARK_CHARS = "▁▂▃▄▅▆▇█"  # 8 levels

def spark(values):
    if not values:
        return ""
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return SPARK_CHARS[0] * len(values)
    out = []
    rng = hi - lo
    steps = len(SPARK_CHARS) - 1
    for v in values:
        idx = int((v - lo) / rng * steps)
        if idx < 0: idx = 0
        if idx > steps: idx = steps
        out.append(SPARK_CHARS[idx])
    return "".join(out)

def bar(pct, width):
    pct = max(0.0, min(100.0, pct))
    width = max(1, width)
    filled = int(round(pct/100.0 * width))
    if filled > width: filled = width
    return BAR_CHAR*filled + " "*(width-filled)

def human(n):
    units = ["B","KB","MB","GB","TB","PB"]
    f = float(n); u = 0
    while f >= 1024.0 and u < len(units)-1:
        f /= 1024.0; u += 1
    return f"{f:.1f}{units[u]}" if f < 100 else f"{int(f)}{units[u]}"

def draw_line(stdscr, y, text, color=0):
    h, w = stdscr.getmaxyx()
    if 0 <= y < h:
        maxw = max(1, w - 1)
        try:
            stdscr.addnstr(y, 0, text[:maxw].ljust(maxw), maxw, color)
        except curses.error:
            pass

def run(stdscr, refresh: float, duration: float, start_perdisk: bool):
    curses.curs_set(0)
    try:
        curses.use_default_colors()
    except curses.error:
        pass
    stdscr.nodelay(True)

    show_disks = start_perdisk

    cpu_hist_total = deque(maxlen=HIST_LEN)
    cpu_hist_cores = defaultdict(lambda: deque(maxlen=HIST_LEN))
    mem_hist = deque(maxlen=HIST_LEN)
    io_hist_r = deque(maxlen=HIST_LEN)
    io_hist_w = deque(maxlen=HIST_LEN)

    last_disk = psutil.disk_io_counters()
    last_time = time.time()
    started_at = time.time()

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        inner_w = max(10, w - 30)

        draw_line(stdscr, 0, "ghtop — CPU/MEM/DISK I/O  (q: quit  +/-: refresh  d: per-disk)")

        cpu_total = psutil.cpu_percent(interval=None)
        cpu_per = psutil.cpu_percent(interval=None, percpu=True)
        cpu_hist_total.append(cpu_total)

        y = 2
        draw_line(stdscr, y, f"CPU Total: {cpu_total:5.1f}%  [{bar(cpu_total, inner_w)}]  {spark(cpu_hist_total)}"); y+=1
        for i, v in enumerate(cpu_per):
            cpu_hist_cores[i].append(v)
            draw_line(stdscr, y, f"Core {i:>2}: {v:5.1f}%  [{bar(v, inner_w)}]  {spark(cpu_hist_cores[i])}")
            y += 1
            if y >= h-8:
                break

        y += 1
        vm = psutil.virtual_memory()
        mem_pct = vm.percent
        mem_hist.append(mem_pct)
        draw_line(stdscr, y, f"Memory: {mem_pct:5.1f}%  {human(vm.used)}/{human(vm.total)}  [{bar(mem_pct, inner_w)}]  {spark(mem_hist)}"); y+=1

        try:
            du = psutil.disk_usage("/")
            du_pct = du.percent
            draw_line(stdscr, y, f"Disk FS '/': {du_pct:5.1f}%  {human(du.used)}/{human(du.total)}  [{bar(du_pct, inner_w)}]"); y+=1
        except Exception:
            pass

        now_disk = psutil.disk_io_counters()
        now_time = time.time()
        dt = max(1e-6, now_time - last_time)
        rps = (now_disk.read_bytes - last_disk.read_bytes)/dt
        wps = (now_disk.write_bytes - last_disk.write_bytes)/dt
        io_hist_r.append(rps); io_hist_w.append(wps)
        last_disk = now_disk; last_time = now_time

        def io_pct(bps): 
            return min(100.0, (bps / (10*1024*1024)) * 100.0)  # 10 MiB/s = 100%

        draw_line(stdscr, y, f"I/O Read:  {human(rps)}/s  [{bar(io_pct(rps), inner_w)}]  {spark(io_hist_r)}"); y+=1
        draw_line(stdscr, y, f"I/O Write: {human(wps)}/s  [{bar(io_pct(wps), inner_w)}]  {spark(io_hist_w)}"); y+=1

        if show_disks:
            y += 1
            draw_line(stdscr, y, "Per-disk I/O (cumulative since boot):"); y+=1
            try:
                for name, ioc in psutil.disk_io_counters(perdisk=True).items():
                    draw_line(stdscr, y, f"  {name:<12} R:{human(ioc.read_bytes)} W:{human(ioc.write_bytes)}")
                    y += 1
                    if y >= h-2: break
            except Exception:
                pass

        footer = f"Refresh: {refresh:.2f}s   Term: {w}x{h}"
        draw_line(stdscr, h-1, footer)
        stdscr.refresh()

        waited = 0.0
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
            waited += 0.05

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
# roda por ~2 segundos e sai (não bloqueia o terminal)
"${BINDIR}/${PKG}" --selftest || true

green "Done!"
echo "Package: ${DEB}"
echo "Run:     ${PKG}"
echo "Remove:  sudo apt remove ${PKG}"
