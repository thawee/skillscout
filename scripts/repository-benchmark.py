#!/usr/bin/env python3
"""Compare local repository workflows with a recorded baseline and made-up skills."""
import argparse
import io
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--baseline", default="HEAD")
parser.add_argument("--baseline-patch", type=Path)
parser.add_argument("--skills", type=int, default=500)
parser.add_argument("--samples", type=int, default=5)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
output = root / "build/discover-benchmark"
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")

with tempfile.TemporaryDirectory(prefix="skillscout-benchmark-", dir="/private/tmp") as scratch:
    scratch = Path(scratch)
    baseline = scratch / "baseline"
    baseline.mkdir()
    archive = subprocess.check_output(["git", "archive", args.baseline], cwd=root)
    with tarfile.open(fileobj=io.BytesIO(archive)) as files:
        files.extractall(baseline, filter="data")
    if args.baseline_patch:
        subprocess.run(["git", "apply", str(args.baseline_patch.resolve())], cwd=baseline, check=True)
    binaries = {}
    for label, tree in (("baseline", baseline), ("current", root)):
        section = (tree / "project.yml").read_text().split("  SkillscoutCLI:", 1)[1].split("    settings:", 1)[0]
        sources = [str(tree / line.strip().removeprefix("- ")) for line in section.splitlines()
                   if line.strip().startswith("- Skillscout/")]
        binary = scratch / label
        if label == "baseline":
            binary = scratch / "baseline-benchmark"
        subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
                        "-module-cache-path", str(scratch / "module-cache"), *sources,
                        str(root / "scripts/repository-benchmark.swift"), "-o", str(binary)], env=env, check=True)
        binaries[label] = binary
    fixture = scratch / "fixture"
    for index in range(args.skills):
        folder = fixture / f"skills/skill-{index:04d}"
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text(f"---\nname: demo-{index:04d}\ndescription: Made-up benchmark skill\n---\n" + "Read the supplied demo files and report the result.\n" * 20)
        (folder / "helper.txt").write_text("Made-up supporting file.\n" * 20)
    rows = []
    for iteration in range(args.samples + 1):
        order = ("baseline", "current") if iteration % 2 == 0 else ("current", "baseline")
        for label in order:
            home = scratch / f"home-{iteration}-{label}"
            source = home / "fixtures/demo"
            shutil.copytree(fixture, source)
            run = subprocess.run([str(binaries[label]), str(source)], env=dict(env, HOME=str(home)),
                                 capture_output=True, text=True, timeout=60)
            if run.returncode:
                raise RuntimeError(f"{label} exited {run.returncode}: {run.stderr[-4000:]}")
            row = dict(json.loads(run.stdout.strip()), label=label, iteration=iteration, warmup=iteration == 0)
            if row["skills"] != args.skills:
                raise RuntimeError(f"Incomplete scan: {row}")
            rows.append(row)
    report = {"baseline": args.baseline, "patch": str(args.baseline_patch), "skills": args.skills,
              "files": args.skills * 2, "bytes": sum(p.stat().st_size for p in fixture.rglob("*") if p.is_file()),
              "samples": args.samples, "rows": rows, "medians": {}}
    for label in binaries:
        report["medians"][label] = {key: statistics.median(row[key] for row in rows if row["label"] == label and not row["warmup"])
                                     for key in ("importMS", "scanMS", "warmScanMS", "updateMS")}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"skills": args.skills, "medians": report["medians"]}, indent=2))
