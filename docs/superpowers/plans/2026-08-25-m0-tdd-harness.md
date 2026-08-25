# M0: 自動 TDD ハーネス Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OpenCV を一切含まない最小 C ABI に対して、L1（native 契約テスト）・L2（ASan）・L3（素の .NET での P/Invoke 検証）が単一コマンドと GitHub Actions の両方で回り、クラッシュ・ハング・メモリ破壊が人手を介さず赤く落ちる状態を作る。

**Architecture:** `native/` に `extern "C"` の C ABI（`ocvu_` prefix）と、例外を境界で止める仕組みを置く。テストは ABI のみに触れ、backend 実装に依存しない。C# 側は UPM パッケージ配下に置き、`Runtime/Interop` と `Runtime/Core` を UnityEngine 非依存に保つことで、Unity を起動せず netstandard2.1 プロジェクトとして同じソースをテストできるようにする。

**Tech Stack:** C++17 / CMake 3.25+ / Visual Studio 17 2022 generator / GoogleTest / CTest / .NET 8 SDK / xUnit / PowerShell 7 / GitHub Actions

**Spec:**
- [docs/roadmap.md](../../roadmap.md) M0 節
- [docs/native-backend-language-tdd-evaluation.md](../../native-backend-language-tdd-evaluation.md) §5（ハーネス設計）
- [docs/unity-opencv-integration-research-and-plan.md](../../unity-opencv-integration-research-and-plan.md) §6（C ABI 設計原則）、§10（ディレクトリ構成）、§11（命名）

## Global Constraints

すべてのタスクの要件に、以下が暗黙に含まれる。

- **C ABI prefix は `ocvu_`。** C# namespace は `CvUnity`。native library 名は `opencv_unity_native`。
- **UPM package ID は `com.ayutaz.opencv-unity-native`。**
- **対象 Unity は 6000.x のみ。** Unity 2022 LTS は非対応。C# 言語バージョンは **9.0**、ターゲットは **netstandard2.1**。
- **最低 C++ 標準は C++17。**
- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。** UnityEngine に依存するコードは `Runtime/UnityIntegration/`（M2 で追加）にのみ置く。
- **ABI に出す型は固定サイズ型（`int32_t` 等）と opaque handle のみ。** C++ 型・STL 型を境界の外へ出さない。
- **例外を ABI 境界の外へ伝播させない。** すべて status code と thread-local last-error に変換する。
- **ライセンスは Apache-2.0。**
- **CI はローカルと同一のコマンド（`tools/dev.ps1`）を呼ぶ。** CI 専用の手順を作らない。すべての CI ジョブに `timeout-minutes` を設定する。
- OpenCV には**一切依存しない**。M0 の成果物に OpenCV のヘッダ・ライブラリが現れてはならない。

## File Structure

| ファイル | 責務 |
| --- | --- |
| `CMakeLists.txt` | トップレベル。C++17、オプション定義、`native/` の追加 |
| `CMakePresets.json` | `windows-x64-debug` / `windows-x64-asan` の宣言的な構成 |
| `cmake/run_expect_failure.cmake` | 「失敗するはずのプローブ」を実行し、失敗を PASS に変換する CTest ラッパ |
| `native/CMakeLists.txt` | 実装ソースを SHARED（配布物）と STATIC（テスト用）の 2 ターゲットにコンパイルする |
| `native/include/opencv_unity_native.h` | 公開 C ABI。backend 実装から独立 |
| `native/src/ocvu_error.h` / `.cpp` | status code と thread-local last-error、例外バリアマクロ |
| `native/src/ocvu_version.cpp` | `ocvu_get_abi_version` の実装 |
| `native/src/ocvu_debug.cpp` | conformance test 用の意図的な例外送出 |
| `native/tests/ocvu_test_platform.h` / `.cpp` | クラッシュダイアログ抑止（Windows の WER / CRT） |
| `native/tests/test_main.cpp` | GoogleTest エントリ。ダイアログ抑止を最初に呼ぶ |
| `native/tests/test_version.cpp` | ABI version の契約テスト |
| `native/tests/test_error.cpp` | last-error の契約テスト |
| `native/tests/test_exception_barrier.cpp` | 例外が境界を越えないことの契約テスト |
| `native/tests/ocvu_probe.cpp` | 意図的に crash / hang / UAF する別プロセス |
| `Packages/com.ayutaz.opencv-unity-native/package.json` | UPM manifest |
| `Packages/.../Runtime/CvUnity.Runtime.asmdef` | Unity 用アセンブリ定義 |
| `Packages/.../Runtime/Interop/NativeMethods.cs` | P/Invoke 宣言のみ |
| `Packages/.../Runtime/Core/CvNative.cs` | status code / last-error の C# 側表現 |
| `Packages/.../Runtime/Core/CvStatus.cs` | status code 列挙 |
| `Packages/.../Runtime/Core/CvNativeException.cs` | status → 例外への変換 |
| `tests/Managed/CvUnity.Runtime.Shim/*.csproj` | UPM の `Runtime/Interop` と `Runtime/Core` を netstandard2.1 として**共有参照**する |
| `tests/Managed/CvUnity.Tests.Managed/*.csproj` | xUnit テスト。net8.0 |
| `tests/Managed/CvUnity.Tests.Managed/NativeLibraryResolver.cs` | `OCVU_NATIVE_DIR` から DLL を解決 |
| `tools/dev.ps1` | 単一エントリポイント。ローカルと CI が同じものを呼ぶ |
| `.github/workflows/ci-native.yml` | L1 + L3 |
| `.github/workflows/ci-sanitizers.yml` | L2 |

---

### Task 1: C ABI の骨格と L1 テストレーン

最小の C ABI（ABI version query）を作り、GoogleTest + CTest が単一コマンドで回る状態にする。

**Files:**
- Create: `CMakeLists.txt`
- Create: `CMakePresets.json`
- Create: `native/CMakeLists.txt`
- Create: `native/include/opencv_unity_native.h`
- Create: `native/src/ocvu_version.cpp`
- Create: `native/tests/CMakeLists.txt`
- Create: `native/tests/test_main.cpp`
- Test: `native/tests/test_version.cpp`
- Create: `tools/dev.ps1`
- Create: `.gitignore`
- Create: `LICENSE`

**Interfaces:**
- Produces: `int32_t ocvu_get_abi_version(void)` — 現在の ABI バージョンを返す。M0 では `1`。
- Produces: `OCVU_API` / `OCVU_ABI_VERSION` / `OCVU_STATIC` マクロ。
- Produces: CMake ターゲット `opencv_unity_native`（SHARED、配布物）、`ocvu_static`（STATIC、テスト用）、`ocvu_tests`。**テストは `ocvu_static` にリンクする** — SHARED は公開 ABI しかエクスポートしないため、内部シンボルに到達できない。
- Produces: `tools/dev.ps1` の `build` / `test-native` サブコマンド。

- [ ] **Step 1: `.gitignore` と `LICENSE` を置く**

`.gitignore`:

```gitignore
build/
third_party/
[Bb]in/
[Oo]bj/
*.user
.vs/
.vscode/
TestResults/
artifacts/
```

`LICENSE` には Apache License 2.0 の全文を入れる（`https://www.apache.org/licenses/LICENSE-2.0.txt` の内容そのまま）。

- [ ] **Step 2: 失敗するテストを書く**

`native/tests/test_version.cpp`:

```cpp
#include <gtest/gtest.h>

#include "opencv_unity_native.h"

TEST(AbiVersion, ReturnsCurrentAbiVersion) {
    EXPECT_EQ(ocvu_get_abi_version(), OCVU_ABI_VERSION);
}

TEST(AbiVersion, IsPositive) {
    EXPECT_GT(ocvu_get_abi_version(), 0);
}
```

`native/tests/test_main.cpp`:

```cpp
#include <gtest/gtest.h>

int main(int argc, char** argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
```

- [ ] **Step 3: ビルド構成を書き、テストが「ビルドできない」ことを確認する**

`CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.25)
project(opencv_unity_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(OCVU_BUILD_TESTS "Build native tests" ON)
option(OCVU_ENABLE_ASAN "Build with AddressSanitizer" OFF)

if(OCVU_ENABLE_ASAN)
    if(MSVC)
        # MSVC の ASan は /RTC1 と /INCREMENTAL と併用できない
        string(REGEX REPLACE "/RTC[su1]+" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
        add_compile_options(/fsanitize=address /Zi)
        add_link_options(/INCREMENTAL:NO /DEBUG)
    else()
        add_compile_options(-fsanitize=address -fno-omit-frame-pointer -g)
        add_link_options(-fsanitize=address)
    endif()
endif()

add_subdirectory(native)

if(OCVU_BUILD_TESTS)
    enable_testing()
    add_subdirectory(native/tests)
endif()
```

`native/CMakeLists.txt`:

```cmake
# 実装ソースは 2 つのターゲットにコンパイルする。
#   opencv_unity_native (SHARED) — 配布物。公開 ABI だけをエクスポートする
#   ocvu_static         (STATIC) — L1 テスト用
#
# テストを SHARED にリンクすると、DLL がエクスポートしていない内部シンボル
# (ocvu::set_last_error など) に到達できず link エラーになる。
# よってテストは STATIC 側へリンクする。
set(OCVU_SOURCES
    src/ocvu_version.cpp
)

add_library(opencv_unity_native SHARED ${OCVU_SOURCES})
target_include_directories(opencv_unity_native
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_compile_definitions(opencv_unity_native PRIVATE OCVU_BUILDING_DLL)
set_target_properties(opencv_unity_native PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    OUTPUT_NAME opencv_unity_native
)

add_library(ocvu_static STATIC ${OCVU_SOURCES})
target_include_directories(ocvu_static
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
           $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
)
# PUBLIC にすることで、リンクするテスト側のヘッダ展開でも
# __declspec(dllimport) が付かなくなる。
target_compile_definitions(ocvu_static PUBLIC OCVU_STATIC)
```

`native/tests/CMakeLists.txt`:

```cmake
include(FetchContent)

FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.15.2
    GIT_SHALLOW    TRUE
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

add_executable(ocvu_tests
    test_main.cpp
    test_version.cpp
)

# SHARED ではなく STATIC 側にリンクする（native/CMakeLists.txt の注記を参照）
target_link_libraries(ocvu_tests PRIVATE ocvu_static GTest::gtest)

add_test(NAME ocvu_tests COMMAND ocvu_tests)
set_tests_properties(ocvu_tests PROPERTIES TIMEOUT 120)
```

`CMakePresets.json`:

```json
{
  "version": 6,
  "cmakeMinimumRequired": { "major": 3, "minor": 25, "patch": 0 },
  "configurePresets": [
    {
      "name": "windows-x64-debug",
      "displayName": "Windows x64 Debug (MSVC)",
      "generator": "Visual Studio 17 2022",
      "architecture": "x64",
      "binaryDir": "${sourceDir}/build/windows-x64-debug",
      "cacheVariables": { "OCVU_BUILD_TESTS": "ON" }
    },
    {
      "name": "windows-x64-asan",
      "inherits": "windows-x64-debug",
      "displayName": "Windows x64 ASan (MSVC)",
      "binaryDir": "${sourceDir}/build/windows-x64-asan",
      "cacheVariables": { "OCVU_ENABLE_ASAN": "ON" }
    }
  ],
  "buildPresets": [
    { "name": "windows-x64-debug", "configurePreset": "windows-x64-debug", "configuration": "Debug" },
    { "name": "windows-x64-asan", "configurePreset": "windows-x64-asan", "configuration": "Debug" }
  ],
  "testPresets": [
    {
      "name": "windows-x64-debug",
      "configurePreset": "windows-x64-debug",
      "configuration": "Debug",
      "output": { "outputOnFailure": true }
    },
    {
      "name": "windows-x64-asan",
      "configurePreset": "windows-x64-asan",
      "configuration": "Debug",
      "output": { "outputOnFailure": true }
    }
  ]
}
```

Run: `cmake --preset windows-x64-debug` に続けて `cmake --build --preset windows-x64-debug`
Expected: FAIL。`opencv_unity_native.h` が存在しないというコンパイルエラー。

- [ ] **Step 4: 最小実装を書く**

`native/include/opencv_unity_native.h`:

```c
#ifndef OPENCV_UNITY_NATIVE_H
#define OPENCV_UNITY_NATIVE_H

#include <stdint.h>

/*
 * OCVU_STATIC: 実装を静的リンクする側（L1 テスト）が定義する。
 * OCVU_BUILDING_DLL: 共有ライブラリ自身のビルド時のみ定義する。
 */
#if defined(OCVU_STATIC)
#  define OCVU_API
#elif defined(_WIN32)
#  if defined(OCVU_BUILDING_DLL)
#    define OCVU_API __declspec(dllexport)
#  else
#    define OCVU_API __declspec(dllimport)
#  endif
#else
#  define OCVU_API __attribute__((visibility("default")))
#endif

/* C# 側は CallingConvention.Cdecl を使う */
#define OCVU_ABI_VERSION 1

#ifdef __cplusplus
extern "C" {
#endif

/* 現在の C ABI バージョンを返す。失敗しない。 */
OCVU_API int32_t ocvu_get_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENCV_UNITY_NATIVE_H */
```

`native/src/ocvu_version.cpp`:

```cpp
#include "opencv_unity_native.h"

extern "C" int32_t ocvu_get_abi_version(void) {
    return OCVU_ABI_VERSION;
}
```

- [ ] **Step 5: テストが通ることを確認する**

Run:

```powershell
cmake --preset windows-x64-debug
cmake --build --preset windows-x64-debug
ctest --preset windows-x64-debug
```

Expected: PASS。`100% tests passed, 0 tests failed out of 1`

- [ ] **Step 6: `tools/dev.ps1` を書く**

```powershell
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test-native', 'test-asan', 'test-managed', 'test', 'clean')]
    [string]$Command = 'test'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$Preset        = 'windows-x64-debug'
$AsanPreset    = 'windows-x64-asan'
$NativeOutDir  = Join-Path $RepoRoot "build/$Preset/native/Debug"
$ResultsDir    = Join-Path $RepoRoot 'artifacts/test-results'

function Invoke-Checked([scriptblock]$Action, [string]$What) {
    Write-Host "==> $What" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

function Build-Native {
    Invoke-Checked { cmake --preset $Preset } 'configure native'
    Invoke-Checked { cmake --build --preset $Preset } 'build native'
}

function Test-Native {
    Build-Native
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    Invoke-Checked {
        ctest --preset $Preset --output-junit (Join-Path $ResultsDir 'native.xml')
    } 'run native tests (L1)'
}

switch ($Command) {
    'build'       { Build-Native }
    'test-native' { Test-Native }
    'test'        { Test-Native }
    'clean'       { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
    default       { throw "Command '$Command' is not implemented yet." }
}

Write-Host "OK: $Command" -ForegroundColor Green
```

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。`artifacts/test-results/native.xml` が生成される。

- [ ] **Step 7: Commit**

```bash
git add .gitignore LICENSE CMakeLists.txt CMakePresets.json native tools
git commit -m "feat(native): add C ABI skeleton with abi version query and CTest lane"
```

---

### Task 2: status code と thread-local last-error

エラーモデルを確立する。以降のすべての ABI 関数がこの上に乗る。

**Files:**
- Modify: `native/include/opencv_unity_native.h`
- Create: `native/src/ocvu_error.h`
- Create: `native/src/ocvu_error.cpp`
- Modify: `native/CMakeLists.txt`
- Test: `native/tests/test_error.cpp`
- Modify: `native/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 の `OCVU_API`、`opencv_unity_native` ターゲット。
- Produces: `typedef int32_t ocvu_status` と `OCVU_STATUS_*` 定数。
- Produces: `ocvu_status ocvu_get_last_error_message(char* buffer, int32_t buffer_size, int32_t* out_required_size)`
- Produces: `ocvu_status ocvu_get_last_error_status(void)`
- Produces: C++ 内部 API `ocvu::set_last_error(ocvu_status, const char*)` と `ocvu::clear_last_error()`（`native/src/ocvu_error.h`、公開ヘッダには出さない）。

- [ ] **Step 1: 失敗するテストを書く**

`native/tests/test_error.cpp`:

```cpp
#include <gtest/gtest.h>

#include <string>
#include <thread>
#include <vector>

