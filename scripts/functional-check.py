#!/usr/bin/env python3
"""Build and run the Swift functional checks with isolated data and preferences."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent.parent
swiftui = "--swiftui" in sys.argv
projects = "--projects" in sys.argv
selectors = "--selectors" in sys.argv
repository_updates = "--repository-updates" in sys.argv
providers_only = "--providers-only" in sys.argv
system_only = "--system-only" in sys.argv
manage_only = "--manage-only" in sys.argv
skillset_scope_only = "--skillset-scope-only" in sys.argv
global_counts_only = "--global-counts-only" in sys.argv
enabled_tools = "--enabled-tools" in sys.argv or providers_only or system_only or manage_only or skillset_scope_only or global_counts_only
suite = "swiftui-check" if swiftui else "enabled-tools-check" if enabled_tools else "repository-update-check" if repository_updates else "selection-check" if selectors else "project-check" if projects else "functional-check"
build = root / "build" / suite
app = build / "Functional Check.app"
exe = app / "Contents/MacOS/FunctionalCheck"
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")

if "--run-only" not in sys.argv:
    exe.parent.mkdir(parents=True, exist_ok=True)
    resources = app / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    (resources / "registry.json").write_bytes((root / "registry.json").read_bytes())
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "FunctionalCheck",
        "CFBundleIdentifier": "com.thawee.quartermaster." + suite,
        "CFBundleName": "Quartermaster Functional Check",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        # cacheDisplay can't draw macOS 26's Liquid Glass sidebar and toolbar, so render the earlier design.
        "UIDesignRequiresCompatibility": True,
    }))
    sources = [str(p) for p in sorted((root / "Skillscout").glob("*.swift"))
               if p.name != "SkillscoutApp.swift"]
    if selectors:
        sources = [str(root / "Skillscout" / name) for name in ("Models.swift", "Components.swift")]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "-module-cache-path", str(build / "module-cache"),
                    "-target", "arm64-apple-macos15.0", *sources,
                    str(root / "scripts" / (suite + ".swift")), "-o", str(exe)],
                   env=env, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)

if "--build-only" not in sys.argv:
    home = build / ("home-" + uuid.uuid4().hex)
    output = build / "results"
    result = output / "result.txt"
    if result.exists():
        result.unlink()
    if swiftui or projects or selectors or repository_updates or enabled_tools:
        output.mkdir(parents=True, exist_ok=True)
        (output / "render-manifest.json").unlink(missing_ok=True)
        (output / "fixture-home.txt").write_text(str(home))
    if swiftui or selectors or repository_updates or enabled_tools:
        native_stdout = output / "native-stdout.log"
        native_stderr = output / "native-stderr.log"
        native_stdout.write_text("")
        native_stderr.write_text("")
        modes = [("main", None), ("cancel", "--cancel-only"), ("states", "--states-only")] if repository_updates else [("providers", "--providers-only")] if providers_only else [("system", "--system-only")] if system_only else [("manage", "--manage-only")] if manage_only else [("skillset-scope", "--skillset-scope-only")] if skillset_scope_only else [("global-counts", "--global-counts-only")] if global_counts_only else [("main", None)]
        for mode, flag in modes:
            mode_home = home if mode == "main" else build / ("home-" + uuid.uuid4().hex)
            mode_stdout = output / ("native-" + mode + "-stdout.log")
            mode_stderr = output / ("native-" + mode + "-stderr.log")
            mode_stdout.write_text("")
            mode_stderr.write_text("")
            result.unlink(missing_ok=True)
            args = [str(mode_home), str(output)] + ([flag] if flag else [])
            subprocess.run(["open", "-W", "-n", "-a", str(app),
                            "--stdout", str(mode_stdout), "--stderr", str(mode_stderr),
                            "--args", *args], env=env, check=True, timeout=120)
            for log, combined in ((mode_stdout, native_stdout), (mode_stderr, native_stderr)):
                if log.exists():
                    text = log.read_text()
                    print(text, end="")
                    with combined.open("a") as stream:
                        stream.write(text)
            message = result.read_text()
            if not message.startswith("All functional checks passed."):
                print(message, end="")
                sys.exit(1)
    else:
        subprocess.run([str(exe), str(home), str(output)], env=env, check=True, timeout=240)
    message = result.read_text()
    print(message, end="")
    print("Screenshots:", output)
    if not message.startswith("All functional checks passed."):
        sys.exit(1)
