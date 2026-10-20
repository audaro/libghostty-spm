# Why this fork exists

This is a fork of [`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm)
that exists for exactly one reason, and it is a licence reason rather than a
technical one.

Tether is a closed-source iOS app. The upstream package's prebuilt
`libghostty.a` statically links `pkg/libintl` — GNU gettext plus a handful of
gnulib sources, carrying the lesser copyleft licence version 2.1 or later.
Upstream is aware of this and says so in a comment above the link in
`src/build/SharedDeps.zig`: their compliance argument is that an end user can
edit the build script and relink against their own libintl. That argument
works for an open-source build. It does not transfer to a binary shipped
through the App Store, where the user has neither the build script nor the
ability to relink. Measured on the upstream `ios-arm64` slice: 19,478,488
bytes, 167 archive members, thirty of which are those gettext and gnulib
objects.

Ghostty already has a build option that turns internationalisation off —
`-Di18n=false` — and it is **necessary but not sufficient**. It gates every
*call site* (`src/os/i18n.zig`'s `init`, `initGlobalDomain`, `_()` and
`canonicalizeLocale` each open with `if (comptime !build_config.i18n)`) and
the `.mo` install steps, but the link itself is unconditional for every Darwin
target, and `GhosttyLib.initStatic` merges every entry of `static_libs` into
one archive. With the flag alone the thirty members are still there and still
define their symbols.

So this fork does two things: it passes the flag, and it gates the link.

## What this branch is based on

The `tether` branch starts at `7e45d27`, upstream's `1.6.20260909` release
commit, whose `Ghostty.ref` is the pin this fork builds
(`82938b633ba646db38591d969c3c526332bd7e65`). It is a released commit rather
than upstream main on purpose: its `Package.swift` was verified against a
published asset, so the only unverified thing on this branch is what this fork
adds. Upstream is tracked as the `upstream` remote and merged deliberately,
never automatically.

## The diff from upstream

Six files, and nothing else. Everything here is additive except two scripts
whose hardcoded expectations assumed the upstream target set.

- **`Patches/ghostty/0018-gate-libintl-on-i18n.sh`** (new) — wraps the libintl
  `lazyDependency` block in `src/build/SharedDeps.zig` in
  `if (self.config.i18n)`, so the objects never enter `static_libs`. What
  makes that safe is upstream's own comptime guards: the four `extern fn`
  declarations are unreferenced when `i18n` is false, and
  `canonicalizeLocale`'s fallback is a pure-Zig copy, so nothing needs a
  replacement libintl and no symbol goes undefined. The script asserts all
  four of those preconditions before editing anything and refuses the tree if
  any is missing — the day upstream reworks i18n, this must stop loudly rather
  than produce an archive that does not link. It is re-runnable, like every
  patch in that directory.
- **`Script/build-ghostty.sh`** — a `TETHER_I18N` environment variable
  (`true`/`false`, defaulting to `false`, refusing anything else) that feeds a
  fixed `-Di18n=$TETHER_I18N` in the Zig flag array, and the same variable
  added to the build cache stamp. The flag is fixed rather than passed through
  `$ZIG_BUILD_EXTRA_ARGS` because a flag that can be forgotten is this fork's
  entire subject; it is a variable at all only so the `i18n=true` control
  build is expressible. It is in the cache stamp because without it the
  control build reuses the shipped build's cache and the differential below
  diffs to nothing — which would read as a refuted premise rather than a stale
  cache.
- **`Script/build-platform.sh`** — a `tether` platform group: `aarch64-ios`
  and `aarch64-ios-simulator`, with no `@apple_a17` on the simulator slice and
  no x86_64 slice. Tether's app is iOS-only and every machine in its build and
  test loop is Apple Silicon.
- **`Script/tether-tag.sh`** and **`Tether.build`** (new) — the release tag,
  `tether-<ghostty-sha12>-<build>`, mirroring `Script/storage-tag.sh`. The
  build number is always present, where upstream's omits `-1`.
- **`Script/tether-libintl-objects.sh`**,
  **`Script/tether-audit-archive.sh`**, **`Script/tether-i18n-diff.sh`** (new)
  — the verification, described below.
- **`Script/verify-xcframework.sh`** and
  **`Script/test-xcframework-consumer.sh`** — both had the upstream slice set
  written into them: the first requires an iOS simulator slice to be
  `arm64 + x86_64`, the second builds a consumer app for macOS and Mac
  Catalyst destinations unconditionally. Each now reads the set it should
  expect — the first from an `XCFRAMEWORK_PROFILE` environment variable
  (`tether` is stricter than `upstream`, not looser: a slice the profile does
  not build is refused), the second from the artifact's own `Info.plist`. A
  slice with no destination mapped is an error rather than a silent skip.
- **`.github/workflows/tether-build.yml`** (new) — the build, below.

Upstream's own workflows are left in the tree untouched and are **disabled**
in this fork's Actions settings. In particular `weekly.yml` would otherwise
repoint `Ghostty.ref` at upstream main every Monday, push it, and cut
releases. The pin here moves only when Tether chooses to move it.

Nothing in this fork is a candidate for an upstream pull request. The gate
serves a consumer whose licence position upstream does not share, and
upstream's default (`i18n` on, libintl linked) is right for an open-source
build.

## The build, and why its output is believable

`.github/workflows/tether-build.yml`, dispatch-only. It builds the two iOS
slices with `TETHER_I18N=false`, assembles them into
`GhosttyKit.xcframework`, and publishes `tether-<sha12>-<build>` with the zip,
the member lists, and the differential. `Package.swift` is rendered against
that asset and committed back to this branch, which is what a consumer
resolves.

The claim being made is narrow and falsifiable — *this archive contains none of
those thirty objects and no gettext symbol* — so the workflow checks it on the
artifact instead of asserting it from the source:

1. **Every shipped archive is audited** (`tether-audit-archive.sh … absent`):
   no member may match `pkg/libintl`'s object set, and `nm -a` may show no
   gettext symbol under either spelling — prefixed or unprefixed, since
   `intl-compat.c` defines the unprefixed aliases. Undefined symbols count
   too: an undefined one means this archive is asking to be linked against the
   library.
2. **The expected object set is derived from the pinned Ghostty's own
   `pkg/libintl/build.zig`** (`tether-libintl-objects.sh`), never from a list
   kept here, which would go stale on a pin bump in the one direction that
   matters.
3. **One `aarch64-ios` archive is also built with `-Di18n=true`** and audited
   with `… present`: the whole expected set must be there, and the symbol scan
   must find something. Matching archive members by basename is an assumption
   about how Zig names them, and the `present` case is what stops that
   assumption from being load-bearing — if the naming were different, `absent`
   would pass vacuously while `present` failed on the same run. Neither half
   is evidence without the other.
4. **The two member sets are subtracted** (`tether-i18n-diff.sh`) and the
   difference must be *exactly* that object set. An empty difference **fails**:
   the two ways it happens — a flag that never reached the link, or a reused
   cache — are both wrong, and a premise that cannot be distinguished from a
   stale cache is not a premise that was tested.
5. **The slices are re-audited after the merge**, inside the artifact that
   actually ships. `lipo` and `libtool` have both been seen to drop Zig's
   oddly-aligned archive members (which is what
   `Patches/ghostty/0013-host-toolchain.sh` routes around), so an audit before
   the merge speaks about a file nobody consumes.
6. **The published asset is downloaded back** and its checksum compared with
   the manifest's before `Package.swift` is committed.

Targets build on `macos-15` and only the merge runs on `macos-26`, following
upstream's split for the reason upstream has it: `build-ghostty.sh` ends in a
direct `xcrun libtool -static`, and Xcode 27's libtool is the one that drops
those members.

## Rebuilding, and what to re-check when the pin moves

```
gh workflow run "Build Tether XCFramework" --repo audaro/libghostty-spm --ref tether
```

The workflow exits early if the tag already exists. Bump `Tether.build` to
republish the same Ghostty commit after a patch-stack change; delete it back
to `1` when `Ghostty.ref` moves.

When `Ghostty.ref` moves, three things have to be re-read rather than assumed:

- **`src/build/SharedDeps.zig`'s libintl block**, which `0018` anchors on. The
  patch refuses the tree if its four preconditions are gone, so a rework stops
  the build; a *moved* block just needs new anchors.
- **`src/os/i18n.zig`'s comptime guards.** They are the whole safety argument.
  A new function that calls gettext without one would leave an undefined
  symbol, which the audit's symbol scan catches, but read them anyway.
- **Zig's version**, pinned in this workflow and upstream's, against the new
  pin's `minimum_zig_version`.