#include "opencv_unity_native.h"
#include "ocvu_error.h"

namespace {

std::string ReadLastErrorMessage() {
    int32_t required = 0;
    const ocvu_status query = ocvu_get_last_error_message(nullptr, 0, &required);
    EXPECT_EQ(query, OCVU_STATUS_INVALID_ARGUMENT);
    if (required <= 1) {
        return std::string();
    }
    std::vector<char> buffer(static_cast<size_t>(required));
    const ocvu_status copy =
        ocvu_get_last_error_message(buffer.data(), required, &required);
    EXPECT_EQ(copy, OCVU_STATUS_OK);
    return std::string(buffer.data());
}

}  // namespace

TEST(LastError, IsEmptyAfterClear) {
    ocvu::clear_last_error();
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OK);
    EXPECT_EQ(ReadLastErrorMessage(), "");
}

TEST(LastError, StoresStatusAndMessage) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "bad width");
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ReadLastErrorMessage(), "bad width");
}

TEST(LastError, SetLastErrorReturnsTheStatusItStored) {
    EXPECT_EQ(ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "null"),
              OCVU_STATUS_NULL_POINTER);
}

TEST(LastError, RequiresOutRequiredSize) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "boom");
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, nullptr),
              OCVU_STATUS_NULL_POINTER);
}

TEST(LastError, ReportsRequiredSizeIncludingNulTerminator) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "abcd");
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, &required),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(required, 5);
}

TEST(LastError, RejectsTooSmallBuffer) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "abcd");
    char small[2] = {0};
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_last_error_message(small, 2, &required),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(required, 5);
}

TEST(LastError, IsThreadLocal) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "main thread");

    ocvu_status observed_in_worker = OCVU_STATUS_INVALID_ARGUMENT;
    std::thread worker([&observed_in_worker]() {
        observed_in_worker = ocvu_get_last_error_status();
        ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY, "worker thread");
    });
    worker.join();

    EXPECT_EQ(observed_in_worker, OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ReadLastErrorMessage(), "main thread");
}
```

- [ ] **Step 2: テストが失敗することを確認する**

`native/tests/CMakeLists.txt` の `add_executable(ocvu_tests ...)` に `test_error.cpp` を追加してから実行する。

Run: `pwsh tools/dev.ps1 test-native`
Expected: FAIL。`ocvu_error.h` が見つからない、`OCVU_STATUS_OK` が未定義というコンパイルエラー。

- [ ] **Step 3: 実装を書く**

`native/include/opencv_unity_native.h` の `#define OCVU_ABI_VERSION 1` の下に追加する:

```c
typedef int32_t ocvu_status;

#define OCVU_STATUS_OK                0
#define OCVU_STATUS_INVALID_ARGUMENT  1
#define OCVU_STATUS_NULL_POINTER      2
#define OCVU_STATUS_OUT_OF_MEMORY     3
#define OCVU_STATUS_OPENCV_ERROR      4
#define OCVU_STATUS_UNKNOWN_ERROR     5
```

`extern "C" {` ブロック内、`ocvu_get_abi_version` の下に追加する:

```c
/* 直近のエラー status を返す。呼び出しスレッドごとに独立している。 */
OCVU_API ocvu_status ocvu_get_last_error_status(void);

/*
 * 直近のエラーメッセージを UTF-8・NUL 終端で buffer に書く。
 *
 * out_required_size は必須で、NUL を含む必要バイト数が常に書かれる。
 * buffer が NULL、または buffer_size が必要量未満の場合は
 * OCVU_STATUS_INVALID_ARGUMENT を返す（サイズ問い合わせとして使える）。
 * out_required_size が NULL の場合は OCVU_STATUS_NULL_POINTER を返す。
 *
 * この関数自身は last-error を変更しない。
 */
OCVU_API ocvu_status ocvu_get_last_error_message(char* buffer,
                                                 int32_t buffer_size,
                                                 int32_t* out_required_size);
```

`native/src/ocvu_error.h`:

```cpp
#ifndef OCVU_ERROR_H
#define OCVU_ERROR_H

#include "opencv_unity_native.h"

namespace ocvu {

/* last-error を設定し、渡された status をそのまま返す。 */
ocvu_status set_last_error(ocvu_status status, const char* message);

void clear_last_error();

}  // namespace ocvu

#endif  // OCVU_ERROR_H
```

`native/src/ocvu_error.cpp`:

```cpp
#include "ocvu_error.h"

#include <cstring>
#include <string>

namespace {

thread_local ocvu_status g_last_status = OCVU_STATUS_OK;
thread_local std::string g_last_message;

}  // namespace

namespace ocvu {

ocvu_status set_last_error(ocvu_status status, const char* message) {
    g_last_status = status;
    g_last_message = (message != nullptr) ? message : "";
    return status;
}

void clear_last_error() {
    g_last_status = OCVU_STATUS_OK;
    g_last_message.clear();
}

}  // namespace ocvu

extern "C" ocvu_status ocvu_get_last_error_status(void) {
    return g_last_status;
}

extern "C" ocvu_status ocvu_get_last_error_message(char* buffer,
                                                   int32_t buffer_size,
                                                   int32_t* out_required_size) {
    if (out_required_size == nullptr) {
        return OCVU_STATUS_NULL_POINTER;
    }

    const size_t length = g_last_message.size();
    const int32_t required = static_cast<int32_t>(length) + 1;
    *out_required_size = required;

    if (buffer == nullptr || buffer_size < required) {
        return OCVU_STATUS_INVALID_ARGUMENT;
    }

    std::memcpy(buffer, g_last_message.c_str(), length);
    buffer[length] = '\0';
    return OCVU_STATUS_OK;
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_error.cpp` を追加する（SHARED と STATIC の両ターゲットに反映される）:

```cmake
set(OCVU_SOURCES
    src/ocvu_version.cpp
    src/ocvu_error.cpp
)
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。`LastError.*` の 7 テストがすべて green。

- [ ] **Step 5: Commit**

```bash
git add native
git commit -m "feat(native): add status codes and thread-local last-error"
```

---

### Task 3: 例外バリア

C++ 例外が ABI 境界を越えないことを保証する。計画書 §6 の必須要件。

**Files:**
- Modify: `native/include/opencv_unity_native.h`
- Modify: `native/src/ocvu_error.h`
- Create: `native/src/ocvu_debug.cpp`
- Modify: `native/CMakeLists.txt`
- Test: `native/tests/test_exception_barrier.cpp`
- Modify: `native/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 2 の `ocvu::set_last_error`、`OCVU_STATUS_*`。
- Produces: マクロ `OCVU_TRY_BEGIN` / `OCVU_TRY_END`（`native/src/ocvu_error.h`）。以降のすべての ABI 関数はこの対で本体を囲む。
- Produces: `ocvu_status ocvu_debug_throw(int32_t kind)` — conformance test 用。`kind` は 0=`std::runtime_error`、1=`std::bad_alloc`、2=非標準例外（`int`）、3=例外を投げない。

- [ ] **Step 1: 失敗するテストを書く**

`native/tests/test_exception_barrier.cpp`:

```cpp
#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "opencv_unity_native.h"
#include "ocvu_error.h"

namespace {

std::string ReadLastErrorMessage() {
    int32_t required = 0;
    ocvu_get_last_error_message(nullptr, 0, &required);
    if (required <= 1) {
        return std::string();
    }
    std::vector<char> buffer(static_cast<size_t>(required));
    ocvu_get_last_error_message(buffer.data(), required, &required);
    return std::string(buffer.data());
}

}  // namespace

TEST(ExceptionBarrier, StdExceptionBecomesUnknownErrorStatus) {
    EXPECT_EQ(ocvu_debug_throw(0), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_NE(ReadLastErrorMessage().find("ocvu_debug_throw"), std::string::npos);
}

TEST(ExceptionBarrier, BadAllocBecomesOutOfMemoryStatus) {
    EXPECT_EQ(ocvu_debug_throw(1), OCVU_STATUS_OUT_OF_MEMORY);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OUT_OF_MEMORY);
}

TEST(ExceptionBarrier, NonStandardExceptionBecomesUnknownErrorStatus) {
    EXPECT_EQ(ocvu_debug_throw(2), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_NE(ReadLastErrorMessage(), "");
}

TEST(ExceptionBarrier, SuccessPathClearsPreviousError) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "stale error");
    EXPECT_EQ(ocvu_debug_throw(3), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OK);
    EXPECT_EQ(ReadLastErrorMessage(), "");
}

TEST(ExceptionBarrier, UnknownKindIsRejectedWithoutThrowing) {
    EXPECT_EQ(ocvu_debug_throw(99), OCVU_STATUS_INVALID_ARGUMENT);
}
```

