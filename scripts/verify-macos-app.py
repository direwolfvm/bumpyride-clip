#!/usr/bin/env python3
"""Fail packaging if the native app includes footage, debug access, or one architecture."""
import plistlib
import subprocess
import sys
from pathlib import Path


def verify(app, mode):
    def require(condition, message):
        if not condition:
            raise SystemExit(message)

    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info["CFBundleIdentifier"] == "com.herbertindustries.BumpyRide-Clip", "Unexpected app identity")
    project_type = "com.herbertindustries.bumpyride.clipproject"
    declarations = info.get("UTExportedTypeDeclarations", [])
    require(any(item.get("UTTypeIdentifier") == project_type and
                "bumpyclip" in item.get("UTTypeTagSpecification", {}).get("public.filename-extension", []) and
                "public.json" in item.get("UTTypeConformsTo", []) for item in declarations),
            "Missing .bumpyclip JSON document declaration")
    document_types = info.get("CFBundleDocumentTypes", [])
    require(any(project_type in item.get("LSItemContentTypes", []) and item.get("LSHandlerRank") == "Owner" for item in document_types),
            "Missing project-file ownership")
    require(any("public.json" in item.get("LSItemContentTypes", []) and item.get("LSHandlerRank") == "Alternate" for item in document_types),
            "Legacy JSON must remain an alternate document type")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    require(set(architectures) == {"arm64", "x86_64"}, f"Expected universal app; found {architectures}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    raw = subprocess.check_output(["codesign", "--display", "--entitlements", "-", "--xml", str(app)], stderr=subprocess.DEVNULL)
    entitlements = plistlib.loads(raw)
    required = {"com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope"}
    require(set(entitlements) == required and all(entitlements.values()), f"Unexpected entitlements: {entitlements}")
    signature = subprocess.run(["codesign", "--display", "--verbose=4", str(app)], check=True, capture_output=True, text=True).stderr
    require("runtime" in signature, "Hardened runtime is required")
    if mode == "release":
        require("Authority=Developer ID Application:" in signature, "Developer ID Application signature is required")
        require("Timestamp=" in signature, "A secure signing timestamp is required")
    else:
        require("Signature=adhoc" in signature, "Local test builds must use ad-hoc signing")
    size = 0
    for path in app.rglob("*"):
        require(path.name not in {"sample_video", "node_modules", ".git"}, f"Unwanted bundle content: {path}")
        require(path.suffix.lower() not in {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".swift", ".js", ".p12", ".p8"}, f"Unwanted bundled file: {path}")
        if path.is_file():
            size += path.stat().st_size
    require(size < 50 * 1024 * 1024, f"Unexpected bundle size: {size} bytes; check bundled resources")
    print(f"BumpyRide Clip {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
    print(f"macOS {info['LSMinimumSystemVersion']}+; Apple silicon and Intel")
    print(f"Verified {mode} signature, hardened runtime, sandbox, and file-access entitlements")
    print(f"Bundle: {size / 1024 / 1024:.2f} MiB; no footage, source code, or development credentials")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[2] not in {"local", "release"}:
        raise SystemExit("Usage: verify-macos-app.py /path/to/App.app local|release")
    verify(Path(sys.argv[1]), sys.argv[2])
