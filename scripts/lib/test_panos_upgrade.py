#!/usr/bin/env python3
"""Unit tests for the PAN-OS upgrade path planner.

Run: python3 scripts/lib/test_panos_upgrade.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from panos_upgrade import Version, plan_upgrade  # noqa: E402

# Update-server list shaped like a real one: no 12.0 release, hotfixes present.
AVAILABLE = [
    "10.1.0", "10.1.14", "10.2.0", "10.2.4", "10.2.10", "10.2.10-h2",
    "11.0.0", "11.0.6", "11.1.0", "11.1.4", "11.1.6-h1",
    "11.2.0", "11.2.5", "12.1.0", "12.1.2", "12.1.9",
    "12.2.0", "12.2.2", "12.2.4", "12.2.4-h1",
    "13.1.0", "13.1.1",
]


def s(plan):
    return {k: [str(v) for v in plan[k]] for k in ("downloads", "hops")}


class PlanTest(unittest.TestCase):
    def test_same_release_maintenance(self):
        self.assertEqual(s(plan_upgrade("12.2.2", "12.2.4", AVAILABLE)),
                         {"downloads": ["12.2.4"], "hops": ["12.2.4"]})

    def test_next_release_needs_target_base(self):
        # Today's real case: 12.1.9 -> 12.2.4 needs the 12.2.0 base on the FW.
        self.assertEqual(s(plan_upgrade("12.1.9", "12.2.4", AVAILABLE)),
                         {"downloads": ["12.2.0", "12.2.4"], "hops": ["12.2.4"]})

    def test_target_is_base(self):
        self.assertEqual(s(plan_upgrade("12.1.9", "12.2.0", AVAILABLE)),
                         {"downloads": ["12.2.0"], "hops": ["12.2.0"]})

    def test_skip_three_releases_single_install(self):
        # 11.0 -> 12.2: skips 11.1, 11.2, 12.1 (3) — one install, full base chain.
        self.assertEqual(s(plan_upgrade("11.0.6", "12.2.4", AVAILABLE)),
                         {"downloads": ["11.1.0", "11.2.0", "12.1.0", "12.2.0", "12.2.4"],
                          "hops": ["12.2.4"]})

    def test_no_12_0_release_is_not_invented(self):
        plan = s(plan_upgrade("11.2.5", "12.1.9", AVAILABLE))
        self.assertEqual(plan, {"downloads": ["12.1.0", "12.1.9"], "hops": ["12.1.9"]})

    def test_more_than_three_skipped_splits_into_hops(self):
        # 10.2 -> 12.2 skips 11.0, 11.1, 11.2, 12.1 (4) -> first hop lands on 12.1.
        self.assertEqual(s(plan_upgrade("10.2.10", "12.2.4", AVAILABLE)),
                         {"downloads": ["11.0.0", "11.1.0", "11.2.0", "12.1.0", "12.1.9",
                                        "12.2.0", "12.2.4"],
                          "hops": ["12.1.9", "12.2.4"]})

    def test_panorama_one_release_per_hop(self):
        self.assertEqual(s(plan_upgrade("11.1.4", "12.2.4", AVAILABLE, max_skip=0)),
                         {"downloads": ["11.2.0", "11.2.5", "12.1.0", "12.1.9", "12.2.0", "12.2.4"],
                          "hops": ["11.2.5", "12.1.9", "12.2.4"]})

    def test_hotfix_target_uses_plain_base(self):
        self.assertEqual(s(plan_upgrade("12.1.9", "12.2.4-h1", AVAILABLE)),
                         {"downloads": ["12.2.0", "12.2.4-h1"], "hops": ["12.2.4-h1"]})

    def test_hotfix_on_current(self):
        self.assertEqual(s(plan_upgrade("12.2.4", "12.2.4-h1", AVAILABLE)),
                         {"downloads": ["12.2.4-h1"], "hops": ["12.2.4-h1"]})

    def test_noop(self):
        self.assertEqual(s(plan_upgrade("12.2.4", "12.2.4", AVAILABLE)),
                         {"downloads": [], "hops": []})

    def test_downgrade_refused(self):
        with self.assertRaises(ValueError):
            plan_upgrade("12.2.4", "12.1.9", AVAILABLE)

    def test_unavailable_target_refused(self):
        with self.assertRaises(ValueError):
            plan_upgrade("12.1.9", "12.2.9", AVAILABLE)

    def test_pre_10_1_no_skip(self):
        avail = ["9.1.0", "9.1.16", "10.0.0", "10.0.12", "10.1.0", "10.1.14"]
        self.assertEqual(s(plan_upgrade("9.1.16", "10.1.14", avail)),
                         {"downloads": ["10.0.0", "10.0.12", "10.1.0", "10.1.14"],
                          "hops": ["10.0.12", "10.1.14"]})

    def test_version_ordering(self):
        self.assertTrue(Version("12.2.4") < Version("12.2.4-h1") < Version("12.2.10"))
        self.assertTrue(Version("11.2.5") < Version("12.1.0"))
        self.assertTrue(Version("12.2.4") >= Version("12.2.4"))
        self.assertTrue(Version("12.2.4") <= Version("12.2.4-h1"))
        self.assertFalse(Version("12.1.9") >= Version("12.2.4"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