- [ ] **Step 2: テストが失敗することを確認する**

`native/tests/CMakeLists.txt` の `add_executable(ocvu_tests ...)` に `test_exception_barrier.cpp` を追加してから実行する。

Run: `pwsh tools/dev.ps1 test-native`
Expected: FAIL。`ocvu_debug_throw` が未定義というコンパイルエラー。

- [ ] **Step 3: 実装を書く**

`native/include/opencv_unity_native.h` の `extern "C" {` ブロック内に追加する:

```c
/*
 * conformance test 用に、内部で意図的に例外を投げる。
 * kind: 0 = std::runtime_error, 1 = std::bad_alloc,
 *       2 = 非標準例外, 3 = 例外を投げない
 * 例外が ABI 境界を越えないことの検証に使う。
 */
OCVU_API ocvu_status ocvu_debug_throw(int32_t kind);
```

`native/src/ocvu_error.h` の `namespace ocvu { ... }` の後に追加する:

```cpp
/*
 * ABI 関数の本体を囲む例外バリア。
 * すべての公開 ABI 関数はこの対で本体を囲むこと。
 * M2 で cv::Exception のハンドラをここに追加する。
 */
#define OCVU_TRY_BEGIN          \
    ::ocvu::clear_last_error(); \
    try {
#define OCVU_TRY_END                                                       \
    }                                                                      \
    catch (const std::bad_alloc&) {                                        \
        return ::ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY,           \
                                      "out of memory");                    \
    }                                                                      \
    catch (const std::exception& e) {                                      \
        return ::ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, e.what());\
    }                                                                      \
    catch (...) {                                                          \
        return ::ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR,           \
                                      "unknown non-standard exception");   \
    }
```

`ocvu_error.h` の先頭 include に `<exception>` `<new>` `<stdexcept>` を足す:

```cpp
#include <exception>
#include <new>
#include <stdexcept>

#include "opencv_unity_native.h"
```

`native/src/ocvu_debug.cpp`:

```cpp
#include <new>
#include <stdexcept>

#include "ocvu_error.h"

extern "C" ocvu_status ocvu_debug_throw(int32_t kind) {
    OCVU_TRY_BEGIN
    switch (kind) {
        case 0:
            throw std::runtime_error("ocvu_debug_throw: std::runtime_error");
        case 1:
            throw std::bad_alloc();
        case 2:
            throw 42;
        case 3:
            return OCVU_STATUS_OK;
        default:
            return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                          "ocvu_debug_throw: unknown kind");
    }
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_debug.cpp` を追加する:

```cmake
set(OCVU_SOURCES
    src/ocvu_version.cpp
    src/ocvu_error.cpp
    src/ocvu_debug.cpp
)
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。`ExceptionBarrier.*` の 5 テストがすべて green。

- [ ] **Step 5: Commit**

```bash
git add native
git commit -m "feat(native): stop C++ exceptions at the ABI boundary"
```

---

### Task 4: クラッシュとハングが有限時間で赤になることの実証

**このタスクが M0 の中心である。** エージェントの TDD ループを止める最大要因は、テスト失敗ではなくネイティブクラッシュによるハングとモーダルダイアログである。

**Files:**
- Create: `cmake/run_expect_failure.cmake`
- Create: `native/tests/ocvu_test_platform.h`
- Create: `native/tests/ocvu_test_platform.cpp`
- Create: `native/tests/ocvu_probe.cpp`
- Modify: `native/tests/test_main.cpp`
- Modify: `native/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 の `ocvu_tests` ターゲット。
- Produces: 実行可能ターゲット `ocvu_probe`。`argv[1]` に `ok` / `segfault` / `hang` / `use-after-free` / `leak` を取る。
- Produces: CMake 関数 `ocvu_add_expect_failure_test(<name> <mode> <inner_timeout_s> <expect_regex>)`。
- Produces: `ocvu_test::suppress_crash_dialogs()`（`native/tests/ocvu_test_platform.h`）。

- [ ] **Step 1: クラッシュダイアログ抑止を書く**

`native/tests/ocvu_test_platform.h`:

```cpp
#ifndef OCVU_TEST_PLATFORM_H
#define OCVU_TEST_PLATFORM_H

namespace ocvu_test {

/*
 * クラッシュ時にモーダルダイアログを出さないようにする。
 * これを呼ばないと、Windows では異常終了が Windows Error Reporting の
 * ダイアログで停止し、CI とエージェントのループがタイムアウトまで固まる。
 * テストプロセスの main で最初に呼ぶこと。
 */
void suppress_crash_dialogs();

}  // namespace ocvu_test

#endif  // OCVU_TEST_PLATFORM_H
```

`native/tests/ocvu_test_platform.cpp`:

```cpp
#include "ocvu_test_platform.h"

#if defined(_WIN32)

#include <crtdbg.h>
#include <stdlib.h>
#include <windows.h>

namespace ocvu_test {

void suppress_crash_dialogs() {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX |
                 SEM_NOOPENFILEERRORBOX);

    // abort() が "This application has requested the Runtime to terminate"
    // ダイアログを出さないようにする。
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);

    // CRT のアサートをダイアログではなく stderr に出す。
    const int reports[] = {_CRT_WARN, _CRT_ERROR, _CRT_ASSERT};
    for (int report : reports) {
        _CrtSetReportMode(report, _CRTDBG_MODE_FILE);
        _CrtSetReportFile(report, _CRTDBG_FILE_STDERR);
    }
}

}  // namespace ocvu_test

#else

namespace ocvu_test {

void suppress_crash_dialogs() {}

}  // namespace ocvu_test

#endif
```

`native/tests/test_main.cpp` を書き換える:

```cpp
#include <gtest/gtest.h>

#include "ocvu_test_platform.h"

int main(int argc, char** argv) {
    ocvu_test::suppress_crash_dialogs();
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
```

- [ ] **Step 2: プローブプロセスを書く**

`native/tests/ocvu_probe.cpp`:

```cpp
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

#include "ocvu_test_platform.h"

int main(int argc, char** argv) {
    ocvu_test::suppress_crash_dialogs();

    if (argc < 2) {
        std::fprintf(stderr, "usage: ocvu_probe <mode>\n");
        return 2;
    }

    const char* mode = argv[1];

    if (std::strcmp(mode, "ok") == 0) {
        std::printf("probe ok\n");
        return 0;
    }

    if (std::strcmp(mode, "segfault") == 0) {
        std::fprintf(stderr, "probe: dereferencing null\n");
        std::fflush(stderr);
        volatile int* p = nullptr;
        *p = 1;
        return 0;
    }

    if (std::strcmp(mode, "hang") == 0) {
        std::fprintf(stderr, "probe: sleeping forever\n");
        std::fflush(stderr);
        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(3600));
        }
    }

    if (std::strcmp(mode, "use-after-free") == 0) {
        int* p = new int[16];
        p[0] = 7;
        delete[] p;
        volatile int observed = p[0];  // ASan: heap-use-after-free
        std::printf("observed %d\n", static_cast<int>(observed));
        return 0;
    }

    if (std::strcmp(mode, "leak") == 0) {
        int* p = new int[64];
        p[0] = 1;
        std::printf("leaked %d\n", p[0]);
        return 0;
    }

    std::fprintf(stderr, "probe: unknown mode '%s'\n", mode);
    return 2;
}
```

- [ ] **Step 3: 失敗を PASS に変換する CTest ラッパを書く**

CTest の `WILL_FAIL` はタイムアウトの扱いがバージョン間で揺れるため使わない。`execute_process` の `TIMEOUT` を使い、失敗の種類に依存しない形で判定する。

`cmake/run_expect_failure.cmake`:

