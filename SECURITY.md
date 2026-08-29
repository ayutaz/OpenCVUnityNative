# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/ayutaz/OpenCVUnityNative/security/advisories/new)
rather than opening a public issue.

Include what you need to reproduce it: the version, the platform, and the smallest
input or call sequence that triggers it. If you have a crash dump or a sanitizer
report, that is usually enough.

There is no bounty, and no service-level commitment on response time — this is a
personal open-source project.

## What is in scope

This package puts a C ABI between managed code and OpenCV, and the boundary is where
memory-safety problems live. Reports about the following are especially useful:

- **Buffer handling across the boundary.** Anything where a length, stride or offset
  passed from managed code leads to a read or write outside the intended range.
- **Handle lifetime.** Use of a released `Mat` handle, double release, or a handle
  from one thread being freed while another call is using it.
- **Exception escape.** A C++ or OpenCV exception crossing the ABI boundary instead
  of being converted to a status code — unwinding across FFI is undefined behaviour.
- **Anything that turns malformed image data into memory corruption** rather than an
  error status.

## What is not in scope

- **Vulnerabilities in OpenCV itself.** Report those to the
  [OpenCV project](https://github.com/opencv/opencv/security). If a pinned OpenCV
  version in this repository carries a known advisory, that is in scope — the pin is
  ours.
- **Denial of service through obviously excessive inputs** (allocating a `Mat` larger
  than memory, and so on). These return an error status; they are not treated as
  vulnerabilities.
- Anything that requires already having code execution in the host process.

## What this project does to find these itself

Reports are welcome regardless, but for context, the boundary is covered by:

- **AddressSanitizer** on Windows and Linux, plus **LeakSanitizer** on Linux
- **Contract tests** (GoogleTest) and **P/Invoke tests** on plain .NET that
  deliberately provoke double release, use-after-release, and out-of-range buffer
  arguments
- **CodeQL** on the C++ and C# sources
- Crash and hang probes that assert the harness actually fails rather than hanging

None of that is a guarantee. The most serious defect found so far — a
use-after-free in the handle table — was caught by a test that failed once in six
runs, not by any of the above.
