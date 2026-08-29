# OpenCV Unity Native

OpenCV 5 for Unity through a project-owned C ABI, distributed as a reproducible native UPM package.

> **Status: v0.1.1, desktop only (M0–M3 complete).** Windows x64, macOS arm64 and Linux x64 are built, tested and packaged by CI, and Unity itself exercises the plugin on both Mono (EditMode) and a real IL2CPP player. The public C ABI is deliberately narrow — `Mat` lifecycle and buffer transfer plus `cvtColor` / `resize` / `GaussianBlur` — because M2 was about getting ownership, stride, error handling and IL2CPP right rather than covering surface area. Mobile (M4) and Web (M6) are not started. **If you are on Linux, take v0.1.1 or later:** the Linux plugin in v0.1.0 required glibc 2.38 and would not load on Ubuntu 22.04.

## What this is

A Unity-first integration of OpenCV 5, built around a narrow C ABI that this project owns and versions itself — rather than a repackaging of an existing .NET wrapper.

- **OpenCV 5 first.** Designed against the 5.x module layout, not ported from a 4.x wrapper.
- **Unity first.** IL2CPP, AOT, iOS static linking, Android and Web are design constraints, not afterthoughts.
- **A project-owned C ABI.** No C++ or STL types cross the boundary. Opaque handles, fixed-size types, explicit ownership, exceptions converted to status codes.
- **Reproducible binaries.** Pinned OpenCV tag, build options, toolchain and hashes, regenerated from CI.
- **Apache-2.0.**

## Non-goals

Reimplementing OpenCV algorithms. Hand-wrapping the entire OpenCV API up front. Duplicating OpenCvSharp's managed API for compatibility. Shipping one large binary with every codec, DNN and GPU backend enabled.

## Platforms

**Shipping today:** Windows x64, macOS arm64, Linux x64. Each is built, tested and
packaged by CI, and the Linux and Windows plugins are exercised by Unity itself
(EditMode on Mono and a real IL2CPP player).

**Planned:** Android and iOS, then Web/Wasm. Unity 6000.x only throughout.

## Installing

