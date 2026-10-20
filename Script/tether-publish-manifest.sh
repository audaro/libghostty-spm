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

if [ "$MODE" != "render" ] && [ "$MODE" != "verify" ]; then
    echo "Usage: $0 render <tether_tag> <local_zip>"
    echo "       $0 verify <tether_tag> [local_zip]"
    exit 1
fi

if [ -z "$TETHER_TAG" ]; then
    echo "[!] no tag given"
    exit 1
fi

REPO=${TETHER_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
URL="https://github.com/$REPO/releases/download/$TETHER_TAG/$ASSET"

# Package.swift's checksum comes from the zip this run built and audited, and
# from nothing else. That is the whole design of this script, and it is a
# correction: an earlier version rendered the manifest from the asset
# downloaded back out of the release, which reads as the stronger check -- the
# bytes GitHub serves are the ones named -- and is in fact the weaker one. A
# release asset can be replaced after the fact, and a release can be created by
# a path that never built anything; GitHub's own asset digest is computed from
# whatever is attached now, so it cannot distinguish either case. Rendering
# from the published asset therefore means the manifest can come to name bytes
# that no audit in this workflow ever saw.
#
# Rendering from the local zip makes that structurally impossible, and it
# decides the step order in tether-build.yml: render and commit the manifest
# BEFORE the release is created. Every way the run can then die leaves a state
# that fails closed for a consumer -- a manifest naming an asset that is not
# there yet (SwiftPM: not found), or one whose checksum the published bytes do
# not match (SwiftPM: checksum mismatch). Neither resolves. The state being
# avoided is the one that resolves perfectly well and links something nobody
# audited.
if [ "$MODE" = "render" ]; then
    if [ -z "$LOCAL_ZIP" ]; then
        echo "[!] render needs the locally built zip: it is the only permitted source of the"
        echo "[!] checksum. There is deliberately no way to render from a published asset."
        exit 1
    fi
    if [ ! -f "$LOCAL_ZIP" ]; then
        echo "[!] local zip not found: $LOCAL_ZIP"
        exit 1
    fi

    ./Script/build-manifest.sh "$LOCAL_ZIP" "$URL"
    LOCAL_SHA=$(shasum -a 256 "$LOCAL_ZIP" | awk '{print $1}')

    # build-manifest.sh substitutes with ${var/pat/repl}, which silently does
    # nothing when the placeholder is absent, so the rendered file is checked
    # rather than assumed. A manifest that kept __DOWNLOAD_URL__ would fail at
    # resolution time in a consumer's checkout, a long way from here.
    if ! grep -q "$URL" Package.swift || ! grep -q "$LOCAL_SHA" Package.swift; then
        echo "[!] Package.swift does not carry the built asset after rendering:"
        echo "[!]   expected url: $URL"
        echo "[!]   expected checksum: $LOCAL_SHA"
        grep -nE 'url:|checksum:|__DOWNLOAD_URL__|__CHECKSUM__' Package.swift | sed 's/^/    /'
        exit 1
    fi

    echo "[*] Package.swift points at $TETHER_TAG ($LOCAL_SHA)"
    exit 0
fi

# verify: the published asset must be exactly what the committed manifest
# names. Run after the release is created, and again by prepare on any
# re-dispatch, where it is the whole of the "is this tag finished" question.
MANIFEST_SHA=$(sed -n 's/^ *checksum: *"\([0-9a-f]\{64\}\)".*/\1/p' Package.swift | head -1)
if [ -z "$MANIFEST_SHA" ]; then
    echo "[!] no checksum found in Package.swift"
    exit 1
fi

if ! grep -q "$URL" Package.swift; then
    echo "[!] Package.swift does not name $TETHER_TAG's asset. It names:"
    grep -nE 'url:' Package.swift | sed 's/^/    /'
    echo "[!] A published tag whose manifest was never committed cannot be repaired from here:"
    echo "[!] the checksum may only come from a zip this workflow built and audited, and that zip"
    echo "[!] is gone with the run that built it. Bump Tether.build and re-dispatch to rebuild, or"
    echo "[!] delete the release and its tag first. Deleting a published release is outward-facing,"
    echo "[!] so it stays a decision for a person."
    exit 1
fi

if ! gh release view "$TETHER_TAG" --repo "$REPO" --json assets \
    --jq '.assets[].name' 2>/dev/null | grep -qx "$ASSET"; then
    echo "[!] release $TETHER_TAG does not carry $ASSET, so the manifest on this branch names an"
    echo "[!] asset that does not exist. Consumers fail closed on that, which is the safe side of"
    echo "[!] the failure, but it is still broken: bump Tether.build and re-dispatch."
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
gh release download "$TETHER_TAG" --repo "$REPO" --pattern "$ASSET" --dir "$WORK_DIR"
PUBLISHED_SHA=$(shasum -a 256 "$WORK_DIR/$ASSET" | awk '{print $1}')

if [ "$PUBLISHED_SHA" != "$MANIFEST_SHA" ]; then
    echo "[!] the published asset is not what the manifest names:"
    echo "[!]   manifest:  $MANIFEST_SHA"
    echo "[!]   published: $PUBLISHED_SHA"
    echo "[!] Either the upload was corrupted or the asset was replaced after the run that built"
    echo "[!] and audited it. Re-pointing the manifest at these bytes is exactly what must not"
    echo "[!] happen -- nothing here has audited them. Bump Tether.build and re-dispatch."
    exit 1
fi

if [ -n "$LOCAL_ZIP" ]; then
    if [ ! -f "$LOCAL_ZIP" ]; then
        echo "[!] local zip not found: $LOCAL_ZIP"
        exit 1
    fi
    LOCAL_SHA=$(shasum -a 256 "$LOCAL_ZIP" | awk '{print $1}')
    if [ "$LOCAL_SHA" != "$PUBLISHED_SHA" ]; then
        echo "[!] the published asset does not match the zip this run built: $PUBLISHED_SHA != $LOCAL_SHA"
        exit 1
    fi
    echo "[*] published asset matches the zip this run built and audited"
fi

echo "[*] $TETHER_TAG is published and the committed manifest names it ($PUBLISHED_SHA)"
