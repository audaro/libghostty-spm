#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

MODE=${1:-}
TETHER_TAG=${2:-}
LOCAL_ZIP=${3:-}
ASSET=GhosttyKit.xcframework.zip

if [ "$MODE" != "check" ] && [ "$MODE" != "render" ]; then
    echo "Usage: $0 <check|render> <tether_tag> [local_zip]"
    exit 1
fi

if [ -z "$TETHER_TAG" ]; then
    echo "Usage: $0 <check|render> <tether_tag> [local_zip]"
    exit 1
fi

REPO=${TETHER_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
URL="https://github.com/$REPO/releases/download/$TETHER_TAG/$ASSET"

# Both modes read the PUBLISHED bytes, and that is the point of the script.
#
# A release is created before its manifest can be rendered -- the manifest has
# to name a URL that resolves -- so there is a window where the release exists
# and Package.swift still points somewhere else. For this fork "somewhere else"
# means upstream's asset, the one with the gettext and gnulib members in it, so
# a run that dies in that window and a retry that reports "nothing to build"
# would leave a consumer resolving exactly the artifact this fork exists to
# replace. check is what makes that state visible; render is what repairs it,
# and neither needs the build to be re-run.
#
# Rendering from the downloaded asset rather than from the locally built zip is
# also what makes the manifest's checksum mean something: it is by construction
# the checksum of the bytes GitHub serves. When a local zip is given -- the
# normal path, straight after a build -- the two are compared, which is the
# check that the upload was not truncated.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

if ! gh release view "$TETHER_TAG" --repo "$REPO" --json assets \
    --jq '.assets[].name' 2>/dev/null | grep -qx "$ASSET"; then
    echo "[!] release $TETHER_TAG does not carry $ASSET."
    echo "[!] A release without its asset cannot be repaired from here: it needs a rebuild."
    echo "[!] Delete the release and its tag, then re-dispatch. Deleting a published release is"
    echo "[!] outward-facing, so it is a decision for a person and not for this script."
    exit 1
fi

gh release download "$TETHER_TAG" --repo "$REPO" --pattern "$ASSET" --dir "$WORK_DIR"
PUBLISHED_SHA=$(shasum -a 256 "$WORK_DIR/$ASSET" | awk '{print $1}')

if [ -n "$LOCAL_ZIP" ]; then
    if [ ! -f "$LOCAL_ZIP" ]; then
        echo "[!] local zip not found: $LOCAL_ZIP"
        exit 1
    fi
    LOCAL_SHA=$(shasum -a 256 "$LOCAL_ZIP" | awk '{print $1}')
    if [ "$LOCAL_SHA" != "$PUBLISHED_SHA" ]; then
        echo "[!] the published asset does not match what was built: $PUBLISHED_SHA != $LOCAL_SHA"
        exit 1
    fi
    echo "[*] published asset matches the local build: $PUBLISHED_SHA"
fi

manifest_is_current() {
    grep -q "$URL" Package.swift && grep -q "$PUBLISHED_SHA" Package.swift
}

if [ "$MODE" = "check" ]; then
    if manifest_is_current; then
        echo "[*] $TETHER_TAG is published and Package.swift carries its asset"
        echo "state=complete"
    else
        echo "[*] $TETHER_TAG is published but Package.swift does not carry its asset"
        echo "[*] (a previous run died between creating the release and committing the manifest)"
        echo "state=manifest-stale"
    fi
    exit 0
fi

./Script/build-manifest.sh "$WORK_DIR/$ASSET" "$URL"

# build-manifest.sh substitutes with ${var/pat/repl}, which silently does
# nothing when the placeholder is absent, so the rendered file is checked
# rather than assumed. A manifest that kept __DOWNLOAD_URL__ would fail at
# resolution time in a consumer's checkout, which is a long way from here.
if ! manifest_is_current; then
    echo "[!] Package.swift does not carry the asset after rendering:"
    echo "[!]   expected url: $URL"
    echo "[!]   expected checksum: $PUBLISHED_SHA"
    grep -nE 'url:|checksum:|__DOWNLOAD_URL__|__CHECKSUM__' Package.swift | sed 's/^/    /'
    exit 1
fi

echo "[*] Package.swift points at $TETHER_TAG ($PUBLISHED_SHA)"
