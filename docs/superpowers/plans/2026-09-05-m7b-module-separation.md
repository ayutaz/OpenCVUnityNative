# M7 (b) — C ABI と C# の module 分離の実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `dnn` のような opt-in profile を後から足せるよう、native の CMake target と C# の assembly を module 単位に割り、**割っても配布する binary の公開面が 1 バイトも変わっていないこと**を機械が守る形にする。

**Architecture:** 先に**安全網**を作る —— 配布する binary が実際にエクスポートしているシンボルを読み、`bindings/spec/*.json` の関数一覧と**完全一致**することを要求する検査を足す。この網があってはじめて、CMake の作り替えが「何も落としていない」と言える。そのうえで (1) module ごとの OBJECT ライブラリに割り、(2) spec に `profile` を持たせ、profile が既定でないものは別 assembly・別クラスへ出す、(3) その assembly を `defineConstraints` で切る。

**Tech Stack:** CMake 3.25+ / .NET 8（生成器）/ Unity asmdef / PowerShell 7 / `dumpbin`（Windows）・`nm`（macOS / Linux）

**Spec:** [`2026-09-05-m7-profiles-and-performance.md`](./2026-09-05-m7-profiles-and-performance.md)

---

## (a) 完了後の見直し（2026-09-06）

**(a)（`2026-09-05-m7a-low-copy-and-benchmarks.md`）が完了したので、
この計画の前提を実測で洗い直した。** 変えたのは 2 点である。

| # | 崩れていた前提 | 直した場所 |
| --- | --- | --- |
| 1 | **到達性テストの生成器が profile を知らない。** Task 3 は `CsPInvokeEmitter` と `Program.cs` を分岐させるが、`ReachabilityEmitter` を触らない —— (c) が `dnn.json` を足した瞬間に Unity の 3 レーンが落ちる | **Task 3 に Step 4b を足した**。決定は spec の **D8** |
| 2 | **L3 の件数が 181 だった。** (a) が `AllocationTests` を足して 185 になった | Task 2 Step 3 の期待値。**数を写す形をやめ、着手時に測った値からの差分で書く** |

**変えなかったもの**: (b) が (a) の成果物（`RenderTextureConverter` /
`measure-package-size.ps1` / `CiVisibilityTests`）に触る箇所は無い。
`$ToolsTestScriptsFast` は (a) が 4 → 5 にしたが、この計画は**本数を写していない**
ので影響が無い（Task 1 Step 6）。

## Global Constraints

**spec の §3 を逐語で引く。全タスクの要件に暗黙に含まれる。**

- **C ABI が唯一の native contract。** `cv::Mat*` や STL 型を境界の外へ出さない
- **例外を ABI の外へ伝播させない。** 公開 ABI 関数は原則 `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で本体を囲む
- **境界の宣言を手で書かない。** `bindings/spec/*.json` が正本で、C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表は `./tools/dev.ps1 generate` が出す。手で足すと `./tools/dev.ps1 verify-generated` が落とす
- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。** `tests/Managed/CvUnity.Runtime.Shim/`（netstandard2.1）がビルドで機械的に強制する
- **この計画は公開 ABI を 1 本も増やさない。** `OCVU_ABI_VERSION` は 1 のままで、`docs/api-map.md` の本数は変わらない
- **`tools/opencv-config.psd1` の `Modules` を触らない。** 触ると構成ハッシュが変わり、6 platform 分の OpenCV を作り直すことになる（設計 D6）
- **すべての実装を TDD で行う**
- **`dev.ps1` のレーンは相互排他である。2 つ同時に走らせないこと**
- **OpenCV をローカルでビルドしない**（`block-local-opencv-build.sh` が拒否する）
- **`git add -A` / `git add .` は hook が拒否する。** ファイルを名指しで stage する
- **非 ASCII を出力する PowerShell スクリプトは、必ず先頭に** `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` **を置く**
- **生成物を手で編集しない**（`check-generated-file-edit.sh` がその場で指摘し、`check-staged-generated-file.sh` が commit を止める）
- **検査を足したり変えたりしたら、壊して落ちることを見る**（`prove-a-check-works` skill）
- **数を写さない。** module の一覧の正本は `bindings/spec/*.json` のファイル名である

---

## File Structure

| ファイル | 新規/変更 | 責任 |
| --- | --- | --- |
| `tools/verify-exported-symbols.ps1` | 新規 | **安全網。** 配布 binary のエクスポートが spec の関数一覧と完全一致することを要求する |
| `tools/tests/ExportedSymbols.Tests.ps1` | 新規 | 上が実際に落ちることを、合成した入力で毎回確かめる |
| `native/CMakeLists.txt` | 変更 | ソース一覧を module ごとの OBJECT ライブラリに割り、`OCVU_MODULES` から組み立てる |
| `native/modules.cmake` | 新規 | **module 名 → ソースの対応表。正本。** CMake から読む |
| `bindings/spec/schema.json` | 変更 | 任意の `profile` を許す（既定 `"standard"`） |
| `bindings/generator/Ocvu.Generator/SpecModel.cs` | 変更 | `ModuleSpec.Profile` を読む |
| `bindings/generator/Ocvu.Generator/CsPInvokeEmitter.cs` | 変更 | profile ごとに namespace・クラス名を変える |
| `bindings/generator/Ocvu.Generator/Program.cs` | 変更 | profile ごとに出力先ディレクトリを変える |
| `bindings/generator/Ocvu.Generator/ReachabilityEmitter.cs` | 変更 | **profile ごとに別ファイル・別クラスへ出す**（spec の D8）。いまは全 spec を平らに畳んで 1 ファイルに書いている |
| `tests/UnityProject/Assets/Tests/Shared.Dnn/CvUnity.Tests.Shared.Dnn.asmdef` | 新規 | 非既定 profile の到達性テストが入る assembly。`defineConstraints` で切る |
| `bindings/generator/Ocvu.Generator.Tests/ProfileTests.cs` | 新規 | 合成した spec で、profile が出力先とクラス名を変えることを見る |
| `Packages/.../Runtime/Interop/CvUnity.Interop.asmdef` | 変更 | 参照は変えない（既定 profile はここ） |
| `docs/abi-ownership-and-versioning.md` | 変更 | profile の規約を書く |
| `docs/roadmap.md` | 変更 | M7 決定 1・2 の状態を更新する |
| `.github/workflows/ci-native.yml` | 変更 | `verify-exported-symbols.ps1` を desktop 3 job に配線する |

---

## Task 1: 公開面の安全網（先に作る）

**Files:**
- Create: `tools/verify-exported-symbols.ps1`
- Create: `tools/tests/ExportedSymbols.Tests.ps1`
- Modify: `tools/dev.ps1`（`$ToolsTestScriptsFast` に配線）

**Interfaces:**
- Consumes: `bindings/spec/*.json`（既存）、`build/<preset>/native/**/opencv_unity_native.{dll,dylib,so}`
- Produces: 標準出力に `==> exported symbols: <n> (spec: <n>)`、食い違いで exit 1

**なぜ最初か**: **Task 2 と 3 は「作り替えても公開面が変わらない」ことを主張する。
その主張を守る機械が先に無ければ、作り替えは検証されない。** 網を作ってから跳ぶ。

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/ExportedSymbols.Tests.ps1`:

