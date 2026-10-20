#!/bin/bash

# Print the release tag that stores Tether's XCFramework for the pinned
# Ghostty commit: `tether-<first 12 hex of Ghostty.ref>-<Tether.build>`.
#
# Deliberately NOT upstream's `upstream.<sha12>` namespace: this artifact is
# built with -Di18n=false and the 0018 libintl gate, so it is not the same
# binary as an `upstream.*` asset of the same commit, and a reader comparing
# two checksums must be able to see which is which from the tag alone. The
# build number is always present, unlike storage-tag.sh's, so `-1` is a real
# tag and nothing has to remember that a bare tag means build 1.
#
# tether-build.yml reads it from here so the workflow and a hand-run build can
# never disagree.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout." >&2
    exit 1
fi

GHOSTTY_REF=$(tr -d '[:space:]' < Ghostty.ref)
if ! echo "$GHOSTTY_REF" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "[!] Ghostty.ref must contain one full lowercase commit sha: $GHOSTTY_REF" >&2
    exit 1
fi

TETHER_BUILD=1
if [ -f Tether.build ]; then
    TETHER_BUILD=$(tr -d '[:space:]' < Tether.build)
    if ! echo "$TETHER_BUILD" | grep -Eq '^[1-9][0-9]*$'; then
        echo "[!] Tether.build must be a positive integer: $TETHER_BUILD" >&2
        exit 1
    fi
fi

echo "tether-${GHOSTTY_REF:0:12}-$TETHER_BUILD"
