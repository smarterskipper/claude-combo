#!/usr/bin/env python3
"""Tests for the planner and result merge in xq-test. No Mac involved. Run: python3 test-xq-test.py"""
import importlib.machinery, importlib.util, os, unittest

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "xq-test")
loader = importlib.machinery.SourceFileLoader("xq_test", path)
spec = importlib.util.spec_from_loader("xq_test", loader)
xt = importlib.util.module_from_spec(spec)
loader.exec_module(xt)

T = "MenosTests"


def timings(**classes):
    """Render=[3, 2] -> two methods in class Render taking 3 s and 2 s."""
    return {(c, f"test{i}"): s for c, secs in classes.items() for i, s in enumerate(secs)}


def listed(args):
    return {a.split(":", 1)[1] for a in args}


class Plan(unittest.TestCase):
    def test_no_timings_is_one_shard_with_no_filter(self):
        shards = xt.plan({}, set(), 2, 2, T)
        self.assertEqual(shards, [{"mac": "a", "args": []}])

    def test_the_rest_shard_skips_exactly_what_the_others_run(self):
        t = timings(A=[5], B=[4], C=[3], D=[2], E=[1])
        shards = xt.plan(t, set(), 1, 1, T)
        self.assertEqual(len(shards), 2)
        rest, other = shards
        self.assertTrue(all(a.startswith("-skip-testing:") for a in rest["args"]))
        self.assertTrue(all(a.startswith("-only-testing:") for a in other["args"]))
        self.assertEqual(listed(rest["args"]), listed(other["args"]))

    def test_the_rest_shard_stays_on_the_build_mac(self):
        shards = xt.plan(timings(A=[5], B=[4]), set(), 1, 1, T)
        self.assertEqual(shards[0]["mac"], "a")

    def test_a_class_too_big_for_one_shard_is_split_by_method(self):
        t = timings(Big=[3] * 8, Small=[1])
        shards = xt.plan(t, set(), 1, 1, T)
        other = listed(shards[1]["args"])
        self.assertTrue(other)
        self.assertTrue(all(i.startswith(f"{T}/Big/test") for i in other), other)

    def test_a_pinned_class_never_leaves_the_build_mac(self):
        t = timings(Pinned=[50], Big=[1], Other=[1])
        shards = xt.plan(t, {"Pinned"}, 1, 1, T)
        for s in shards:
            if s["mac"] == "b":
                self.assertFalse([a for a in s["args"] if "Pinned" in a])

    def test_a_pinned_class_too_big_for_one_shard_stays_on_the_build_mac_when_split(self):
        t = timings(Pinned=[10] * 6, Other=[1])
        shards = xt.plan(t, {"Pinned"}, 2, 1, T)
        for s in shards:
            if s["mac"] == "b":
                self.assertFalse([a for a in s["args"] if "Pinned" in a])

    def test_the_load_is_even(self):
        t = timings(**{f"C{i}": [i + 1] for i in range(20)})
        shards = xt.plan(t, set(), 2, 2, T)
        self.assertEqual(len(shards), 4)
        secs = xt.shard_seconds(shards, t, T)
        self.assertLess(max(secs) - min(secs), 12)

    def test_the_other_mac_gets_less_to_cover_its_late_start(self):
        t = timings(**{f"C{i}": [2] for i in range(40)})
        a, b = xt.shard_seconds(xt.plan(t, set(), 1, 1, T, b_delay=10), t, T)
        self.assertGreater(a, b)

    def test_one_mac_with_one_sim_is_one_unfiltered_shard(self):
        shards = xt.plan(timings(A=[5], B=[4]), set(), 1, 0, T)
        self.assertEqual(shards, [{"mac": "a", "args": []}])


class Parse(unittest.TestCase):
    def test_reads_the_serial_format(self):
        log = ("Test Case '-[MenosTests.Foo testA]' passed (0.004 seconds).\n"
               "Test Case '-[MenosTests.Foo testB]' failed (1.500 seconds).\n"
               "Test Case '-[MenosTests.Foo testC]' skipped (0.005 seconds).\n"
               "Test Case '-[MenosTests.Foo testD]' started.\n")
        self.assertEqual(xt.parse_log(log), {("Foo", "testA"): ("passed", 0.004),
                                             ("Foo", "testB"): ("failed", 1.5),
                                             ("Foo", "testC"): ("skipped", 0.005)})

    def test_reads_the_parallel_format(self):
        log = "Test case 'Foo.testA()' passed on 'Clone 1 of xq-shard - Menos (91691)' (0.005 seconds)\n"
        self.assertEqual(xt.parse_log(log), {("Foo", "testA"): ("passed", 0.005)})


class Merge(unittest.TestCase):
    def shard(self, rc=0, **results):
        return {"name": "s", "rc": rc, "results": {("C", k): (v, 1.0) for k, v in results.items()}}

    def test_all_passed(self):
        m = xt.merge([self.shard(a="passed"), self.shard(b="passed", c="skipped")], set())
        self.assertTrue(m["ok"])
        self.assertEqual((m["total"], m["skipped"], m["failed"]), (3, 1, []))

    def test_a_failed_test_fails_the_run(self):
        m = xt.merge([self.shard(a="passed"), self.shard(b="failed")], set())
        self.assertFalse(m["ok"])
        self.assertEqual(m["failed"], ["C.b"])

    def test_a_shard_that_exited_badly_fails_the_run_even_if_no_test_failed(self):
        self.assertFalse(xt.merge([self.shard(a="passed"), self.shard(rc=65, b="passed")], set())["ok"])

    def test_a_shard_that_ran_nothing_fails_the_run(self):
        self.assertFalse(xt.merge([self.shard(a="passed"), self.shard()], set())["ok"])

    def test_a_test_run_twice_fails_the_run(self):
        m = xt.merge([self.shard(a="passed"), self.shard(a="passed")], set())
        self.assertFalse(m["ok"])
        self.assertEqual(m["twice"], ["C.a"])

    def test_far_fewer_of_the_expected_tests_than_last_time_fails_the_run(self):
        expected = {("C", "a"), ("C", "b")} | {("C", f"t{i}") for i in range(98)}
        self.assertFalse(xt.merge([self.shard(a="passed", b="passed")], expected)["ok"])

    def test_a_few_tests_fewer_than_last_time_is_fine(self):
        expected = {("C", k) for k in "abcdefghijklmnopqrst"}   # 20; 19 ran
        self.assertTrue(xt.merge([self.shard(**{k: "passed" for k in "abcdefghijklmnopqrs"})], expected)["ok"])


