"""Unit tests for build-report.py: python3 -m unittest discover -s scripts -p 'test_*.py'"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("build_report", HERE / "build-report.py")
build_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_report)

VALIDATE_LOG = (HERE / "testdata" / "validate.log").read_text(encoding="utf-8")
ENV = {
    "GITHUB_REPOSITORY": "AkibUllah/k8s-gitops-platform",
    "GITHUB_RUN_ID": "42",
    "GITHUB_SHA": "0123456789abcdef",
    "GITHUB_EVENT_NAME": "schedule",
}


def write_e2e(root: Path, *, finished: bool = True) -> Path:
    e2e = root / "e2e"
    e2e.mkdir()
    (e2e / "started").write_text("2026-10-30T05:00:00Z\n")
    if finished:
        (e2e / "finished").write_text("2026-10-30T05:09:12Z\n")
    (e2e / "server-version.txt").write_text(
        json.dumps({"serverVersion": {"gitVersion": "v1.36.4"}})
    )
    (e2e / "checks.tsv").write_text(
        "helm test url-shortener\ttest-health hook passed\n"
        'GET /health url-shortener\t{"status":"ok","database":"ok","cache":"ok"}\n'
        "NetworkPolicy\ta pod outside the platform timed out reaching the payment gateway\n"
    )
    (e2e / "nodes.txt").write_text("NAME STATUS\ncp Ready\nw1 Ready\nw2 Ready\n")
    (e2e / "images.tsv").write_text("payment-gateway\treal image\nurl-shortener\tstand-in\n")
    (e2e / "pods.txt").write_text("NAME READY STATUS\nurl-shortener-abc 1/1 Running\n<script>x</script>\n")
    return e2e


class ParseValidateTest(unittest.TestCase):
    def test_headline_numbers_from_a_real_log(self) -> None:
        result = build_report.parse_validate(VALIDATE_LOG)
        self.assertTrue(result["passed"])
        self.assertEqual(result["lint_ok"], 9)
        self.assertEqual(
            result["kubeconform"],
            [
                {"version": "1.34.11", "resources": 178, "valid": 178, "invalid": 0},
                {"version": "1.36.4", "resources": 178, "valid": 178, "invalid": 0},
            ],
        )
        self.assertEqual(result["policy_unit_tests"]["passed"], 39)
        self.assertEqual(result["policy_checks"]["failures"], 0)
        self.assertEqual(len(result["negative_checks"]), 3)
        self.assertIn("image.tag=latest is rejected at render time", result["negative_checks"])

    def test_colour_codes_are_ignored(self) -> None:
        log = (
            "==> conftest verify (policy unit tests)\n"
            "\x1b[32m39 tests, 39 passed, 0 warnings, 0 failures, 0 exceptions\x1b[0m\n"
        )
        self.assertEqual(build_report.parse_validate(log)["policy_unit_tests"]["tests"], 39)

    def test_a_failed_run_is_not_passed(self) -> None:
        log = VALIDATE_LOG.replace("All validation passed.", "FAIL: image.tag=latest rendered")
        self.assertFalse(build_report.parse_validate(log)["passed"])


class BuildTest(unittest.TestCase):
    def test_report_from_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = build_report.build(write_e2e(Path(tmp)), VALIDATE_LOG, ENV)
        self.assertTrue(report["e2e"]["passed"])
        self.assertEqual(report["e2e"]["kubernetes"], "v1.36.4")
        self.assertEqual(report["e2e"]["nodes"], 3)
        self.assertEqual(len(report["e2e"]["checks"]), 3)
        self.assertEqual(
            report["run_url"], "https://github.com/AkibUllah/k8s-gitops-platform/actions/runs/42"
        )

    def test_unfinished_run_is_not_passed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = build_report.build(write_e2e(Path(tmp), finished=False), VALIDATE_LOG, ENV)
        self.assertFalse(report["e2e"]["passed"])

    def test_bad_version_json_is_tolerated(self) -> None:
        self.assertIsNone(build_report.server_version("not json"))
        self.assertIsNone(build_report.server_version('{"clientVersion": {}}'))


class RenderTest(unittest.TestCase):
    def test_page_shows_the_evidence_and_escapes_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            e2e = write_e2e(root)
            page = build_report.render(build_report.build(e2e, VALIDATE_LOG, ENV), e2e)
        self.assertIn("All checks passed", page)
        self.assertIn("178/178", page)
        self.assertIn("39/39", page)
        self.assertIn("helm test url-shortener", page)
        self.assertIn("url-shortener (stand-in)", page)
        self.assertIn('href="https://github.com/AkibUllah/k8s-gitops-platform/commit/0123456789abcdef"', page)
        self.assertIn("&lt;script&gt;x&lt;/script&gt;", page)  # cluster output is escaped
        self.assertNotIn("<script>x</script>", page)


class MainTest(unittest.TestCase):
    def test_writes_page_and_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            e2e = write_e2e(root)
            log = root / "validate.log"
            log.write_text(VALIDATE_LOG)
            out = root / "site"
            code = build_report.main(["--e2e", str(e2e), "--validate", str(log), "--out", str(out)])
            self.assertEqual(code, 0)
            self.assertTrue((out / "index.html").is_file())
            data = json.loads((out / "report.json").read_text())
            self.assertTrue(data["validate"]["passed"])

    def test_refuses_to_publish_incomplete_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            e2e = write_e2e(root, finished=False)
            log = root / "validate.log"
            log.write_text(VALIDATE_LOG)
            out = root / "site"
            code = build_report.main(["--e2e", str(e2e), "--validate", str(log), "--out", str(out)])
            self.assertEqual(code, 1)
            self.assertFalse((out / "index.html").exists())


if __name__ == "__main__":
    unittest.main()
