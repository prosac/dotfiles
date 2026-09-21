#!/usr/bin/env python3
"""Tests for `handover` — the lifecycle verbs and the ripple they perform.

Everything runs against a throwaway docs tree via HANDOVER_DOCS_DIR / HANDOVER_INDEX_FILE /
HANDOVER_SNAPDIR, so the real `~/Documents/docs` is never touched. Stdlib only, like the tool.

Run: python3 tests/test_handover.py   (or `mise run ch:test`)
"""

from __future__ import annotations

import datetime
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "dot_local" / "bin" / "executable_handover"


def load_tool(docs: Path, index: Path, snaps: Path):
    """Import the script fresh, with its module-level paths pointed at a temp tree."""
    os.environ["HANDOVER_DOCS_DIR"] = str(docs)
    os.environ["HANDOVER_INDEX_FILE"] = str(index)
    os.environ["HANDOVER_SNAPDIR"] = str(snaps)
    spec = importlib.util.spec_from_loader("handover_tool", loader=None)
    module = importlib.util.module_from_spec(spec)
    # Register before exec: @dataclass(slots=True) rebuilds the class and looks its module up in
    # sys.modules, which fails for a module that is not there yet.
    sys.modules["handover_tool"] = module
    exec(compile(TOOL.read_text(), str(TOOL), "exec"), module.__dict__)  # noqa: S102
    return module


DOC = """---
publish: false
title: A thing
status: open
tickets: [CVHERO-1, CVHERO-2]
next: "do the thing"
short: "the thing"
updated: 2026-01-01
tags: [a, b]
---

# A thing

Body text that must survive verbatim.
"""


class HandoverCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.docs = root / "docs"
        self.docs.mkdir()
        self.index = root / "CLAUDE.md"
        self.snaps = root / "snapshots"
        self.snaps.mkdir()
        self.doc = self.docs / "a-thing.md"
        self.doc.write_text(DOC)
        self.index.write_text(
            "# Index\n- `~/Documents/docs/a-thing.md` - the thing\n- `~/Documents/docs/other.md` - other\n"
        )
        self.h = load_tool(self.docs, self.index, self.snaps)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _snapshot_now(self) -> None:
        """A snapshot that is unambiguously newer — same-tick mtimes compare equal, not greater."""
        snap = self.snaps / "2099-01-01-0000"
        snap.mkdir()
        later = self.doc.stat().st_mtime + 10
        os.utime(snap, (later, later))

    def _item(self, key="a-thing"):
        return self.h.resolve(key, self.h.collect(include_done=True))


# --- the editing primitive ------------------------------------------------------------

class EditFrontMatter(HandoverCase):
    def test_keys_this_tool_does_not_own_survive_verbatim(self):
        """Re-serialising the block would reformat `publish`/`tags` and drop page-id comments."""
        self.h.edit_front_matter(self.doc, assign={"status": "done"})
        text = self.doc.read_text()

        self.assertIn("publish: false\n", text)
        self.assertIn("tags: [a, b]\n", text)
        self.assertIn("title: A thing\n", text)
        self.assertIn("Body text that must survive verbatim.", text)

    def test_sets_replaces_and_drops(self):
        self.h.edit_front_matter(self.doc, assign={"status": "done", "closed": "2026-01-02"}, drop=("next",))
        fields = self.h.read_front_matter(self.doc)

        self.assertEqual(fields["status"], "done")
        self.assertEqual(fields["closed"], "2026-01-02")
        self.assertNotIn("next", fields)

    def test_a_value_containing_a_quote_stays_parseable(self):
        """Notes are free text; an unescaped `"` would end the scalar and break the file."""
        note = 'moved to the "operating" runbook, see `rm` \\ guards'

        self.h.edit_front_matter(self.doc, assign={"next": note})

        self.assertEqual(self.h.read_front_matter(self.doc)["next"], note)

    def test_refuses_a_file_without_frontmatter(self):
        plain = self.docs / "plain.md"
        plain.write_text("# no frontmatter\n")

        with self.assertRaises(ValueError):
            self.h.edit_front_matter(plain, assign={"status": "done"})


# --- resolving ------------------------------------------------------------------------

class Resolve(HandoverCase):
    def test_stem_and_index_both_work(self):
        items = self.h.collect(include_done=True)

        self.assertEqual(self.h.resolve("a-thing", items).path, self.doc)
        self.assertEqual(self.h.resolve("1", items).path, self.doc)

    def test_a_bad_key_raises_rather_than_returning_nothing(self):
        """`$(handover path X)` must not silently become the empty string."""
        items = self.h.collect(include_done=True)

        with self.assertRaises(KeyError):
            self.h.resolve("99", items)
        with self.assertRaises(KeyError):
            self.h.resolve("nope", items)


# --- verbs ------------------------------------------------------------------------------

