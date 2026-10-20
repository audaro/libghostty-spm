#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

SOURCE_DIR=${1:-}

if [ -z "$SOURCE_DIR" ]; then
    echo "Usage: $0 <ghostty_source_dir>"
    exit 1
fi

# The object files pkg/libintl would contribute to libghostty.a, derived from
# that package's own source list rather than from a list kept here: a hardcoded
# set would go stale on an upstream bump in the one direction that matters,
# silently shrinking what the audit looks for.
#
# These are GNU gettext and gnulib sources, LGPL-2.1-or-later. The whole point
# of Patches/ghostty/0018-gate-libintl-on-i18n.sh is that none of them reaches
# an archive built with i18n=false; this list is what both halves of that claim
# are checked against.
python3 - "$SOURCE_DIR" <<'PY'
import os
import re
import sys

source_dir = sys.argv[1]
build_zig = os.path.join(source_dir, "pkg", "libintl", "build.zig")

if not os.path.isfile(build_zig):
    raise SystemExit(f"[!] not a Ghostty source tree, missing: {build_zig}")

with open(build_zig, "r", encoding="utf-8") as handle:
    text = handle.read()

match = re.search(
    r"^const srcs: \[\]const \[\]const u8 = &\.\{\n(.*?)^\};$",
    text,
    re.S | re.M,
)
if match is None:
    raise SystemExit(f"[!] could not find the srcs list in {build_zig}")

objects = set()
for line in match.group(1).splitlines():
    line = line.strip()
    # A commented-out source is not compiled, so it is not an expected object.
    if not line or line.startswith("//"):
        continue
    source = re.fullmatch(r'"([^"]+\.c)",', line)
    if source is None:
        raise SystemExit(f"[!] unparsed line in the srcs list: {line!r}")
    objects.add(os.path.basename(source.group(1))[:-2] + ".o")

if not objects:
    raise SystemExit(f"[!] the srcs list in {build_zig} is empty")

print("\n".join(sorted(objects)))
PY
