# OpenCV Unity Native

OpenCV 5 for Unity through a project-owned C ABI, distributed as a reproducible native UPM package.

> **Status: early development (M0/M1 complete; M2 meets 7 of its 8 completion criteria; M3 meets 1 of its 6).** M2's unmet criterion: CI never runs the Unity lanes (`ci-unity.yml` exists but has never executed, and registering credentials alone won't fix it — the GitHub-hosted runner has no Unity installed and nothing reads `UNITY_LICENSE` yet). The automated test harness (native GoogleTest lane, AddressSanitizer lane, managed P/Invoke contract lane, a Unity EditMode lane, and a Windows IL2CPP Player lane) exists and passes locally, linked against a reproducible OpenCV 5.0.0 build that CI produces and publishes as an artifact for Windows, macOS and Linux. The C ABI exposes a `Mat` lifecycle (create/release/clone/get_info/copy_from_buffer/copy_to_buffer) and three `imgproc` calls (cvtColor/resize/GaussianBlur) in addition to the M0 version/build-information/debug surface — 18 functions total. `Texture2D` round-trips through OpenCV and back with the same result in both Unity Editor (Mono) and a Windows IL2CPP Player build. M3 (three-platform desktop support) has all its work implemented and committed, but only the Unity sample and API reference criterion is actually verified — the other five (three-platform native-plugin CI build and Plugin Import Settings, Git URL/tarball installability, a complete release bundle, Linux leak detection, and machine-checked linkage on macOS/Linux) exist as code that has never run in CI on this branch, because the commits implementing them haven't been pushed past the last commit CI validated. Nothing beyond Windows x64 has an actual compiled plugin yet.

## What this is

A Unity-first integration of OpenCV 5, built around a narrow C ABI that this project owns and versions itself — rather than a repackaging of an existing .NET wrapper.

- **OpenCV 5 first.** Designed against the 5.x module layout, not ported from a 4.x wrapper.
- **Unity first.** IL2CPP, AOT, iOS static linking, Android and Web are design constraints, not afterthoughts.
- **A project-owned C ABI.** No C++ or STL types cross the boundary. Opaque handles, fixed-size types, explicit ownership, exceptions converted to status codes.
- **Reproducible binaries.** Pinned OpenCV tag, build options, toolchain and hashes, regenerated from CI.
- **Apache-2.0.**

## Non-goals

Reimplementing OpenCV algorithms. Hand-wrapping the entire OpenCV API up front. Duplicating OpenCvSharp's managed API for compatibility. Shipping one large binary with every codec, DNN and GPU backend enabled.

## Planned platforms

Windows, macOS and Linux first, then Android and iOS, then Web/Wasm. Unity 6000.x only.

## Installing

**Not published yet.** No release has been tagged, so there is nothing to install
from a release URL today. What follows describes the intended path, and is written
here because `release.yml` points at it — if you are reading this after the first
tag, the release page will have the files named below.

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
    "com.ayutaz.opencv-unity-native": "file:../ThirdParty/com.ayutaz.opencv-unity-native-0.1.0-windows-x64.tgz"
  }
}
```

A relative path is resolved from the `Packages` folder; an absolute path also
works. Unity 6000.x is required — 2022 LTS is not supported.

### Why not a Git URL

**A Git URL will not work, and this is deliberate.** The native plugin binaries
(`.dll` / `.dylib` / `.so`) are not tracked in git — keeping three platforms'
binaries in history would grow it without bound. A Git URL reference therefore
delivers the C# code and the Plugin Import Settings but no actual libraries, and
every `DllImport` fails at runtime. Use the release tarball.

### One tarball per platform

Each tarball contains the binary for **one** platform. If you build for more than
one, take the corresponding tarball on each build machine. A single package
holding all three is not published, because it would ship two unusable binaries
to every consumer.

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

# Unity EditMode (L4) and a Windows IL2CPP Player build + run (L5); require a local Unity install
./tools/dev.ps1 test-unity-editmode
./tools/dev.ps1 test-unity-player

# Remove build output
./tools/dev.ps1 clean
```

CI calls the same `tools/dev.ps1` script — there are no CI-only procedures. A local green run is an approximation kept for speed; CI decides mergeability. The Unity lanes above are the one exception right now: `ci-unity.yml` exists but has never executed in this repo's CI, because no Unity license is registered in GitHub Secrets. They currently pass only where run locally.

## License

Apache License 2.0 for this repository's own source. That does not by itself determine the terms of third-party code linked into the distributed binary — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses of what the pinned OpenCV build bundles. That file lists every licence the artifact ships and says, per component, whether it is actually linked into the binaries — SoftFloat, annoylib, MSCR's chi table and the Rubik font are linked alongside zlib, libpng, libjpeg-turbo and libclapack; a few others ship a licence file without being linked. The Rubik font is under the SIL Open Font License, not a BSD-family licence, so the set is not uniform. Dependencies are constrained by an allowlist (`tools/verify-opencv-artifact.ps1`) and documented per build profile.

The runtime library is shared (`/MD`), not embedded — a developer integrating this package decides what to redistribute with their game rather than the package deciding for them.

## Documentation

Design and research documents (in Japanese) live under `docs/`:

- [Roadmap](docs/roadmap.md)
- [M0 implementation plan](docs/superpowers/plans/2026-08-25-m0-tdd-harness.md)
- [M1 implementation plan](docs/superpowers/plans/2026-08-25-m1-opencv-build.md)
- [M2 implementation plan](docs/superpowers/plans/2026-08-26-m2-windows-vertical-slice.md)
- [C ABI ownership and versioning](docs/abi-ownership-and-versioning.md)
- [Unity/OpenCV integration research and plan](docs/unity-opencv-integration-research-and-plan.md)
- [Native backend language TDD evaluation](docs/native-backend-language-tdd-evaluation.md)
