#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

MEMBERS_FALSE=${1:-}
MEMBERS_TRUE=${2:-}
EXPECTED_OBJECTS=${3:-}
DIFF_OUT=${4:-}

if [ -z "$MEMBERS_FALSE" ] || [ -z "$MEMBERS_TRUE" ] || [ -z "$EXPECTED_OBJECTS" ] || [ -z "$DIFF_OUT" ]; then
    echo "Usage: $0 <members_i18n_false> <members_i18n_true> <expected_libintl_objects> <diff_out>"
    exit 1
fi

for required in "$MEMBERS_FALSE" "$MEMBERS_TRUE" "$EXPECTED_OBJECTS"; do
    if [ ! -f "$required" ]; then
        echo "[!] input not found: $required"
        exit 1
    fi
done

mkdir -p "$(dirname "$DIFF_OUT")"

# The differential: one archive of the same target built each way, and the
# member sets subtracted. The claim being tested is narrow and falsifiable —
# turning i18n off removes exactly pkg/libintl's thirty objects and changes
# nothing else about what the archive contains.
#
# An empty diff fails rather than passing, because the two ways an empty diff
# happens are both wrong: the flag plus Patches/ghostty/0018 did not reach the
# link at all, or the second build reused the first's cache (which is why
# TETHER_I18N is in build-ghostty.sh's cache stamp). A premise that cannot be
# distinguished from a stale cache is not evidence.
python3 - "$MEMBERS_FALSE" "$MEMBERS_TRUE" "$EXPECTED_OBJECTS" "$DIFF_OUT" <<'PY'
import sys

false_path, true_path, expected_path, diff_path = sys.argv[1:5]


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        values = {line.strip() for line in handle if line.strip()}
    if not values:
        raise SystemExit(f"[!] empty member list: {path}")
    return values


without = read(false_path)
with_i18n = read(true_path)
expected = read(expected_path)

added = with_i18n - without
removed = without - with_i18n

lines = [
    "# libghostty.a member differential, i18n=true minus i18n=false",
    "#",
    "# Produced by Script/tether-i18n-diff.sh in the Build Tether XCFramework",
    "# workflow. One aarch64-ios archive built each way; the members below are",
    "# the ones the i18n=true build carries and the shipped i18n=false build",
    "# does not. They are GNU gettext and gnulib objects, LGPL-2.1-or-later,",
    "# derived from the pinned Ghostty's own pkg/libintl/build.zig source list.",
    "#",
    f"# i18n=false members: {len(without)}",
    f"# i18n=true  members: {len(with_i18n)}",
    f"# only in i18n=true:  {len(added)}",
    f"# only in i18n=false: {len(removed)}",
    "",
]
lines += sorted(added)
if removed:
    lines += ["", "# only in the i18n=false archive (expected: none)"]
    lines += sorted(removed)
with open(diff_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")

if not added:
    raise SystemExit(
        "[!] the two builds have identical member sets. Either -Di18n and "
        "Patches/ghostty/0018-gate-libintl-on-i18n.sh did not reach the link, or the "
        "second build reused the first's cache. This is not a refuted premise, it is "
        "an inconclusive run: stop and report."
    )

if removed:
    raise SystemExit(
        f"[!] turning i18n off ADDED {len(removed)} member(s), which the premise of this "
        f"fork does not predict: {sorted(removed)}"
    )

if added != expected:
    unexpected = sorted(added - expected)
    missing = sorted(expected - added)
    raise SystemExit(
        "[!] the differential is not exactly pkg/libintl's object set, so something "
        "other than i18n moved: "
        f"unexpected={unexpected} not_removed={missing}"
    )

print(f"[*] differential is exactly pkg/libintl's {len(expected)} objects: {diff_path}")
PY
