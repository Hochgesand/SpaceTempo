#!/usr/bin/env python3
"""Integration-test guardian lifetime handling with a mock setter only.

No live SkyLight call, keyboard event, permission change, or preference write.
"""
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def ready(proc):
    with selectors.DefaultSelector() as selector:
        selector.register(proc.stdout, selectors.EVENT_READ)
        assert selector.select(3), "guardian readiness timed out"
    assert proc.stdout.readline().strip() == b"READY"


def log_values(path):
    return path.read_text().splitlines() if path.exists() else []


with tempfile.TemporaryDirectory(prefix="spacetempo-guard-") as directory:
    directory = Path(directory)
    binary = directory / "mock-guard"
    subprocess.run([
        "clang", "-std=c11", "-D_DARWIN_C_SOURCE", "-DST_GUARD_TEST",
        "-Wall", "-Wextra", "-Werror", str(ROOT / "Sources/InputGuard/main.c"),
        "-o", str(binary),
    ], check=True)
    log = directory / "restores.log"
    env = {**os.environ, "ST_GUARD_TEST_LOG": str(log)}

    def launch(left, right, extra_env=None):
        log.unlink(missing_ok=True)
        return subprocess.Popen(
            [str(binary), str(os.getpid()), str(left), str(right)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            env={**env, **(extra_env or {})},
        )

    # Every initial state combination is restored exactly on pipe EOF.
    for left in (0, 1):
        for right in (0, 1):
            proc = launch(left, right)
            ready(proc)
            assert log_values(log) == []
            proc.stdin.close()
            assert proc.wait(3) == 0
            assert log_values(log) == [f"79 {left}", f"81 {right}"]

    # Parent has already restored: disarm prevents a late write over a new lease.
    proc = launch(1, 0)
    ready(proc)
    proc.stdin.write(b"D")
    proc.stdin.flush()
    proc.stdin.close()
    assert proc.wait(3) == 0
    assert log_values(log) == []

    # SIGTERM requests rollback rather than leaving the live shortcuts disabled.
    proc = launch(0, 1)
    ready(proc)
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(3) == 0
    proc.stdin.close()
    assert log_values(log) == ["79 0", "81 1"]

    # Failure before readiness never pretends the restoration lease is armed.
    proc = launch(1, 1, {"ST_GUARD_TEST_FAIL_READY": "1"})
    assert proc.wait(3) == 4
    assert proc.stdout.read() == b""
    proc.stdin.close()
    assert log_values(log) == []

    # Keep stdin open in this process so NOTE_EXIT, not pipe EOF, is exercised.
    log.unlink(missing_ok=True)
    read_fd, write_fd = os.pipe()
    parent_code = """
import os, subprocess, sys, time
p = subprocess.Popen([sys.argv[1], str(os.getpid()), '1', '0'], stdin=int(sys.argv[2]), stdout=subprocess.PIPE)
assert p.stdout.readline() == b'READY\\n'
print('READY', flush=True)
while True: time.sleep(10)
"""
    parent = subprocess.Popen(
        [sys.executable, "-c", parent_code, str(binary), str(read_fd)],
        pass_fds=(read_fd,), stdout=subprocess.PIPE, env=env,
    )
    os.close(read_fd)
    try:
        ready(parent)
        parent.kill()
        parent.wait(3)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and len(log_values(log)) < 2:
            time.sleep(0.02)
        assert log_values(log) == ["79 1", "81 0"]
    finally:
        os.close(write_fd)
        if parent.poll() is None:
            parent.kill()
            parent.wait(3)

    # Invalid caller cannot arm a guardian against an unrelated PID.
    log.unlink(missing_ok=True)
    rejected = subprocess.run([str(binary), "2", "1", "1"], env=env, capture_output=True)
    assert rejected.returncode == 2
    assert log_values(log) == []

print("Input guardian: EOF ×4, disarm, SIGTERM, readiness failure, parent death, invalid caller passed (mock backend).")
