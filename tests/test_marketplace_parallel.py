"""Parallel-safe add-ons install side by side; what the platform and the log see stays a serial install's."""

from __future__ import annotations

import io
import json
import os
import re
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
KIT = ROOT
import apply as market_apply  # noqa: E402
from service import _module  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402

PERSONA = "dash-server,json-tables,semantic-views"
STAMP = re.compile(r"^\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\] ", re.M)


class FakeAddons:
    """Stands in for service.invoke: an install that sleeps, reports activity, logs a command and an event, and
    writes several receipt fields; every other operation answers at once."""

    def __init__(self, delay: float = 0.3, fail: str = ""):
        self.delay = delay
        self.fail = fail
        self.lock = threading.Lock()
        self.running: set[str] = set()
        self.overlaps: dict[str, set[str]] = {}

    def __call__(self, _root, addon_id, operation, *, ctx):
        if operation != "install":
            if operation == "tool-outcomes":
                return 0, []
            return 0, (f"{addon_id} summary" if operation == "summary" else None)
        with self.lock:
            self.overlaps.setdefault(addon_id, set()).update(self.running)
            for other in self.running:
                self.overlaps.setdefault(other, set()).add(addon_id)
            self.running.add(addon_id)
        try:
            ctx.activity(f"{addon_id}: fetching")
            ctx.log_event(f"{addon_id} checksum verified")
            ctx.run_logged(f"Installing {addon_id}", sys.executable, "-c", f"print('built {addon_id}')")
            time.sleep(self.delay)
            if addon_id == self.fail:
                raise AddonFailure(f"{addon_id} download failed")
            receipt = "components." + addon_id.replace("-", "_")
            for field in ("version", "venv", "python", "command"):
                ctx.manifest.set_many({f"{receipt}.{field}": f"{addon_id}-{field}"})
            ctx.manifest.set_many({f"{receipt}.ownership": "kit"})
            ctx.activity(f"{addon_id}: built")
        finally:
            with self.lock:
                self.running.discard(addon_id)
        return 0, None


def _settled(stream: str) -> str:
    """The stream without its "installing" records: where those stand is the one way a side-by-side turn differs."""
    return "\n".join(line for line in stream.splitlines() if not re.match(r"@@EXAKIT\|[^|]+\|installing\|", line))


class ParallelApplyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def run_apply(self, ids: str, *, parallel: bool, fake: FakeAddons | None = None,
                  name: str = "home") -> tuple[str, dict, str, float, FakeAddons, int]:
        home = Path(self.temp.name) / f"{name}-{'parallel' if parallel else 'serial'}"
        home.mkdir()
        (home / "manifest.json").write_text('{"components":{}}\n', encoding="utf-8")
        ctx = KitContext(KIT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
        fake = fake or FakeAddons()
        out = io.StringIO()
        env = {"EXAKIT_MARKETPLACE_PARALLEL": "1" if parallel else "0"}
        env_drop = ("EXAKIT_MARKETPLACE_ACTIVITY_FILE", "EXAKIT_FORCE_COMPONENT_INSTALL")
        with patch.dict(os.environ, env), \
             patch.object(market_apply, "invoke", side_effect=fake), \
             patch.object(market_apply, "install_addon_skills", return_value=[]), \
             patch.object(market_apply, "register_autostart", return_value=False), \
             patch.object(market_apply, "register_mcp_endpoint", return_value=""), \
             patch.object(market_apply.KitContext, "from_environment", return_value=ctx), \
             redirect_stdout(out):
            for name_ in env_drop:
                os.environ.pop(name_, None)
            started = time.monotonic()
            code = market_apply.main([ids, "--stream"])
            elapsed = time.monotonic() - started
        manifest = json.loads((home / "manifest.json").read_text(encoding="utf-8"))
        log = STAMP.sub("", (home / "logs" / "marketplace.log").read_text(encoding="utf-8"))
        # Seconds differ between runs by nature; every other byte of the stream must not.
        stream = re.sub(r"\|\d+$", "|N", out.getvalue(), flags=re.M)
        return stream, manifest, log, elapsed, fake, code

    def test_persona_addons_install_at_the_same_time(self) -> None:
        _, _, _, serial, _, _ = self.run_apply(PERSONA, parallel=False)
        _, _, _, parallel, fake, code = self.run_apply(PERSONA, parallel=True)
        self.assertEqual(0, code)
        self.assertGreater(serial, len(PERSONA.split(",")) * 0.3)
        self.assertLess(parallel, serial * 0.6, f"parallel {parallel:.2f}s vs serial {serial:.2f}s")
        self.assertTrue(any(fake.overlaps.values()), "no two installs ever overlapped")

    def test_stream_receipts_and_log_match_a_serial_install(self) -> None:
        serial = self.run_apply(PERSONA, parallel=False)
        parallel = self.run_apply(PERSONA, parallel=True)
        # The platform's live records, activity lines included, as a serial install's - except that every add-on of a
        # side-by-side turn says "installing" when its worker starts, so each row has its bar at once.
        self.assertEqual(_settled(serial[0]), _settled(parallel[0]))
        lines = parallel[0].splitlines()
        self.assertLess(lines.index("@@EXAKIT|json-tables|installing||N"), lines.index("  • dash-server: fetching"),
                        "both bars start before either says what it is doing")
        self.assertEqual(serial[1], parallel[1])          # manifest.json receipts
        self.assertEqual(serial[2], parallel[2])          # marketplace.log, add-on by add-on
        order = [line.split("|")[1] for line in parallel[0].splitlines() if line.startswith("@@EXAKIT|")]
        self.assertEqual(PERSONA.split(","), list(dict.fromkeys(order)))
        self.assertIn("built dash-server", parallel[2])
        self.assertLess(parallel[2].index("built dash-server"), parallel[2].index("json-tables checksum verified"))

    def test_activity_lines_follow_their_addon(self) -> None:
        stream = self.run_apply(PERSONA, parallel=True)[0].splitlines()
        for addon_id in PERSONA.split(","):
            start = stream.index(f"@@EXAKIT|{addon_id}|installing||N")
            done_at = next(i for i, line in enumerate(stream) if line.startswith(f"@@EXAKIT|{addon_id}|done|"))
            self.assertIn(f"  • {addon_id}: fetching", stream[start:done_at])
            done = next(i for i, line in enumerate(stream) if line.startswith(f"@@EXAKIT|{addon_id}|done|"))
            self.assertIn(f"  • {addon_id}: built", stream[start:done])

    def test_one_failure_leaves_the_others_installed_and_said_in_order(self) -> None:
        serial = self.run_apply(PERSONA, parallel=False, fake=FakeAddons(fail="json-tables"))
        parallel = self.run_apply(PERSONA, parallel=True, fake=FakeAddons(fail="json-tables"))
        self.assertEqual(1, parallel[5])
        self.assertEqual(_settled(serial[0]), _settled(parallel[0]))
        self.assertEqual(serial[1], parallel[1])
        self.assertIn("@@EXAKIT|json-tables|failed|json-tables download failed|N", parallel[0])
        self.assertIn("@@EXAKIT|semantic-views|done|semantic-views summary|N", parallel[0])

    def test_an_addon_that_is_not_parallel_safe_installs_alone(self) -> None:
        ids = "dash-server,exasol-scheduler,json-tables,semantic-views"
        fake = FakeAddons(delay=0.15)
        with patch("addons.exasol_scheduler.applicable", return_value=True):
            stream, _, _, _, fake, _ = self.run_apply(ids, parallel=True, fake=fake)
        self.assertEqual(set(), fake.overlaps.get("exasol-scheduler", set()))
        self.assertEqual(set(), fake.overlaps.get("dash-server", set()))
        self.assertEqual({"semantic-views"}, fake.overlaps["json-tables"])

    def test_groups(self) -> None:
        modules = {addon_id: _module(KIT, addon_id)[1] for addon_id in
                   ("dash-server", "exasol-scheduler", "json-tables", "semantic-views", "dbt-exasol")}
        ids = list(modules)
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_PARALLEL": "1"}):
            self.assertEqual([["dash-server"], ["exasol-scheduler"], ["json-tables", "semantic-views"],
                              ["dbt-exasol"]], market_apply._groups(ids, modules))
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_PARALLEL": "0"}):
            self.assertEqual([[item] for item in ids], market_apply._groups(ids, modules))

    def test_already_installed_addon_starts_no_worker(self) -> None:
        fake = FakeAddons(delay=0.05)
        with patch.object(market_apply, "_installed", side_effect=lambda _c, a, _m: "1.0" if a == "json-tables" else None):
            stream, _, _, _, fake, code = self.run_apply(PERSONA, parallel=True, fake=fake)
        self.assertEqual(0, code)
        self.assertNotIn("json-tables", fake.overlaps)
        self.assertIn("@@EXAKIT|json-tables|done|already installed (1.0); exakit update json-tables refreshes it|N",
                      stream)


class ManifestThreadsTest(unittest.TestCase):
    def test_concurrent_receipt_writes_all_land(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "manifest.json"
            path.write_text('{"components":{}}\n', encoding="utf-8")
            manifest = Manifest(path)

            def write(worker: int) -> None:
                for field in range(40):
                    manifest.set_many({f"components.w{worker}.f{field}": field})

            threads = [threading.Thread(target=write, args=(worker,)) for worker in range(6)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            doc = json.loads(path.read_text(encoding="utf-8"))
            for worker in range(6):
                self.assertEqual({f"f{field}": field for field in range(40)}, doc["components"][f"w{worker}"])


if __name__ == "__main__":
    unittest.main()
