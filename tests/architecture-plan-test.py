#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Regressions for scripts/architecture-plan.py.

Each case writes a small plan and a throwaway git repository, runs the
checker as a subprocess and asserts its exit code and output, so what is
tested is what the integrating agent sees.

Usage: python3 tests/architecture-plan-test.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "architecture-plan.py")

SEQUENCE = ["V1", "B1", "N0", "S1"]

TRACKED = [
    ".formatter.exs",
    "README.md",
    "apps/a/lib/one.ex",
    "apps/a/lib/two.ex",
    "apps/b/lib/three.ex",
    "apps/c/lib/four.ex",
    "old/moved.ex",
]

PERMISSIONS = {
    ".formatter.exs": ["V1", "B1", "N0", "S1"],
    "README.md": ["V1", "B1", "N0", "S1"],
    "apps/a/lib/one.ex": ["V1"],
    "apps/b/lib/three.ex": ["B1"],
    "apps/cyfr/test/cyfr/docs_drift_test.exs": ["V1", "B1"],
    "docs/plans/end-state-architecture.md": ["V1", "B1", "N0", "S1"],
    "integration-guide.md": ["V1", "B1"],
    "new/moved.ex": ["N0"],
    "old/moved.ex": ["N0"],
    "apps/c/lib/after.ex": ["S1"],
}

MOVES = {"old/moved.ex": "new/moved.ex"}


def plan_text(sequence=SEQUENCE, headings=None, permissions=PERMISSIONS, moves=MOVES, blocks=None):
    headings = sequence if headings is None else headings
    if blocks is None:
        blocks = [json.dumps(permissions, indent=2), json.dumps(moves, indent=2)]
    fenced = "\n\n".join(f"```json\n{block}\n```" for block in blocks)
    sections = "\n\n".join(f"### {target} — the {target} cut\n\nIts text." for target in headings)
    return (
        "# Plan\n\n## 10. Enforcement\n\n`X1 → X2` is not the sequence.\n\n"
        "## 11. Implementation plan\n\nThe execution sequence is:\n\n"
        f"`{' → '.join(sequence)}`.\n\n{sections}\n\n"
        "## 16. Exact file ownership and move ledger\n\n"
        f"<details>\n\n{fenced}\n\n</details>\n"
    )


class Repo:
    """A throwaway repository with one commit of `files`."""

    def __init__(self, root, files=TRACKED):
        self.root = os.path.join(root, "repo")
        os.makedirs(self.root)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "test")
        self.git("config", "commit.gpgsign", "false")
        self.commit(files, "base")

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", self.root, *args], check=True, capture_output=True, text=True
        ).stdout.strip()

    def commit(self, files, message):
        for path in files:
            full = os.path.join(self.root, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "a", encoding="utf-8") as handle:
                handle.write(f"{message}\n")
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")


class ArchitecturePlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Repo(self.tmp.name)
        self.plan = os.path.join(self.tmp.name, "plan.md")
        self.write_plan(plan_text())

    def write_plan(self, text):
        with open(self.plan, "w", encoding="utf-8") as handle:
            handle.write(text)

    def run_script(self, *args, plan=True):
        extra = ["--plan", self.plan] if plan else []
        result = subprocess.run(
            [sys.executable, SCRIPT, "--repo", self.repo.root, *extra, *args],
            capture_output=True,
            text=True,
        )
        return result.returncode, result.stdout, result.stderr

    def assert_check_fails(self, text, message):
        self.write_plan(text)
        code, out, _err = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn(message, out)

    # --check

    def test_a_clean_plan_passes_with_its_counts(self):
        code, out, err = self.run_script("--check")
        self.assertEqual(code, 0, out + err)
        self.assertIn("ok: 10 keys, 1 moves, 4 targets, 0 future inputs", out)
        self.assertNotIn("error:", out)

    def test_the_default_plan_is_read_from_the_repository(self):
        default = os.path.join(self.repo.root, "docs", "plans", "end-state-architecture.md")
        os.makedirs(os.path.dirname(default))
        with open(default, "w", encoding="utf-8") as handle:
            handle.write(plan_text())
        code, out, err = self.run_script("--check", plan=False)
        self.assertEqual(code, 0, out + err)

    def test_malformed_json_fails(self):
        broken = json.dumps(PERMISSIONS)[:-1]
        text = plan_text(blocks=[broken, json.dumps(MOVES)])
        self.assert_check_fails(text, "malformed permission map")

    def test_a_missing_json_block_fails(self):
        text = plan_text(blocks=[json.dumps(PERMISSIONS)])
        self.assert_check_fails(text, "section 16 has 1 json blocks")

    def test_a_move_map_of_the_wrong_shape_fails(self):
        blocks = [json.dumps(PERMISSIONS), json.dumps({"old/moved.ex": ["new/moved.ex"]})]
        self.assert_check_fails(plan_text(blocks=blocks), "malformed move map")

    def test_a_path_listed_twice_fails(self):
        doubled = json.dumps(PERMISSIONS)[:-1] + ', "README.md": ["V1"]}'
        text = plan_text(blocks=[doubled, json.dumps(MOVES)])
        self.assert_check_fails(text, "duplicate key 'README.md'")

    def test_a_plan_without_a_sequence_fails(self):
        text = plan_text().replace("`V1 → B1 → N0 → S1`", "V1, B1")
        self.assert_check_fails(text, "0 target sequences")

    def test_a_sequenced_target_without_a_section_fails(self):
        text = plan_text(headings=["V1", "N0", "S1"])
        self.assert_check_fails(text, "B1 is in the sequence and has no '### B1 —' section")

    def test_a_sequenced_target_without_a_projection_fails(self):
        text = plan_text(sequence=["V1", "B1", "N0", "S1", "U3"])
        self.assert_check_fails(text, "U3 is in the sequence and owns no path")

    def test_a_duplicate_destination_fails(self):
        moves = {"old/moved.ex": "new/moved.ex", "apps/a/lib/two.ex": "new/moved.ex"}
        self.assert_check_fails(plan_text(moves=moves), "destination new/moved.ex is claimed by")

    def test_a_destination_that_already_exists_fails(self):
        moves = {"old/moved.ex": "apps/c/lib/four.ex"}
        self.assert_check_fails(plan_text(moves=moves), "apps/c/lib/four.ex already exists")

    def test_a_missing_source_no_earlier_target_produces_fails(self):
        permissions = dict(PERMISSIONS, **{"old/later.ex": ["S1", "N0"]})
        moves = dict(MOVES, **{"old/absent.ex": "new/absent.ex", "old/later.ex": "new/later.ex"})
        self.write_plan(plan_text(permissions=permissions, moves=moves))
        code, out, _err = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("error: move source old/absent.ex does not exist", out)
        # S1 comes after N0, so owning the path does not produce it in time.
        self.assertIn("error: move source old/later.ex does not exist", out)

    def test_a_missing_source_an_earlier_target_produces_is_a_future_input(self):
        permissions = dict(PERMISSIONS, **{"old/future.ex": ["B1", "N0"]})
        moves = dict(MOVES, **{"old/future.ex": "new/future.ex"})
        self.write_plan(plan_text(permissions=permissions, moves=moves))
        code, out, err = self.run_script("--check")
        self.assertEqual(code, 0, out + err)
        self.assertIn("future input: old/future.ex (produced by B1)", out)
        self.assertIn("1 future inputs", out)

    def test_a_completed_move_passes_and_is_counted(self):
        # Moved: the source untracked and the destination tracked.
        os.makedirs(os.path.join(self.repo.root, "new"))
        self.repo.git("mv", "old/moved.ex", "new/moved.ex")
        self.repo.commit([], "move")
        code, out, err = self.run_script("--check")
        self.assertEqual(code, 0, out + err)
        self.assertIn("0 future inputs, 1 moves complete", out)
        self.assertNotIn("error:", out)

        # Both tracked is a collision, whichever side came back.
        self.repo.commit(["old/moved.ex"], "source back")
        code, out, _err = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("error: move destination new/moved.ex already exists beside its source", out)

        # Neither tracked is a missing source unless an earlier target produces it.
        self.repo.git("rm", "-q", "old/moved.ex", "new/moved.ex")
        self.repo.commit([], "both gone")
        code, out, _err = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("error: move source old/moved.ex does not exist", out)

        permissions = dict(PERMISSIONS, **{"old/moved.ex": ["B1", "N0"]})
        self.write_plan(plan_text(permissions=permissions))
        code, out, err = self.run_script("--check")
        self.assertEqual(code, 0, out + err)
        self.assertIn("future input: old/moved.ex (produced by B1)", out)
        self.assertIn("1 future inputs, 0 moves complete", out)

    def test_a_repository_that_tracks_nothing_fails(self):
        empty = os.path.join(self.tmp.name, "empty")
        os.makedirs(empty)
        subprocess.run(["git", "-C", empty, "init", "-q"], check=True)
        self.repo.root = empty
        code, out, _err = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("error: the repository tracks no file", out)

    # --target --range

    def test_a_range_inside_the_projection_and_its_directories_passes(self):
        base = self.repo.git("rev-parse", "HEAD")
        head = self.repo.commit(["apps/a/lib/one.ex", "apps/a/lib/private.ex"], "inside")
        code, out, err = self.run_script("--target", "V1", "--range", f"{base}..{head}")
        self.assertEqual(code, 0, out + err)
        self.assertIn("ok: 2 changed paths inside V1's projection", out)

    def test_a_path_outside_the_projection_is_listed(self):
        base = self.repo.git("rev-parse", "HEAD")
        head = self.repo.commit(
            ["apps/a/lib/one.ex", "apps/a/lib/private.ex", "apps/b/lib/three.ex", "apps/a/x.ex"],
            "mixed",
        )
        code, out, _err = self.run_script("--target", "V1", "--range", f"{base}..{head}")
        self.assertEqual(code, 1, out)
        self.assertEqual(out.splitlines(), ["apps/a/x.ex", "apps/b/lib/three.ex"])

    def test_an_integration_file_claims_no_directory(self):
        # S1's only root-level path is README.md, an integration file.
        permissions = dict(PERMISSIONS, **{".formatter.exs": ["V1", "B1", "N0"]})
        self.write_plan(plan_text(permissions=permissions))
        base = self.repo.git("rev-parse", "HEAD")
        head = self.repo.commit(["README.md", "Makefile", "apps/c/lib/private.ex"], "root")
        code, out, _err = self.run_script("--target", "S1", "--range", f"{base}..{head}")
        self.assertEqual(code, 1, out)
        self.assertEqual(out.splitlines(), ["Makefile"])

    def test_a_rename_lists_the_side_the_target_does_not_own(self):
        base = self.repo.git("rev-parse", "HEAD")
        self.repo.git("mv", "apps/b/lib/three.ex", "apps/a/lib/three.ex")
        head = self.repo.commit([], "move")
        code, out, _err = self.run_script("--target", "V1", "--range", f"{base}..{head}")
        self.assertEqual(code, 1, out)
        self.assertEqual(out.splitlines(), ["apps/b/lib/three.ex"])

    def test_a_target_without_a_range_is_a_usage_error(self):
        self.assertEqual(self.run_script("--target", "V1")[0], 2)
        self.assertEqual(self.run_script("--target", "V1", "--range", "HEAD")[0], 2)
        self.assertEqual(self.run_script("--target", "V1", "--range", "nope..HEAD")[0], 2)

    # --disjoint

    def test_disjoint_projections_pass(self):
        code, out, err = self.run_script("--disjoint", "V1", "B1")
        self.assertEqual(code, 0, out + err)
        self.assertIn("disjoint: V1 and B1", out)

    def test_the_integration_files_do_not_make_two_projections_overlap(self):
        # V1 and B1 share exactly the five integration-only files.
        shared = {path for path, owners in PERMISSIONS.items() if "V1" in owners and "B1" in owners}
        self.assertEqual(len(shared), 5)
        self.assertEqual(self.run_script("--disjoint", "V1", "B1")[0], 0)

    def test_overlapping_projections_fail_with_the_shared_paths(self):
        overlap = {"apps/a/lib/two.ex": ["V1", "S1"], "apps/c/lib/after.ex": ["V1", "S1"]}
        permissions = dict(PERMISSIONS, **overlap)
        self.write_plan(plan_text(permissions=permissions))
        code, out, _err = self.run_script("--disjoint", "V1", "S1")
        self.assertEqual(code, 1, out)
        self.assertEqual(out.splitlines(), ["apps/a/lib/two.ex", "apps/c/lib/after.ex"])

    # usage

    def test_an_unknown_target_is_a_usage_error(self):
        base = self.repo.git("rev-parse", "HEAD")
        code, _out, err = self.run_script("--target", "ZZ", "--range", f"{base}..{base}")
        self.assertEqual(code, 2)
        self.assertIn("unknown target ZZ", err)
        self.assertIn("usage:", err)
        self.assertEqual(self.run_script("--disjoint", "V1", "ZZ")[0], 2)

    def test_no_mode_or_a_missing_plan_is_a_usage_error(self):
        self.assertEqual(self.run_script()[0], 2)
        os.remove(self.plan)
        self.assertEqual(self.run_script("--check")[0], 2)


if __name__ == "__main__":
    unittest.main()