```powershell
#!/usr/bin/env pwsh
# verify-exported-symbols.ps1 が、食い違いを実際に捕まえることを見る。
#
# **実物の binary は使わない。** シンボルの一覧を外から与えられる形にして
# あるので、合成した入力で全分岐を毎回通せる（実物に頼ると、
# 「たまたま一致している」ときに分岐が 1 本も動かない）。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repoRoot 'tools/verify-exported-symbols.ps1'
$failures = 0

# **一時ファイルの名前を固定しない**（check-shared-temp-paths.sh が見ている）。
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-exports-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Test-Case {
    param([string]$Name, [string[]]$Symbols, [bool]$ShouldPass)

    $file = Join-Path $work ((New-Guid).ToString() + '.txt')
    Set-Content -LiteralPath $file -Value $Symbols -Encoding utf8

    & pwsh -NoProfile -File $script -SymbolListPath $file 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)

    if ($ok -eq $ShouldPass) {
        Write-Host "PASS: $Name"
        return 0
    }
    Write-Host "FAIL: $Name (exit=$LASTEXITCODE, 期待は $(if ($ShouldPass) { '成功' } else { '失敗' }))"
    return 1
}

try {
    # spec に在る関数名を正本から読む。**写さない。**
    $specDir = Join-Path $repoRoot 'bindings/spec'
    $expected = @(
        Get-ChildItem -LiteralPath $specDir -Filter '*.json' |
            Where-Object { $_.Name -ne 'schema.json' } |
            ForEach-Object {
                (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).functions.name
            }
    ) | Sort-Object -Unique

    if ($expected.Count -lt 10) {
        Write-Error "spec から関数名が拾えていない（$($expected.Count) 件）"
        exit 1
    }

    $failures += Test-Case '完全一致は通る' $expected $true
    $failures += Test-Case '1 本足りないと落ちる' ($expected | Select-Object -Skip 1) $false
    $failures += Test-Case '知らないものが 1 本あると落ちる' ($expected + 'ocvu_not_in_spec') $false
    $failures += Test-Case '空は落ちる' @() $false
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Error "$failures 件失敗"; exit 1 }
Write-Host '==> ExportedSymbols.Tests: OK'
```

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/tests/ExportedSymbols.Tests.ps1
```

期待: `verify-exported-symbols.ps1` が存在しないので落ちる。

- [ ] **Step 3: `verify-exported-symbols.ps1` を実装する**

```powershell
#!/usr/bin/env pwsh
param(
    # 実物の binary から読む場合。
    [string]$LibraryPath,
    # シンボル一覧を直接与える場合（テスト用。1 行 1 名）。
    [string]$SymbolListPath
)

# 配布する binary がエクスポートしているシンボルが、spec の関数一覧と
# **完全一致**することを要求する。
#
# **両向きに効く。**
#   - spec に在るのにエクスポートされていない → 利用者が呼べない関数を宣言している
#   - エクスポートされているのに spec に無い  → 契約の外に出ている面がある
#
# **数を写さない。** 期待する一覧は bindings/spec/*.json から毎回読む。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent $PSScriptRoot

# --- 期待する一覧を正本から読む ---
$specDir = Join-Path $repoRoot 'bindings/spec'
$expected = @(
    Get-ChildItem -LiteralPath $specDir -Filter '*.json' |
        Where-Object { $_.Name -ne 'schema.json' } |
        ForEach-Object {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).functions.name
        }
) | Sort-Object -Unique

# **0 件を「一致した」と読まない。** spec が読めていないなら、
# どんな binary とも「一致」してしまう。
if ($expected.Count -eq 0) {
    Write-Error 'spec から関数名が 1 つも拾えなかった。走査が効いていない'
    exit 1
}

# --- 実際の一覧を得る ---
if ($SymbolListPath) {
    $actual = @(Get-Content -LiteralPath $SymbolListPath |
        Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
} elseif ($LibraryPath) {
    if (-not (Test-Path -LiteralPath $LibraryPath)) {
        Write-Error "binary が無い: $LibraryPath"
        exit 1
    }
    $actual = @(Get-ExportedSymbol -Path $LibraryPath)
} else {
    Write-Error '-LibraryPath か -SymbolListPath のどちらかが要る'
    exit 1
}

$actual = @($actual | Where-Object { $_ -like 'ocvu_*' }) | Sort-Object -Unique

# --- 突き合わせる ---
$missing = @($expected | Where-Object { $_ -notin $actual })
$extra   = @($actual   | Where-Object { $_ -notin $expected })

Write-Host "==> exported symbols: $($actual.Count) (spec: $($expected.Count))"

if ($missing.Count -gt 0) {
    Write-Host 'spec に在るのにエクスポートされていない:'
    $missing | ForEach-Object { Write-Host "  - $_" }
}
if ($extra.Count -gt 0) {
    Write-Host 'エクスポートされているのに spec に無い:'
    $extra | ForEach-Object { Write-Host "  + $_" }
}

if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
    Write-Error "公開面が spec と食い違う（不足 $($missing.Count) / 余剰 $($extra.Count)）"
    exit 1
}
```

**`Get-ExportedSymbol` を同じファイルの先頭（`param` の直後）に定義する:**

```powershell
function Get-ExportedSymbol {
    param([Parameter(Mandatory = $true)][string]$Path)

    # **道具が無いことを「合格」にしない。** 見つからなければ落とす ——
    # tools/verify-artifact-linkage.ps1 が SKIP を出すのとは扱いを変える。
    # あちらは検査の対象が複数あるが、こちらは 1 つで、
    # **SKIP は「公開面を確かめていない」と同義である。**
    if ($IsWindows) {
        $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
        if (-not $dumpbin) {
            # Visual Studio の配下を探す。
            $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
            if (Test-Path -LiteralPath $vswhere) {
                $vs = & $vswhere -latest -property installationPath
                $found = Get-ChildItem -Path $vs -Filter 'dumpbin.exe' -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($found) { $dumpbin = $found.FullName }
            }
        }
        if (-not $dumpbin) {
            Write-Error 'dumpbin が見つからない。公開面を確かめられないので落とす'
            exit 1
        }
        $out = & $dumpbin /EXPORTS $Path 2>&1
        # dumpbin の出力は「序数 / RVA / 名前」の 3 列。名前だけを取る。
        return @($out | ForEach-Object {
            if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') { $Matches[1] }
        })
    }

    $nm = Get-Command nm -ErrorAction SilentlyContinue
    if (-not $nm) {
        Write-Error 'nm が見つからない。公開面を確かめられないので落とす'
        exit 1
    }
    # -g は外部シンボルだけ、--defined-only は定義されているものだけ。
    $out = & nm -g --defined-only $Path 2>&1
    return @($out | ForEach-Object {
        if ($_ -match '^\S+\s+[TtDd]\s+_?(\S+)') { $Matches[1] }
    })
}
```

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/tests/ExportedSymbols.Tests.ps1
```

期待: 4 件とも PASS。

- [ ] **Step 5: 実物の binary に当てる**

```
pwsh -NoProfile -File tools/dev.ps1 build
pwsh -NoProfile -File tools/verify-exported-symbols.ps1 -LibraryPath build/windows-x64-debug/native/Debug/opencv_unity_native.dll
```

期待: `==> exported symbols: N (spec: N)` で exit 0。

**一致しなかった場合、それは今日の欠陥である** —— 直してから先へ進むこと。
**この検査は「作り替えても変わらない」を守るためのものなので、
作り替える前から食い違っていては意味を成さない。**