```cmake
# 「失敗するはずのコマンド」を実行し、実際に失敗したら PASS する。
#
# 必須: OCVU_COMMAND (実行ファイルのパス), OCVU_MODE, OCVU_TIMEOUT
# 任意: OCVU_EXPECT_REGEX (結合した stdout+stderr がこれにマッチすること)

if(NOT DEFINED OCVU_COMMAND OR NOT DEFINED OCVU_MODE OR NOT DEFINED OCVU_TIMEOUT)
    message(FATAL_ERROR "OCVU_COMMAND, OCVU_MODE and OCVU_TIMEOUT are required")
endif()

execute_process(
    COMMAND "${OCVU_COMMAND}" "${OCVU_MODE}"
    TIMEOUT ${OCVU_TIMEOUT}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE stdout_text
    ERROR_VARIABLE stderr_text
)

set(combined "${stdout_text}${stderr_text}")
message(STATUS "probe '${OCVU_MODE}' result: ${result}")
message(STATUS "probe output:\n${combined}")

# 成功終了(0)なら、検出できていないので FAIL。
# タイムアウト時 result は 0 ではない説明文字列になる。
if(result STREQUAL "0")
    message(FATAL_ERROR
        "probe '${OCVU_MODE}' exited successfully, but a failure was expected. "
        "The harness is NOT detecting this class of failure.")
endif()

if(DEFINED OCVU_EXPECT_REGEX AND NOT OCVU_EXPECT_REGEX STREQUAL "")
    if(NOT combined MATCHES "${OCVU_EXPECT_REGEX}")
        message(FATAL_ERROR
            "probe '${OCVU_MODE}' failed as expected, but its output did not match "
            "'${OCVU_EXPECT_REGEX}'.")
    endif()
endif()

message(STATUS "probe '${OCVU_MODE}' failed as expected")
```

- [ ] **Step 4: ハーネスのメタテストを登録する**

`native/tests/CMakeLists.txt` の末尾に追加する:

```cmake
add_executable(ocvu_probe
    ocvu_probe.cpp
    ocvu_test_platform.cpp
)

# name: テスト名 / mode: プローブのモード
# inner_timeout_s: プローブ自体に許す秒数
# expect_regex: 出力に期待する正規表現 (不要なら "")
function(ocvu_add_expect_failure_test name mode inner_timeout_s expect_regex)
    add_test(NAME ${name}
        COMMAND ${CMAKE_COMMAND}
            -DOCVU_COMMAND=$<TARGET_FILE:ocvu_probe>
            -DOCVU_MODE=${mode}
            -DOCVU_TIMEOUT=${inner_timeout_s}
            -DOCVU_EXPECT_REGEX=${expect_regex}
            -P ${CMAKE_SOURCE_DIR}/cmake/run_expect_failure.cmake
    )
    math(EXPR outer_timeout "${inner_timeout_s} + 60")
    set_tests_properties(${name} PROPERTIES TIMEOUT ${outer_timeout})
endfunction()

# 正常系: プローブ自体が動くことの確認
add_test(NAME harness.probe_ok COMMAND ocvu_probe ok)
set_tests_properties(harness.probe_ok PROPERTIES TIMEOUT 30)

# ネイティブクラッシュが赤になり、ダイアログでハングしないこと
ocvu_add_expect_failure_test(harness.segfault_is_detected segfault 30 "")

# 無限ループが有限時間で赤になること
ocvu_add_expect_failure_test(harness.hang_is_detected hang 5 "")
```

`ocvu_tests` ターゲットにも `ocvu_test_platform.cpp` を追加する:

```cmake
add_executable(ocvu_tests
    test_main.cpp
    ocvu_test_platform.cpp
    test_version.cpp
    test_error.cpp
    test_exception_barrier.cpp
)
```

- [ ] **Step 5: テストが通ることを確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。`harness.probe_ok` / `harness.segfault_is_detected` / `harness.hang_is_detected` が green。**`harness.hang_is_detected` は 5 秒程度で終わり、それ以上待たされないこと。**

- [ ] **Step 6: 抑止が効いていることを目視でも確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: 実行中に Windows のクラッシュダイアログ・「動作を停止しました」ダイアログが**一切表示されない**こと。表示された場合は `suppress_crash_dialogs()` が呼ばれていない。

- [ ] **Step 7: Commit**

```bash
git add cmake native
git commit -m "test(harness): prove native crashes and hangs fail fast without dialogs"
```

---

### Task 5: ASan レーンと use-after-free 検出の実証

**Files:**
- Modify: `native/tests/CMakeLists.txt`
- Modify: `CMakeLists.txt`
- Modify: `tools/dev.ps1`

**Interfaces:**
- Consumes: Task 4 の `ocvu_probe` と `ocvu_add_expect_failure_test`。Task 1 の `windows-x64-asan` プリセット。
- Produces: `tools/dev.ps1 test-asan` サブコマンド。
- Produces: ASan ビルドでのみ登録されるテスト `harness.use_after_free_is_detected`。

> **注意:** MSVC の AddressSanitizer は **LeakSanitizer を含まない**。リーク検出は M3 の Linux レーン（LSan / Valgrind）が担当する。M0 では `leak` モードのプローブを用意するだけで、テストとしては登録しない。

- [ ] **Step 1: ASan テストを登録する**

`native/tests/CMakeLists.txt` の末尾に追加する:

```cmake
if(OCVU_ENABLE_ASAN)
    # ASan ビルドでのみ意味を持つ。通常ビルドでは UAF が検出されず、
    # プローブが 0 で終了してしまうため登録しない。
    ocvu_add_expect_failure_test(harness.use_after_free_is_detected
        use-after-free 60 "heap-use-after-free")
endif()
```

- [ ] **Step 2: ASan ランタイム DLL を PATH に通す**

MSVC の ASan は `clang_rt.asan_dynamic-x86_64.dll` を必要とし、これは cl.exe と同じディレクトリにある。開発者コマンドプロンプト外から CTest を実行すると見つからないため、テストの環境を CMake 側で補正する。

`native/tests/CMakeLists.txt` の `ocvu_add_expect_failure_test` 関数定義の**前**に追加する:

```cmake
# MSVC の ASan ランタイム DLL は cl.exe と同じディレクトリにある。
# 開発者コマンドプロンプト外でも見つかるよう、テストの PATH に足す。
set(OCVU_TEST_ENV_MODIFICATION "")
if(OCVU_ENABLE_ASAN AND MSVC)
    get_filename_component(OCVU_MSVC_BIN_DIR "${CMAKE_CXX_COMPILER}" DIRECTORY)
    set(OCVU_TEST_ENV_MODIFICATION
        "PATH=path_list_prepend:${OCVU_MSVC_BIN_DIR}")
endif()
```

`ocvu_add_expect_failure_test` 内の `set_tests_properties` を書き換える:

```cmake
    set_tests_properties(${name} PROPERTIES
        TIMEOUT ${outer_timeout}
        ENVIRONMENT_MODIFICATION "${OCVU_TEST_ENV_MODIFICATION}")
```

`ocvu_tests` と `harness.probe_ok` にも同じ補正を適用する:

```cmake
set_tests_properties(ocvu_tests PROPERTIES
    TIMEOUT 120
    ENVIRONMENT_MODIFICATION "${OCVU_TEST_ENV_MODIFICATION}")

set_tests_properties(harness.probe_ok PROPERTIES
    TIMEOUT 30
    ENVIRONMENT_MODIFICATION "${OCVU_TEST_ENV_MODIFICATION}")
```

- [ ] **Step 3: `tools/dev.ps1` に `test-asan` を追加する**

`Test-Native` 関数の下に追加する:

```powershell
function Test-Asan {
    Invoke-Checked { cmake --preset $AsanPreset } 'configure native (asan)'
    Invoke-Checked { cmake --build --preset $AsanPreset } 'build native (asan)'
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    Invoke-Checked {
        ctest --preset $AsanPreset --output-junit (Join-Path $ResultsDir 'native-asan.xml')
    } 'run native tests under ASan (L2)'
}
```

`switch ($Command)` に追加する:

```powershell
    'test-asan'   { Test-Asan }
```

- [ ] **Step 4: ASan が use-after-free を検出することを確認する**

Run: `pwsh tools/dev.ps1 test-asan`
Expected: PASS。`harness.use_after_free_is_detected` が green で、出力に `heap-use-after-free` が含まれる。既存のテストもすべて green（＝ハーネス自身が ASan clean）。

