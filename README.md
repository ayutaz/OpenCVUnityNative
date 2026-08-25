# OpenCV Unity Native

OpenCV 5 for Unity through a project-owned C ABI, distributed as a reproducible native UPM package.

> **Status: early development (M1 complete, M2 next).** The automated test harness (native GoogleTest lane, AddressSanitizer lane, and managed P/Invoke contract lane) exists and passes locally and in CI, linked against a reproducible OpenCV 5.0.0 build that CI produces and publishes as an artifact. The C ABI still only exposes version/build-information queries and the debug/error-reporting surface built in M0 — no `Mat` lifecycle or `imgproc` calls yet; that is M2's job.

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
# Both fast lanes (L1 native GoogleTest + L3 managed P/Invoke contract tests)
./tools/dev.ps1 test

# Individual lanes
./tools/dev.ps1 build
./tools/dev.ps1 test-native
./tools/dev.ps1 test-managed

# AddressSanitizer lane (L2)
./tools/dev.ps1 test-asan

# Remove build output
./tools/dev.ps1 clean
```

CI calls the same `tools/dev.ps1` script — there are no CI-only procedures. A local green run is an approximation kept for speed; CI decides mergeability.

## License

Apache License 2.0 for this repository's own source. That does not by itself determine the terms of third-party code linked into the distributed binary — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses of what the pinned OpenCV build bundles (zlib, libpng, libjpeg-turbo, libclapack). Dependencies are constrained by an allowlist (`tools/verify-opencv-artifact.ps1`) and documented per build profile.

The runtime library is shared (`/MD`), not embedded — a developer integrating this package decides what to redistribute with their game rather than the package deciding for them.

## Documentation

Design and research documents (in Japanese) live under `docs/`:

- [Roadmap](docs/roadmap.md)
- [M0 implementation plan](docs/superpowers/plans/2026-08-25-m0-tdd-harness.md)
- [M1 implementation plan](docs/superpowers/plans/2026-08-25-m1-opencv-build.md)
- [Unity/OpenCV integration research and plan](docs/unity-opencv-integration-research-and-plan.md)
- [Native backend language TDD evaluation](docs/native-backend-language-tdd-evaluation.md)
