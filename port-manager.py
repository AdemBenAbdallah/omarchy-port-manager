#!/usr/bin/env python3
"""Backend for the Port Manager Omarchy plugin.

Everything the panel knows about a listening socket is produced here, as a
single JSON document on stdout. The QML side never shells out to anything
else, so one `ss` pass plus a handful of /proc reads is the whole cost of a
refresh.

Commands:
    (none)              list every listening socket
    stop PID [--force]  SIGTERM (or SIGKILL) a process this user owns
    kill-port PORT      stop whatever holds PORT
    check PORT          report whether PORT is free, and who holds it
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

CLOCK_TICKS = os.sysconf("SC_CLK_TCK")

# Loopback addresses only this machine can reach. Anything else on a
# listening socket means the port is reachable from the network.
LOCAL_HOSTS = {"127.0.0.1", "::1", "localhost", "127.0.0.53"}

# Glyphs are Nerd Font devicons, written as escapes so the source stays
# plain ASCII and survives any editor or transport that mangles the private
# use area. One glyph per runtime family rather than per framework: the
# family is what you recognise at a glance in a list.
JS = "\ue718"        # nodejs
PY = "\ue73c"        # python
RB = "\ue739"        # ruby
PHP = "\ue73d"       # php
GO = "\ue626"        # go
RS = "\ue7a8"        # rust
JV = "\ue738"        # java
DK = "\ue7b0"        # docker
DB = "\uf1c0"        # database
SSH = "\uf023"       # lock
DEFAULT_GLYPH = "\uf233"  # server

# Ordered stack fingerprints. The first pattern that matches the process
# name or its full command line wins, so put the specific runtimes (vite,
# next) ahead of the generic ones (node, python).
STACKS = (
    ("Vite", JS, r"\bvite\b"),
    ("Next.js", JS, r"\bnext(-server)?\b|\.next/"),
    ("Nuxt", JS, r"\bnuxt\b"),
    ("Astro", JS, r"\bastro\b"),
    ("Remix", JS, r"\bremix\b"),
    ("Webpack", JS, r"webpack-dev-server"),
    ("Storybook", JS, r"storybook"),
    ("Bun", JS, r"\bbun\b"),
    ("Deno", JS, r"\bdeno\b"),
    ("Node", JS, r"\bnode\b|\bnpm\b|\bpnpm\b|\byarn\b"),
    ("Django", PY, r"manage\.py\s+runserver"),
    ("Uvicorn", PY, r"\buvicorn\b"),
    ("Gunicorn", PY, r"\bgunicorn\b"),
    ("Flask", PY, r"\bflask\b"),
    ("Python", PY, r"\bpython[0-9.]*\b"),
    ("Rails", RB, r"\brails\b|\bpuma\b"),
    ("Ruby", RB, r"\bruby\b"),
    ("Laravel", PHP, r"artisan\s+serve"),
    ("PHP", PHP, r"\bphp\b"),
    ("Go", GO, r"\bgo\b\s+run|/tmp/go-build"),
    ("Rust", RS, r"\bcargo\b|/target/(debug|release)/"),
    ("Java", JV, r"\bjava\b|\bgradle\b|\bmvn\b"),
    ("Docker", DK, r"docker-proxy|containerd"),
    ("Postgres", DB, r"\bpostgres\b"),
    ("MySQL", DB, r"\bmysqld\b|\bmariadbd\b"),
    ("Redis", DB, r"redis-server"),
    ("Mongo", DB, r"\bmongod\b"),
    ("SSH", SSH, r"\bsshd?\b"),
)


# `ss` cannot name a process this user does not own, so a system row would
# otherwise read "unknown". For the ports that are always the same service,
# say so — an unexplained listener is exactly what makes a port list scary.
WELL_KNOWN = {
    22: "SSH",
    25: "SMTP",
    53: "DNS",
    80: "HTTP",
    111: "rpcbind",
    123: "NTP",
    143: "IMAP",
    443: "HTTPS",
    445: "SMB",
    546: "DHCPv6",
    547: "DHCPv6 server",
    631: "CUPS printing",
    993: "IMAPS",
    1900: "SSDP / UPnP",
    3306: "MySQL",
    5353: "mDNS / Avahi",
    5432: "PostgreSQL",
    6379: "Redis",
    27017: "MongoDB",
    41641: "Tailscale",
}


def well_known(port):
    return WELL_KNOWN.get(port, "")


def read_text(path):
    try:
        with open(path, "r", errors="replace") as handle:
            return handle.read()
    except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
        return ""


def owner_is_current_user(pid):
    try:
        return os.stat(f"/proc/{pid}").st_uid == os.getuid()
    except (FileNotFoundError, PermissionError, OSError):
        return False


def command_line(pid):
    raw = read_text(f"/proc/{pid}/cmdline")
    if not raw:
        return ""
    return " ".join(part for part in raw.split("\0") if part).strip()


def working_directory(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except (FileNotFoundError, PermissionError, OSError):
        return ""


def project_name(cwd):
    """Walk up from the process cwd to the nearest git checkout.

    Cheaper and more predictable than asking git: no subprocess, no timeout,
    and it stays quiet on directories git would refuse to read.
    """
    if not cwd or not os.path.isdir(cwd):
        return "", ""
    path = cwd
    home = os.path.expanduser("~")
    while True:
        if os.path.exists(os.path.join(path, ".git")):
            return os.path.basename(path), path
        parent = os.path.dirname(path)
        if parent == path or path == home:
            return "", ""
        path = parent


def uptime_seconds(pid):
    stat = read_text(f"/proc/{pid}/stat")
    if not stat:
        return 0
    # The comm field can contain spaces and parentheses, so start counting
    # fields after the final ')'.
    tail = stat[stat.rfind(")") + 2:].split()
    if len(tail) < 20:
        return 0
    try:
        started = int(tail[19]) / CLOCK_TICKS
    except (ValueError, ZeroDivisionError):
        return 0
    boot = read_text("/proc/uptime").split()
    if not boot:
        return 0
    try:
        return max(0, int(float(boot[0]) - started))
    except ValueError:
        return 0


def memory_bytes(pid):
    for line in read_text(f"/proc/{pid}/status").splitlines():
        if line.startswith("VmRSS:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                return int(parts[1]) * 1024
    return 0


def container_name(pid):
    cgroup = read_text(f"/proc/{pid}/cgroup")
    match = re.search(r"docker[-/]([0-9a-f]{12})", cgroup)
    if match:
        return match.group(1)
    return ""


def stack_haystack(process, cmdline):
    """Build the string the stack patterns run against.

    Flags are dropped first. Chromium-family apps pass things like
    `--render-node-override`, and matching those as runtimes labelled every
    browser socket "Node".
    """
    words = [process]
    for token in cmdline.split():
        if token.startswith("-"):
            continue
        words.append(token)
        base = os.path.basename(token)
        if base and base != token:
            words.append(base)
    return " ".join(words).lower()


def detect_stack(process, cmdline):
    haystack = stack_haystack(process, cmdline)
    for name, glyph, pattern in STACKS:
        if re.search(pattern, haystack):
            return name, glyph
    return "", DEFAULT_GLYPH


# Sockets above this are kernel-assigned ephemeral ports. A browser or chat
# client opening one is not something you ever want to see in a port manager,
# so they sink into the collapsed section unless a real stack was detected.
EPHEMERAL_PORT = 32768


def classify(row):
    if not row["mine"]:
        return "system"
    if row["protocol"] != "TCP":
        return "other"
    if row["port"] >= EPHEMERAL_PORT and not row["project"]:
        return "other"
    if row["project"] or row["stack"] or row["container"]:
        return "dev"
    return "other"


def split_address(address):
    """Split an `ss` local-address column into (host, port)."""
    match = re.match(r"^\[(?P<host>.*)\]:(?P<port>\d+)$", address)
    if not match:
        match = re.match(r"^(?P<host>.*):(?P<port>\d+)$", address)
    if not match:
        return "", 0
    return match.group("host"), int(match.group("port"))


def is_wildcard(host):
    return host in ("0.0.0.0", "*", "::", "")


def describe_process(pid):
    cmdline = command_line(pid)
    cwd = working_directory(pid)
    project, project_path = project_name(cwd)
    return {
        "cmdline": cmdline,
        "cwd": cwd,
        "project": project,
        "projectPath": project_path,
        "uptime": uptime_seconds(pid),
        "memory": memory_bytes(pid),
        "container": container_name(pid),
    }


def list_ports():
    try:
        raw = subprocess.check_output(
            ["ss", "-H", "-ltnup"], text=True, stderr=subprocess.DEVNULL
        )
    except FileNotFoundError:
        return {"ok": False, "error": "`ss` is missing. Install iproute2."}
    except subprocess.CalledProcessError as exc:
        return {"ok": False, "error": f"Unable to read listening ports: {exc}"}

    # A single server usually holds both an IPv4 and an IPv6 socket on the
    # same port. Collapse them onto one row keyed by (pid, port, protocol)
    # and keep the widest exposure of the group.
    merged = {}
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        protocol = parts[0].upper()
        host, port = split_address(parts[4])
        if not port:
            continue

        process = ""
        pid = 0
        match = re.search(r'users:\(\("([^"]+)",pid=(\d+)', line)
        if match:
            process = match.group(1)
            pid = int(match.group(2))

        key = (pid, port, protocol, process)
        row = merged.get(key)
        if row is None:
            row = {
                "protocol": protocol,
                "port": port,
                "process": process or "unknown",
                "pid": pid,
                "hosts": [],
                "exposed": False,
            }
            merged[key] = row
        if host and host not in row["hosts"]:
            row["hosts"].append(host)
        if is_wildcard(host) or host not in LOCAL_HOSTS:
            row["exposed"] = True

    rows = []
    for row in merged.values():
        pid = row["pid"]
        mine = bool(pid and owner_is_current_user(pid))
        row["canStop"] = mine
        row["mine"] = mine
        if mine:
            row.update(describe_process(pid))
        else:
            row.update({
                "cmdline": "",
                "cwd": "",
                "project": "",
                "projectPath": "",
                "uptime": 0,
                "memory": 0,
                "container": "",
            })
        stack, glyph = detect_stack(row["process"], row["cmdline"])
        row["stack"] = stack
        row["glyph"] = glyph
        row["address"] = ", ".join(row.pop("hosts")) or "*"
        row["url"] = f"http://localhost:{row['port']}" if row["protocol"] == "TCP" else ""
        row["service"] = well_known(row["port"])
        row["group"] = classify(row)
        rows.append(row)

    # Dev servers first — they are what you came here for — then the rest of
    # your sockets, then everything the system owns.
    order = {"dev": 0, "other": 1, "system": 2}
    rows.sort(key=lambda r: (order[r["group"]], r["port"], r["protocol"]))
    return {"ok": True, "ports": rows, "generatedAt": int(time.time())}


def stop_process(pid, force=False):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return {"ok": False, "error": "Invalid process ID."}
    if pid <= 1:
        return {"ok": False, "error": "Refusing to signal PID {}.".format(pid)}
    if not owner_is_current_user(pid):
        return {"ok": False, "error": "This process is not owned by your user."}
    name = read_text(f"/proc/{pid}/comm").strip() or f"PID {pid}"
    try:
        os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
    except ProcessLookupError:
        return {"ok": False, "error": "The process has already exited."}
    except PermissionError:
        return {"ok": False, "error": "Permission denied."}

    # Give a graceful stop a moment to land so the panel can report the real
    # outcome instead of an optimistic one.
    deadline = time.time() + (0.4 if force else 1.5)
    while time.time() < deadline:
        if not os.path.exists(f"/proc/{pid}"):
            return {"ok": True, "exited": True, "process": name}
        time.sleep(0.05)
    return {"ok": True, "exited": False, "process": name}


def find_by_port(port):
    listing = list_ports()
    if not listing.get("ok"):
        return listing, None
    for row in listing["ports"]:
        if row["port"] == port:
            return listing, row
    return listing, None


def kill_port(port, force=False):
    try:
        port = int(port)
    except (TypeError, ValueError):
        return {"ok": False, "error": "Invalid port."}
    _, row = find_by_port(port)
    if row is None:
        return {"ok": False, "error": f"Nothing is listening on port {port}."}
    if not row["canStop"]:
        return {"ok": False, "error": f"Port {port} is held by {row['process']}, which you do not own."}
    return stop_process(row["pid"], force)


def check_port(port):
    try:
        port = int(port)
    except (TypeError, ValueError):
        return {"ok": False, "error": "Invalid port."}
    listing, row = find_by_port(port)
    if not listing.get("ok"):
        return listing
    taken = {r["port"] for r in listing["ports"]}
    next_free = port
    while next_free in taken and next_free < 65535:
        next_free += 1
    return {
        "ok": True,
        "port": port,
        "free": row is None,
        "holder": row,
        "nextFree": next_free,
    }


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    force = "--force" in argv
    if command == "stop" and len(argv) > 2:
        return stop_process(argv[2], force)
    if command == "kill-port" and len(argv) > 2:
        return kill_port(argv[2], force)
    if command == "check" and len(argv) > 2:
        return check_port(argv[2])
    if command and command not in ("list", ""):
        return {"ok": False, "error": f"Unknown command: {command}"}
    return list_ports()


if __name__ == "__main__":
    print(json.dumps(main(sys.argv)))
