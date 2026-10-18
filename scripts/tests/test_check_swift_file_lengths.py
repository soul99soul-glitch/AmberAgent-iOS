"""End-to-end checks of Git visibility and the migration contract."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "check_swift_file_lengths.py"


class SwiftFileLengthCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)

    def write_lines(self, name, count, final_newline=True):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"// comment\n" * (count - 1) +
                         (b"\n" if final_newline else b"// final line"))
        return path

    def run_check(self, *arguments):
        return subprocess.run(
            [sys.executable, str(CHECKER), *arguments],
            cwd=self.root, text=True, capture_output=True,
        )

    def baseline(self, files):
        (self.root / "baseline.json").write_text(
            json.dumps({"version": 1, "limit": 1500, "files": files}),
            encoding="utf-8",
        )

    def test_strict_boundary_counts_blank_comments_and_unterminated_last_line(self):
        self.write_lines("Sources/AtLimit.swift", 1500, final_newline=False)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        self.write_lines("Sources/AboveLimit.swift", 1501, final_newline=False)
        (self.root / "Sources/Blank.swift").write_bytes(b"\n" * 1501)
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/AboveLimit.swift: 1501 lines", result.stdout)
        self.assertIn("Sources/Blank.swift: 1501 lines", result.stdout)
        self.assertNotIn("AtLimit.swift:", result.stdout)

    def test_git_visible_files_include_untracked_but_skip_ignored_and_deleted(self):
        self.write_lines("Tracked.swift", 1501)
        subprocess.run(["git", "add", "Tracked.swift"], cwd=self.root, check=True)
        (self.root / "Tracked.swift").unlink()
        self.write_lines("Untracked.swift", 1501)
        (self.root / ".gitignore").write_text("Ignored.swift\n", encoding="utf-8")
        self.write_lines("Ignored.swift", 1501)

        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Untracked.swift: 1501 lines", result.stdout)
        self.assertNotIn("Tracked.swift:", result.stdout)
        self.assertNotIn("Ignored.swift:", result.stdout)
        self.assertIn("1 files", result.stdout)

    def test_migration_disallows_new_over_limit_and_existing_growth(self):
        self.write_lines("Existing.swift", 1502)
        self.baseline({"Existing.swift": {"max_lines": 1502, "owner": "chat"}})
        self.assertEqual(self.run_check("--baseline", "baseline.json").returncode, 0)

        self.write_lines("Existing.swift", 1503)
        self.write_lines("New.swift", 1501)
        result = self.run_check("--baseline", "baseline.json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Existing.swift: grew to 1503", result.stdout)
        self.assertIn("New.swift: new over-limit file", result.stdout)

    def test_resolved_and_removed_files_require_baseline_cleanup(self):
        self.write_lines("Existing.swift", 1501)
        self.baseline({"Existing.swift": {"max_lines": 1501, "owner": "chat"}})
        self.write_lines("Existing.swift", 1500)
        result = self.run_check("--baseline", "baseline.json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("remove its resolved baseline entry", result.stdout)

        (self.root / "Existing.swift").unlink()
        result = self.run_check("--baseline", "baseline.json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("file no longer exists", result.stdout)

        self.baseline({})
        self.assertEqual(self.run_check("--baseline", "baseline.json").returncode, 0)


if __name__ == "__main__":
    unittest.main()
