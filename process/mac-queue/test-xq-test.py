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
        m = xt.merge([self.shard(a="passed"), self.shard(b="passed", c="skipped")], 0)
        self.assertTrue(m["ok"])
        self.assertEqual((m["total"], m["skipped"], m["failed"]), (3, 1, []))

    def test_a_failed_test_fails_the_run(self):
        m = xt.merge([self.shard(a="passed"), self.shard(b="failed")], 0)
        self.assertFalse(m["ok"])
        self.assertEqual(m["failed"], ["C.b"])

    def test_a_shard_that_exited_badly_fails_the_run_even_if_no_test_failed(self):
        self.assertFalse(xt.merge([self.shard(a="passed"), self.shard(rc=65, b="passed")], 0)["ok"])

    def test_a_shard_that_ran_nothing_fails_the_run(self):
        self.assertFalse(xt.merge([self.shard(a="passed"), self.shard()], 0)["ok"])

    def test_a_test_run_twice_fails_the_run(self):
        m = xt.merge([self.shard(a="passed"), self.shard(a="passed")], 0)
        self.assertFalse(m["ok"])
        self.assertEqual(m["twice"], ["C.a"])

    def test_far_fewer_tests_than_last_time_fails_the_run(self):
        self.assertFalse(xt.merge([self.shard(a="passed", b="passed")], 100)["ok"])

    def test_a_few_tests_fewer_than_last_time_is_fine(self):
        self.assertTrue(xt.merge([self.shard(a="passed", b="passed")], 2)["ok"])


if __name__ == "__main__":
    unittest.main()
