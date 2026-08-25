# OpenCV Unity Native

OpenCV 5 for Unity through a project-owned C ABI, distributed as a reproducible native UPM package.

> **Status: early development (M0).** The automated test harness (native GoogleTest lane, AddressSanitizer lane, and managed P/Invoke contract lane) exists and passes locally and in CI. No OpenCV integration exists yet — the C ABI is still a skeleton.

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

## Development

All local development goes through `tools/dev.ps1`:

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

OpenCV is not built locally. `tools/opencv.ps1 restore` fetches a prebuilt
artifact produced by CI; `tools/opencv.ps1 build` reproduces that build
locally and takes 30-60 minutes, so use it only to verify what CI produced.

## License

Apache License 2.0. Note that the project's own source being Apache-2.0 does not by itself determine the terms of third-party code linked into a distributed binary — dependencies are constrained by an allowlist and documented per build profile.

## Documentation

Design and research documents (in Japanese) live under `docs/`:

- [Roadmap](docs/roadmap.md)
- [Unity/OpenCV integration research and plan](docs/unity-opencv-integration-research-and-plan.md)
- [Native backend language TDD evaluation](docs/native-backend-language-tdd-evaluation.md)