- [ ] **Step 6: 速いレーンと CI に配線する**

`tools/dev.ps1` の `$ToolsTestScriptsFast` に `ExportedSymbols.Tests.ps1` を足す。
**`OpenCvConfig.Tests.ps1` が配線を見ているので、足さないとそちらが落ちる** ——
落ちることを先に確かめること。

`.github/workflows/ci-native.yml` の desktop 3 job（Windows / macOS / Linux）に、
ビルドの直後の step として足す:

```yaml
      - name: Verify the exported surface matches the spec
        shell: pwsh
        run: |
          ./tools/verify-exported-symbols.ps1 -LibraryPath (
            Get-ChildItem -Path build -Recurse -Include 'opencv_unity_native.dll','libopencv_unity_native.dylib','libopencv_unity_native.so' |
              Select-Object -First 1 -ExpandProperty FullName)
```

> **クロスの 3 job（Android / iOS / Web）には配線しない。** Android の `.so` は
> host の `nm` で読めるが、iOS と Web は静的ライブラリで「エクスポート」という
> 概念が違う。**配線しない理由を step のコメントに書くこと** ——
> 黙って外すと、次の人が「なぜここだけ無いのか」を調べ直すことになる。

- [ ] **Step 7: コミット**

```bash
git add tools/verify-exported-symbols.ps1 tools/tests/ExportedSymbols.Tests.ps1 tools/dev.ps1 .github/workflows/ci-native.yml
git commit -m "test(m7b): 配布 binary の公開面が spec と完全一致することを要求する

**これは Task 2/3 の安全網である。** 作り替えが「何も落としていない」ことは、
公開面を機械が見ていて初めて主張できる。

**両向きに効く**: spec に在るのにエクスポートされていなければ利用者が
呼べない関数を宣言していることになり、逆なら契約の外に出ている面がある。

**道具が無いことを合格にしない** —— dumpbin / nm が見つからなければ落とす。
SKIP は「公開面を確かめていない」と同義である。

**負の対照**: 完全一致は通り、1 本抜くと落ち、知らないものを足すと落ち、
空は落ちる。4 通りとも ExportedSymbols.Tests.ps1 が毎回実行する。"
```

---

## Task 2: native を module ごとの OBJECT ライブラリに割る

**Files:**
- Create: `native/modules.cmake`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: `tools/verify-exported-symbols.ps1`（Task 1）
- Produces: CMake 変数 `OCVU_MODULES`（既定は `native/modules.cmake` の全 module）と、
  module ごとの OBJECT ライブラリ `ocvu_obj_<module>`

**何を成立させるか**: **module を 1 つ外すと、その module の関数だけが binary から消える。**
これが「profile」の native 側の実体である。

- [ ] **Step 1: 対応表を作る**

`native/modules.cmake`:

```cmake
# module 名 → その module を実装するソース。**正本である。**
#
# **spec のファイル名と対応する** —— bindings/spec/<module>.json が 1 つあれば、
# ここに <module> の項が 1 つある。ずれると Task 3 の検査が落ちる。
#
# **1 つの用途が複数 module にまたがることがある。** ocvu_calibration.cpp は
# objdetect / calib / imgproc の 3 つに関数を出すが、実装は 1 ファイルである。
# **そういうファイルは、最も外せない module に置く** —— ここでは calib。
# 外せる単位を作るのが目的なので、「どの module の一部か」より
# 「どれを外したら一緒に消えるべきか」で決める。

set(OCVU_MODULE_infra
    src/ocvu_version.cpp
    src/ocvu_error.cpp
    src/ocvu_status.cpp
    src/ocvu_debug.cpp
    src/ocvu_opencv_info.cpp
)

set(OCVU_MODULE_core
    src/ocvu_mat_table.cpp
    src/ocvu_mat.cpp
    src/ocvu_mat_buffer.cpp
    src/ocvu_core_ops.cpp
)

set(OCVU_MODULE_imgproc
    src/ocvu_imgproc.cpp
    src/ocvu_imgproc_ops.cpp
    src/ocvu_imgproc_shape.cpp
)

set(OCVU_MODULE_imgcodecs  src/ocvu_imgcodecs.cpp)
set(OCVU_MODULE_objdetect  src/ocvu_objdetect.cpp src/ocvu_aruco.cpp)
set(OCVU_MODULE_features   src/ocvu_features.cpp src/ocvu_matching.cpp)
set(OCVU_MODULE_geometry   src/ocvu_geometry.cpp src/ocvu_pose.cpp)
set(OCVU_MODULE_calib      src/ocvu_calibration.cpp)
set(OCVU_MODULE_stereo     src/ocvu_stereo.cpp)

# **infra と core は外せない。** last-error も status も Mat も、
# 他の全 module が使う。外せる単位から明示的に除く。
set(OCVU_REQUIRED_MODULES infra core)

# 既定で全部入れる。profile はこの一覧から引く形で表す。
set(OCVU_ALL_MODULES
    infra core imgproc imgcodecs objdetect features geometry calib stereo)
```

> **`OCVU_ALL_MODULES` は module 名を写している。** `bindings/spec/*.json` が
> 正本なので、**Task 3 の検査がこの一覧と spec のファイル名が一致することを要求する。**
> CMake から glob すると、生成物の一覧が構成に混ざって再現性が落ちるので、
> **写したうえで機械に守らせる**という形を採る。

- [ ] **Step 2: 失敗する状態を作る**

`native/CMakeLists.txt` の `set(OCVU_SOURCES ...)` を消し、代わりに:

```cmake
include(${CMAKE_CURRENT_SOURCE_DIR}/modules.cmake)

# 呼ぶ側が絞れる。既定は全部。
if(NOT DEFINED OCVU_MODULES)
    set(OCVU_MODULES ${OCVU_ALL_MODULES})
endif()

# **外せない module を黙って足さない。** 落とす ——
# 「infra を外したのに動いた」は、外したつもりで外れていないということである。
foreach(required ${OCVU_REQUIRED_MODULES})
    list(FIND OCVU_MODULES ${required} _idx)
    if(_idx EQUAL -1)
        message(FATAL_ERROR
            "OCVU_MODULES に必須の module '${required}' が無い。"
            "infra と core は他の全 module が使うので外せない")
    endif()
endforeach()

set(OCVU_SOURCES "")
foreach(mod ${OCVU_MODULES})
    if(NOT DEFINED OCVU_MODULE_${mod})
        message(FATAL_ERROR
            "module '${mod}' が modules.cmake に無い。"
            "bindings/spec/${mod}.json を足したなら modules.cmake にも足すこと")
    endif()
    list(APPEND OCVU_SOURCES ${OCVU_MODULE_${mod}})
endforeach()

if(OCVU_SOURCES STREQUAL "")
    message(FATAL_ERROR "OCVU_SOURCES が空。modules.cmake の読み込みが効いていない")
endif()
```