# Branches of one repo share one timings file, which the last green run of any branch rewrites. The last green run
# here was another branch's: it has class Shop, which this branch doesn't, Hangar.testShop, removed on purpose, and
# Hangar.testTaxi, which this branch moved to Run.
OTHER_BRANCH = {("Flight", m): 30.0 for m in ("testA", "testB", "testC")}
OTHER_BRANCH.update({("Hangar", m): 20.0 for m in ("testOpen", "testTaxi", "testSettings", "testShop")})
OTHER_BRANCH.update({("Shop", m): 40.0 for m in ("testBuy", "testRestore", "testPrice")})
OTHER_BRANCH.update({("Run", m): 50.0 for m in ("testCrash", "testPause", "testStage")})
THIS_BRANCH = ({k for k in OTHER_BRANCH if k[0] != "Shop" and k[1] not in ("testShop", "testTaxi")}
               | {("Run", "testNew"), ("Run", "testTaxi")})
# What the worker's scan of this branch's test folder reports (XQT tests <type> <methods>): each test method with
# the type declared above it, plus a helper type's test-named method that isn't a test.
SCAN = THIS_BRANCH | {("TestHelpers", "testHelperNotATest")}


def run_on_this_branch(shards, drop=()):
    """What xcodebuild runs for each shard on THIS_BRANCH: the listed ids it has, or for the first shard everything
    it has but the skipped ids. drop: tests a shard silently left out."""
    def matches(key, ident):
        parts = ident.split("/")
        return parts[1] == key[0] and (len(parts) == 2 or parts[2] == key[1])
    out = []
    for i, s in enumerate(shards):
        ids = [a.split(":", 1)[1] for a in s["args"]]
        if i == 0:
            ran = [k for k in THIS_BRANCH if not any(matches(k, x) for x in ids)]
        else:
            ran = [k for k in THIS_BRANCH if any(matches(k, x) for x in ids)]
        out.append({"name": f"s{i}", "rc": 0,
                    "results": {k: ("passed", 1.0) for k in sorted(ran) if k not in drop}})
    return out


class Branches(unittest.TestCase):
    def verdict(self, drop=()):
        here = xt.in_build(OTHER_BRANCH, SCAN)
        shards = xt.plan(here, set(), 2, 2, T)
        return shards, xt.merge(run_on_this_branch(shards, drop), set(here))

    def test_a_green_run_of_a_branch_with_fewer_tests_than_the_timings_passes(self):
        _, m = self.verdict()
        self.assertEqual(m["problems"], [])
        self.assertTrue(m["ok"])
        self.assertEqual(m["total"], len(THIS_BRANCH))

    def test_no_shard_is_given_only_tests_this_build_lacks(self):
        shards, _ = self.verdict()
        for s in shards[1:]:
            ids = listed(s["args"])
            self.assertFalse([i for i in ids if "/Shop" in i or i.endswith("/testShop") or "Hangar/testTaxi" in i], ids)

    def test_the_timings_keep_only_tests_this_build_has(self):
        self.assertEqual(set(xt.in_build(OTHER_BRANCH, SCAN)), THIS_BRANCH - {("Run", "testNew"), ("Run", "testTaxi")})

    def test_a_test_moved_to_another_class_is_not_expected_in_its_old_class(self):
        self.assertNotIn(("Hangar", "testTaxi"), xt.in_build(OTHER_BRANCH, SCAN))

    def test_a_shard_that_leaves_out_tests_this_build_has_still_fails(self):
        here = set(xt.in_build(OTHER_BRANCH, SCAN))
        drop = set(sorted(here)[:3])
        _, m = self.verdict(drop)
        self.assertFalse(m["ok"])

    def test_with_no_names_from_the_build_every_timed_test_stays(self):
        self.assertEqual(xt.in_build(OTHER_BRANCH, set()), OTHER_BRANCH)


class Cleanup(unittest.TestCase):
    def test_each_mac_drops_its_own_simulators(self):
        cmds = xt.cleanup_cmds(["mini1", "macbook"], "ru7gate", "/tmp/xqt/ru7gate-1", False)
        self.assertEqual([m for m, _ in cmds], ["mini1", "macbook"])
        self.assertIn("~/bin/xq drop ru7gate ", cmds[0][1])
        self.assertIn("~/bin/xq drop ru7gate-b ", cmds[1][1])
        self.assertTrue(all(c.startswith("rm -rf /tmp/xqt/ru7gate-1") for _, c in cmds))

    def test_one_mac_run_drops_on_that_mac_only(self):
        self.assertEqual(len(xt.cleanup_cmds(["mini1"], "t", "/tmp/xqt/t-1", False)), 1)

    def test_keep_sims_only_removes_the_folder(self):
        cmds = xt.cleanup_cmds(["mini1", "macbook"], "t", "/tmp/xqt/t-1", True)
        self.assertTrue(all("drop" not in c for _, c in cmds))


if __name__ == "__main__":
    unittest.main()
