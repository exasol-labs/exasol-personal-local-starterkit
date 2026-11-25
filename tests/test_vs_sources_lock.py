"""(run: python3 tests/test_vs_sources_lock.py) The source engine's sources lock (setup/virtual-schemas/engine/
sources.py Store.lock, over setup/core/state.py manifest_lock) is exclusive on every platform: a second command
waits for the first however long the first holds it - a whole exakit connect runs far longer than five seconds -
and on Windows it waits too, then fails clearly, instead of going ahead unlocked after five seconds (AGT-04).

The Windows half runs anywhere: os.name reads "nt" and msvcrt is a stand-in with msvcrt.locking's semantics (one
holder per file, LK_NBLCK refused while another handle holds it). On a Windows runner the native test drives the
real msvcrt."""

from __future__ import annotations

import errno
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "setup" / "virtual-schemas" / "engine"
sys.path.insert(0, str(ENGINE))

import sources  # noqa: E402

state = sources.core_state

HOLDER = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
import sources
with sources.Store(sys.argv[2]).lock():
    print("held", flush=True)
    time.sleep(float(sys.argv[3]))
    open(sys.argv[4], "w").write(repr(time.time()))
"""


class FakeMsvcrt(types.ModuleType):
    """msvcrt.locking as Windows answers it: a byte range has one holder, a non-blocking lock by any other
    handle fails with EACCES until the holder unlocks it."""

    LK_UNLCK, LK_LOCK, LK_NBLCK = 0, 1, 2

    def __init__(self):
        super().__init__("msvcrt")
        self.holders = {}
        self.guard = threading.Lock()

    def locking(self, fd, mode, nbytes):
        st = os.fstat(fd)
        key = (st.st_dev, st.st_ino)
        with self.guard:
            holder = self.holders.get(key)
            if mode == self.LK_UNLCK:
                if holder != fd:
                    raise OSError(errno.EACCES, "not locked by this handle")
                del self.holders[key]
            elif holder is not None and holder != fd:
                raise OSError(errno.EACCES, "Permission denied")
            else:
                self.holders[key] = fd


class FakeClock(object):
    """time.time / time.sleep for the lock's wait: a sleep moves the clock, not the test."""

    def __init__(self, on_tick=None):
        self.now = 1000.0
        self.on_tick = on_tick

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds
        if self.on_tick:
            self.on_tick(self.now - 1000.0)
            time.sleep(0.001)


class SourcesLockTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="vs-lock-")
        self.addCleanup(shutil.rmtree, self.home, True)
        # The registry the lock is taken on, there before any platform is pretended.
        with sources.Store(self.home).lock():
            pass

    def windows(self, clock, fake):
        """os.name "nt", the stand-in msvcrt and the fake clock, for the length of a with."""
        stack = mock.patch.multiple(state, time=clock)
        stack.start()
        self.addCleanup(stack.stop)
        modules = mock.patch.dict(sys.modules, {"msvcrt": fake})
        modules.start()
        self.addCleanup(modules.stop)
        name = mock.patch.object(state.os, "name", "nt")
        name.start()
        self.addCleanup(name.stop)

    def test_native_a_lock_held_past_five_seconds_keeps_the_second_command_out(self):
        """This platform's own lock (flock, or the real msvcrt on Windows): A holds it 6.5 s, B waits for all of it."""
        done = os.path.join(self.home, "released")
        holder = subprocess.Popen([sys.executable, "-c", HOLDER, str(ENGINE), self.home, "6.5", done],
                                  stdout=subprocess.PIPE, universal_newlines=True)
        try:
            self.assertEqual("held", holder.stdout.readline().strip())
            start = time.time()
            with sources.Store(self.home).lock():
                acquired = time.time()
                released = float(open(done).read()) if os.path.exists(done) else None
            self.assertIsNotNone(released, "B ran while A still held the sources lock")
            self.assertGreaterEqual(acquired, released)
            self.assertGreater(acquired - start, 5.5)
        finally:
            holder.wait(timeout=30)
            holder.stdout.close()

    def test_windows_a_lock_held_past_five_seconds_keeps_the_second_command_out(self):
        """Windows: B is still waiting at 5 s and enters only once A lets go (at 12 s here)."""
        a_held, b_waited, a_released = threading.Event(), threading.Event(), threading.Event()
        clock = FakeClock(on_tick=lambda waited: b_waited.set() if waited > 12 else None)
        self.windows(clock, FakeMsvcrt())

        def first():
            with sources.Store(self.home).lock():
                a_held.set()
                b_waited.wait(timeout=10)
                a_released.set()

        a = threading.Thread(target=first)
        a.start()
        self.assertTrue(a_held.wait(timeout=10))
        seen = {}
        try:
            with sources.Store(self.home).lock():
                seen["a_released"] = a_released.is_set()
                seen["waited"] = clock.now - 1000.0
        finally:
            b_waited.set()
            a.join(timeout=10)
        self.assertTrue(seen["a_released"], "B went ahead after %.1f s while A held the lock" % seen["waited"])
        self.assertGreater(seen["waited"], 12)

    def test_windows_a_lock_never_let_go_fails_clearly_instead_of_running_unlocked(self):
        """Windows: past the long wait the command fails with a sentence, and its body never runs."""
        fake = FakeMsvcrt()
        clock = FakeClock()
        self.windows(clock, fake)
        other = open(os.path.join(self.home, "sources", "registry.json.lock"), "a+")
        self.addCleanup(other.close)
        fake.locking(other.fileno(), fake.LK_NBLCK, 1)
        ran = []
        with self.assertRaises(sources.SourceError) as caught:
            with sources.Store(self.home).lock():
                ran.append(True)
        self.assertEqual([], ran)
        self.assertGreaterEqual(clock.now - 1000.0, state.EXCLUSIVE_WAIT_SECONDS)
        self.assertIn("Another exakit command has held", str(caught.exception))
        self.assertIn("for 30 minutes", str(caught.exception))

    def test_windows_an_install_manifest_write_still_gives_up_after_five_seconds(self):
        """The install manifest's own writes keep their rule: not worth failing an install over (PowerShell's too)."""
        fake = FakeMsvcrt()
        clock = FakeClock()
        manifest = os.path.join(self.home, "manifest.json")
        with open(manifest, "w") as handle:
            handle.write("{}\n")
        self.windows(clock, fake)
        other = open(manifest + ".lock", "a+")
        self.addCleanup(other.close)
        fake.locking(other.fileno(), fake.LK_NBLCK, 1)
        state.update_component(manifest, "skills", {"version": "1"})
        waited = clock.now - 1000.0
        self.assertGreaterEqual(waited, 5)
        self.assertLess(waited, 6)
        self.assertEqual({"version": "1"}, state.component(state.read_manifest(manifest), "skills"))


if __name__ == "__main__":
    unittest.main()