- [ ] **Step 3: ビルドして、公開面が変わっていないことを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 build
pwsh -NoProfile -File tools/verify-exported-symbols.ps1 -LibraryPath build/windows-x64-debug/native/Debug/opencv_unity_native.dll
```

期待: **Task 1 Step 5 と同じ件数**で exit 0。
**これが「作り替えても公開面が変わっていない」の証拠である。**

```
pwsh -NoProfile -File tools/dev.ps1 test
```

期待: exit 0。**件数は着手前に測った値から 1 件も動かない** ——
この Task は作り替えであって、テストを足しも減らしもしないからである。
**数をここに写さない**（正本は `CLAUDE.md` の `test-native` / `test-managed` の行で、
(a) が L3 を 181 → 185 にしたときこの行が古くなった）。

- [ ] **Step 4: 「外せる」ことを実証する**

**これが `prove-a-check-works` の負の対照にあたる。** 割った意味は、
**外せることでしか確かめられない。**

```
cmake --preset windows-x64-debug -DOCVU_MODULES="infra;core;imgproc"
cmake --build build/windows-x64-debug --config Debug --target opencv_unity_native
pwsh -NoProfile -File tools/verify-exported-symbols.ps1 -LibraryPath build/windows-x64-debug/native/Debug/opencv_unity_native.dll
```

期待: **exit 1**。`stereo` / `calib` / `features` / `geometry` / `objdetect` /
`imgcodecs` の関数が「spec に在るのにエクスポートされていない」と名指しで並ぶ。

**これは 2 つを同時に証明する**: module を外すと本当に消えること、
そして Task 1 の検査が実物でそれを捕まえること。

必須 module を外すと configure が落ちることも見る:

```
cmake --preset windows-x64-debug -DOCVU_MODULES="imgproc"
```

期待: `OCVU_MODULES に必須の module 'infra' が無い` で **configure が失敗**。

**既定に戻すこと:**

```
cmake --preset windows-x64-debug -UOCVU_MODULES
pwsh -NoProfile -File tools/dev.ps1 build
```

- [ ] **Step 5: コミット**

```bash
git add native/modules.cmake native/CMakeLists.txt
git commit -m "refactor(m7b): native のソース一覧を module 単位に割る

**配布する binary は変わらない** —— Task 1 の公開面検査が、割る前と
同じ件数で通ることを確かめた。

**割った意味は「外せること」でしか確かめられないので、実際に外した**:
OCVU_MODULES を infra/core/imgproc に絞ると、他 6 module の関数が
「spec に在るのにエクスポートされていない」と名指しで並んで落ちた。
必須の infra を外すと configure の時点で落ちる。

**1 つの用途が複数 module にまたがるファイルの置き場所は、
「どの module の一部か」ではなく「どれを外したら一緒に消えるべきか」で
決めた** —— ocvu_calibration.cpp は 3 module に関数を出すが calib に置く。"
```

---

## Task 3: spec に profile を持たせ、生成器を分岐させる

**Files:**
- Modify: `bindings/spec/schema.json`
- Modify: `bindings/generator/Ocvu.Generator/SpecModel.cs`
- Modify: `bindings/generator/Ocvu.Generator/CsPInvokeEmitter.cs`
- Modify: `bindings/generator/Ocvu.Generator/Program.cs`
- Modify: `bindings/generator/Ocvu.Generator/ReachabilityEmitter.cs`
- Create: `tests/UnityProject/Assets/Tests/Shared.Dnn/CvUnity.Tests.Shared.Dnn.asmdef`
- Create: `bindings/generator/Ocvu.Generator.Tests/ProfileTests.cs`
- Modify: `tools/tests/BindingGenerator.Tests.ps1`

**Interfaces:**
- Consumes: `ModuleSpec`（既存）、`SpecModel.Load`（既存）
- Produces:
  - `ModuleSpec.Profile` → `string`（既定 `"standard"`）
  - `CsPInvokeEmitter.Emit(ModuleSpec)` は profile が `"standard"` 以外なら
    namespace `CvUnity.Interop.<Pascal(profile)>`、クラス `NativeMethods<Pascal(profile)>` を出す
  - `Program.cs` は profile が `"standard"` 以外なら
    `Runtime/Interop.<Pascal(profile)>/NativeMethods.<Pascal(module)>.g.cs` へ書く
  - `ReachabilityEmitter.Emit(specs, profile)` と `OutputPathFor(profile)`。
    **非既定 profile は `Assets/Tests/Shared.<Pascal>/AbiReachabilityChecks.<Pascal>.g.cs` へ、
    `CvUnity.Tests.Shared.<Pascal>` assembly（`defineConstraints`）の中に出る**（Step 4b、spec の D8）。
    **(c) はこれに乗る** —— 乗らないと `dnn.json` を足した瞬間に Unity の 3 レーンが落ちる

**なぜ別クラスにするか**: **`partial class` は assembly を跨げない。**
`NativeMethods` を別 assembly でも `partial` にすることはできないので、
profile ごとに別の型にする。**`internal` のままにする** ——
`AssemblyInfo.cs` が「public にはしない。P/Invoke 宣言は実装詳細であり、
利用者向けの API ではない」と明記している。

- [ ] **Step 1: 失敗するテストを書く**

`bindings/generator/Ocvu.Generator.Tests/ProfileTests.cs`:

```csharp
using System;
using System.IO;
using Xunit;

public class ProfileTests
{
    /// <summary>
    /// **profile を書かない spec は "standard" になる。**
    /// 既存の 9 つの spec はどれも profile を書いていないので、
    /// これが崩れると全部が別 assembly へ動く。
    /// </summary>
    [Fact]
    public void AProfileIsStandardWhenTheSpecDoesNotSayOtherwise()
    {
        var spec = LoadSynthetic(profile: null);
        Assert.Equal("standard", spec.Profile);
    }

    [Fact]
    public void AnExplicitProfileIsRead()
    {
        var spec = LoadSynthetic(profile: "dnn");
        Assert.Equal("dnn", spec.Profile);
    }

    /// <summary>
    /// **standard は今までどおりの場所・今までどおりのクラス名。**
    /// ここが変わると、既存の 10 個の生成物が全部動く。
    /// </summary>
    [Fact]
    public void StandardEmitsIntoTheExistingClass()
    {
        var spec = LoadSynthetic(profile: null);
        var text = CsPInvokeEmitter.Emit(spec);

        Assert.Contains("namespace CvUnity.Interop", text);
        Assert.Contains("internal static partial class NativeMethods", text);
        Assert.DoesNotContain("NativeMethodsDnn", text);
    }

    /// <summary>
    /// **非 standard は別 namespace・別クラス。**
    /// partial class は assembly を跨げないので、同じ型にはできない。
    /// </summary>
    [Fact]
    public void ANonStandardProfileEmitsIntoItsOwnClass()
    {
        var spec = LoadSynthetic(profile: "dnn");
        var text = CsPInvokeEmitter.Emit(spec);

        Assert.Contains("namespace CvUnity.Interop.Dnn", text);
        Assert.Contains("internal static partial class NativeMethodsDnn", text);
    }

    /// <summary>
    /// **知らない profile は落とす。**
    /// 綴り間違いを黙って新しい profile として受けると、
    /// その module の宣言がどこからも参照されない assembly へ静かに消える。
    /// </summary>
    [Fact]
    public void AnUnknownProfileIsRejected()
    {
        var ex = Assert.Throws<SpecFormatException>(() => LoadSynthetic(profile: "dnnn"));
        Assert.Contains("dnnn", ex.Message);
    }

