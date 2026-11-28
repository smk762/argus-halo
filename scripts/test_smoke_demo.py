"""scripts/smoke-demo.py's own plumbing: teardown and the secrets check, without docker.

    python3 -m unittest discover -s scripts -p 'test_*.py'
"""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location("smoke_demo", Path(__file__).with_name("smoke-demo.py"))
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)


SERVICES = ("frontend", "caddy", "curator", "quarry", "forge", "proof", "atlas")
ALL_UP = {s: "abc" for s in SERVICES}


class FakeDocker:
    """Stands in for subprocess.run: records docker calls, answers from a script."""

    def __init__(self, up_fails=False, ps_ids=None):
        self.calls = []
        self.up_fails = up_fails
        self.ps_ids = ps_ids if ps_ids is not None else {}

    def __call__(self, argv, check=False, **kw):
        self.calls.append(argv)
        rc, out = 0, ""
        if "up" in argv and self.up_fails:
            rc = 1
        elif "ps" in argv and "-q" in argv:
            out = self.ps_ids.get(argv[-1], "")
        elif argv[:2] == ["docker", "inspect"]:
            if len(argv) <= 4:
                rc = 1  # docker refuses `inspect` with no container
            out = '["PATH=/usr/bin"]'
        if check and rc:
            raise subprocess.CalledProcessError(rc, argv)
        return subprocess.CompletedProcess(argv, rc, stdout=out, stderr="")

    def compose_verbs(self):
        return [a[a.index("-f") + 2] for a in self.calls if a[:2] == ["docker", "compose"]]


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.work = self.tmp / "work"
        self.work.mkdir()
        smoke.failures.clear()
        for patch in (
            mock.patch.object(smoke.tempfile, "mkdtemp", return_value=str(self.work)),
            mock.patch.object(smoke, "probe", lambda: None),
            mock.patch.object(smoke, "call", lambda *a, **k: (200, "", {})),
            mock.patch.object(smoke, "health", lambda svc: (200, {})),
            mock.patch.object(sys, "argv", ["smoke-demo.py"]),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def run_main(self, docker):
        with mock.patch.object(smoke.subprocess, "run", docker):
            return smoke.main()

    def test_a_failed_up_is_still_torn_down(self):
        docker = FakeDocker(up_fails=True)
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_main(docker)
        self.assertEqual(docker.compose_verbs(), ["up", "down"])
        self.assertFalse(self.work.exists())

    def test_teardown_removes_the_project_not_just_stops_it(self):
        docker = FakeDocker(ps_ids=ALL_UP)
        self.assertEqual(self.run_main(docker), 0)
        down = [a for a in docker.calls if "down" in a]
        self.assertEqual(len(down), 1)
        self.assertIn("-v", down[0])
        self.assertIn("--remove-orphans", down[0])
        self.assertNotIn("stop", docker.compose_verbs())

    def test_the_work_dir_holding_smoke_env_is_removed(self):
        self.run_main(FakeDocker(ps_ids=ALL_UP))
        self.assertFalse(self.work.exists())

    def test_keep_leaves_the_stack_and_its_files(self):
        with mock.patch.object(sys, "argv", ["smoke-demo.py", "--keep"]):
            docker = FakeDocker(ps_ids=ALL_UP)
            self.run_main(docker)
        self.assertNotIn("down", docker.compose_verbs())
        self.assertTrue((self.work / "smoke.env").exists())

    def test_smoke_env_is_private(self):
        smoke.build(self.work)
        self.assertEqual((self.work / "smoke.env").stat().st_mode & 0o077, 0)


class SecretsTest(unittest.TestCase):
    def setUp(self):
        smoke.failures.clear()

    def test_a_service_without_containers_is_a_failure_not_a_crash(self):
        docker = FakeDocker(ps_ids={"frontend": "abc"})

        def compose(*args, **kw):
            kw.setdefault("check", True)
            return docker(["docker", "compose", "-f", "x", *args], **kw)

        with mock.patch.object(smoke.subprocess, "run", docker):
            smoke.secrets(compose)
        self.assertIn("caddy has a container to inspect", smoke.failures)
        # Every service was still looked at, and inspect never ran without ids.
        self.assertEqual(sum("ps" in a for a in docker.calls), len(SERVICES))
        self.assertTrue(all(len(a) > 4 for a in docker.calls if a[:2] == ["docker", "inspect"]))


if __name__ == "__main__":
    unittest.main()
