"""Tests for scripts/check_deny_expiry.py.

The fixtures are hermetic deny.toml shapes with a fixed "today", so the
boundary is pinned: an entry dated today is current, one dated yesterday
is the re-triage prompt. Two gates read the repo's real deny.toml: every
live entry is current, and a copy with one flipped expiry date is
reported — the failure the weekly cargo-deny workflow exists to surface.
"""

import tempfile
import unittest
from contextlib import redirect_stderr
from datetime import date, timedelta
from io import StringIO
from pathlib import Path

from script_loader import ROOT, load

expiry = load("check_deny_expiry", ROOT / "scripts" / "check_deny_expiry.py")

TODAY = date(2026, 1, 15)

# The deny.toml ignore-entry shape: single-line entries with the expiry
# riding as a comment, exactly as the repo file writes them.
CURRENT_TOML = """\
[advisories]
ignore = [
    { id = "RUSTSEC-2025-0001", reason = "fixture: expires today" }, # expiry: 2026-01-15
    { id = "RUSTSEC-2025-0002", reason = "fixture: expires later" }, # expiry: 2026-06-01
]
"""


class ParseTests(unittest.TestCase):
    """One triple per ignore entry; nothing else becomes one."""

    def test_entries_carry_line_id_and_expiry(self) -> None:
        self.assertEqual(
            expiry.parse_entries(CURRENT_TOML),
            [
                (3, "RUSTSEC-2025-0001", "2026-01-15"),
                (4, "RUSTSEC-2025-0002", "2026-06-01"),
            ],
        )

    def test_a_missing_expiry_comment_parses_as_empty(self) -> None:
        entries = expiry.parse_entries(
            '{ id = "RUSTSEC-2025-0003", reason = "fixture: no expiry" },\n'
        )
        self.assertEqual(entries, [(1, "RUSTSEC-2025-0003", "")])

    def test_lines_without_an_id_are_not_entries(self) -> None:
        self.assertEqual(expiry.parse_entries("# expiry: 2020-01-01\nignore = [\n"), [])


class PastDueTests(unittest.TestCase):
    """The boundary (today passes, yesterday fails) and the two shape failures."""

    def entry(self, expiry_comment: str) -> list[tuple[int, str, str]]:
        return expiry.parse_entries(
            f'{{ id = "RUSTSEC-2025-0001", reason = "fixture" }}, {expiry_comment}\n'
        )

    def test_today_and_future_entries_are_current(self) -> None:
        self.assertEqual(expiry.past_due(self.entry("# expiry: 2026-01-15"), TODAY), [])
        self.assertEqual(expiry.past_due(self.entry("# expiry: 2027-01-01"), TODAY), [])

    def test_a_past_due_entry_names_itself_and_its_date(self) -> None:
        failures = expiry.past_due(self.entry("# expiry: 2026-01-14"), TODAY)
        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0][0], 1)
        self.assertEqual(failures[0][1], "RUSTSEC-2025-0001")
        self.assertIn("expired 2026-01-14", failures[0][2])

    def test_a_missing_expiry_comment_fails(self) -> None:
        failures = expiry.past_due(self.entry(""), TODAY)
        self.assertEqual(len(failures), 1)
        self.assertIn("no expiry comment", failures[0][2])

    def test_a_malformed_expiry_fails(self) -> None:
        for bad in ["# expiry: soon", "# expiry: 2026-1-5", "# expiry: 2026-13-40"]:
            with self.subTest(expiry=bad):
                failures = expiry.past_due(self.entry(bad), TODAY)
                self.assertEqual(len(failures), 1, failures)
                self.assertIn("not a", failures[0][2])


class CheckTests(unittest.TestCase):
    """check() over a file, and the CLI exit code the workflow reads."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.toml = Path(self._tmp.name) / "deny.toml"

    def test_a_current_file_reports_no_failures(self) -> None:
        self.toml.write_text(CURRENT_TOML, encoding="utf-8")
        self.assertEqual(expiry.check(self.toml, TODAY), [])

    def test_main_exits_0_on_today_and_1_on_a_flipped_date(self) -> None:
        # main reads the real clock (the workflow's contract): an entry
        # dated today is current, and the same entry flipped to
        # yesterday fails the run.
        today = expiry.today_utc()
        entry = '    {{ id = "RUSTSEC-2025-0001", reason = "fixture" }}, # expiry: {d}\n'
        self.toml.write_text(
            "[advisories]\nignore = [\n" + entry.format(d=today.isoformat()) + "]\n",
            encoding="utf-8",
        )
        self.assertEqual(expiry.main(["check_deny_expiry.py", str(self.toml)]), 0)
        self.toml.write_text(
            "[advisories]\nignore = [\n"
            + entry.format(d=(today - timedelta(days=1)).isoformat()) + "]\n",
            encoding="utf-8",
        )
        with redirect_stderr(StringIO()):
            self.assertEqual(expiry.main(["check_deny_expiry.py", str(self.toml)]), 1)


class RepoGateTests(unittest.TestCase):
    """The two live gates: the repo file is current, and a flipped date is caught."""

    def test_every_repo_deny_toml_entry_is_current(self) -> None:
        self.assertEqual(expiry.check(ROOT / "deny.toml", expiry.today_utc()), [])

    def test_a_flipped_expiry_date_in_a_deny_toml_copy_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            flipped = Path(tmp) / "deny.toml"
            flipped.write_text(
                (ROOT / "deny.toml").read_text(encoding="utf-8").replace(
                    "# expiry: 2027-05-14",
                    f"# expiry: {(expiry.today_utc() - timedelta(days=1)).isoformat()}",
                    1,
                ),
                encoding="utf-8",
            )
            failures = expiry.check(flipped, expiry.today_utc())
            self.assertEqual(len(failures), 1, failures)
            self.assertIn("expired", failures[0][2])


if __name__ == "__main__":
    unittest.main()