    private static ModuleSpec LoadSynthetic(string profile)
    {
        var profileLine = profile is null ? "" : $"\"profile\": \"{profile}\",";
        var json = $$"""
        {
          "module": "probe",
          {{profileLine}}
          "functions": [
            {
              "name": "ocvu_probe_thing",
              "summary": "合成した spec。生成器の分岐を見るためだけに存在する。",
              "returns": "ocvu_status",
              "csReturns": "int",
              "wrapInTryBarrier": true,
              "params": []
            }
          ]
        }
        """;

        var path = Path.Combine(
            Path.GetTempPath(), Guid.NewGuid().ToString() + ".json");
        File.WriteAllText(path, json);
        try { return SpecModel.LoadFile(path); }
        finally { File.Delete(path); }
    }
}
```

> **`SpecModel.LoadFile(string)` と `SpecFormatException` の実際の名前を、
> 着手時に `bindings/generator/Ocvu.Generator/SpecModel.cs` で確かめること。**
> **推測で書かない** —— 既存の `SpecSchemaTests.cs` が同じものを使っているので、
> そこから写すのが確実である。

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: `ModuleSpec.Profile` が未定義でコンパイルエラー。

- [ ] **Step 3: `schema.json` に `profile` を足す**

`bindings/spec/schema.json` のトップレベル `properties` に:

```json
    "profile": {
      "type": "string",
      "enum": ["standard", "dnn"],
      "description": "この module がどの profile に属するか。書かなければ standard。standard 以外は別 assembly へ出る"
    }
```

**`enum` で閉じる。** 開いておくと綴り間違いが新しい profile になり、
その module の宣言がどこからも参照されない assembly へ静かに消える。
**既存の型表（`SpecModel.AllowedCsTypes`）が閉じているのと同じ理由である。**

- [ ] **Step 4: `SpecModel` と emitter を直す**

`SpecModel.cs` の `ModuleSpec` に:

```csharp
    /// <summary>
    /// この module がどの profile に属するか。spec が書かなければ "standard"。
    /// **standard 以外は別 assembly・別クラスへ出る**（partial class は
    /// assembly を跨げないため）。
    /// </summary>
    public string Profile { get; init; } = "standard";
```

読み込み側で、`enum` に無い値は `SpecFormatException` にする。
**schema 検証が先に落とすなら、そちらのメッセージに profile 名が入ることを確かめる**
—— `prove-a-check-works` の「手前に別の門がある」節が、
**`System.Text.Json` が先に落とすので足した検査は 1 度も動かなかった**という実例を持つ。

`CsPInvokeEmitter.Emit` の namespace とクラス名を profile で分岐させる:

```csharp
        var isStandard = spec.Profile == "standard";
        var suffix = isStandard
            ? ""
            : char.ToUpperInvariant(spec.Profile[0]) + spec.Profile[1..];

        sb.AppendLine(isStandard
            ? "namespace CvUnity.Interop"
            : $"namespace CvUnity.Interop.{suffix}");
        // ...
        sb.AppendLine($"    internal static partial class NativeMethods{suffix}");
```

`Program.cs` の出力先を分岐させる:

```csharp
    var interopDir = spec.Profile == "standard"
        ? "Interop"
        : "Interop." + char.ToUpperInvariant(spec.Profile[0]) + spec.Profile[1..];
    outputs.Add((Path.Combine(repoRoot, "Packages", "com.ayutaz.opencv-unity-native",
                              "Runtime", interopDir, $"NativeMethods.{pascal}.g.cs"),
                 CsPInvokeEmitter.Emit(spec)));
```

- [ ] **Step 4b: `ReachabilityEmitter` を profile ごとに分ける**

**この step は (a) 完了後の見直しで足した。決定は spec の D8 にある。**
**番号を 4b にしてあるのは、Step 7 / Step 8 が互いを番号で参照しているためで、
振り直すと参照が壊れる。**

現状は**全 spec を平らに畳んで 1 ファイルに書いている**（実測）:

```csharp
// ReachabilityEmitter.cs:53
var fns = specs.SelectMany(s => s.Functions)...
// :72
sb.AppendLine("using CvUnity.Interop;");
```

**このままだと (c) が `dnn.json` を足した瞬間に、
`NativeMethods.ocvu_net_read(...)` という存在しない呼び出しが
`CvUnity.Tests.Shared` に書き出され、EditMode / Standalone / Web が
同時にコンパイルできなくなる。**

`Emit` を profile ごとに 1 回呼ぶ形に変える:

```csharp
    /// <summary>
    /// **profile ごとに 1 ファイル出す。** 既定 profile は今までどおり
    /// AbiReachabilityChecks.g.cs へ、非既定は
    /// Assets/Tests/Shared.<Profile>/AbiReachabilityChecks.<Profile>.g.cs へ。
    ///
    /// **1 ファイルに #if で同居させない。** そちらだと CvUnity.Tests.Shared が
    /// CvUnity.Interop.Dnn を参照することになり、define が立っていないとき
    /// 参照先がコンパイルされない。**Unity がその参照を黙って落とすかは
    /// 測っていない**（spec の D8）。
    /// </summary>
    public static string Emit(IReadOnlyList<ModuleSpec> specs, string profile)
```

**名前は Pascal 化した profile 名を後ろに繋げる**（`dnn` なら `Dnn`）。
**山括弧に見える書き方をしない** —— C# のジェネリクスと読み違えられる:

| | 既定 profile | `dnn` profile |
| --- | --- | --- |
| using | `using CvUnity.Interop;` | `using CvUnity.Interop.Dnn;` |
| クラス | `AbiReachabilityChecks` | `AbiReachabilityChecksDnn` |
| 呼ぶ先 | `NativeMethods` | `NativeMethodsDnn` |

**`OutputPath` という既存の定数を消したり付け替えたりしない。**
**4 つの consumer がある**（実測）—— `ApiMapEmitter.cs:107` がこの値を
`docs/api-map.md` の本文へ書き込み、`ApiMapEmitterTests.cs` が 4 箇所で
assert している。**付け替えると生成物の中身が変わり、
`verify-generated` が無関係な差分で落ちる。**

```csharp
    /// 既定 profile の出力先。**この定数の値は変えない**（ApiMapEmitter が
    /// docs/api-map.md へ書き込んでおり、そのテストが 4 箇所で見ている）。
    public const string OutputPath = /* いまの値のまま */;

    /// profile ごとの出力先。既定 profile では OutputPath をそのまま返す。
    public static string OutputPathFor(string profile) =>
        profile == "standard" ? OutputPath : /* Shared.<Pascal>/... */;
```

`Program.cs` は profile の集合を spec から導いて回す。**一覧を書かない**:

```csharp
foreach (var profile in specs.Select(s => s.Profile).Distinct().OrderBy(p => p))
{
    outputs.Add((Path.Combine(repoRoot, ReachabilityEmitter.OutputPathFor(profile)),
                 ReachabilityEmitter.Emit(specs, profile)));
}
```

**`--list-outputs` にも自動で載る**（Step 8 が見ている「消えるべき生成物」の
検出も、そのまま効く）。

**profile 側の `AssemblyInfo.cs` に `InternalsVisibleTo` が 1 本要る。**
Step 6 は「`CvUnity.Interop.Dnn` には出さない」と決めるが、
**到達性テスト宛の 1 本だけは例外である** —— 既定 profile 側が同じ例外を
既に持っており（`Runtime/Interop/AssemblyInfo.cs` の末尾）、
**理由は profile が変わっても変わらない。**

```csharp
// Packages/.../Runtime/Interop.Dnn/AssemblyInfo.cs
// **到達性テストだけが例外である。** 理由は Runtime/Interop/AssemblyInfo.cs の
// 末尾と同じで、公開 API 経由では「どの entry point が呼ばれたか」を
// spec から機械的に導けない。**profile が変わっても、その理由は変わらない。**
[assembly: InternalsVisibleTo("CvUnity.Tests.Shared.Dnn")]
```

**負の対照を取る。** 合成した spec（`profile: "test"` を 1 つ持つもの）で
生成器を走らせ、**2 ファイル出ること**・**既定側のファイルに `test` profile の
関数が 1 本も現れないこと**を `ProfileTests.cs` で見る。
**「既定側が変わらない」だけを見ない** —— それは分岐が丸ごと死んでいても真になる。

- [ ] **Step 5: テストが通り、生成物が 1 バイトも動かないことを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
pwsh -NoProfile -File tools/dev.ps1 verify-generated
```

