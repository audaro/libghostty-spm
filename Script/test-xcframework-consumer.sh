#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

XCFRAMEWORK_PATH=${1:-BinaryTarget/GhosttyKit.xcframework}

if [ ! -d "$XCFRAMEWORK_PATH" ]; then
    echo "[!] xcframework not found: $XCFRAMEWORK_PATH"
    exit 1
fi

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    else
        cat
    fi
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Consumer/BinaryTarget" "$WORK_DIR/Consumer/Sources/Consumer"
ditto "$XCFRAMEWORK_PATH" "$WORK_DIR/Consumer/BinaryTarget/GhosttyKit.xcframework"

cat >"$WORK_DIR/Consumer/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Consumer", targets: ["Consumer"]),
    ],
    targets: [
        .binaryTarget(
            name: "libghostty",
            path: "BinaryTarget/GhosttyKit.xcframework"
        ),
        .target(
            name: "Consumer",
            dependencies: ["libghostty"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
    ]
)
EOF

cat >"$WORK_DIR/Consumer/Sources/Consumer/Consumer.swift" <<'EOF'
import libghostty

public func passThroughPlatform(_ platform: ghostty_platform_e) -> ghostty_platform_e {
    platform
}
EOF

test_build() {
    local destination="$1"
    local command=(
        xcodebuild
        -scheme Consumer
        -destination "$destination"
        -derivedDataPath "$WORK_DIR/DerivedData"
        -packageCachePath "$WORK_DIR/PackageCache"
        build
    )

    echo "[*] consumer build destination=$destination"
    "${command[@]}" 2>&1 | format_output
    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        echo "[!] consumer build failed destination=$destination"
        exit "$exit_code"
    fi
}

# The destinations are the ones this artifact actually has slices for: a
# consumer build for a platform the xcframework does not carry fails at the
# link with a missing-library error that reads nothing like its cause, and an
# iOS-only artifact (Script/build-platform.sh's `tether` group) carries two.
# A slice with no destination mapped is a hard error, not a silent skip.
DESTINATIONS=$(python3 - "$WORK_DIR/Consumer/BinaryTarget/GhosttyKit.xcframework" <<'PY'
import os
import plistlib
import sys

xcframework = sys.argv[1]
with open(os.path.join(xcframework, "Info.plist"), "rb") as handle:
    info = plistlib.load(handle)

destinations = {
    ("macos", None): "generic/platform=macOS",
    ("ios", "maccatalyst"): "generic/platform=macOS,variant=Mac Catalyst",
    ("ios", None): "generic/platform=iOS",
    ("ios", "simulator"): "generic/platform=iOS Simulator",
    ("xros", None): "generic/platform=visionOS",
    ("xros", "simulator"): "generic/platform=visionOS Simulator",
}

selected = []
for library in info["AvailableLibraries"]:
    key = (library.get("SupportedPlatform"), library.get("SupportedPlatformVariant"))
    destination = destinations.get(key)
    if destination is None:
        raise SystemExit(f"[!] no consumer destination known for slice: {key}")
    if destination not in selected:
        selected.append(destination)

if not selected:
    raise SystemExit("[!] xcframework carries no slices")

print("\n".join(selected))
PY
)

(
    cd "$WORK_DIR/Consumer"
    while IFS= read -r destination; do
        test_build "$destination"
    done <<< "$DESTINATIONS"
)

echo "[*] xcframework consumer tests passed"
