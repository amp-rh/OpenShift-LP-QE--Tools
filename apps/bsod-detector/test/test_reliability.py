#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


APP = Path(__file__).resolve().parents[1]
HOST = APP / "src" / "scripts" / "host"
RELIABILITY = HOST / "reliability.py"
FIXTURES = APP / "test" / "fixtures"


def run_helper(*args, stdin=""):
    return subprocess.run(
        [sys.executable, str(RELIABILITY), *args],
        input=stdin,
        text=True,
        capture_output=True,
        check=False,
    )


class ReliabilityTests(unittest.TestCase):
    def test_unknown_domstate_fails_at_threshold_instead_of_looping_to_108(self):
        for misses in (2, 3, 108):
            result = run_helper(
                "decision", "--misses", str(misses), "--threshold", "2",
                "--domstate", "unknown", "--vmi-phase", "Running", "--pod-present",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["reason"], "ambiguous-domstate-unknown")

    def test_current_pvpanic_corrobates_unavailable_domstate(self):
        result = run_helper(
            "decision", "--misses", "2", "--threshold", "2",
            "--domstate", "unavailable", "--vmi-phase", "Running",
            "--pod-present", "--pvpanic",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["decision"], "capture")

    def test_running_domain_without_pvpanic_is_ambiguous(self):
        result = run_helper(
            "decision", "--misses", "2", "--threshold", "2",
            "--domstate", "running", "--vmi-phase", "Running", "--pod-present",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["reason"], "ambiguous-domstate-running")

    def test_write_progress_then_quiescence_completes(self):
        sequence = (FIXTURES / "domstats-progress.json").read_text(encoding="utf-8")
        result = run_helper("progress-sequence", "--device", "vda", "--idle-samples", "3", stdin=sequence)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = json.loads(result.stdout)
        self.assertEqual(body["reason"], "progress-then-quiescence")
        self.assertTrue(body["observedProgress"])

    def test_no_progress_is_timeout_failure(self):
        sequence = (FIXTURES / "domstats-no-progress.json").read_text(encoding="utf-8")
        result = run_helper("progress-sequence", "--device", "vda", stdin=sequence)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["reason"], "no-progress-timeout")

    def test_missing_statistics_is_not_zero_activity(self):
        sequence = (FIXTURES / "domstats-missing.json").read_text(encoding="utf-8")
        result = run_helper("progress-sequence", "--device", "vda", stdin=sequence)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["reason"], "statistics-unavailable")

    def test_artifact_signatures_and_checksums(self):
        samples = {
            "screenshot": b"\x89PNG\r\n\x1a\nfixture",
            "memory": b"\x7fELFfixture",
            "dump": b"PAGEDU64" + bytes(96),
            "evtx": b"ElfFile\x00fixture",
        }
        with tempfile.TemporaryDirectory() as temporary:
            for kind, data in samples.items():
                path = Path(temporary) / kind
                path.write_bytes(data)
                result = run_helper("validate-artifact", "--type", kind, "--path", str(path))
                self.assertEqual(result.returncode, 0, (kind, result.stderr))
                body = json.loads(result.stdout)
                self.assertEqual(len(body["sha256"]), 64)

    def test_summary_is_derived_from_real_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            (out / "bsod-screenshot.png").write_bytes(b"\x89PNG\r\n\x1a\nfixture")
            (out / "vm-memory.elf").write_bytes(b"\x7fELFfixture")
            (out / "MEMORY.DMP").write_bytes(b"PAGEDU64" + bytes(96))
            (out / "System.evtx").write_bytes(b"ElfFile\x00fixture")
            (out / "watcher.log").write_text("fixture log\n", encoding="utf-8")
            errors = out / "stage-errors.jsonl"
            errors.write_text("", encoding="utf-8")
            result = run_helper(
                "write-summary", "--out", str(out), "--stage-errors", str(errors),
                "--mode", "fixture", "--vm", "fixture-vm", "--namespace", "fixture-ns",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((out / "evidence-summary.json").read_text(encoding="utf-8"))
            self.assertTrue(summary["ok"])
            self.assertTrue(all(item["size"] > 0 and item["sha256"] for item in summary["artifacts"]))

            (out / "MEMORY.DMP").unlink()
            failed = run_helper(
                "write-summary", "--out", str(out), "--stage-errors", str(errors),
                "--mode", "fixture", "--vm", "fixture-vm", "--namespace", "fixture-ns",
            )
            self.assertNotEqual(failed.returncode, 0)
            summary = json.loads((out / "evidence-summary.json").read_text(encoding="utf-8"))
            self.assertFalse(summary["ok"])
            self.assertIn("dump", summary["missingRequiredArtifactTypes"])


class GuestAgentExitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("guest_agent", HOST / "guest-agent.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_guest_nonzero_exit_is_propagated(self):
        with mock.patch.object(self.module, "guest_exec", return_value={"exitcode": 7, "stdout": "out", "stderr": "err"}), \
                mock.patch.object(sys, "argv", ["guest-agent.py", "exec", "fixture.exe"]), \
                contextlib.redirect_stdout(io.StringIO()) as stdout, \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            status = self.module.main()
        self.assertEqual(status, 7)
        self.assertEqual(stdout.getvalue(), "out\n")
        self.assertEqual(stderr.getvalue(), "err\n")

    def test_psfile_companion_contract(self):
        companions, arguments = self.module._psfile_args(
            ["--companion", "local.json", r"C:\Windows\Temp\local.json", "--", "-VerifyOnly"]
        )
        self.assertEqual(companions, [("local.json", r"C:\Windows\Temp\local.json")])
        self.assertEqual(arguments, ["-VerifyOnly"])


if __name__ == "__main__":
    unittest.main()