期待: `Ocvu.Generator.Tests` が 106 → **111**。
**`verify-generated` は「生成物は最新」と言うこと** ——
既存の 9 module はどれも profile を書いていないので `standard` になり、
**出力は 1 バイトも変わらないはずである。**

**変わったら、それは既定の解釈が壊れているということである。** 直してから進む。

- [ ] **Step 6: module 名と spec のファイル名の一致を要求する**

`tools/tests/BindingGenerator.Tests.ps1` に足す:

```powershell
# **native/modules.cmake の module 一覧が、spec のファイル名と一致すること。**
#
# CMake 側は写しである（glob すると生成物が構成に混ざって再現性が落ちる）。
# **写しを持つなら、機械が正本と突き合わせる。**
$specModules = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'bindings/spec') -Filter '*.json' |
        Where-Object { $_.Name -ne 'schema.json' } |
        ForEach-Object { $_.BaseName }
) | Sort-Object

$cmakeText = Get-Content -LiteralPath (Join-Path $repoRoot 'native/modules.cmake') -Raw
if ($cmakeText -notmatch '(?ms)set\(OCVU_ALL_MODULES\s+(.*?)\)') {
    Write-Host 'FAIL: modules.cmake から OCVU_ALL_MODULES を取り出せなかった'
    $failures++
} else {
    $cmakeModules = @($Matches[1] -split '\s+' |
        Where-Object { $_ -ne '' }) | Sort-Object

    # **0 件を「一致」と読まない。**
    if ($cmakeModules.Count -eq 0) {
        Write-Host 'FAIL: OCVU_ALL_MODULES が空。抽出が効いていない'
        $failures++
    } elseif (Compare-Object $specModules $cmakeModules) {
        Write-Host 'FAIL: modules.cmake と bindings/spec の module 一覧が食い違う'
        Compare-Object $specModules $cmakeModules |
            ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
        $failures++
    } else {
        Write-Host "PASS: module 一覧が一致（$($cmakeModules.Count) 件）"
    }
}
```

- [ ] **Step 7: 負の対照を取る**

**先にコミットしてから壊す。**

壊し方 1 —— `native/modules.cmake` の `OCVU_ALL_MODULES` から `stereo` を消す:

```
pwsh -NoProfile -File tools/dev.ps1 test-tools
```

期待: 「modules.cmake と bindings/spec の module 一覧が食い違う」で **FAIL**。

壊し方 2 —— `bindings/spec/stereo.json` に `"profile": "dnn"` を足す:

```
pwsh -NoProfile -File tools/dev.ps1 generate
```

期待: `Runtime/Interop.Dnn/NativeMethods.Stereo.g.cs` が**新しく現れる**。
`Runtime/Interop/NativeMethods.Stereo.g.cs` は残るので、
**`verify-generated` は「古い生成物が残っている」を見ていない**ことが分かる。

> **これは発見であって欠陥ではない** —— 生成器は「出すべき物」を申告するが、
> 「出すべきでない物」は知らない。**Step 8 でそれを塞ぐ。**

**両方を戻すこと**（`git checkout -- bindings/spec/stereo.json native/modules.cmake`
の後に `dev.ps1 generate`）。

- [ ] **Step 8: 「消えるべき生成物」を検出する**

`tools/tests/BindingGenerator.Tests.ps1` に足す:

```powershell
# **生成物のディレクトリに、申告に無いファイルが残っていないこと。**
#
# Step 7 の壊し方 2 で分かった穴を塞ぐ。生成器は「出すべき物」を
# --list-outputs で申告するが、**profile を変えると前の場所に古い物が残る。**
# 残った物は「生成物である」と名乗ったまま、誰も再生成しない。
$declared = @(& dotnet run --project (Join-Path $repoRoot 'bindings/generator/Ocvu.Generator') -- --list-outputs)
$interopRoot = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime'
$onDisk = @(
    Get-ChildItem -LiteralPath $interopRoot -Recurse -Filter '*.g.cs' -ErrorAction SilentlyContinue |
        ForEach-Object {
            [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/')
        }
)

if ($onDisk.Count -eq 0) {
    Write-Host 'FAIL: .g.cs が 1 つも見つからない。走査が効いていない'
    $failures++
} else {
    $orphans = @($onDisk | Where-Object { $_ -notin $declared })
    if ($orphans.Count -gt 0) {
        Write-Host 'FAIL: 生成器が申告していない .g.cs が残っている:'
        $orphans | ForEach-Object { Write-Host "  $_" }
        $failures++
    } else {
        Write-Host "PASS: 残留した生成物は無い（$($onDisk.Count) 件）"
    }
}
```

- [ ] **Step 9: コミット**

```bash
git add bindings/spec/schema.json bindings/generator/Ocvu.Generator/SpecModel.cs bindings/generator/Ocvu.Generator/CsPInvokeEmitter.cs bindings/generator/Ocvu.Generator/Program.cs bindings/generator/Ocvu.Generator.Tests/ProfileTests.cs tools/tests/BindingGenerator.Tests.ps1
git commit -m "feat(m7b): spec に profile を持たせ、非 standard を別 assembly へ出す

**partial class は assembly を跨げない**ので、profile ごとに別の型にする。
internal のままにする —— AssemblyInfo.cs が「P/Invoke 宣言は実装詳細であり
利用者向けの API ではない」と明記している。

**profile の enum を閉じた。** 開いておくと綴り間違いが新しい profile になり、
その module の宣言がどこからも参照されない assembly へ静かに消える。

**既存の 9 module は 1 バイトも動いていない**（verify-generated で確認）。

**負の対照を取ったら穴が 1 つ見つかった**: profile を変えると前の場所に
古い生成物が残り、それは「生成物である」と名乗ったまま誰も再生成しない。
生成器の申告に無い .g.cs を落とす検査を足して塞いだ。"
```

---

## Task 4: profile を切る asmdef と、その効き目

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/CvUnity.Interop.Dnn.asmdef`（**中身は空でよい**）
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/AssemblyInfo.cs`
- Create: `tests/UnityProject/Assets/Tests/EditMode/ProfileGatingTests.cs`

**Interfaces:**
- Consumes: Task 3 の出力先分岐
- Produces: `CvUnity.Interop.Dnn` assembly（`defineConstraints: ["OCVU_PROFILE_DNN"]`）

