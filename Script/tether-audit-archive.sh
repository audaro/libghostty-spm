#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .root ]; then
    echo "[!] repository root not found. Run this script from a libghostty-spm checkout."
    exit 1
fi

ARCHIVE=${1:-}
EXPECTED_OBJECTS=${2:-}
EXPECTATION=${3:-}
MEMBERS_OUT=${4:-}

if [ -z "$ARCHIVE" ] || [ -z "$EXPECTED_OBJECTS" ] || [ -z "$EXPECTATION" ] || [ -z "$MEMBERS_OUT" ]; then
    echo "Usage: $0 <archive> <expected_libintl_objects> <absent|present> <members_out>"
    exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
    echo "[!] archive not found: $ARCHIVE"
    exit 1
fi

if [ ! -f "$EXPECTED_OBJECTS" ]; then
    echo "[!] expected-objects list not found: $EXPECTED_OBJECTS"
    exit 1
fi

if [ "$EXPECTATION" != "absent" ] && [ "$EXPECTATION" != "present" ]; then
    echo "[!] expectation must be absent or present: $EXPECTATION"
    exit 1
fi

mkdir -p "$(dirname "$MEMBERS_OUT")"
ar t "$ARCHIVE" | sort > "$MEMBERS_OUT"

# Two expectations over one archive, and they are each other's control.
#
# `absent` is the claim Tether ships on: an archive built with i18n=false
# carries none of pkg/libintl's objects and defines no gettext symbol.
# `present` is run against the i18n=true control build and asserts the *whole*
# expected set is there. Matching members by basename is an assumption about
# how Zig names them, and that assumption is what makes `absent` worth
# anything — so it is not left as an assumption: if the naming were different,
# `absent` would pass vacuously while `present` failed on the same run. Neither
# half is evidence without the other, which is why CI runs both.
NM_OUTPUT=$(mktemp)
trap 'rm -f "$NM_OUTPUT"' EXIT
nm -a "$ARCHIVE" > "$NM_OUTPUT"

python3 - "$ARCHIVE" "$EXPECTED_OBJECTS" "$EXPECTATION" "$MEMBERS_OUT" "$NM_OUTPUT" <<'PY'
import re
import sys

archive, expected_path, expectation, members_path, nm_path = sys.argv[1:6]

with open(expected_path, "r", encoding="utf-8") as handle:
    expected = {line.strip() for line in handle if line.strip()}
with open(members_path, "r", encoding="utf-8") as handle:
    members = {line.strip() for line in handle if line.strip()}

if not expected:
    raise SystemExit("[!] the expected-objects list is empty")
if not members:
    raise SystemExit(f"[!] {archive} has no members")

found = sorted(expected & members)

# Every symbol gettext publishes under either spelling: pkg/libintl builds
# intl-compat.c, which defines the unprefixed aliases on top of the
# _libintl_-prefixed definitions, so looking for only one spelling would miss
# half the library. `nm -a` lists defined and undefined alike and both matter:
# a defined symbol is LGPL code in the archive, and an *undefined* one is this
# archive asking to be linked against it.
symbol_pattern = re.compile(
    r"^_(libintl_|bindtextdomain|bind_textdomain_codeset|textdomain"
    r"|d?c?n?gettext|getlocalename_l|setlocale_null)"
)
gettext_symbols = set()
with open(nm_path, "r", encoding="utf-8") as handle:
    for line in handle:
        fields = line.split()
        if not fields:
            continue
        symbol = fields[-1]
        if symbol_pattern.match(symbol):
            gettext_symbols.add(symbol)

print(f"[*] {archive}: {len(members)} members, expectation={expectation}")

if expectation == "absent":
    if found:
        raise SystemExit(
            f"[!] {archive} carries {len(found)} LGPL libintl object(s) that i18n=false "
            f"must have removed: {found}"
        )
    if gettext_symbols:
        raise SystemExit(
            f"[!] {archive} references or defines {len(gettext_symbols)} gettext symbol(s): "
            f"{sorted(gettext_symbols)}"
        )
    print(f"[*] no libintl members and no gettext symbols ({len(expected)} objects looked for)")
else:
    missing = sorted(expected - members)
    if missing:
        raise SystemExit(
            f"[!] the i18n=true control is missing {len(missing)} of the {len(expected)} "
            f"libintl objects, so the member naming this audit matches on is wrong: {missing}"
        )
    if not gettext_symbols:
        raise SystemExit(
            f"[!] the i18n=true control defines no gettext symbol, so the symbol scan "
            f"in the absent case proves nothing"
        )
    print(
        f"[*] control carries all {len(expected)} libintl objects "
        f"and {len(gettext_symbols)} gettext symbols"
    )
PY
