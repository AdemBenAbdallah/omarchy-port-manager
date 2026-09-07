#!/usr/bin/env python3
"""Regression tests for the one action in this plugin that cannot be undone.

Run with `python3 test_stop_safety.py`. No dependencies, no network, and every
process it signals is one it started itself.

The case that matters is the third group. A PID is not a process identity:
Linux recycles PIDs, so a snapshot the panel took a moment ago can name a PID
that now belongs to something else the same user owns. An owner check alone
passes on that stranger. These tests assert that a request carrying a stale
identity signals *nothing at all*.
"""
import importlib.util
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_backend():
    spec = importlib.util.spec_from_file_location(
        "port_manager", os.path.join(HERE, "port-manager.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pm = load_backend()

failures = []
sent_signals = []


def check(label, condition, detail=""):
    mark = "pass" if condition else "FAIL"
    print(f"  [{mark}] {label}" + (f"  -- {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)


def sleeper():
    """A process of our own to signal, unrelated to any listening socket."""
    process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    time.sleep(0.4)
    return process


def instrument():
    """Record which signal reached pidfd_send_signal, and fail on the fallback.

    The fallback is correct but weaker, so a silent slide into it on a machine
    that supports pidfd would quietly reduce the guarantee being tested.
    """
    real = getattr(signal, "pidfd_send_signal", None)
    if real is None:
        return False

    def spy(fd, sig, *args, **kwargs):
        sent_signals.append(sig)
        return real(fd, sig, *args, **kwargs)

    signal.pidfd_send_signal = spy

    def refuse(pid, sig, expect):
        raise AssertionError("fell back to os.kill on a machine with pidfd")

    pm.signal_by_pid = refuse
    return True


def main():
    has_pidfd = instrument()
    print(f"backend: {pm.__file__}")
    print(f"pidfd available: {has_pidfd}\n")

    print("identity tokens")
    token = pm.identity_token(os.getpid())
    check("token is <pid>:<ticks>", token.startswith(f"{os.getpid()}:"), token)
    check("start ticks are non-zero", pm.start_ticks(os.getpid()) > 0)
    check("a dead pid has no token", pm.identity_token(999999) == "")
    check("our own state is R or S", pm.process_state(os.getpid()) in ("R", "S"))

    print("\nstopping the right process")
    proc = sleeper()
    result = pm.stop_process(proc.pid, False, pm.identity_token(proc.pid))
    check("reports ok and exited", result.get("ok") and result.get("exited"), result)
    if has_pidfd:
        check("delivered SIGTERM via pidfd", sent_signals[-1:] == [signal.SIGTERM])
    proc.wait(timeout=5)

    print("\nrefusing a stale identity (the PID-reuse race)")
    proc = sleeper()
    stale = f"{proc.pid}:1"
    result = pm.stop_process(proc.pid, False, stale)
    check("refused", not result.get("ok"), result)
    check("flagged as changed", result.get("changed") is True, result)
    check("process was NOT signalled", proc.poll() is None)

    result = pm.stop_process(proc.pid, True, stale)
    check("force kill also refused", result.get("changed") is True, result)
    check("process still NOT signalled", proc.poll() is None)

    result = pm.stop_process(proc.pid, False, "999999:12345")
    check("another process's identity refused", result.get("changed") is True, result)
    check("process still alive", proc.poll() is None)

    print("\nforce kill with a matching identity")
    result = pm.stop_process(proc.pid, True, pm.identity_token(proc.pid))
    check("reports ok and exited", result.get("ok") and result.get("exited"), result)
    if has_pidfd:
        check("delivered SIGKILL via pidfd", sent_signals[-1:] == [signal.SIGKILL])
    proc.wait(timeout=5)

    print("\nguards")
    check("PID 1 refused", not pm.stop_process(1, False, "").get("ok"))
    check("PID 0 refused", not pm.stop_process(0, False, "").get("ok"))
    check("negative PID refused", not pm.stop_process(-1, False, "").get("ok"))
    check("non-numeric PID refused", not pm.stop_process("abc", False, "").get("ok"))
    check("exited PID refused",
          "already exited" in pm.stop_process(999999, False, "").get("error", ""))

    found = subprocess.run(["pgrep", "-u", "root", "-n", "."],
                           capture_output=True, text=True).stdout.strip()
    if found:
        result = pm.stop_process(int(found), False, "")
        check("a root-owned process is refused", not result.get("ok"), result)

    print("\nlisting")
    listing = pm.list_ports()
    check("listing succeeds", listing.get("ok"), listing.get("error"))
    mine = [r for r in listing.get("ports", []) if r["mine"]]
    check("every row you own carries an identity", all(r.get("identity") for r in mine))
    others = [r for r in listing.get("ports", []) if not r["mine"]]
    check("rows you do not own are not stoppable", not any(r["canStop"] for r in others))

    print()
    if failures:
        print(f"{len(failures)} FAILED: " + "; ".join(failures))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