**なぜ空の asmdef を先に置くか**: **(c) が着手する前に、切り替えの機構が
働くことを確かめておく。** (c) の中で機構と中身を同時に作ると、
壊れたときにどちらが壊れたか切り分けられない（M5 で同じ判断をしている）。

- [ ] **Step 1: 失敗するテストを書く**

`tests/UnityProject/Assets/Tests/EditMode/ProfileGatingTests.cs`:

```csharp
using System.Linq;
using NUnit.Framework;
using UnityEditor.Compilation;

/// <summary>
/// **profile の切り替えが Unity のコンパイル単位として効いていること。**
///
/// PluginGatingTests が「Unity が自分の platform の plugin だけを有効にする」
/// ことを PluginImporter に問うのと同じ形で、こちらは
/// **assembly の定義を Unity 自身に問う。**
///
/// 自分で asmdef の JSON をパースする案は採らない ——
/// **自分でパースする検査は本物の解釈を代理できない**
/// （prove-a-check-works skill。M4 で .meta のキー名がまさにこれで、
/// 自前パースは通り、Unity に問う検査だけが落とした）。
/// </summary>
public class ProfileGatingTests
{
    private const string DnnAssembly = "CvUnity.Interop.Dnn";
    private const string StandardAssembly = "CvUnity.Interop";

    [Test]
    public void TheStandardInteropAssemblyIsAlwaysCompiled()
    {
        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.Contains(StandardAssembly, names,
            "既定の Interop assembly がコンパイルされていない");
    }

    /// <summary>
    /// **define が無ければ dnn の assembly はコンパイルされない。**
    ///
    /// これが roadmap の決定 2（「dnn が入らないビルドで参照が壊れない」）の
    /// 実体である —— 実行時に EntryPointNotFoundException が出ることではなく、
    /// **参照するコードがビルドを通らないこと。**
    /// </summary>
    [Test]
    public void TheDnnInteropAssemblyIsAbsentWithoutItsDefine()
    {
        var defines = UnityEditor.PlayerSettings.GetScriptingDefineSymbols(
            UnityEditor.Build.NamedBuildTarget.Standalone);

        // このプロジェクトは既定で OCVU_PROFILE_DNN を立てていない。
        // **前提が崩れたら、この検査は何も見ていないので落とす。**
        Assert.That(defines, Does.Not.Contain("OCVU_PROFILE_DNN"),
            "このテストは OCVU_PROFILE_DNN が立っていないことを前提にしている");

        var names = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
            .Select(a => a.name).ToList();
        Assert.That(names, Does.Not.Contain(DnnAssembly),
            "define が無いのに dnn の assembly がコンパイルされている。" +
            "defineConstraints が効いていない");
    }

    /// <summary>
    /// **asmdef のファイル自体は在ること。**
    ///
    /// 上の検査は「コンパイルされていない」を見るが、
    /// **asmdef を消しても同じ結果になる。** 在ることを別に要求しないと、
    /// 機構ごと消えたのか制約が効いているのか区別できない。
    /// </summary>
    [Test]
    public void TheDnnAsmdefExistsOnDisk()
    {
        var guids = UnityEditor.AssetDatabase.FindAssets("CvUnity.Interop.Dnn t:AssemblyDefinitionAsset");
        Assert.IsNotEmpty(guids,
            "dnn の asmdef がプロジェクトに無い。制約が効いているのではなく、機構ごと無い");
    }
}
```

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: `TheDnnAsmdefExistsOnDisk` が **FAIL**（asmdef がまだ無い）。
他の 2 件は通る。

- [ ] **Step 3: asmdef を置く**

`Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/CvUnity.Interop.Dnn.asmdef`:

```json
{
    "name": "CvUnity.Interop.Dnn",
    "rootNamespace": "CvUnity.Interop.Dnn",
    "references": [],
    "includePlatforms": [],
    "excludePlatforms": [],
    "allowUnsafeCode": true,
    "noEngineReferences": true,
    "defineConstraints": [
        "OCVU_PROFILE_DNN"
    ]
}
```

**`.meta` も要る。** Unity が生成するので、EditMode を 1 度走らせてから
生成された `.meta` を stage する。

**ディレクトリが空だと Unity が扱わないことがある**ので、
`Runtime/Interop.Dnn/README.md` を置く:

```markdown
# CvUnity.Interop.Dnn

**dnn profile の P/Invoke 宣言が入る場所。** いまは空である。

`OCVU_PROFILE_DNN` が立っていなければ、この assembly はコンパイルされない
（`defineConstraints`）。**それが「dnn が入らないビルドで参照が壊れない」の
実体である** —— 実行時に `EntryPointNotFoundException` が出るのではなく、
**参照するコードがビルドを通らない。**

中身は `bindings/spec/dnn.json` に `"profile": "dnn"` を書いて
`./tools/dev.ps1 generate` を実行すると生成される。**手で書かない。**
```

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: 3 件とも PASS。EditMode の合計が **+3**。

- [ ] **Step 5: define を立てると本当に現れることを実証する**

**これが機構の負の対照である。** 「define が無いから無い」だけでは、
**そもそも asmdef が壊れていて永遠にコンパイルされない**場合と区別できない。

一時的に `tests/UnityProject/ProjectSettings/ProjectSettings.asset` の
`scriptingDefineSymbols` に `OCVU_PROFILE_DNN` を足すか、Editor から設定する。
**空の assembly はコンパイルされない**ので、確認用に 1 ファイル置く:

```csharp
// tests/UnityProject/Assets/Tests/EditMode/... ではなく、
// Packages/.../Runtime/Interop.Dnn/ に一時的に置く。**戻すこと。**
namespace CvUnity.Interop.Dnn
{
    internal static class ProfileProbe { internal const int Marker = 1; }
}
```

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: `TheDnnInteropAssemblyIsAbsentWithoutItsDefine` が
「このテストは OCVU_PROFILE_DNN が立っていないことを前提にしている」で **FAIL**
—— **前提の崩れを検査自身が申告する**ので、「何も見ていないのに緑」にならない。

**define と probe ファイルを両方戻すこと。**

- [ ] **Step 6: `InternalsVisibleTo` の扱いを決めて書く**

`Runtime/Interop/AssemblyInfo.cs` に**足さない。** 理由をコメントで書く:

```csharp
// **CvUnity.Interop.Dnn には InternalsVisibleTo を出さない。**
//
// dnn の宣言は CvUnity.Interop.Dnn の中で完結し、そこから
// CvUnity.Interop の internal を見る必要は無い —— 見たくなったら、
// それは共通の何かが Interop 側に在るということなので、
// **そちらを別の場所へ切り出す合図である。**
//
// 逆向き（Interop が Dnn を見る）も出さない。既定 profile が
// opt-in profile を知っていたら、切り離せていない。
```

- [ ] **Step 7: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/ Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/AssemblyInfo.cs tests/UnityProject/Assets/Tests/EditMode/ProfileGatingTests.cs
git commit -m "feat(m7b): profile を切る asmdef と、それを Unity に問う検査

**自分で asmdef をパースしない。** Unity の CompilationPipeline に問う ——
自分でパースする検査は本物の解釈を代理できない（M4 の .meta のキー名で
実証済み: 自前パースは通り、Unity に問う検査だけが落とした）。

**「コンパイルされていない」だけを見ない。** asmdef を消しても同じ結果に
なるので、**在ることを別に要求する。**