- [ ] **Step 5: ASan レーンが実際に効いていることを反証する**

Run: `ctest --preset windows-x64-debug -R use_after_free`
Expected: `No tests were found` — 通常ビルドでは登録されないこと。これにより Step 4 の green が ASan によるものだと確認できる。

- [ ] **Step 6: Commit**

```bash
git add CMakeLists.txt native tools
git commit -m "test(harness): add ASan lane and prove use-after-free is detected"
```

---

### Task 6: UPM パッケージ骨格と netstandard2.1 shim

C# 側の骨格を作り、**`Runtime/Interop` と `Runtime/Core` が UnityEngine 非依存であること**をビルドで機械的に強制する。この制約が L3（Unity 非経由テスト）を可能にする。

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/package.json`
- Create: `Packages/com.ayutaz.opencv-unity-native/LICENSE.md`
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/CvUnity.Runtime.asmdef`
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs`
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs`
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvNativeException.cs`
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvNative.cs`
- Create: `tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj`
- Create: `tests/Managed/CvUnity.Managed.sln`

**Interfaces:**
- Consumes: Task 2 / Task 3 の ABI 関数群。
- Produces: `CvUnity.CvStatus`（enum）、`CvUnity.CvNativeException`、`CvUnity.CvNative`（`AbiVersion`、`GetLastErrorStatus()`、`GetLastErrorMessage()`、`ThrowIfFailed(int)`、`DebugThrow(int)`）。
- Produces: netstandard2.1 アセンブリ `CvUnity.Runtime`。

- [ ] **Step 1: UPM manifest と asmdef を書く**

`Packages/com.ayutaz.opencv-unity-native/package.json`:

```json
{
  "name": "com.ayutaz.opencv-unity-native",
  "version": "0.0.1",
  "displayName": "OpenCV Unity Native",
  "description": "OpenCV 5 for Unity through a project-owned C ABI. Apache-2.0.",
  "unity": "6000.0",
  "license": "Apache-2.0",
  "keywords": ["opencv", "computer-vision", "native"]
}
```

`Packages/com.ayutaz.opencv-unity-native/Runtime/CvUnity.Runtime.asmdef`:

```json
{
  "name": "CvUnity.Runtime",
  "rootNamespace": "CvUnity",
  "references": [],
  "includePlatforms": [],
  "excludePlatforms": [],
  "allowUnsafeCode": false,
  "autoReferenced": true,
  "noEngineReferences": true
}
```

> `noEngineReferences: true` が Unity 側でも UnityEngine 非依存を強制する。M2 で `UnityIntegration` を追加する際は、**別の asmdef**（`noEngineReferences: false`）にする。

`Packages/com.ayutaz.opencv-unity-native/LICENSE.md` にはリポジトリ直下の `LICENSE` と同じ Apache License 2.0 全文を入れる。

- [ ] **Step 2: P/Invoke 宣言を書く**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs`:

```csharp
using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static class NativeMethods
    {
#if UNITY_IOS && !UNITY_EDITOR
        internal const string LibraryName = "__Internal";
#else
        internal const string LibraryName = "opencv_unity_native";
#endif

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_abi_version();

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_last_error_status();

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_last_error_message(
            byte[] buffer, int bufferSize, out int requiredSize);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_debug_throw(int kind);
    }
}
```

- [ ] **Step 3: C# 側のエラー表現を書く**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs`:

```csharp
namespace CvUnity
{
    /// <summary>ネイティブ C ABI が返す status code。</summary>
    public enum CvStatus
    {
        Ok = 0,
        InvalidArgument = 1,
        NullPointer = 2,
        OutOfMemory = 3,
        OpenCvError = 4,
        UnknownError = 5,
    }
}
```

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvNativeException.cs`:

```csharp
using System;

namespace CvUnity
{
    /// <summary>ネイティブ層が非 OK status を返したときに送出される。</summary>
    public class CvNativeException : Exception
    {
        public CvStatus Status { get; }

        public CvNativeException(CvStatus status, string message)
            : base(message)
        {
            Status = status;
        }
    }
}
```

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvNative.cs`:

```csharp
using System.Text;
using CvUnity.Interop;

namespace CvUnity
{
    /// <summary>ネイティブ層のバージョン照会とエラー取得。</summary>
    public static class CvNative
    {
        /// <summary>ロードされているネイティブライブラリの C ABI バージョン。</summary>
        public static int AbiVersion => NativeMethods.ocvu_get_abi_version();

        /// <summary>呼び出しスレッドの直近のエラー status。</summary>
        public static CvStatus GetLastErrorStatus()
        {
            return (CvStatus)NativeMethods.ocvu_get_last_error_status();
        }

        /// <summary>呼び出しスレッドの直近のエラーメッセージ。無ければ空文字列。</summary>
        public static string GetLastErrorMessage()
        {
            int required;
            NativeMethods.ocvu_get_last_error_message(null, 0, out required);
            if (required <= 1)
            {
                return string.Empty;
            }

            var buffer = new byte[required];
            var status = NativeMethods.ocvu_get_last_error_message(
                buffer, buffer.Length, out required);
            if (status != (int)CvStatus.Ok)
            {
                return string.Empty;
            }

            return Encoding.UTF8.GetString(buffer, 0, required - 1);
        }

        /// <summary>非 OK status を <see cref="CvNativeException"/> に変換する。</summary>
        public static void ThrowIfFailed(int status)
        {
            if (status == (int)CvStatus.Ok)
            {
                return;
            }

            var message = GetLastErrorMessage();
            if (message.Length == 0)
            {
                message = "native call failed with status " + status;
            }

            throw new CvNativeException((CvStatus)status, message);
        }

        /// <summary>conformance test 用。ネイティブ層に意図的に例外を投げさせる。</summary>
        public static int DebugThrow(int kind)
        {
            return NativeMethods.ocvu_debug_throw(kind);
        }
    }
}
```

- [ ] **Step 4: netstandard2.1 shim プロジェクトを書く**

`tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <!-- Unity 6000.x の managed plug-in 条件に合わせる。
         ここが通ることが Runtime/Interop と Runtime/Core が
         UnityEngine 非依存であることの機械的な証明になる。 -->
    <TargetFramework>netstandard2.1</TargetFramework>
    <LangVersion>9.0</LangVersion>
    <AssemblyName>CvUnity.Runtime</AssemblyName>
    <RootNamespace>CvUnity</RootNamespace>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <GenerateAssemblyInfo>true</GenerateAssemblyInfo>
  </PropertyGroup>

  <PropertyGroup>
    <OcvuPackageRuntime>$(MSBuildThisFileDirectory)..\..\..\Packages\com.ayutaz.opencv-unity-native\Runtime</OcvuPackageRuntime>
  </PropertyGroup>

  <ItemGroup>
    <!-- UnityEngine に依存しない層だけを取り込む。
         UnityIntegration は意図的に含めない。 -->
    <Compile Include="$(OcvuPackageRuntime)\Interop\**\*.cs" />
    <Compile Include="$(OcvuPackageRuntime)\Core\**\*.cs" />
  </ItemGroup>

  <ItemGroup>
    <InternalsVisibleTo Include="CvUnity.Tests.Managed" />
  </ItemGroup>

</Project>
```

`tests/Managed/CvUnity.Managed.sln` は次で生成する:

```powershell
dotnet new sln --name CvUnity.Managed --output tests/Managed
dotnet sln tests/Managed/CvUnity.Managed.sln add tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj
```

- [ ] **Step 5: shim がビルドできることを確認する**

Run: `dotnet build tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj`
Expected: PASS。警告 0 件でビルドが通る。

