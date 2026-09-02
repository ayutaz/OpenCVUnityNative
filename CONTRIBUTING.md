# Contributing

This is a personal open-source project. Issues and pull requests are welcome; there
is no commitment on response time.

## Before you start

Read [`CLAUDE.md`](CLAUDE.md). It is written for AI agents working in this
repository, but it is also the most accurate description of how the project is
built, what the invariants are, and why. The design documents under
[`docs/`](docs/) are in Japanese.

The two things worth knowing up front:

- **The C ABI is the only native contract.** No C++ or STL types cross the boundary.
  Opaque handles, fixed-size types, explicit ownership, exceptions converted to
  status codes.
- **`Runtime/Interop` and `Runtime/Core` must not reference `UnityEngine`.** This is
  what keeps the P/Invoke tests runnable without Unity, and it is enforced by a
  netstandard2.1 shim project that fails to build if it is violated.

## Getting a working tree

Requires PowerShell 7+, CMake 3.25+, the .NET 8 SDK, a C++ toolchain, and the
`gh` CLI (authenticated). OpenCV is **not** built locally.

```powershell
./tools/opencv.ps1 restore   # fetch the pinned OpenCV artifact CI published
./tools/dev.ps1 test         # tools tests + generated-bindings check + L1 + L3
./tools/dev.ps1 generate     # regenerate the bindings after editing bindings/spec
```

`./tools/dev.ps1` is the only entry point for local development. Everything else
(`test-asan`, `test-unity-editmode`, `test-unity-player`, `test-unity-tarball`)
hangs off it. See [README](README.md#development) for the full list.

## What a change needs

- **Tests first.** This project is built test-first, and the tests are expected to
  fail before the implementation exists.
- **Prove your check works.** If you add or change a test, an assertion, a
  verification script or a CI gate, **break the thing it guards and watch it fail.**
  A check that has only ever been observed passing has not been shown to work. This
  is written up in `.claude/skills/prove-a-check-works/`.
- **Adding an ABI function** has a specific order, and **the declarations are not
  part of it** — since M5 the C header and the C# P/Invoke are generated from
  `bindings/spec/*.json`, and writing either by hand makes `verify-generated` fail.
  The order is: L1 contract test first, then one entry in the spec followed by
  `./tools/dev.ps1 generate`, then the implementation, then the L3 test — and if
  the change adds a status code, the managed `CvStatus` enum has to follow by hand.
  See `.claude/skills/add-abi-function/`.
- **Do not put milestone-specific rules in hooks.** Conditions that expire become
  stale in exactly the way the documents do.

## What CI will check

Every pull request runs, across Windows / macOS / Linux: the contract tests, the
P/Invoke tests, the sanitizer lanes (with LeakSanitizer on Linux), artifact linkage
and portability verification, and — on Linux — Unity EditMode and a real IL2CPP
player. Android and iOS are cross-compiled and their artifacts inspected (16 KB page
alignment, bundled symbols), **but no device runs them.** The release path is
dry-run on every pull request as well: it builds and assembles the distributable
for all five platforms without publishing anything, because three defects had
accumulated there while it only ran on tags — one of which meant tagging would have
produced no release at all. Workflows, shell scripts and PowerShell are linted;
CodeQL analyses the C++ and C#.

**CI is the authority on mergeability.** A green local run is an approximation kept
for speed.

## What CI does not check

Documentation going stale, scope creep, and claiming a milestone is complete when it
is not — none of these turn CI red. They are the reviewer's job, and historically
they are where the serious problems in this repository have come from.
