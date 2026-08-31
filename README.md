# OpenCV Unity Native

OpenCV 5 for Unity through a project-owned C ABI, distributed as a reproducible native UPM package.

> **Status: v0.1.1 is the newest published release, and the repository is ahead of it. Desktop only — M0–M3 are in that release, M3.5 is in the repository and not yet released.** Windows x64, macOS arm64 and Linux x64 are built, tested and packaged by CI, and Unity itself exercises the plugin on both Mono (EditMode) and a real IL2CPP player. The public C ABI is deliberately narrow — `Mat` lifecycle and buffer transfer, `cvtColor` / `resize` / `GaussianBlur`, and encoding/decoding images to and from byte arrays in memory — because the point was getting ownership, stride, error handling and IL2CPP right rather than covering surface area. **Two things described below are not in v0.1.1** and reach you in the next release: the in-memory image encode/decode functions, and the single package that carries all three platforms. Mobile (M4) and Web (M6) are not started. **If you are on Linux, take v0.1.1 or later:** the Linux plugin in v0.1.0 required glibc 2.38 and would not load on Ubuntu 22.04.

## What this is

A Unity-first integration of OpenCV 5, built around a narrow C ABI that this project owns and versions itself — rather than a repackaging of an existing .NET wrapper.

- **OpenCV 5 first.** Designed against the 5.x module layout, not ported from a 4.x wrapper.
- **Unity first.** IL2CPP, AOT, iOS static linking, Android and Web are design constraints, not afterthoughts.
- **A project-owned C ABI.** No C++ or STL types cross the boundary. Opaque handles, fixed-size types, explicit ownership, exceptions converted to status codes.
- **Reproducible binaries.** Pinned OpenCV tag, build options, toolchain and hashes, regenerated from CI.
- **Apache-2.0.**

## Non-goals

Reimplementing OpenCV algorithms. Hand-wrapping the entire OpenCV API up front. Duplicating OpenCvSharp's managed API for compatibility. Shipping one large binary with every codec, DNN and GPU backend enabled — `imgcodecs` is linked, but only with PNG and JPEG; TIFF, WebP, OpenEXR, JPEG 2000 and the rest are off in the build, as are video I/O (FFmpeg, GStreamer), DNN and every GPU backend.

## Platforms

**Shipping today:** Windows x64, macOS arm64, Linux x64. Each is built, tested and
packaged by CI, and the Linux and Windows plugins are exercised by Unity itself
(EditMode on Mono and a real IL2CPP player).

The macOS plugin is packaged, and Unity itself now reads its Plugin Import Settings —
an EditMode test asks Unity's own `PluginImporter` how it interpreted all three
`.meta` files, with all three binaries present. But the macOS library has never been
loaded, and Unity has never been run on macOS at all. Treat that platform as built and
gated rather than exercised.

**Planned:** Android and iOS, then Web/Wasm. Unity 6000.3 or newer throughout.

## Installing

