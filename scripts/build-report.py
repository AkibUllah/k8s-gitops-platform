#!/usr/bin/env python3
"""Build the proof page from a CI run's evidence.

Inputs:
  --e2e DIR        what scripts/e2e-kind.sh wrote with REPORT_DIR=DIR
  --validate FILE  the output of scripts/validate.sh
  --out DIR        where index.html and report.json are written

The GitHub run URL and commit come from the standard GITHUB_* variables when they
are set. Standard library only, so it runs on a bare CI runner.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STEP = re.compile(r"^==> (.+)$")
KUBECONFORM = re.compile(r"Summary: (\d+) resources found in (\d+) files - Valid: (\d+), Invalid: (\d+)")
CONFTEST = re.compile(r"(\d+) tests, (\d+) passed, (\d+) warnings, (\d+) failures")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def parse_validate(log: str) -> dict:
    """Pull the headline numbers out of scripts/validate.sh output."""
    result: dict = {
        "passed": "All validation passed." in log,
        "kubeconform": [],
        "policy_unit_tests": None,
        "policy_checks": None,
        "negative_checks": [],
        "lint_ok": 0,
    }
    step = ""
    for raw in log.splitlines():
        line = ANSI.sub("", raw).rstrip()
        if m := STEP.match(line):
            step = m.group(1)
            continue
        if step == "helm lint" and line.startswith("ok  "):
            result["lint_ok"] += 1
        if (m := KUBECONFORM.search(line)) and step.startswith("kubeconform"):
            version = step.removeprefix("kubeconform (Kubernetes ").rstrip(")")
            found, _, valid, invalid = (int(g) for g in m.groups())
            result["kubeconform"].append(
                {"version": version, "resources": found, "valid": valid, "invalid": invalid}
            )
        if m := CONFTEST.search(line):
            tests, passed, warnings, failures = (int(g) for g in m.groups())
            counts = {"tests": tests, "passed": passed, "warnings": warnings, "failures": failures}
            if step.startswith("conftest verify"):
                result["policy_unit_tests"] = counts
            elif step.startswith("conftest: per-document"):
                result["policy_checks"] = counts
        if step == "negative checks" and line.startswith("ok  "):
            result["negative_checks"].append(line[4:])
    return result


def parse_tsv(text: str) -> list[tuple[str, str]]:
    rows = []
    for line in text.splitlines():
        if "\t" in line:
            name, detail = line.split("\t", 1)
            rows.append((name, detail))
    return rows


def server_version(text: str) -> str | None:
    try:
        return json.loads(text)["serverVersion"]["gitVersion"]
    except (ValueError, KeyError, TypeError):
        return None


def build(e2e_dir: Path, validate_log: str, env: dict[str, str]) -> dict:
    e2e = {
        "started": read(e2e_dir / "started").strip() or None,
        "finished": read(e2e_dir / "finished").strip() or None,
        "kubernetes": server_version(read(e2e_dir / "server-version.txt")),
        "nodes": max(0, len(read(e2e_dir / "nodes.txt").strip().splitlines()) - 1),
        "checks": parse_tsv(read(e2e_dir / "checks.tsv")),
        "images": parse_tsv(read(e2e_dir / "images.tsv")),
    }
    e2e["passed"] = e2e["finished"] is not None and bool(e2e["checks"])
    run_url = None
    if env.get("GITHUB_RUN_ID") and env.get("GITHUB_REPOSITORY"):
        server = env.get("GITHUB_SERVER_URL", "https://github.com")
        run_url = f"{server}/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
    return {
        "e2e": e2e,
        "validate": parse_validate(validate_log),
        "commit": env.get("GITHUB_SHA"),
        "trigger": env.get("GITHUB_EVENT_NAME"),
        "run_url": run_url,
        "repository": env.get("GITHUB_REPOSITORY", "AkibUllah/k8s-gitops-platform"),
    }


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def pre(title: str, text: str) -> str:
    if not text.strip():
        return ""
    return f"<details><summary>{esc(title)}</summary><pre>{esc(text.rstrip())}</pre></details>"


def render(report: dict, e2e_dir: Path) -> str:
    e2e, val = report["e2e"], report["validate"]
    ok = e2e["passed"] and val["passed"]
    status = "All checks passed" if ok else "Last run did not pass"
    repo = esc(report["repository"])
    commit = report["commit"]
    commit_html = (
        f'<a href="https://github.com/{repo}/commit/{esc(commit)}"><code>{esc(commit[:7])}</code></a>'
        if commit
        else "local run"
    )
    run_html = f'<a href="{esc(report["run_url"])}">full CI log</a>' if report["run_url"] else ""

    stats = []
    for kc in val["kubeconform"]:
        stats.append((f"{kc['valid']}/{kc['resources']}", f"resources valid on Kubernetes {kc['version']}"))
    if (unit := val["policy_unit_tests"]) is not None:
        stats.append((f"{unit['passed']}/{unit['tests']}", "Rego policy unit tests passed"))
    if (pol := val["policy_checks"]) is not None:
        stats.append((f"{pol['failures']}", f"policy failures across {pol['tests']} checks"))
    if val["lint_ok"]:
        stats.append((str(val["lint_ok"]), "chart x environment combinations lint clean"))
    stat_html = "".join(
        f'<div class="stat"><b>{esc(n)}</b><span>{esc(label)}</span></div>' for n, label in stats
    )

    checks_html = "".join(
        f'<li><span class="tick" aria-hidden="true">&#10003;</span><div><b>{esc(name)}</b>'
        f"<p><code>{esc(detail)}</code></p></div></li>"
        for name, detail in e2e["checks"]
    ) or "<li>No end-to-end evidence in this run.</li>"
    negative_html = "".join(f"<li>{esc(item)}</li>" for item in val["negative_checks"])
    images_html = ", ".join(f"{esc(name)} ({esc(kind)})" for name, kind in e2e["images"])

    evidence = "".join(
        pre(title, read(e2e_dir / name))
        for title, name in [
            ("kubectl get pods -o wide", "pods.txt"),
            ("kubectl get deploy,statefulset,svc,hpa,pdb,networkpolicy", "workloads.txt"),
            ("helm list", "releases.txt"),
            ("kubectl get nodes -o wide", "nodes.txt"),
            ("namespace labels (Pod Security Standard)", "namespace.txt"),
        ]
    )
    finished = e2e["finished"] or ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GitOps Platform Proof</title>
<meta name="description" content="Evidence from the latest CI run of k8s-gitops-platform: three services deployed to a real kind cluster and tested.">
<style>
  :root {{
    --bg: #f6f8fa; --panel: #ffffff; --line: #d8dee4; --text: #1f2328; --muted: #59636e;
    --ok: #1a7f37; --bad: #cf222e; --accent: #0969da; --code: #eff2f5;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --bg: #0d1117; --panel: #151b23; --line: #30363d; --text: #e6edf3; --muted: #9198a1;
      --ok: #3fb950; --bad: #f85149; --accent: #4493f8; --code: #1f2630;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg: #0d1117; --panel: #151b23; --line: #30363d; --text: #e6edf3; --muted: #9198a1;
    --ok: #3fb950; --bad: #f85149; --accent: #4493f8; --code: #1f2630;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--text);
         font: 15px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }}
  main {{ max-width: 960px; margin: 0 auto; padding: 32px 16px 48px; }}
  a {{ color: var(--accent); }}
  h1 {{ font-size: 26px; margin: 0 0 6px; }}
  h2 {{ font-size: 17px; margin: 32px 0 12px; }}
  .lead {{ color: var(--muted); margin: 0 0 20px; }}
  .status {{ display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; padding: 14px 16px;
            background: var(--panel); border: 1px solid var(--line); border-radius: 10px; }}
  .badge {{ font-weight: 600; color: {"var(--ok)" if ok else "var(--bad)"}; }}
  .meta {{ color: var(--muted); font-size: 14px; }}
  .stats {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }}
  .stat {{ background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px; }}
  .stat b {{ display: block; font-size: 22px; }}
  .stat span {{ color: var(--muted); font-size: 13px; }}
  ul.checks {{ list-style: none; padding: 0; margin: 0; background: var(--panel);
              border: 1px solid var(--line); border-radius: 10px; }}
  ul.checks li {{ display: flex; gap: 12px; padding: 12px 16px; border-top: 1px solid var(--line); }}
  ul.checks li:first-child {{ border-top: 0; }}
  .tick {{ color: var(--ok); font-weight: 700; }}
  ul.checks p {{ margin: 2px 0 0; color: var(--muted); overflow-wrap: anywhere; }}
  code, pre {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }}
  details {{ background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
            margin-bottom: 10px; }}
  summary {{ cursor: pointer; padding: 10px 16px; font-family: ui-monospace, monospace; font-size: 13px; }}
  pre {{ margin: 0; padding: 12px 16px; background: var(--code); overflow-x: auto;
        border-top: 1px solid var(--line); border-radius: 0 0 10px 10px; }}
  footer {{ margin-top: 36px; color: var(--muted); font-size: 13px; }}
</style>
</head>
<body>
<main>
  <h1>GitOps platform: live proof</h1>
  <p class="lead">Every push to <code>main</code> and every Monday, CI renders and validates every chart,
  then creates a real Kubernetes cluster (kind), deploys a payment gateway, a webhook relay
  and a URL shortener with their databases, and tests them. This page is generated from that run.</p>

  <div class="status">
    <span class="badge">{esc(status)}</span>
    <span class="meta">verified <time datetime="{esc(finished)}" id="when">{esc(finished or "n/a")}</time></span>
    <span class="meta">Kubernetes {esc(e2e["kubernetes"] or "n/a")}, {esc(e2e["nodes"])}-node kind cluster</span>
    <span class="meta">commit {commit_html}</span>
    <span class="meta">{run_html}</span>
  </div>

  <h2>Static validation</h2>
  <div class="stats">{stat_html}</div>

  <h2>Deployed and tested on the cluster</h2>
  <ul class="checks">{checks_html}</ul>
  <p class="meta">Images: {images_html or "n/a"}. Namespace enforces the <code>restricted</code> Pod Security Standard.</p>

  <h2>Rejected on purpose</h2>
  <ul>{negative_html or "<li>n/a</li>"}</ul>

  <h2>Raw evidence</h2>
  {evidence or '<p class="meta">No cluster output in this run.</p>'}

  <footer>Source: <a href="https://github.com/{repo}">github.com/{repo}</a>. The cluster is deleted
  after each run; this page is the record of what it did.</footer>
</main>
<script>
  // Show the age of the evidence in the viewer's own terms ("3 days ago").
  const el = document.getElementById("when");
  const t = Date.parse(el.dateTime);
  if (!Number.isNaN(t)) {{
    const days = Math.floor((Date.now() - t) / 86400000);
    const ago = days <= 0 ? "today" : days === 1 ? "yesterday" : days + " days ago";
    el.textContent = ago + " (" + new Date(t).toUTCString().replace(" GMT", " UTC") + ")";
  }}
</script>
</body>
</html>
"""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--e2e", type=Path, required=True)
    parser.add_argument("--validate", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)

    report = build(args.e2e, read(args.validate), dict(os.environ))
    if not report["e2e"]["passed"] or not report["validate"]["passed"]:
        print("evidence is incomplete: refusing to publish a proof page", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "index.html").write_text(render(report, args.e2e), encoding="utf-8")
    (args.out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out / 'index.html'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
