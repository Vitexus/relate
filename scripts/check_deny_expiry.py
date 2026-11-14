#!/usr/bin/env python3
"""Fail when a deny.toml ignore entry is past its expiry comment.

The [advisories] policy in deny.toml (its own header states it) is that
every ignore entry carries a reason and an expiry: an entry past its
expiry is a re-triage prompt, not a standing accept. cargo-deny 0.20.x
cannot enforce that — its ignore entries accept only ``id`` and
``reason``, so the expiry rides as a ``# expiry: YYYY-MM-DD`` comment on
the entry — and without a mechanical check an expired entry stays green
forever, the silent decay into standing accepts the policy exists to
prevent.

The check walks every ignore entry (a line carrying ``id = "..."``),
requires its expiry comment, and fails on any date before today (UTC):
an entry expiring today is current, one from yesterday is a re-triage
prompt. The weekly cargo-deny workflow runs it after the scan, and
``make test-deny-expiry`` (a test-scripts prerequisite) runs the suite
including the live deny.toml gate, so a PR that ships an expired entry
fails before the week is out:

    python3 scripts/check_deny_expiry.py             # the repo deny.toml
    python3 scripts/check_deny_expiry.py other.toml  # any other copy
"""

from __future__ import annotations

import re
import sys
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TOML = ROOT / "deny.toml"

# An ignore entry: the `{ id = "RUSTSEC-...", reason = "..." },` line
# shape cargo-deny 0.20.x accepts (deny.toml writes entries single-line,
# so the expiry comment rides on the entry's own line).
ENTRY_RE = re.compile(r'\bid\s*=\s*"([^"]+)"')
EXPIRY_RE = re.compile(r'#\s*expiry:\s*(\S+)')
DATE_SHAPE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def today_utc() -> date:
    """The UTC date the expiry comparison runs against (CI runs UTC)."""
    return datetime.now(timezone.utc).date()


def parse_entries(text: str) -> list[tuple[int, str, str]]:
    """One (line number, advisory id, expiry) triple per ignore entry.

    The expiry is the entry's ``# expiry:`` comment value; a missing
    comment yields "" and a value that is not a date passes through
    as-is — both are failures past_due() names, never silently
    dropped entries.
    """
    entries = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        entry = ENTRY_RE.search(line)
        if entry is None:
            continue
        expiry = EXPIRY_RE.search(line)
        entries.append((lineno, entry.group(1), expiry.group(1) if expiry else ""))
    return entries


def past_due(entries: list[tuple[int, str, str]], today: date) -> list[tuple[int, str, str]]:
    """The failures in one entry list: (line, id, why), empty = current.

    Three ways an entry fails: its expiry has passed (the re-triage
    prompt), it carries no expiry comment, or the comment is not a
    YYYY-MM-DD date — each names itself on its own line.
    """
    failures = []
    for lineno, advisory, expiry in entries:
        if expiry == "":
            failures.append(
                (lineno, advisory, "no expiry comment — every ignore entry carries one (deny.toml [advisories] header)")
            )
            continue
        if DATE_SHAPE.match(expiry) is None:
            failures.append((lineno, advisory, f"expiry {expiry!r} is not a YYYY-MM-DD date"))
            continue
        try:
            entry_date = date.fromisoformat(expiry)
        except ValueError:
            failures.append((lineno, advisory, f"expiry {expiry!r} is not a valid calendar date"))
            continue
        if entry_date < today:
            failures.append(
                (lineno, advisory, f"expired {expiry} — re-triage: delete the entry, or rewrite it with a fresh reason and expiry")
            )
    return failures


def check(path: Path, today: date) -> list[tuple[int, str, str]]:
    """The failures in one deny.toml; empty means every entry is current."""
    return past_due(parse_entries(path.read_text(encoding="utf-8")), today)


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT_TOML
    failures = check(path, today_utc())
    for lineno, advisory, why in failures:
        print(f"{path}:{lineno}: {advisory}: {why}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