class Verbs(HandoverCase):
    def test_done_always_stamps_closed(self):
        """Without `closed:` lint's age rule can never fire — that is how 3 docs went stale."""
        self.h.cmd_done(self._item(), note="lives in the runbook")
        fields = self.h.read_front_matter(self.doc)

        self.assertEqual(fields["status"], "done")
        self.assertEqual(fields["closed"], datetime.date.today().isoformat())
        self.assertEqual(fields["next"], "lives in the runbook")

    def test_open_reverses_done(self):
        self.h.cmd_done(self._item(), note=None)
        self.h.cmd_open(self._item())
        fields = self.h.read_front_matter(self.doc)

        self.assertEqual(fields["status"], "open")
        self.assertNotIn("closed", fields)

    def test_next_rewrites_the_action_without_closing(self):
        """A `next:` can go wrong, not just stale — correcting it must not close the doc."""
        self.h.cmd_next(self._item(), "actually: verify the sweep first")
        fields = self.h.read_front_matter(self.doc)

        self.assertEqual(fields["next"], "actually: verify the sweep first")
        self.assertEqual(fields["status"], "open")
        self.assertNotIn("closed", fields)
        self.assertEqual(fields["updated"], datetime.date.today().isoformat())

    def test_next_works_on_a_closed_doc_too(self):
        self.h.cmd_done(self._item(), note=None)

        self.h.cmd_next(self._item(), "reopened question")

        fields = self.h.read_front_matter(self.doc)
        self.assertEqual(fields["next"], "reopened question")
        self.assertEqual(fields["status"], "done")

    def test_next_leaves_the_rest_of_the_frontmatter_alone(self):
        self.h.cmd_next(self._item(), "x")
        text = self.doc.read_text()

        self.assertIn("publish: false\n", text)
        self.assertIn("tags: [a, b]\n", text)
        self.assertIn("Body text that must survive verbatim.", text)

    def test_untrack_removes_the_block_when_nothing_else_is_left(self):
        """A doc whose frontmatter was only handover keys should not keep a bare `---\\n---`."""
        self.doc.write_text('---\nstatus: open\nnext: "x"\nshort: "y"\n---\n\n# A thing\n')

        self.h.cmd_untrack(self._item())

        self.assertEqual(self.doc.read_text(), "# A thing\n")

    def test_untrack_strips_only_the_handover_keys(self):
        self.h.cmd_untrack(self._item())
        fields = self.h.read_front_matter(self.doc)

        self.assertEqual(set(fields), {"publish", "title", "updated", "tags"})
        self.assertIn("Body text that must survive verbatim.", self.doc.read_text())


class Snapshots(HandoverCase):
    def test_freshness_comes_from_the_name_not_the_mtime(self):
        """btrfs snapshots inherit the source subvolume's mtime — all of them report the same
        ancient timestamp, so an mtime comparison rejects every delete."""
        old = self.snaps / "2099-01-01-0000"
        old.mkdir()
        ancient = self.doc.stat().st_mtime - 10_000_000
        os.utime(old, (ancient, ancient))

        self.assertEqual(self.h._fresh_snapshot(self.doc), old)

    def test_a_snapshot_older_than_the_file_is_no_undo(self):
        stale = self.snaps / "2000-01-01-0000"
        stale.mkdir()

        self.assertIsNone(self.h._fresh_snapshot(self.doc))


class Remove(HandoverCase):
    def test_refuses_while_still_open(self):
        self._snapshot_now()

        self.assertEqual(self.h.cmd_rm(self._item(), note=None, force=False), 2)
        self.assertTrue(self.doc.exists())

    def test_refuses_a_live_docs_as_code_source(self):
        """Deleting it orphans the Confluence page — untrack is the answer, not rm."""
        self.doc.write_text(DOC.replace("publish: false", "publish: true") + "\n<!-- confluence-page-id: 123 -->\n")
        self.h.cmd_done(self._item(), note=None)
        self._snapshot_now()

        self.assertEqual(self.h.cmd_rm(self._item(), note=None, force=False), 2)
        self.assertTrue(self.doc.exists())

    def test_refuses_without_a_snapshot_to_undo_from(self):
        self.h.cmd_done(self._item(), note=None)

        self.assertEqual(self.h.cmd_rm(self._item(), note=None, force=False), 2)
        self.assertTrue(self.doc.exists())

    def test_deletes_and_performs_the_ripple(self):
        other = self.docs / "refers.md"
        other.write_text("---\npublish: false\n---\n\nsee a-thing.md for detail\n")
        self.h.cmd_done(self._item(), note="moved to the repo runbook")
        self._snapshot_now()

        self.assertEqual(self.h.cmd_rm(self._item(), note="moved to the repo runbook", force=False), 0)

        self.assertFalse(self.doc.exists())
        index = self.index.read_text()
        self.assertNotIn("a-thing.md", index)
        self.assertIn("other.md", index)          # the neighbouring bullet is untouched
        ledger = (self.docs / "handover-log.md").read_text()
        self.assertIn("moved to the repo runbook", ledger)
        self.assertIn("2099-01-01-0000", ledger)  # the undo snapshot is named
        self.assertIn("see a-thing.md", other.read_text())  # referenced file reported, never edited

    def test_leaves_the_index_alone_when_a_doc_is_mentioned_twice(self):
        self.index.write_text(
            "- `~/Documents/docs/a-thing.md` - one\n- `~/Documents/docs/a-thing.md` - two\n"
        )
        self.h.cmd_done(self._item(), note=None)
        self._snapshot_now()
        self.h.cmd_rm(self._item(), note=None, force=False)

        self.assertEqual(self.index.read_text().count("a-thing.md"), 2)


# --- the surface the shell and the skill depend on ---------------------------------------

class Surface(HandoverCase):
    def test_motd_is_silent_and_succeeds_on_an_empty_tree(self):
        self.doc.unlink()

        self.assertEqual(self.h.main(["handover", "--motd"]), 0)

    def test_motd_survives_an_unreadable_frontmatter(self):
        (self.docs / "broken.md").write_text("---\nstatus: open\n")  # never closes

        self.assertEqual(self.h.main(["handover", "--motd"]), 0)

    def test_an_unknown_status_is_invisible_and_lint_says_so(self):
        self.doc.write_text(DOC.replace("status: open", "status: partial"))

        self.assertEqual(self.h.collect(include_done=True), [])
        self.assertEqual(self.h.cmd_lint(), 0)  # nags, never acts


if __name__ == "__main__":
    unittest.main(verbosity=2)
