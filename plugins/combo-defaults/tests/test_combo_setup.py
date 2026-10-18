import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "combo-setup.py")


def run(path, *args):
    return subprocess.run(
        [sys.executable, SCRIPT, "--settings", path, *args],
        capture_output=True, text=True,
    )


class ComboSetup(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "settings.json")

    def write(self, data):
        with open(self.path, "w") as f:
            json.dump(data, f, indent=2)

    def read(self):
        with open(self.path) as f:
            return json.load(f)

    def backups(self):
        return [n for n in os.listdir(self.dir) if n.startswith("settings.json.bak-")]

    def test_merges_keys_and_keeps_others_in_order(self):
        self.write({
            "permissions": {"allow": ["Bash"]},
            "model": "opus",
            "modelSettings": {"claude-opus-5-5": {"effortLevel": "medium", "x": 1},
                              "claude-sonnet-5": {"effortLevel": "low"}},
            "theme": "dark",
        })
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = self.read()
        self.assertEqual(list(data), ["permissions", "model", "modelSettings", "theme",
                                      "outputStyle", "ultracode"])
        self.assertEqual(data["model"], "claude-opus-5-5")
        self.assertEqual(data["modelSettings"]["claude-opus-5-5"], {"effortLevel": "high", "x": 1})
        self.assertEqual(data["modelSettings"]["claude-sonnet-5"], {"effortLevel": "low"})
        self.assertEqual(data["outputStyle"], "Proactive")
        self.assertIs(data["ultracode"], True)
        self.assertEqual(data["theme"], "dark")
        self.assertEqual(len(self.backups()), 1)
        self.assertIn('model: "opus" -> "claude-opus-5-5"', r.stdout)

    def test_second_run_changes_nothing(self):
        self.write({"theme": "dark"})
        run(self.path)
        before = open(self.path).read()
        r = run(self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(open(self.path).read(), before)
        self.assertEqual(len(self.backups()), 1)
        self.assertIn("already set", r.stdout)

    def test_dry_run_writes_nothing(self):
        self.write({"theme": "dark"})
        before = open(self.path).read()
        r = run(self.path, "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(open(self.path).read(), before)
        self.assertEqual(self.backups(), [])
        self.assertIn('+ outputStyle: "Proactive"', r.stdout)

    def test_creates_missing_file(self):
        path = os.path.join(self.dir, "sub", "settings.json")
        r = run(path)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(path) as f:
            self.assertEqual(json.load(f), {
                "model": "claude-opus-5-5",
                "modelSettings": {"claude-opus-5-5": {"effortLevel": "high"}},
                "outputStyle": "Proactive",
                "ultracode": True,
            })

    def test_invalid_json_is_left_alone(self):
        with open(self.path, "w") as f:
            f.write("{ not json")
        r = run(self.path)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(open(self.path).read(), "{ not json")
        self.assertEqual(self.backups(), [])

    def test_keeps_file_mode(self):
        self.write({})
        os.chmod(self.path, 0o600)
        run(self.path)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