Releases live at
[github.com/ayutaz/OpenCVUnityNative/releases](https://github.com/ayutaz/OpenCVUnityNative/releases).
Desktop only, and deliberately small: `Mat` lifecycle, `cvtColor` / `resize` /
`GaussianBlur`, and encoding/decoding PNG and JPEG to and from byte arrays in memory.
The ABI takes no file paths at all — only byte buffers. That is on purpose: a
`StreamingAssets` file inside an Android APK has no path that can be opened, and a
path crossing this boundary would drag Windows text encoding along with it. Mobile
and Web are not supported yet.

**On Linux, use v0.1.1 or later.** The Linux plugin in v0.1.0 was built against
glibc 2.38 and fails to load on anything older — Ubuntu 22.04 included — with
`DllNotFoundException`. Since v0.1.1 the Linux artifacts are built in an Ubuntu
22.04 container and require only glibc 2.34.

Each release carries one tarball holding **all three** platforms — that is the one to
take — plus one tarball per platform for anyone who wants a single platform's binary
and nothing else:

```
com.ayutaz.opencv-unity-native.tgz                        # all three platforms — take this one
com.ayutaz.opencv-unity-native-<version>-windows-x64.tgz  # one platform only, if that is what you want
com.ayutaz.opencv-unity-native-<version>-macos-arm64.tgz
com.ayutaz.opencv-unity-native-<version>-linux-x64.tgz
```

The all-platform tarball carries no version number in its filename on purpose:
OpenUPM selects a release asset by a stable name prefix, so a version in the name
would mean rewriting that pattern every release. The per-platform tarballs keep
theirs. Registration on OpenUPM itself is prepared but **not submitted** — it needs
one published release carrying the new asset name first, and whether OpenUPM accepts
it is not something this repository controls
([docs/openupm-registration.md](docs/openupm-registration.md)).

Download `com.ayutaz.opencv-unity-native.tgz`, put it somewhere inside or beside your
project, and point the package manifest at it:

```jsonc
// Packages/manifest.json
{
  "dependencies": {
    "com.ayutaz.opencv-unity-native": "file:../ThirdParty/com.ayutaz.opencv-unity-native.tgz"
  }
}
```

A relative path is resolved from the `Packages` folder; an absolute path also works.
Unity 6000.3 or newer is required — 2022 LTS is not supported, and 6000.0 LTS is no
longer what the lanes verify, because its regular support ends in October 2026. The
Unity lanes pin 6000.3.16f1, both locally and in CI, which reads that version out of
the test project rather than carrying its own copy of the number.

### Verifying what you downloaded

Every release also carries `SHA256SUMS.txt`, listing the SHA-256 of every *other*
asset in that release — it cannot list itself. Download it alongside the files you
took and check them in one go:

```sh
sha256sum -c SHA256SUMS.txt        # Linux
shasum -a 256 -c SHA256SUMS.txt    # macOS
```

Files you did not download are reported as missing; that is expected. The line for
each file you did take must say `OK`.

A release also carries checksum files that are not about the downloads at all:
`checksums.txt` for the all-platform package (three lines, one per binary) and
`<platform>-checksums.txt` for each single-platform package. Those cover the files
**inside** those packages, so they are only useful after extracting.
`SHA256SUMS.txt` is the one that covers the downloadable assets themselves.

### Why not a Git URL

**A Git URL will not work, and this is deliberate.** The native plugin binaries
(`.dll` / `.dylib` / `.so`) are not tracked in git — keeping three platforms'
binaries in history would grow it without bound. A Git URL reference therefore
delivers the C# code and the Plugin Import Settings but no actual libraries, and
every `DllImport` fails at runtime. Use the release tarball —
`com.ayutaz.opencv-unity-native.tgz`.

### One package, all three platforms

The package you install carries the Windows, macOS and Linux binaries together. Unity
allows one package per package ID, so a project whose editor and build target are
different platforms needs them in one package. Earlier releases shipped one tarball
per platform and could not express that; the per-platform tarballs still ship, but
only as a convenience for a project that wants a single platform's binary.

Each binary's Plugin Import Settings enable it on its own platform only, and that is
now measured rather than asserted: an EditMode test asks Unity's own `PluginImporter`
how it read the `.meta` files, with all three binaries present. Two things that
measurement established are worth knowing if you go inspecting the settings yourself.
First, `GetCompatibleWithEditor()` returns **true** for all three plugins — the editor
is gated by the `OS` sub-setting underneath that flag, not by the flag, so a check
reading only the flag passes always and proves nothing. Second, the check has teeth:
deliberately breaking a `.meta` so the macOS library claims Windows leaves the older
ten-test suite at 10 of 10 — `DllImport` resolution already branches on the differing
file names, so nothing there ever noticed — and fails 3 of the current 16.

Installing the all-platform tarball into a throwaway project and running EditMode
there passed 16 of 16, measured on one Windows machine on 2026-08-30. CI runs the same EditMode suite on Linux and it passes 16 of 16 there too, but with only the Linux binary present, so the three-platform case those checks exist for is not what CI exercises. The all-platform tarball is
9.6 MB, measured on the CI run that assembled it. See the [roadmap](docs/roadmap.md).

### How releases are made

Tagging `v*` builds all three platforms, verifies the linkage of what was built,
checks that the Linux library does not require a newer glibc or libstdc++ than the
oldest environment we support, overlays the three platforms' plugin trees into one
package, packages everything, and creates a **draft** release. The glibc check reads
the version records inside the built `.so`; it does not load the library, so it is a
statement about what the binary asks of its host, not proof that it runs there.

That portability check now runs on the release path as well, which it did not
before. It was written in response to the v0.1.0 defect, yet it only ran in the
Unity and nightly lanes, neither of which a tag triggers — so it had never been
applied to a binary anyone actually downloaded. Building Linux inside a pinned container prevents
the problem structurally, but "the structure prevents it, so the check is redundant"
is precisely the reasoning v0.1.0 disproved.

The workflow then counts what it staged — 17 assets, and the all-platform tarball
among them by name — before uploading, because a name collision would otherwise
overwrite a file silently and still look successful. (`SHA256SUMS.txt` is written
afterwards, so a published release holds 18 files.) A human looks at what was produced
and publishes it. A tag alone does not make a release visible — that is deliberate, so
a release that is wrong can be discarded before anyone has it.

## Requirements

- Visual Studio 2022 with the C++ desktop workload
- CMake 3.25+
- .NET 8 SDK or newer
- PowerShell 7+
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated — `tools/opencv.ps1 restore` uses it to download the prebuilt OpenCV artifact

## Development

OpenCV is not built locally. Fetch the pinned artifact first:

```powershell
./tools/opencv.ps1 restore
```

This downloads the prebuilt OpenCV 5.0.0 artifact CI publishes for the current configuration hash (`tools/opencv-config.psd1`); `tools/opencv.ps1 build` reproduces that build locally, so use it only to verify what CI produced. Measured cost: CI's own build step (clone + configure + build + install + verify) took 4m09s on a `windows-2022` GitHub Actions runner ([run 32849957498](https://github.com/ayutaz/OpenCVUnityNative/actions/runs/32849957498)); local timing hasn't been measured and may differ with local hardware and network conditions.

All local development after that goes through `tools/dev.ps1`:

```powershell
# The fast tools tests plus both native lanes (L1 GoogleTest + L3 managed P/Invoke)
./tools/dev.ps1 test

# Individual lanes
./tools/dev.ps1 build
./tools/dev.ps1 test-native
./tools/dev.ps1 test-managed

# AddressSanitizer lane (L2)
./tools/dev.ps1 test-asan

# Unity EditMode (L4) and a Windows IL2CPP Player build + run (L5);
# need Unity 6000.3.16f1 installed locally, with the IL2CPP module for the player lane
./tools/dev.ps1 test-unity-editmode
./tools/dev.ps1 test-unity-player

# Install the UPM tarball into a throwaway Unity project and run its tests there.
# Without -PluginSource this packs only this machine's own platform, and says so
# rather than pretending to be the all-platform package. Pass the other platforms'
# plugin trees (';'-separated, e.g. extracted from a published release) to build
# and install the all-platform package instead.
./tools/dev.ps1 test-unity-tarball
./tools/dev.ps1 test-unity-tarball -PluginSource "<mac>/package;<linux>/package"

# Remove build output
./tools/dev.ps1 clean
```

CI calls the same `tools/dev.ps1` script for everything except the Unity lanes, where
it uses [GameCI](https://game.ci/) to provide the editor and activate the licence.
That divergence is deliberate and bounded: **the pass/fail decision is shared**, in
`tools/assert-unity-results.ps1`, which both the local lanes and CI run. In particular
"zero tests executed is not a pass" lives there, so it cannot hold locally while
silently lapsing in CI.

A local green run is an approximation kept for speed; CI decides mergeability.

### What CI covers

| | Windows x64 | macOS arm64 | Linux x64 |
| --- | --- | --- | --- |
| L1 contract tests + L3 P/Invoke | yes | yes | yes |
| L2 sanitizers | ASan | — | ASan + **LeakSanitizer** |
| Artifact linkage and enabled languages | yes | yes | yes |
| Unity EditMode (L4) | local only | local only | **yes** |
| Unity IL2CPP player (L5) | local only | — | **yes** |

The lane that installs the UPM tarball into a throwaway project
(`test-unity-tarball`) is absent from that table because it runs in no workflow at
all — it is local only, and the "installs and passes" result above was measured by
hand.

The Unity lanes run on Linux, and the Windows IL2CPP player is covered only by the
local lane. The reason recorded here previously — that GameCI's Windows images fail on
the `windows-2022` runners GitHub offers — did not survive checking: the two upstream
issues it cited were closed in 2023, and neither describes this setup — one belongs to a
GameCI action this repository does not use, the other to the Windows lineage of the
GameCI images, while this workflow pins an `ubuntu-` one. GameCI's docs for the action it does use say Windows runners are unsupported
for *package* testing, which is not what this workflow does, and their Windows images
cannot ship the Visual Studio Build Tools an IL2CPP build needs. We have never tried it,
so treat Windows here as untested rather than impossible. The roadmap tracks it.

**Linux artifacts are built inside an Ubuntu 22.04 container**, not on the runner
image. A shared library only loads on a system at least as new as the one that built
it, and runner images keep moving forward. Building in a pinned container keeps the
floor where we intend it (glibc 2.35), and `tools/verify-plugin-portability.ps1`
fails the build if what came out requires anything newer.

Beyond the table, every pull request also runs `actionlint`, `shellcheck`,
`PSScriptAnalyzer` and a repository-relative link check, and CodeQL analyses the C++
and C#. A nightly workflow re-checks the Linux artifact's glibc floor, runs the fast
lanes on Windows and macOS, and confirms the pinned OpenCV artifacts have not
expired — things that break while nobody is pushing. **The nightly workflow has not
yet run on its schedule**; it has only been started by hand, once unsuccessfully
(API rate limits) and once green.

**Almost every lane that runs on a pull request blocks a merge.** Nineteen checks are
required: the contract, P/Invoke and sanitizer jobs across the three desktop platforms, the
four lint jobs, both CodeQL analyses, both Unity lanes, and the six release jobs that build
and assemble the distributable for all five platforms. Seven are deliberately not
required. Four build the per-platform plugins the Unity lanes consume: when one fails the
Unity lanes run anyway and go red on the missing input, which is what stops the merge. A
skipped required check counts as passing, so depending on one without that guard would let
a broken build through. The other two cross-compile for Android and iOS; they are not
required **yet**, because a lane is only made required once it has been reliably green —
twice before, promoting a lane too early left a gap where a red check could not stop a
merge. Until 2026-08-29 the
Unity, lint and CodeQL workflows ran on every pull request without being required,
so they could be red and the change still merged; CI watching something and CI
stopping something are different things, and only the second one is a gate. The
remaining two workflows (`build-opencv`, `nightly`) are not triggered by pull
requests at all, so they cannot be required. `release` was in that list until
2026-08-31; it now runs on pull requests too, because three defects had accumulated in the
distribution path while it only ran on tags — one of which meant that tagging a release
would have produced no release at all. Its `Publish the release` job stays out of the
required set: it is skipped on pull requests by design, and a skipped check counts as
passing, so requiring it would stop nothing.

## Contributing and security

- [CONTRIBUTING.md](CONTRIBUTING.md) — how a change gets in, what a change needs, and
  what CI does **not** check.
- [SECURITY.md](SECURITY.md) — how to report a vulnerability privately, and what is
  in scope at this boundary.

## License

Apache License 2.0 for this repository's own source. That does not by itself determine the terms of third-party code linked into the distributed binary — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses of what the pinned OpenCV build bundles. That file lists every licence the artifact ships and says, per component, which of **OpenCV's own static libraries** it is compiled into — SoftFloat, annoylib, MSCR's chi table and the Rubik font are linked alongside zlib, libpng, libjpeg-turbo and libclapack; a few others ship a licence file without being linked. The Rubik font is under the SIL Open Font License, not a BSD-family licence, so the set is not uniform. Dependencies are constrained by an allowlist (`tools/verify-opencv-artifact.ps1`) and documented per build profile.

Which of those then reach the plugin **you** redistribute depends on which OpenCV
modules this plugin links, and that changed: it now links `core`, `imgproc` and
`imgcodecs`, where before it linked only `core` and `imgproc`. Static linking pulls in
only what is referenced, so until the encode/decode functions were written no codec
code reached the shipped library at all; now it does — zlib, libpng and libjpeg-turbo
among it. On Windows the debug library grew from 8,831,488 to 10,177,536 bytes across
that change. Adding the module to the build system alone changed nothing; writing the
functions is what pulled the code in.

That distinction is easy to lose, and this repository lost it for a while. The pinned
OpenCV build has always been configured with `imgcodecs`, and
`ocvu_get_build_information()` duly lists it under "To be built" — which says OpenCV
was built with the module, not that this plugin links against it. It did not, and the
linker is what settled the question: the first calls to `cv::imencode` came out as
unresolved externals.

The notices, SBOM and build manifest are published **per platform**, as separate
release assets. The all-platform tarball carries only its checksum list: both of the
other two are derived from one platform's restored OpenCV artifact, and the job that
bundles the three platforms has no such source, so a merged version would have to be
invented rather than derived. Take the `<platform>-THIRD_PARTY_NOTICES.md` asset for
each platform you ship.

On Windows the plugin links the runtime library in its shared form rather than
embedding a copy. A developer integrating this package decides what to redistribute
with their game, rather than the package deciding for them.

## Documentation

Design and research documents (in Japanese) live under `docs/`:

- [Roadmap](docs/roadmap.md)
- [M0 implementation plan](docs/superpowers/plans/2026-08-25-m0-tdd-harness.md)
- [M1 implementation plan](docs/superpowers/plans/2026-08-25-m1-opencv-build.md)
- [M2 implementation plan](docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md)
- [M3 implementation plan](docs/superpowers/plans/2026-08-28-m3-desktop-three-platforms.md)
- [M3.5 implementation plan](docs/superpowers/plans/2026-08-30-m3.5-distribution-shape.md)
- [API reference](docs/api-reference.md)
- [OpenUPM registration](docs/openupm-registration.md)
- [C ABI ownership and versioning](docs/abi-ownership-and-versioning.md)
- [Unity/OpenCV integration research and plan](docs/unity-opencv-integration-research-and-plan.md)
- [Native backend language TDD evaluation](docs/native-backend-language-tdd-evaluation.md)