Releases live at
[github.com/ayutaz/OpenCVUnityNative/releases](https://github.com/ayutaz/OpenCVUnityNative/releases).
Desktop only, and deliberately small: `Mat` lifecycle plus `cvtColor` / `resize` /
`GaussianBlur`. Mobile and Web are not supported yet.

**On Linux, use v0.1.1 or later.** The Linux plugin in v0.1.0 was built against
glibc 2.38 and fails to load on anything older — Ubuntu 22.04 included — with
`DllNotFoundException`. Since v0.1.1 the Linux artifacts are built in an Ubuntu
22.04 container and require only glibc 2.34.

Each release carries one UPM tarball per platform:

```
com.ayutaz.opencv-unity-native-<version>-windows-x64.tgz
com.ayutaz.opencv-unity-native-<version>-macos-arm64.tgz
com.ayutaz.opencv-unity-native-<version>-linux-x64.tgz
```

Download the one matching the platform you build on, put it somewhere inside or
beside your project, and point the package manifest at it:

```jsonc
// Packages/manifest.json
{
  "dependencies": {
    "com.ayutaz.opencv-unity-native": "file:../ThirdParty/com.ayutaz.opencv-unity-native-<version>-windows-x64.tgz"
  }
}
```

A relative path is resolved from the `Packages` folder; an absolute path also
works. Unity 6000.x is required — 2022 LTS is not supported.

### Verifying what you downloaded

Every release also carries `SHA256SUMS.txt`, listing the SHA-256 of every asset in
that release. Download it alongside the files you took and check them in one go:

```sh
sha256sum -c SHA256SUMS.txt        # Linux
shasum -a 256 -c SHA256SUMS.txt    # macOS
```

Files you did not download are reported as missing; that is expected. The line for
each file you did take must say `OK`.

Note that the per-platform `<platform>-checksums.txt` covers the files **inside**
the package, so it is only useful after extracting. `SHA256SUMS.txt` covers the
downloadable assets themselves.

### Why not a Git URL

**A Git URL will not work, and this is deliberate.** The native plugin binaries
(`.dll` / `.dylib` / `.so`) are not tracked in git — keeping three platforms'
binaries in history would grow it without bound. A Git URL reference therefore
delivers the C# code and the Plugin Import Settings but no actual libraries, and
every `DllImport` fails at runtime. Use the release tarball.

### One tarball per platform — a known limitation

Each tarball contains the binary for **one** platform, so a project that builds for
more than one cannot get them all from a single install: Unity allows one package
per package ID, and taking a different tarball on each build machine does not help
when the editor and the build target are different platforms.

**This is a defect, not a design.** M3.5 adds a package holding every platform and
makes that the canonical one. The per-platform `.meta` files are already written so
that each binary is enabled only on its own platform, but no build has ever had three
of them side by side, so how Unity actually behaves in that case is something M3.5
verifies rather than something we can assert here. See the
[roadmap](docs/roadmap.md).

### How releases are made

Tagging `v*` builds all three platforms, verifies the linkage of what was built,
checks that the Linux library does not require a newer glibc or libstdc++ than the
oldest environment we support, packages it, and creates a **draft** release. That
last check reads the version records inside the built `.so`; it does not load the
library, so it is a statement about what the binary asks of its host, not proof that
it runs there. A human looks at what was produced and publishes it. A tag alone does
not make a release visible — that is deliberate, so a release that is wrong can be
discarded before anyone has it.

That portability check now runs on the release path as well, which it did not
before. It was written in response to the v0.1.0 defect, yet it only ran in the
Unity and nightly lanes, neither of which a tag triggers — so it had never been
applied to a binary anyone actually downloaded. Building Linux inside a pinned container prevents
the problem structurally, but "the structure prevents it, so the check is redundant"
is precisely the reasoning v0.1.0 disproved.

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

# Unity EditMode (L4) and a Windows IL2CPP Player build + run (L5); need a local Unity install
./tools/dev.ps1 test-unity-editmode
./tools/dev.ps1 test-unity-player

# Install the UPM tarball into a throwaway Unity project and run its tests there
./tools/dev.ps1 test-unity-tarball

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

**Every lane that runs on a pull request blocks a merge.** Thirteen checks are
required: the contract, P/Invoke and sanitizer jobs across the three platforms, the
four lint jobs, both CodeQL analyses, and both Unity lanes. Until 2026-08-29 the
Unity, lint and CodeQL workflows ran on every pull request without being required,
so they could be red and the change still merged; CI watching something and CI
stopping something are different things, and only the second one is a gate. The
remaining workflows (`build-opencv`, `nightly`, `release`) are not triggered by pull
requests at all, so they cannot be required.

## Contributing and security

- [CONTRIBUTING.md](CONTRIBUTING.md) — how a change gets in, what a change needs, and
  what CI does **not** check.
- [SECURITY.md](SECURITY.md) — how to report a vulnerability privately, and what is
  in scope at this boundary.

## License

Apache License 2.0 for this repository's own source. That does not by itself determine the terms of third-party code linked into the distributed binary — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses of what the pinned OpenCV build bundles. That file lists every licence the artifact ships and says, per component, whether it is actually linked into the binaries — SoftFloat, annoylib, MSCR's chi table and the Rubik font are linked alongside zlib, libpng, libjpeg-turbo and libclapack; a few others ship a licence file without being linked. The Rubik font is under the SIL Open Font License, not a BSD-family licence, so the set is not uniform. Dependencies are constrained by an allowlist (`tools/verify-opencv-artifact.ps1`) and documented per build profile.

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
- [API reference](docs/api-reference.md)
- [C ABI ownership and versioning](docs/abi-ownership-and-versioning.md)
- [Unity/OpenCV integration research and plan](docs/unity-opencv-integration-research-and-plan.md)
- [Native backend language TDD evaluation](docs/native-backend-language-tdd-evaluation.md)
