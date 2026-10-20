#!/bin/bash

# Gate the Darwin libintl link on the `i18n` build option.
#
# Upstream links GNU gettext's libintl unconditionally for every Darwin
# target, and `GhosttyLib.initStatic` merges everything in `static_libs`
# into one archive, so the shipped libghostty.a carries thirty LGPL
# gettext/gnulib objects. `-Di18n=false` alone does not change that: the
# option gates `GhosttyI18n` (which emits only msgfmt install steps) and the
# gettext *call sites*, and `grep -n i18n src/build/SharedDeps.zig` finds
# nothing. This patch is the other half of the flag.
#
# This patch is Tether's, not libghostty-spm's: see README.tether.md.

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

MARKER="TETHER_I18N_LINK_GATE"

if grep -q "$MARKER" "$SOURCE_DIR/src/build/SharedDeps.zig" 2>/dev/null; then
    echo "[+] libintl i18n gate already applied"
    exit 0
fi

python3 - "$SOURCE_DIR" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])
marker = sys.argv[2]

# ──────────────────────────────────────────────────────────────────────
# 0. Preconditions. The gate is only meaningful if the option it reads
#    still exists and still reaches the comptime guards in os/i18n.zig;
#    without either, a build would gate on a field that is not there and
#    fail with a Zig error far from the cause.
# ──────────────────────────────────────────────────────────────────────
config_path = source_dir / "src/build/Config.zig"
config_text = config_path.read_text()
if "i18n: bool" not in config_text:
    print("[-] src/build/Config.zig has no `i18n: bool` field; upstream renamed the option.")
    sys.exit(1)
if 'addOption(bool, "i18n"' not in config_text:
    print("[-] src/build/Config.zig no longer passes `i18n` to build_options.")
    sys.exit(1)

bc_path = source_dir / "src/build_config.zig"
if "pub const i18n" not in bc_path.read_text():
    print("[-] src/build_config.zig no longer re-exports i18n; the comptime guards are gone.")
    sys.exit(1)

i18n_path = source_dir / "src/os/i18n.zig"
i18n_text = i18n_path.read_text()
guard = "if (comptime !build_config.i18n)"
guards = i18n_text.count(guard)
if guards < 4:
    print(f"[-] src/os/i18n.zig has {guards} `{guard}` guards, expected at least 4.")
    print("    Removing the link is only safe while every gettext call site is comptime-dead:")
    print("    init, initGlobalDomain, _() and canonicalizeLocale. Re-read the file.")
    sys.exit(1)

# ──────────────────────────────────────────────────────────────────────
# 1. SharedDeps.zig — gate the libintl link on self.config.i18n.
#    Same shape as 0006/0007: `if (cond) if (b.lazyDependency(...)) |x| {`
#    with the block's closing brace becoming `};`.
# ──────────────────────────────────────────────────────────────────────
shared_path = source_dir / "src/build/SharedDeps.zig"
text = shared_path.read_text()

gate_comment = f"""        //
        // {marker}: that compliance argument requires the source to
        // be open, which a closed-source App Store binary cannot offer,
        // so this link is gated on the same `i18n` option that already
        // gates every call site. With -Di18n=false the thirty
        // gettext/gnulib objects never enter static_libs and so never
        // become members of the combined libghostty.a. What makes that
        // safe is upstream's own comptime guards: init, initGlobalDomain,
        // _() and canonicalizeLocale each return early under
        // `if (comptime !build_config.i18n)`, so the four extern fns
        // (bindtextdomain, textdomain, dgettext and
        // _libintl_locale_name_canonicalize) are unreferenced and nothing
        // needs a replacement libintl. With -Di18n=true this is
        // upstream's build, unchanged.
"""

edits = [(
    """        // build script to replace the bundled libintl with their own.
        if (b.lazyDependency("libintl", .{""",
    """        // build script to replace the bundled libintl with their own.
"""
    + gate_comment
    + """        if (self.config.i18n) if (b.lazyDependency("libintl", .{""",
), (
    """            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }""",
    """            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        };""",
)]

for old, new in edits:
    if text.count(old) != 1:
        print(f"[-] expected exactly 1 match in src/build/SharedDeps.zig, found {text.count(old)}:")
        print(f"    {old[:90]}...")
        sys.exit(1)
    text = text.replace(old, new)

shared_path.write_text(text)

# Self-check: the gate is there, and it is the only one we added.
check = shared_path.read_text()
if check.count('if (self.config.i18n) if (b.lazyDependency("libintl"') != 1:
    print("[-] post-edit check failed: the libintl gate is not where it should be.")
    sys.exit(1)
if check.count("libintl_dep") != 3:
    print(f"[-] post-edit check failed: {check.count('libintl_dep')} libintl_dep references, expected 3.")
    sys.exit(1)

print(f"[+] patched SharedDeps.zig: libintl link gated on i18n ({marker})")
PYEOF

echo "[+] libintl i18n gate applied"
