import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("updater", Path(__file__).resolve().parents[1] / "scripts/update_libraries.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class LibraryUpdates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wow-library-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.destination = self.root / "addon/Libraries/example"
        self.destination.mkdir(parents=True)
        self.files = {"LICENSE.txt": b"license\n", "main.lua": b"return 1\n",
                      "load.xml": b'<Ui><Script file="main.lua"/></Ui>', "example.toc": b"load.xml\n"}
        for name, data in self.files.items():
            (self.destination / name).write_bytes(data)
        self.library = {"name": "example", "repository": "owner/example", "tag": "1.0.0", "commit": "a" * 40,
                        "destination": "addon/Libraries/example", "include": ["*.lua", "*.xml", "*.toc", "LICENSE.txt"],
                        "files": {name: updater.digest(data) for name, data in self.files.items()}}
        (self.root / updater.MANIFEST).parent.mkdir()
        (self.root / updater.MANIFEST).write_text(json.dumps({"schemaVersion": 1, "libraries": [self.library]}))

    def fetch(self, library):
        return "1.0.1", "b" * 40, self.files | {"main.lua": b"return 2\n"}

    def test_update_then_verify_and_no_op(self):
        summary = updater.run(self.root, update=True, fetch=self.fetch)
        self.assertEqual((self.destination / "main.lua").read_bytes(), b"return 2\n")
        self.assertIn("1.0.0 -> 1.0.1", summary[0])
        summary[0].encode("ascii")
        updater.run(self.root)
        before = (self.root / updater.MANIFEST).read_bytes()
        self.assertEqual(updater.run(self.root, update=True, fetch=lambda lib: (lib["tag"], lib["commit"], None)), [])
        self.assertEqual((self.root / updater.MANIFEST).read_bytes(), before)

    def test_local_edit_blocks_update(self):
        (self.destination / "main.lua").write_bytes(b"user edit\n")
        with self.assertRaisesRegex(ValueError, "local modification"):
            updater.run(self.root, update=True, fetch=self.fetch)
        self.assertEqual((self.destination / "main.lua").read_bytes(), b"user edit\n")

    def test_new_file_collision_blocks_all_writes(self):
        (self.destination / "extra.lua").write_bytes(b"user file\n")
        snapshot = self.files | {"main.lua": b"return 2\n", "extra.lua": b"upstream\n"}
        with self.assertRaisesRegex(ValueError, "overwrite unmanaged"):
            updater.run(self.root, update=True, fetch=lambda lib: ("1.0.1", "b" * 40, snapshot))
        self.assertEqual((self.destination / "main.lua").read_bytes(), self.files["main.lua"])

    def test_removed_file_is_deleted_but_unmanaged_file_is_preserved(self):
        (self.destination / "notes.txt").write_text("local notes")
        snapshot = {"LICENSE.txt": b"license\n", "new.lua": b"return 2\n", "example.toc": b"new.lua\n"}
        updater.run(self.root, update=True, fetch=lambda lib: ("1.0.1", "b" * 40, snapshot))
        self.assertFalse((self.destination / "main.lua").exists())
        self.assertEqual((self.destination / "notes.txt").read_text(), "local notes")
        updater.run(self.root)

    def test_broken_load_reference_blocks_update(self):
        snapshot = self.files | {"load.xml": b'<Ui><Script file="missing.lua"/></Ui>'}
        with self.assertRaisesRegex(ValueError, "load reference"):
            updater.run(self.root, update=True, fetch=lambda lib: ("1.0.1", "b" * 40, snapshot))
        self.assertEqual((self.destination / "load.xml").read_bytes(), self.files["load.xml"])

    def test_license_cannot_disappear(self):
        with self.assertRaisesRegex(ValueError, "LICENSE.txt"):
            updater.validate_files({"main.lua": b"return 1"})

    def test_second_library_failure_prevents_first_library_update(self):
        manifest_path = self.root / updater.MANIFEST
        second = self.library | {"name": "second", "destination": "addon/Libraries/second"}
        manifest_path.write_text(json.dumps({"schemaVersion": 1, "libraries": [self.library, second]}))
        before = manifest_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "second: local modification"):
            updater.run(self.root, update=True, fetch=self.fetch)
        self.assertEqual((self.destination / "main.lua").read_bytes(), self.files["main.lua"])
        self.assertEqual(manifest_path.read_bytes(), before)

    def test_moved_tag_requires_review(self):
        with patch.object(updater, "git", return_value=f"{'b'*40}\trefs/tags/1.0.0\n".encode()):
            with self.assertRaisesRegex(ValueError, "moved upstream"):
                updater.fetch_upstream(self.library)

    def test_upstream_downgrade_is_rejected(self):
        with patch.object(updater, "git", return_value=f"{'b'*40}\trefs/tags/0.9.0\n".encode()):
            with self.assertRaisesRegex(ValueError, "downgrade"):
                updater.fetch_upstream(self.library)

    def test_line_endings_do_not_count_as_local_edits(self):
        (self.destination / "main.lua").write_bytes(b"return 1\r\n")
        updater.run(self.root)

    def test_unsafe_paths_are_rejected(self):
        for name in ("../outside", "/outside", "C:/outside", "nested\\outside", "."):
            with self.subTest(name=name), self.assertRaises(ValueError):
                updater.safe_path(self.root, name)

    def test_latest_tag_ignores_prereleases_and_peels_annotated_tags(self):
        refs = "\n".join([f"{'a'*40}\trefs/tags/v1.9.0", f"{'b'*40}\trefs/tags/v1.10.0",
                          f"{'c'*40}\trefs/tags/v1.10.0^{{}}", f"{'d'*40}\trefs/tags/v2.0.0-beta.1"])
        self.assertEqual(updater.latest_tag(refs), ("v1.10.0", "c" * 40))


if __name__ == "__main__":
    unittest.main()