- [ ] **Step 6: 制約が実際に効いていることを反証する**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvNative.cs` の先頭に一時的に `using UnityEngine;` を追加する。

Run: `dotnet build tests/Managed/CvUnity.Runtime.Shim/CvUnity.Runtime.Shim.csproj`
Expected: FAIL。`error CS0246: The type or namespace name 'UnityEngine' could not be found`

確認後、追加した `using UnityEngine;` を削除して再度ビルドが通ることを確認する。

- [ ] **Step 7: Commit**

```bash
git add Packages tests/Managed
git commit -m "feat(package): add UPM skeleton and UnityEngine-free netstandard2.1 shim"
```

---

### Task 7: L3 — 素の .NET での P/Invoke テスト

Unity を起動せずに、実際の P/Invoke 宣言とマーシャリングを秒単位で検証する。**このレーンがエージェントの反復速度を決める。**

**Files:**
- Create: `tests/Managed/CvUnity.Tests.Managed/CvUnity.Tests.Managed.csproj`
- Create: `tests/Managed/CvUnity.Tests.Managed/NativeLibraryResolver.cs`
- Test: `tests/Managed/CvUnity.Tests.Managed/AbiContractTests.cs`
- Modify: `tools/dev.ps1`
- Modify: `tests/Managed/CvUnity.Managed.sln`

**Interfaces:**
- Consumes: Task 6 の `CvUnity.Runtime` アセンブリと `CvNative` API。Task 1 の native ビルド出力。
- Produces: 環境変数 `OCVU_NATIVE_DIR` 経由でネイティブ DLL を解決する仕組み。
- Produces: `tools/dev.ps1` の `test-managed` サブコマンドと、`test` による全レーン実行。

- [ ] **Step 1: 失敗するテストを書く**

`tests/Managed/CvUnity.Tests.Managed/AbiContractTests.cs`:

```csharp
using System;
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class AbiContractTests
    {
        [Fact]
        public void AbiVersion_MatchesTheVersionThisPackageWasBuiltAgainst()
        {
            Assert.Equal(1, CvNative.AbiVersion);
        }

        [Fact]
        public void DebugThrow_StdException_ReturnsUnknownErrorInsteadOfCrashing()
        {
            var status = CvNative.DebugThrow(0);

            Assert.Equal((int)CvStatus.UnknownError, status);
            Assert.Equal(CvStatus.UnknownError, CvNative.GetLastErrorStatus());
            Assert.Contains("ocvu_debug_throw", CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void DebugThrow_BadAlloc_MapsToOutOfMemory()
        {
            var status = CvNative.DebugThrow(1);

            Assert.Equal((int)CvStatus.OutOfMemory, status);
        }

        [Fact]
        public void DebugThrow_NonStandardException_IsStillContained()
        {
            var status = CvNative.DebugThrow(2);

            Assert.Equal((int)CvStatus.UnknownError, status);
            Assert.NotEmpty(CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void DebugThrow_SuccessPath_ClearsPreviousError()
        {
            CvNative.DebugThrow(0);

            var status = CvNative.DebugThrow(3);

            Assert.Equal((int)CvStatus.Ok, status);
            Assert.Equal(CvStatus.Ok, CvNative.GetLastErrorStatus());
            Assert.Equal(string.Empty, CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void ThrowIfFailed_ConvertsNonOkStatusIntoCvNativeException()
        {
            var status = CvNative.DebugThrow(0);

            var exception = Assert.Throws<CvNativeException>(
                () => CvNative.ThrowIfFailed(status));

            Assert.Equal(CvStatus.UnknownError, exception.Status);
            Assert.Contains("ocvu_debug_throw", exception.Message);
        }

        [Fact]
        public void ThrowIfFailed_DoesNothingOnOk()
        {
            CvNative.ThrowIfFailed((int)CvStatus.Ok);
        }

        [Fact]
        public void GetLastErrorMessage_RoundTripsUtf8WithoutTruncation()
        {
            CvNative.DebugThrow(0);

            var message = CvNative.GetLastErrorMessage();

            // NUL 終端が文字列に混入していないこと
            Assert.DoesNotContain('\0', message);
            Assert.EndsWith("std::runtime_error", message);
        }
    }
}
```

- [ ] **Step 2: ネイティブ DLL の解決とテストプロジェクトを書く**

`tests/Managed/CvUnity.Tests.Managed/NativeLibraryResolver.cs`:

```csharp
using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace CvUnity.Tests.Managed
{
    /// <summary>
    /// ネイティブビルド出力の場所を OCVU_NATIVE_DIR から解決する。
    /// DllImport を宣言しているのは CvUnity.Runtime アセンブリなので、
    /// resolver はそのアセンブリに対して登録する。
    /// </summary>
    internal static class NativeLibraryResolver
    {
        [ModuleInitializer]
        internal static void Initialize()
        {
            var runtimeAssembly = typeof(CvNative).Assembly;
            NativeLibrary.SetDllImportResolver(runtimeAssembly, Resolve);
        }

        private static IntPtr Resolve(
            string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
        {
            if (libraryName != "opencv_unity_native")
            {
                return IntPtr.Zero;
            }

            var directory = Environment.GetEnvironmentVariable("OCVU_NATIVE_DIR");
            if (string.IsNullOrEmpty(directory))
            {
                throw new InvalidOperationException(
                    "OCVU_NATIVE_DIR is not set. Run the managed tests through " +
                    "'tools/dev.ps1 test-managed' so the native build output can be located.");
            }

            var path = Path.Combine(directory, "opencv_unity_native.dll");
            if (!File.Exists(path))
            {
                throw new FileNotFoundException(
                    $"Native library not found at '{path}'. Build it first with 'tools/dev.ps1 build'.",
                    path);
            }

            return NativeLibrary.Load(path);
        }
    }
}
```

`tests/Managed/CvUnity.Tests.Managed/CvUnity.Tests.Managed.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <LangVersion>latest</LangVersion>
    <Nullable>disable</Nullable>
    <IsPackable>false</IsPackable>
    <!-- ネイティブ DLL は x64。テストホストも x64 に固定する。 -->
    <PlatformTarget>x64</PlatformTarget>
    <RootNamespace>CvUnity.Tests.Managed</RootNamespace>
    <AssemblyName>CvUnity.Tests.Managed</AssemblyName>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
    <PackageReference Include="JunitXml.TestLogger" Version="4.1.0" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\CvUnity.Runtime.Shim\CvUnity.Runtime.Shim.csproj" />
  </ItemGroup>

</Project>
```

sln に追加する:

```powershell
dotnet sln tests/Managed/CvUnity.Managed.sln add tests/Managed/CvUnity.Tests.Managed/CvUnity.Tests.Managed.csproj
```

- [ ] **Step 3: テストが失敗することを確認する**

Run:

```powershell
dotnet test tests/Managed/CvUnity.Managed.sln
```

Expected: FAIL。`OCVU_NATIVE_DIR is not set.` という明示的なメッセージで全テストが落ちる（DLL が見つからないという不明瞭なエラーではないこと）。

- [ ] **Step 4: `tools/dev.ps1` に `test-managed` と `test` を実装する**

`Test-Asan` 関数の下に追加する:

```powershell
function Test-Managed {
    Build-Native
    if (-not (Test-Path (Join-Path $NativeOutDir 'opencv_unity_native.dll'))) {
        throw "Native library was not found in '$NativeOutDir' after building."
    }
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

    $env:OCVU_NATIVE_DIR = $NativeOutDir
    Invoke-Checked {
        dotnet test (Join-Path $RepoRoot 'tests/Managed/CvUnity.Managed.sln') `
            --logger "junit;LogFilePath=$(Join-Path $ResultsDir 'managed.xml')" `
            --logger 'console;verbosity=normal'
    } 'run managed tests (L3)'
}
```

`switch ($Command)` を書き換える:

```powershell
switch ($Command) {
    'build'        { Build-Native }
    'test-native'  { Test-Native }
    'test-asan'    { Test-Asan }
    'test-managed' { Test-Managed }
    'test'         { Test-Native; Test-Managed }
    'clean'        { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
}
```

Task 1 で書いた `default { throw ... }` の行は削除する（全サブコマンドが実装済みになるため）。

- [ ] **Step 5: テストが通ることを確認する**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS。`AbiContractTests` の 8 テストがすべて green。`artifacts/test-results/managed.xml` が生成される。

- [ ] **Step 6: 全レーンが単一コマンドで回ることを確認する**

Run: `pwsh tools/dev.ps1 test`
Expected: PASS。L1 と L3 が両方走り、最後に `OK: test` が表示される。**所要時間が 1 分未満であること**（このレーンが遅いなら M0 は目的を達していない）。

- [ ] **Step 7: 失敗が非ゼロ終了コードで返ることを確認する**

`AbiContractTests.cs` の `Assert.Equal(1, CvNative.AbiVersion);` を一時的に `Assert.Equal(999, CvNative.AbiVersion);` に変える。

Run: `pwsh tools/dev.ps1 test; echo "exit=$LASTEXITCODE"`
Expected: FAIL し、`exit` が 0 以外であること。確認後、`1` に戻す。

- [ ] **Step 8: Commit**

```bash
git add tests/Managed tools
git commit -m "test(managed): add L3 P/Invoke contract tests running without Unity"
```

---

### Task 8: GitHub Actions

CI を成果物の一部として完成させる。**ワークフローはローカルと同一のコマンドを呼ぶ。**

**Files:**
- Create: `.github/workflows/ci-native.yml`
- Create: `.github/workflows/ci-sanitizers.yml`
- Create: `README.md`
- Modify: `docs/README.md`

**Interfaces:**
- Consumes: Task 7 で完成した `tools/dev.ps1` の `test` と `test-asan`。
- Produces: `ci-native` / `ci-sanitizers` の 2 ワークフロー。両者とも JUnit XML を artifact 化する。

- [ ] **Step 1: L1 + L3 のワークフローを書く**

`.github/workflows/ci-native.yml`:

```yaml
name: ci-native

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: ci-native-${{ github.ref }}
  cancel-in-progress: true

jobs:
  windows:
    name: Windows x64 (L1 + L3)
    runs-on: windows-2022
    timeout-minutes: 30

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'

      - name: Cache CMake FetchContent (googletest)
        uses: actions/cache@v4
        with:
          path: build/windows-x64-debug/_deps
          key: fetchcontent-windows-${{ hashFiles('native/tests/CMakeLists.txt') }}

      # ローカルと同一のコマンドを呼ぶ。CI 専用の手順を作らない。
      - name: Run all fast lanes
        shell: pwsh
        run: ./tools/dev.ps1 test

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results-windows
          path: artifacts/test-results/
          if-no-files-found: warn
```

- [ ] **Step 2: ASan のワークフローを書く**

`.github/workflows/ci-sanitizers.yml`:

```yaml
name: ci-sanitizers

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: ci-sanitizers-${{ github.ref }}
  cancel-in-progress: true

jobs:
  asan-windows:
    name: Windows x64 AddressSanitizer (L2)
    runs-on: windows-2022
    timeout-minutes: 45

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Cache CMake FetchContent (googletest)
        uses: actions/cache@v4
        with:
          path: build/windows-x64-asan/_deps
          key: fetchcontent-asan-windows-${{ hashFiles('native/tests/CMakeLists.txt') }}

      - name: Run native tests under AddressSanitizer
        shell: pwsh
        run: ./tools/dev.ps1 test-asan

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results-asan-windows
          path: artifacts/test-results/
          if-no-files-found: warn
```

- [ ] **Step 3: README を書く**

`README.md`:

````markdown
# OpenCV Unity Native

OpenCV 5 を Unity へ持ち込むための、プロジェクト所有の C ABI と UPM パッケージ。Apache-2.0。

> **状態: 開発初期（M0）。** まだ OpenCV は統合されていない。現在の成果物は C ABI の骨格と自動テストハーネスである。

## 必要なもの

- Visual Studio 2022（C++ デスクトップ開発ワークロード）
- CMake 3.25 以上
- .NET 8 SDK
- PowerShell 7 以上

## 開発

```powershell
# すべての高速レーン（L1: native 契約テスト + L3: P/Invoke テスト）
./tools/dev.ps1 test

# 個別に実行する
./tools/dev.ps1 build
./tools/dev.ps1 test-native
./tools/dev.ps1 test-managed

# AddressSanitizer レーン（L2）
./tools/dev.ps1 test-asan
```

CI はローカルと同じ `tools/dev.ps1` を呼ぶ。ローカルの green は速さのための近似であり、merge 可否は CI が決める。

## ドキュメント

- [ロードマップ](docs/roadmap.md)
- [競合調査と初期計画](docs/unity-opencv-integration-research-and-plan.md)
- [Native backend 実装言語の評価](docs/native-backend-language-tdd-evaluation.md)

## ライセンス

Apache License 2.0。[LICENSE](LICENSE) を参照。
````

`docs/README.md` の Documents 一覧に次を追加する:

```markdown
- [ロードマップ](./roadmap.md)
  - M0〜M7 のマイルストーンと、各マイルストーンの目的・ゴール・完了条件
  - ローカルループと CI の役割分担、GitHub Actions のワークフロー構成
```

- [ ] **Step 4: ワークフローの構文を検証する**

Run:

```powershell
# 構文チェック（yq もしくは PowerShell の ConvertFrom-Yaml が無ければ push で確認する）
Get-Content .github/workflows/ci-native.yml | Out-Null
Get-Content .github/workflows/ci-sanitizers.yml | Out-Null
```

Expected: ファイルが存在し読み込める。実際の検証は Step 6 の push で行う。

- [ ] **Step 5: Commit**

```bash
git add .github README.md docs/README.md
git commit -m "ci: run the same dev.ps1 lanes on GitHub Actions"
```

- [ ] **Step 6: CI が green であることを確認する**

Run:

```bash
git push -u origin main
gh run list --limit 5
gh run watch
```

Expected: `ci-native` と `ci-sanitizers` の両方が success。失敗した場合は `gh run view --log-failed` でログを確認して修正する。

- [ ] **Step 7: CI が実際に失敗を検出することを確認する**

ブランチを切り、`native/src/ocvu_version.cpp` の `return OCVU_ABI_VERSION;` を `return 999;` に変えて push する。

Run: `gh pr create --fill && gh run watch`
Expected: `ci-native` が FAIL し、artifact に失敗内容を含む `native.xml` と `managed.xml` が入っていること。確認後、このブランチは破棄する。

---

## Self-Review

**Spec coverage（roadmap.md M0 の完了条件）**

| 完了条件 | 対応タスク |
| --- | --- |
| `tools/dev.ps1 test` 一発で L1 と L3 が通り、失敗時に非ゼロ終了 | Task 7 Step 6 / Step 7 |
| segfault が 30 秒以内に赤で返る | Task 4 Step 4（`harness.segfault_is_detected`） |
| 無限ループが 5 秒で赤で返る | Task 4 Step 4（`harness.hang_is_detected`） |
| ASan で use-after-free が検出される | Task 5 Step 4 / Step 5 |
| C++ 例外が status code と last-error に変換される | Task 3、Task 7（L1 と L3 の両方から検証） |
| `Runtime/Interop` と `Runtime/Core` が netstandard2.1 単体でコンパイルできる | Task 6 Step 5 / Step 6 |
| CI がローカルと同一コマンドで通り JUnit XML を artifact 化する | Task 8 Step 1 / Step 2 / Step 6 |
| すべての CI ジョブに `timeout-minutes` | Task 8 Step 1 / Step 2 |

**Global Constraints の遵守**

- `ocvu_` prefix / `CvUnity` namespace / `opencv_unity_native` — Task 1〜3、Task 6
- `com.ayutaz.opencv-unity-native` — Task 6 Step 1
- Unity 6000.x / netstandard2.1 / C# 9 — Task 6 Step 1・Step 4
- C++17 — Task 1 Step 3（`CMAKE_CXX_STANDARD 17`）
- UnityEngine 非依存 — Task 6 Step 4（shim）と Step 1（`noEngineReferences`）の二重の強制
- 固定サイズ型のみ — 全 ABI 関数が `int32_t` と `char*` のみ
- 例外を境界外へ出さない — Task 3
- Apache-2.0 — Task 1 Step 1、Task 6 Step 1
- CI がローカルと同一コマンド — Task 8
- OpenCV に依存しない — 全タスクで OpenCV のヘッダ・ライブラリを参照していない

**未解決事項（M1 以降で扱う）**

- `Runtime/Plugins/` へのネイティブバイナリ配置と Plugin Import Settings は M2 で扱う。M0 の L3 は `OCVU_NATIVE_DIR` で解決する
- リーク検出は MSVC ASan では不可能なため M3 の Linux レーンで導入する（Task 5 に注記済み）
- FetchContent の `GIT_TAG` はタグ名で固定している。commit hash への切り替えは M3 の再現性作業で行う

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-25-m0-tdd-harness.md`.
