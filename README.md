# OpenCV Unity Native

OpenCV 5 for Unity through a project-owned C ABI, distributed as a reproducible native UPM package.

> **Status: planning.** No implementation exists yet. Everything below describes intent, not shipped functionality.

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

## License

Apache License 2.0. Note that the project's own source being Apache-2.0 does not by itself determine the terms of third-party code linked into a distributed binary — dependencies are constrained by an allowlist and documented per build profile.

## Documentation

Design and research documents (in Japanese) live under `docs/` and land on `main` as the work is merged.
