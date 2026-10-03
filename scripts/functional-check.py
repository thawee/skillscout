#!/usr/bin/env python3
"""Build and run the Swift functional checks with isolated data and preferences."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent.parent
build = root / "build/functional-check"
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
        "CFBundleIdentifier": "com.thawee.skillscout.functional-check",
        "CFBundleName": "Skillscout Functional Check",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        # cacheDisplay can't draw macOS 26's Liquid Glass sidebar and toolbar, so render the earlier design.
        "UIDesignRequiresCompatibility": True,
    }))
    sources = [str(p) for p in sorted((root / "Skillscout").glob("*.swift"))
               if p.name != "SkillscoutApp.swift"]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "-module-cache-path", str(build / "module-cache"),
                    "-target", "arm64-apple-macos15.0", *sources,
                    str(root / "scripts/functional-check.swift"), "-o", str(exe)],
                   env=env, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)

if "--build-only" not in sys.argv:
    home = build / ("home-" + uuid.uuid4().hex)
    output = build / "results"
    result = output / "result.txt"
    if result.exists():
        result.unlink()
    subprocess.run([str(exe), str(home), str(output)], env=env, check=True, timeout=60)
    message = result.read_text()
    print(message, end="")
    print("Screenshots:", output)
    if not message.startswith("All functional checks passed."):
        sys.exit(1)