**前提の崩れを検査自身が申告する。** OCVU_PROFILE_DNN が立っている状態では
『この検査は立っていないことを前提にしている』と言って落ちるので、
何も見ていないのに緑、にならない（実際に立てて確かめた）。

**空の asmdef を (c) の前に置くのは、機構と中身を同時に作らないためである** ——
壊れたときにどちらが壊れたか切り分けられなくなる（M5 で同じ判断をした）。"
```

---

## Task 5: 文書と判定

**Files:**
- Modify: `docs/abi-ownership-and-versioning.md`
- Modify: `docs/roadmap.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: `docs/abi-ownership-and-versioning.md` に profile の規約を書く**

新しい節として:

```markdown
## §4 profile

**既定 profile は `standard` である。** `bindings/spec/*.json` が `profile` を
書かなければ `standard` になり、いままでどおり `Runtime/Interop` の
`NativeMethods` に出る。

**`standard` 以外は別 assembly・別クラスへ出る。**

| profile | assembly | クラス | 出力先 |
| --- | --- | --- | --- |
| `standard` | `CvUnity.Interop` | `NativeMethods` | `Runtime/Interop/` |
| `dnn` | `CvUnity.Interop.Dnn` | `NativeMethodsDnn` | `Runtime/Interop.Dnn/` |

**`partial class` は assembly を跨げない**ので、同じ型にはできない。

**profile の値は `schema.json` の `enum` で閉じてある。** 開くと綴り間違いが
新しい profile になり、その module の宣言がどこからも参照されない assembly へ
静かに消える。

**`OCVU_ABI_VERSION` は profile で分けない。** 単一の整数のままにする決定は
§2 が正本で、profile の導入はそれを変えない —— **profile が変えるのは
「どの宣言がコンパイルされるか」であって、「境界の契約が何版か」ではない。**

**native 側の実体は `native/modules.cmake` である。** `OCVU_MODULES` に
渡す module の一覧が、その binary に入る関数を決める。**外せない module が
2 つある**（`infra` と `core`）—— 他の全 module が使うので、
外そうとすると configure の時点で落ちる。
```

- [ ] **Step 2: roadmap の M7 決定 1・2 を更新する**

決定 1 の「**ただし分けたのはヘッダであって CMake target ではない** ——
まだ 1 つの target が全 module を作る」を、実態に合わせて書き直す。
決定 2 の「**M5 では手を付けていない**」も同様。

**「済んだ」と書く前に、何が済んでいないかも書く** ——
`dnn` の spec も実装もまだ無いので、**機構は在るが通っていない**。
`milestone-complete` skill の「満たしたが、実証はしていない」を第 3 の欄として使う。

> **ただしこの計画は 1 つだけ実証している**: profile を変えると出力先と
> クラス名が実際に変わること（Task 3 Step 7）。**「機構が働く」は実証済みで、
> 「dnn で働く」が未実証である。** その区別を書くこと。

- [ ] **Step 3: `CLAUDE.md` を更新する**

- ファイル配置の表に `native/modules.cmake` と `Runtime/Interop.Dnn/` を足す
- `cmake/FindOpenCvUnityDeps.cmake` の行の隣に、`native/modules.cmake` が
  **「このプラグインが何をビルドするか」**を持つことを書く
  （`COMPONENTS` は「何をリンクするか」、`tools/opencv-config.psd1` の `Modules` は
  「OpenCV 側が何をビルドするか」—— **3 つとも別物である**）
- `tools/verify-exported-symbols.ps1` の行を足す
- 開発コマンドの表の件数（`test-tools` / `test-managed` / EditMode）は
  **数を写さない**という規律に従い、**その行が正本である場合だけ**直す

- [ ] **Step 4: 全レーンを回す**

**1 つずつ順に回すこと。**

```
pwsh -NoProfile -File tools/dev.ps1 test
pwsh -NoProfile -File tools/dev.ps1 test-asan
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
pwsh -NoProfile -File tools/dev.ps1 test-unity-player
pwsh -NoProfile -File tools/verify-exported-symbols.ps1 -LibraryPath build/windows-x64-debug/native/Debug/opencv_unity_native.dll
```

- [ ] **Step 5: コミット**

```bash
git add docs/abi-ownership-and-versioning.md docs/roadmap.md CLAUDE.md
git commit -m "docs(m7b): profile の規約と、3 つの「module 一覧」の違いを書く

**同じ名前で違うものが 3 つある**ので、正本を並べて書いた:
  tools/opencv-config.psd1 の Modules  — OpenCV 側が何をビルドするか
  cmake/FindOpenCvUnityDeps の COMPONENTS — このプラグインが何をリンクするか
  native/modules.cmake の OCVU_MODULES  — このプラグインが何をビルドするか

**「機構が働く」と「dnn で働く」を区別して書いた。** profile を変えると
出力先とクラス名が実際に変わることは実証したが、dnn の spec も実装も
まだ無いので、そちらは未実証である。"
```

---

## Self-Review

**1. Spec coverage**

| spec の要件 | 実装するタスク |
| --- | --- |
| 完了条件 4（C ABI と C# の module 分離） | Task 2（native）/ Task 3（C#）/ Task 4（asmdef） |
| roadmap 決定 1（別 CMake target） | Task 2 |
| roadmap 決定 2（別 assembly、参照が壊れない形） | Task 3・4 |
| D5（別 package ではなく asmdef 制約） | Task 4 |
| 「公開 ABI を 1 本も増やさない」 | Task 1 が機械で守る |

**ギャップ**: roadmap 決定 1 は「`dnn` は別ヘッダ・別 `.cpp`」とも言っているが、
**それは (c) の仕事である** —— `dnn.json` が無いのに `dnn.h` は生成できない。
**この計画は「割れる形にする」ところまでで、割る対象はまだ無い。**
Task 5 Step 2 でその区別を roadmap に書くよう指示してある。

**2. Placeholder scan**

- Task 3 Step 1 の `SpecModel.LoadFile` / `SpecFormatException` に
  「着手時に確かめること、既存の `SpecSchemaTests.cs` から写すのが確実」と書いた
- Task 4 Step 3 の `.meta` は「EditMode を 1 度走らせてから stage する」と手順を書いた
- Task 3 Step 7 の壊し方 2 が**穴を見つける**ことを予告し、Step 8 でその塞ぎ方まで書いた
  —— **これは「後で考える」ではなく、見つかることが分かっている穴の先回りである**

**3. Type consistency**

- `ModuleSpec.Profile` → `string`：Task 3 Step 4 で定義、同 Step の emitter と `Program.cs` で使用 ✓
- `CsPInvokeEmitter.Emit(ModuleSpec)` → `string`：既存の署名を変えない ✓
- `OCVU_MODULES` / `OCVU_ALL_MODULES` / `OCVU_REQUIRED_MODULES` / `OCVU_MODULE_<name>`：
  Task 2 Step 1 で定義、Step 2 で使用、Task 3 Step 6 の検査が `OCVU_ALL_MODULES` を読む ✓
- `verify-exported-symbols.ps1` の `-LibraryPath` / `-SymbolListPath`：
  Task 1 で定義、Task 2 Step 3・4、Task 5 Step 4 で使用 ✓
- assembly 名 `CvUnity.Interop.Dnn`、クラス名 `NativeMethodsDnn`、
  ディレクトリ `Runtime/Interop.Dnn/`：Task 3 と Task 4 と Task 5 の表で一致 ✓
