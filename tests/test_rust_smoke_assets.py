"""The bundled Rust smoke libraries must match the published matrix pins."""

import hashlib
import json
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class SmokeAssets(unittest.TestCase):
    def test_bundled_libraries_are_pinned_linux_elf_for_each_architecture(self):
        versions = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
        rows = [row for row in versions["components"]["udf-devkit"]["containers"]
                if row.get("language") == "rust"]
        self.assertEqual({row["arch"] for row in rows}, {"aarch64", "x86_64"})
        for row in rows:
            with self.subTest(arch=row["arch"]):
                asset = row["smoke_asset"]
                relative = Path(asset["bundled_path"])
                self.assertEqual(relative.parent, Path("udf/rust-smoke/prebuilt"))
                path = ROOT / relative
                data = path.read_bytes()
                self.assertEqual(len(data), asset["size"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), asset["sha256"])
                self.assertEqual(data[:4], b"\x7fELF")
                self.assertEqual(data[4:6], b"\x02\x01")  # 64-bit little-endian ELF
                self.assertEqual(struct.unpack_from("<H", data, 18)[0],
                                 {"aarch64": 183, "x86_64": 62}[row["arch"]])


if __name__ == "__main__":
    unittest.main()
