# M3 Desktop 3 platform と配布の再現性 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows / macOS / Linux の native artifact が CI から生成されて platform 込みのハッシュで識別され、Linux レーンがリークを検出し、成果物の linkage が構成の意図と一致することを機械が確かめる。

**Architecture:** 構成の唯一の定義元（`tools/opencv-config.psd1`）を platform 別 table に変え、実行中の platform を検出して該当分を選ぶ。ハッシュは M1 の H3 修正で構成全体を正規化する形になっているので、platform を構成に入れれば自動的にハッシュへ混ざる。成果物の検証は「読み取り方は platform ごとに違うが、判定の骨格は 1 つ」という形にし、**認識できなかったものは失敗側に落とす**。

**Tech Stack:** PowerShell 7（macOS / Linux でも動く）、CMake 3.25+、MSVC / Clang / GCC、GitHub Actions（`windows-2022` / `macos-14` / `ubuntu-24.04`）、AddressSanitizer + LeakSanitizer（Linux）。

**Spec:** `docs/roadmap.md` の M3 節（目的・ゴール・完了条件）

## Global Constraints

以下は全タスクの要件に含まれる。

- **CI はローカルと同一のコマンド（`tools/dev.ps1`）を呼ぶ。CI 専用の手順を作らない。**
- **認識できなかったものは失敗側に落とす。** 検査を足すときは `prove-a-check-works` skill に従い、**壊して落ちることを実際に見る**まで満たしたと記録しない。列挙を増やすのではなく、分類できないものが reject に落ちる形にする。
- **非 ASCII を出力する PowerShell スクリプトは先頭で `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` を設定する。** M1 中に 3 つの別スクリプトで同じ欠落が独立に起きている。
- **ローカルループは秒単位を守る。** 重い検証は `test-tools-slow` か CI に置く。
- **必須チェックの名前（`Windows x64 (L1 + L3)` / `Windows x64 AddressSanitizer (L2)`）を変えない。** 変えると branch protection が要求する context と一致しなくなり、main が恒久的に merge 不能になる。新しい platform の job は**別の名前で足す**。
- 既存の Windows の挙動を壊さない。M2 までに green になっているレーンは M3 の後も green であること。
- **`.ps1` / `.psm1` に platform 分岐を書くときは `$IsWindows` / `$IsMacOS` / `$IsLinux` を使う。** PowerShell 7 の自動変数で、このリポジトリは 7+ を要求している。

---

### Task 1: 構成を platform 別にし、ハッシュと artifact 名に platform を入れる

**Files:**
- Modify: `tools/opencv-config.psd1`（`Toolchain` を platform 別 table へ）
- Modify: `tools/OpenCvConfig.psm1`（platform 検出、`Get-OpenCvArtifactName` の決め打ち解消）
- Test: `tools/tests/OpenCvConfig.Tests.ps1`（既存に追記）

**Interfaces:**
- Produces:
  - `Get-OpenCvPlatform` -> `'windows-x64'` / `'macos-arm64'` / `'linux-x64'`
  - `Get-OpenCvConfig [-Platform <string>]` — 省略時は実行中の platform。返る object に `Platform` プロパティが増える
  - `Get-OpenCvArtifactName` の戻りが `opencv-5.0.0-<platform>-<hash>` になる
- Consumes: 既存の `Get-OpenCvConfigHash`（構成全体を正規化するので変更不要）

**設計の要点（実装前に読むこと）**

`Get-OpenCvConfigHash` は M1 の H3 修正で `ConvertTo-CanonicalJson -Value $Config` を
ハッシュしている。**個々のキーを名指ししていないので、`Config` に `Platform` を足せば
自動的にハッシュへ混ざる。** ハッシュ関数側は触らない。

これが要る理由: 現在 macOS でビルドすると Windows と**同じハッシュ**を名乗る。M1 が
「古い成果物が黙って再利用されない」ために作った仕組みに、そこだけ穴が開いている。

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/OpenCvConfig.Tests.ps1` の集計ブロック（`if ($failures.Count -gt 0)`）より
**前**に追記する。後ろに置くと終了コードに影響せず落ちようがない（hook も検出するが、
最初から前に置くこと）。

```powershell
# --- platform ごとに構成とハッシュが分かれる ---
#
# 現在ハッシュに platform が入っておらず、macOS でビルドしても Windows と同じ
# ハッシュを名乗れてしまう。M1 が「古い成果物が黙って再利用されない」ために
# 作った仕組みの穴なので、platform が違えば必ず違うハッシュになることを固定する。
$platforms = @('windows-x64', 'macos-arm64', 'linux-x64')
$hashes = @{}
foreach ($p in $platforms) {
    $cfg = Get-OpenCvConfig -Platform $p
    Assert-That ($cfg.Platform -eq $p) "Get-OpenCvConfig -Platform $p returns that platform"
    Assert-That ($null -ne $cfg.Toolchain.Generator) "$p has a generator"
    $hashes[$p] = Get-OpenCvConfigHash -Config $cfg
}

Assert-That (($hashes.Values | Sort-Object -Unique).Count -eq $platforms.Count) `
    'every platform produces a distinct config hash'

foreach ($p in $platforms) {
    $name = Get-OpenCvArtifactName -Config (Get-OpenCvConfig -Platform $p)
    Assert-That ($name -eq "opencv-5.0.0-$p-$($hashes[$p])") `
        "the artifact name for $p embeds that platform and its hash"
}

# 実行中の platform を既定にする。引数なしの呼び出しが壊れないこと。
$current = Get-OpenCvPlatform
Assert-That ($current -in $platforms) "Get-OpenCvPlatform returns a known platform (saw '$current')"
Assert-That ((Get-OpenCvConfig).Platform -eq $current) 'Get-OpenCvConfig defaults to the running platform'

# 未知の platform は黙って通さない。認識できなかったものは失敗側に落とす。
$rejected = $false
try { Get-OpenCvConfig -Platform 'solaris-sparc' | Out-Null }
catch { $rejected = $true }
Assert-That $rejected 'an unknown platform is rejected rather than silently defaulted'
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `pwsh -NoProfile -File tools/tests/OpenCvConfig.Tests.ps1`
Expected: FAIL。`Get-OpenCvPlatform` が存在しない。

- [ ] **Step 3: 構成を platform 別にする**

`tools/opencv-config.psd1` の `Toolchain` ブロックを次で置き換える。
**`CMakeArgs` は共通のまま**にし、platform 固有の flag だけを `PlatformCMakeArgs` に分ける。

```powershell
    # platform ごとの toolchain。実行中の platform に対応する 1 つが選ばれ、
    # 構成ハッシュに混ざる（Get-OpenCvConfigHash は Config 全体を正規化する）。
    #
    # Generator が platform ごとに違うのは避けられない: MSVC は Visual Studio
    # generator、macOS / Linux は Ninja を使う。Ninja を選ぶのは、Xcode /
    # Unix Makefiles と違って生成物の配置が platform 間で揃うためである。
    Toolchains = @{
        'windows-x64' = @{
            Generator    = 'Visual Studio 17 2022'
            Architecture = 'x64'
            BuildType    = 'Release'
        }
        'macos-arm64' = @{
            Generator    = 'Ninja'
            Architecture = 'arm64'
            BuildType    = 'Release'
        }
        'linux-x64' = @{
            Generator    = 'Ninja'
            Architecture = 'x86_64'
            BuildType    = 'Release'
        }
    }

    # platform 固有の CMake flag。共通の CMakeArgs に足される。
    PlatformCMakeArgs = @{
        'windows-x64' = @()
        'macos-arm64' = @(
            # 単一アーキテクチャに固定する。指定しないと universal binary に
            # なり得て、成果物の中身が構成から読めなくなる。
            '-DCMAKE_OSX_ARCHITECTURES=arm64'
            # 配布先の下限を固定する。指定しないとビルドマシンの OS 版に
            # 引きずられ、同じ構成ハッシュで別物ができる。
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0'
        )
        'linux-x64' = @(
            # 共有ライブラリへ静的ライブラリを取り込むため。
            # 指定しないとリンク時に relocation エラーになる。
            '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
        )
    }
```

**既存の `Toolchain = @{ ... }` ブロックは削除する。** 残すと定義元が 2 つになる。

- [ ] **Step 4: platform 検出と選択を実装する**

`tools/OpenCvConfig.psm1`:

```powershell
<#
    実行中の platform を返す。

    PowerShell 7 の $IsWindows / $IsMacOS / $IsLinux を使う。uname に頼らない
    のは、Windows に uname が無いか、あっても MSYS のものが混ざるためである。

    アーキテクチャは RuntimeInformation から取る。macOS は Apple Silicon の
    arm64 のみ対応する（Intel Mac は M3 の対象外 — 対応するなら platform を
    1 つ足す作業になり、この関数がその増やし方を示している）。
#>
function Get-OpenCvPlatform {
    [CmdletBinding()]
    param()

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

    if ($IsWindows) {
        if ($arch -ne 'X64') { throw "Windows on $arch is not supported (x64 only)." }
        return 'windows-x64'
    }
    if ($IsMacOS) {
        if ($arch -ne 'Arm64') { throw "macOS on $arch is not supported (Apple Silicon only)." }
        return 'macos-arm64'
    }
    if ($IsLinux) {
        if ($arch -ne 'X64') { throw "Linux on $arch is not supported (x64 only)." }
        return 'linux-x64'
    }

    throw 'Unable to determine the platform. $IsWindows / $IsMacOS / $IsLinux were all false.'
}

function Get-OpenCvConfig {
    [CmdletBinding()]
    param(
        # 省略時は実行中の platform。明示すると他 platform の構成も引ける
        # （CI が全 platform のハッシュを算出するのに使う）。
        [string]$Platform
    )

    $path = Join-Path $PSScriptRoot 'opencv-config.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "OpenCV build configuration not found at '$path'."
    }

    if (-not $Platform) { $Platform = Get-OpenCvPlatform }

    $raw = Import-PowerShellDataFile -LiteralPath $path

    # 未知の platform を黙って通さない。既定に倒すと、対応していない環境で
    # 「Windows の構成で macOS をビルドする」ような事故が静かに成立する。
    if (-not $raw.Toolchains.ContainsKey($Platform)) {
        $known = ($raw.Toolchains.Keys | Sort-Object) -join ', '
        throw "Unknown platform '$Platform'. Known platforms: $known"
    }
    if (-not $raw.PlatformCMakeArgs.ContainsKey($Platform)) {
        throw "opencv-config.psd1 has a toolchain for '$Platform' but no PlatformCMakeArgs entry."
    }

    # psd1 の内容を丸ごと引き継ぎ、platform 依存の 2 箇所だけを解決する。
    #
    # **キーを名指しで列挙しない。** 列挙すると、psd1 に新しい top-level キーを
    # 足した人が「構成を変えたのにハッシュが動かない」状態を作る。M1 の H3 は
    # Get-OpenCvConfigHash について同じ欠陥を閉じており、列挙をここへ移すと
    # 1 段上で再発する。
    $resolved = [ordered]@{ Platform = $Platform }
    foreach ($key in ($raw.Keys | Sort-Object)) {
        if ($key -in @('Toolchains', 'PlatformCMakeArgs')) { continue }
        $resolved[$key] = $raw[$key]
    }
    $resolved['Toolchain'] = $raw.Toolchains[$Platform]
    $resolved['CMakeArgs'] = [string[]](@($raw.CMakeArgs) + @($raw.PlatformCMakeArgs[$Platform]))

    return [pscustomobject]$resolved
}
```

`Get-OpenCvArtifactName` の決め打ちを外す。

```powershell
function Get-OpenCvArtifactName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $hash = Get-OpenCvConfigHash -Config $Config
    return "opencv-$($Config.Tag)-$($Config.Platform)-$hash"
}
```

`Export-ModuleMember` に `Get-OpenCvPlatform` を足す。

- [ ] **Step 5: テストが通ることを確認する**

Run: `pwsh -NoProfile -File tools/tests/OpenCvConfig.Tests.ps1`
Expected: PASS。

- [ ] **Step 6: ハッシュが実際に変わったことを確認する**

Run:

```
pwsh -NoProfile -Command "Import-Module ./tools/OpenCvConfig.psm1 -Force; foreach (`$p in 'windows-x64','macos-arm64','linux-x64') { `$c = Get-OpenCvConfig -Platform `$p; '{0}: {1}' -f `$p, (Get-OpenCvArtifactName -Config `$c) }"
```

Expected: 3 行が出て、**ハッシュがすべて異なる**。Windows のハッシュは M2 時点の
`b20b4dacd9a9` から変わる（`Platform` が構成に加わったため）。**変わらなければ
platform が構成に入っていない**ので Step 3 か 4 が誤っている。

- [ ] **Step 7: 全レーンを回す**

Run: `pwsh tools/dev.ps1 test`
Expected: **OpenCV が見つからないというエラーで落ちる。** ハッシュが変わったので
`third_party/opencv/<新ハッシュ>` がまだ無い。これは正しい挙動で、Task 4 の CI 再ビルド
で解消する。**この時点で「ハッシュを元に戻す」ことでレーンを緑にしないこと** — それは
この Task が入れた変更を無効化することになる。

- [ ] **Step 8: コミット**

```bash
git add tools/opencv-config.psd1 tools/OpenCvConfig.psm1 tools/tests/OpenCvConfig.Tests.ps1
git commit -m "feat(config): make the build configuration and its hash platform-aware"
```

---

### Task 2: CMakePresets と dev.ps1 を platform 対応にする

**Files:**
- Modify: `CMakePresets.json`（macOS / Linux の preset を足す）
- Modify: `tools/dev.ps1`（preset 名を platform から導く）
- Modify: `tools/opencv.ps1`（generator 固有オプションの分岐、**manifest の platform 決め打ち解消**）
- Test: `tools/tests/OpenCvConfig.Tests.ps1`（preset 名の整合、manifest の検査）

**Interfaces:**
- Consumes: Task 1 の `Get-OpenCvPlatform`, `Get-OpenCvConfig`
- Produces: preset 名が `<platform>-debug` / `<platform>-asan`（例: `linux-x64-asan`）

**設計の要点**

`dev.ps1` は現在 `$Preset = 'windows-x64-debug'` と決め打ちしている。これを
`"$(Get-OpenCvPlatform)-debug"` にする。**preset 名と platform 名を一致させる**ので、
新しい platform を足すときに書き換える箇所が構成ファイルだけになる。

Linux の ASan は **LeakSanitizer が既定で有効**になる。これが M3 の完了条件の 1 つ
（リーク検出）を満たす経路である。Windows の ASan は LeakSanitizer を持たないので、
リークは Linux でしか見つからない。

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/OpenCvConfig.Tests.ps1` の集計ブロックより前に追記する。

```powershell
# --- CMakePresets に全 platform 分が在り、名前が platform と一致する ---
#
# preset 名を platform 名から機械的に導くので、片方だけ足して他方を忘れると
# 「preset が無い」という実行時エラーになる。ここで先に落とす。
$presetsPath = Join-Path $PSScriptRoot '../../CMakePresets.json' | Resolve-Path | Select-Object -ExpandProperty Path
$presets = Get-Content -LiteralPath $presetsPath -Raw | ConvertFrom-Json
$configureNames = @($presets.configurePresets | ForEach-Object { $_.name })

foreach ($p in @('windows-x64', 'macos-arm64', 'linux-x64')) {
    Assert-That ("$p-debug" -in $configureNames) "CMakePresets has a configure preset '$p-debug'"
    Assert-That ("$p-asan" -in $configureNames) "CMakePresets has a configure preset '$p-asan'"
}

# build / test preset も同数あること。configure だけ足して build を忘れると
# cmake --build --preset が失敗する。
$buildNames = @($presets.buildPresets | ForEach-Object { $_.name })
$testNames = @($presets.testPresets | ForEach-Object { $_.name })
foreach ($n in $configureNames) {
    Assert-That ($n -in $buildNames) "there is a build preset for '$n'"
    Assert-That ($n -in $testNames) "there is a test preset for '$n'"
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `pwsh -NoProfile -File tools/tests/OpenCvConfig.Tests.ps1`
Expected: FAIL。`macos-arm64-debug` が無い。

- [ ] **Step 3: CMakePresets に 4 つの preset を足す**

`configurePresets` に追記する（既存の 2 つはそのまま）。

```json
    {
      "name": "macos-arm64-debug",
      "displayName": "macOS arm64 Debug (Clang)",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/macos-arm64-debug",
      "cacheVariables": {
        "OCVU_BUILD_TESTS": "ON",
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_OSX_ARCHITECTURES": "arm64"
      }
    },
    {
      "name": "macos-arm64-asan",
      "inherits": "macos-arm64-debug",
      "displayName": "macOS arm64 ASan (Clang)",
      "binaryDir": "${sourceDir}/build/macos-arm64-asan",
      "cacheVariables": { "OCVU_ENABLE_ASAN": "ON" }
    },
    {
      "name": "linux-x64-debug",
      "displayName": "Linux x64 Debug (GCC)",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/linux-x64-debug",
      "cacheVariables": {
        "OCVU_BUILD_TESTS": "ON",
        "CMAKE_BUILD_TYPE": "Debug"
      }
    },
    {
      "name": "linux-x64-asan",
      "inherits": "linux-x64-debug",
      "displayName": "Linux x64 ASan+LSan (GCC)",
      "binaryDir": "${sourceDir}/build/linux-x64-asan",
      "cacheVariables": { "OCVU_ENABLE_ASAN": "ON" }
    }
```

`buildPresets` と `testPresets` にも同じ 4 つを足す。**Ninja は単一構成 generator
なので `"configuration"` を指定しない**（Visual Studio generator の既存 2 つは残す）。

```json
    { "name": "macos-arm64-debug", "configurePreset": "macos-arm64-debug" },
    { "name": "macos-arm64-asan", "configurePreset": "macos-arm64-asan" },
    { "name": "linux-x64-debug", "configurePreset": "linux-x64-debug" },
    { "name": "linux-x64-asan", "configurePreset": "linux-x64-asan" }
```

testPresets 側は `"output": { "outputOnFailure": true }` を付ける。

- [ ] **Step 4: dev.ps1 の preset 決め打ちを外す**

冒頭付近を書き換える。

```powershell
Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force
$Platform      = Get-OpenCvPlatform
$Preset        = "$Platform-debug"
$AsanPreset    = "$Platform-asan"
```

**既存の `$Preset = 'windows-x64-debug'` と `$AsanPreset = 'windows-x64-asan'` を
削除する。** 残すと定義元が 2 つになる。

`Copy-NativePluginForUnity` も platform 依存なので直す。

```powershell
function Copy-NativePluginForUnity {
    # 出力ファイル名と配置は platform ごとに違う。Visual Studio generator は
    # 構成名のサブディレクトリ（Debug/）を作るが、Ninja は作らない。
    $buildDir = Join-Path $RepoRoot "build/$Preset/native"
    $source = if ($IsWindows) {
        Join-Path $buildDir 'Debug/opencv_unity_native.dll'
    } elseif ($IsMacOS) {
        Join-Path $buildDir 'libopencv_unity_native.dylib'
    } else {
        Join-Path $buildDir 'libopencv_unity_native.so'
    }

    if (-not (Test-Path -LiteralPath $source)) {
        Write-DevFailure (@(
            "native plugin が見つかりません: $source"
            "先に './tools/dev.ps1 build' を実行してください。"
        ) -join "`n")
    }

    # Unity の native plugin 置き場も platform ごとに分かれる。
    $pluginDir = switch ($Platform) {
        'windows-x64' { 'x86_64' }
        'macos-arm64' { 'macOS' }
        'linux-x64'   { 'Linux/x86_64' }
    }
    $destDir = Join-Path $RepoRoot "Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/$pluginDir"
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $source -Destination $destDir -Force
}
```

- [ ] **Step 5: opencv.ps1 の generator 固有オプションを分岐する**

`Invoke-Build` の中で `-A $Architecture` を渡している箇所を直す。

```powershell
    # -A は Visual Studio generator 専用のオプションで、Ninja に渡すとエラーになる。
    # アーキテクチャは macOS では CMAKE_OSX_ARCHITECTURES（PlatformCMakeArgs）、
    # Linux ではネイティブ既定で決まる。
    $generatorArgs = @('-G', $Config.Toolchain.Generator)
    if ($Config.Toolchain.Generator -like 'Visual Studio*') {
        $generatorArgs += @('-A', $Config.Toolchain.Architecture)
    }
```

- [ ] **Step 6: manifest の platform 決め打ちと `$NativeOutDir` を直す**

`tools/opencv.ps1` の `Write-BuildManifest` が `platform = 'windows-x64'` と
書いている。**決め打ちにすると manifest が実物と食い違い、「成果物に何が入っているか」の
申告が嘘になる** — Task 6 の SBOM はこの manifest から作るので、そこまで伝播する。

```powershell
        # 構成から取る。決め打ちにすると manifest が実物と食い違い、
        # 「成果物に何が入っているか」の申告が嘘になる。
        platform            = $Config.Platform
```

`tools/dev.ps1` の `$NativeOutDir`（L3 が native ライブラリを探す先）も
`build/windows-x64-debug/native/Debug` と決め打ちになっている。`$Preset` を動的に
した以上ここも動かす必要がある。**直さないと L3 が古い Windows のパスを見続ける。**

```powershell
# Ninja は単一構成なので構成名のサブディレクトリを作らない。
$NativeOutDir = if ($IsWindows) {
    Join-Path $RepoRoot "build/$Preset/native/Debug"
} else {
    Join-Path $RepoRoot "build/$Preset/native"
}
```

検査も足す。実行時の値は CI でしか確かめられないので、ソースを見る。

```powershell
$opencvScript = Join-Path $PSScriptRoot '../opencv.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
$manifestSource = Get-Content -LiteralPath $opencvScript -Raw

Assert-That ($manifestSource -notmatch "platform\s*=\s*'[a-z0-9-]+'") `
    'the build manifest does not hardcode a platform string'
Assert-That ($manifestSource -match 'platform\s*=\s*\$Config\.Platform') `
    'the build manifest takes its platform from the configuration'
```

- [ ] **Step 7: テストが通ることを確認する**

Run: `pwsh -NoProfile -File tools/tests/OpenCvConfig.Tests.ps1`
Expected: PASS。

- [ ] **Step 8: preset が実在することを cmake に確かめさせる**

Run: `cmake --list-presets`
Expected: 6 つの configure preset が並ぶ。

- [ ] **Step 9: コミット**

```bash
git add CMakePresets.json tools/dev.ps1 tools/opencv.ps1 tools/tests/OpenCvConfig.Tests.ps1
git commit -m "feat(build): derive presets and plugin paths from the running platform"
```

---

### Task 3: 成果物の linkage 検証（M1 の持ち越し。Windows 分）

**Files:**
- Create: `tools/verify-artifact-linkage.ps1`
- Test: `tools/tests/VerifyArtifactLinkage.Tests.ps1`
- Modify: `tools/dev.ps1`（`$ToolsTestScriptsSlow` に足す）

**Interfaces:**
- Consumes: Task 1 の `Get-OpenCvConfig`（`CMakeArgs` から意図を読む）
- Produces: `tools/verify-artifact-linkage.ps1 -Root <path> [-Platform <string>]`
  — 意図と一致すれば exit 0、しなければ exit 1

**設計の要点（このタスクの本題）**

M1 が見送った検証である。roadmap の M1 節に経緯がある。**送った CMake flag ではなく、
できたバイナリを読む。**

**まず Windows 分だけを作る。** 読み取り方が 3 系統ある（`DEFAULTLIB` / `readelf` /
`otool`）ので、3 つ同時に立ち上げるとこの Task だけで M3 を食う。Task 5 で macOS /
Linux を足すときに同じ骨格へ載せる。

**認識できなかったものは失敗側に落とす。** 「読み取れなかったら通す」は、M1 が 8 回
繰り返した欠陥の一形態である。ファイルが読めない、期待する記録が 1 つも見つからない、
platform が未対応 — どれも exit 1 にする。

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/VerifyArtifactLinkage.Tests.ps1` を新規作成する。

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    成果物の linkage 検証そのものを検証する。

    この検査は「読めなかったら通す」形になっていないことが最も重要なので、
    正常系より異常系を厚く見る。
#>

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent $PSScriptRoot
$verify = Join-Path $repoRoot 'tools/verify-artifact-linkage.ps1'
$failures = @()

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

# --- 実物に対して通ること ---
$config = Get-OpenCvConfig
$root = Get-OpenCvRoot -Config $config
if (Test-Path -LiteralPath $root) {
    & pwsh -NoProfile -File $verify -Root $root | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'the restored artifact matches the configured linkage'
}
else {
    Write-Host "  SKIP  no restored artifact at $root" -ForegroundColor Yellow
}

# --- 存在しないツリーは失敗にする（黙って通さない） ---
$missing = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-missing-" + [guid]::NewGuid().ToString('n'))
& pwsh -NoProfile -File $verify -Root $missing 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a missing artifact tree fails rather than passing vacuously'

# --- ライブラリが 1 つも無いツリーは失敗にする ---
#
# ここが「読めなかったら通す」の典型的な入り口である。走査して 0 件だったとき、
# 「違反が無かった」と読むと、検査が何も見ていない状態が緑になる。
$empty = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-empty-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path (Join-Path $empty 'x64/vc17/staticlib') | Out-Null
& pwsh -NoProfile -File $verify -Root $empty 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a tree with no libraries fails rather than reporting no violations'
Remove-Item -Recurse -Force $empty -ErrorAction SilentlyContinue

# --- 未対応 platform を指定したら失敗にする ---
& pwsh -NoProfile -File $verify -Root $root -Platform 'solaris-sparc' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unsupported platform fails rather than skipping the check'

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `pwsh -NoProfile -File tools/tests/VerifyArtifactLinkage.Tests.ps1`
Expected: FAIL。`verify-artifact-linkage.ps1` が存在しない。

- [ ] **Step 3: 検証スクリプトを実装する**

`tools/verify-artifact-linkage.ps1`:

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    ビルド済み OpenCV ツリーの linkage が、構成の意図と一致するかを検証する。

    送った CMake flag ではなく、**できたバイナリを読む**。M1 ではこの検証が無く、
    2 件の欠陥が人手で発見された（PATH から拾われたアセンブラ、黙って上書き
    された CRT linkage）。詳細は docs/roadmap.md の M1 節「既知の欠陥」。

    tools/verify-opencv-artifact.ps1 とは別軸である:
      あちら = どのファイルが在るか（依存の allowlist）
      こちら = そのファイルがどう作られたか（linkage）
    依存の集合が正しくても linkage が違えば M1 と同じ欠陥になる。

    **認識できなかったものは失敗側に落とす。** 読めない、1 件も見つからない、
    platform が未対応 — すべて exit 1 にする。「読み取れなかったら通す」は
    M1 が繰り返した欠陥の一形態である。
#>

param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Platform
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force

function Write-VerifyFailure([string]$Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

if (-not $Platform) { $Platform = Get-OpenCvPlatform }
if (-not (Test-Path -LiteralPath $Root)) {
    Write-VerifyFailure "artifact tree not found: $Root"
}

$config = Get-OpenCvConfig -Platform $Platform

# 構成が要求している CRT linkage を読む。これが「意図」の側である。
$wantsSharedRuntime = $config.CMakeArgs -contains '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'

switch ($Platform) {
    'windows-x64' {
        $libs = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter '*.lib' |
                  Where-Object { $_.Name -like 'opencv_*' })
        if ($libs.Count -eq 0) {
            Write-VerifyFailure (@(
                "no opencv_*.lib found under $Root"
                '0 件を「違反なし」と読まない。検査対象が見つからないのは失敗である。'
            ) -join "`n")
        }

        # .lib に埋め込まれた /DEFAULTLIB: 指令を読む。MSVC はリンク時に
        # 使う CRT をここに記録するので、実際にどちらでビルドされたか分かる。
        #   LIBCMT  = 静的 CRT (/MT)
        #   MSVCRT  = 共有 CRT (/MD)
        $violations = @()
        foreach ($lib in $libs) {
            $bytes = [System.IO.File]::ReadAllBytes($lib.FullName)
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            $static = [regex]::Matches($text, 'DEFAULTLIB:"LIBCMT"').Count
            $shared = [regex]::Matches($text, 'DEFAULTLIB:"MSVCRT"').Count

            if ($static -eq 0 -and $shared -eq 0) {
                $violations += "$($lib.Name): no CRT directive found (cannot determine linkage)"
                continue
            }
            if ($wantsSharedRuntime -and $static -gt 0) {
                $violations += "$($lib.Name): configured for the shared runtime but has $static static-CRT directive(s)"
            }
            if (-not $wantsSharedRuntime -and $shared -gt 0) {
                $violations += "$($lib.Name): configured for the static runtime but has $shared shared-CRT directive(s)"
            }
        }

        if ($violations.Count -gt 0) {
            Write-VerifyFailure (@(
                "linkage does not match the configuration ($($violations.Count) file(s)):"
                ($violations | ForEach-Object { "  $_" })
                ''
                "構成の意図: $(if ($wantsSharedRuntime) { '共有ランタイム (/MD)' } else { '静的ランタイム (/MT)' })"
                'tools/opencv-config.psd1 を変えたなら CI で再ビルドが要る。'
            ) -join "`n")
        }

        Write-Host "==> $($libs.Count) libraries match the configured runtime linkage" -ForegroundColor Green
    }
    default {
        # 未対応 platform を黙って通さない。Task 5 でここに macOS / Linux を足す。
        Write-VerifyFailure (@(
            "linkage verification is not implemented for platform '$Platform'."
            'この検査は未対応 platform を成功にしない。実装するまで失敗させる。'
        ) -join "`n")
    }
}

exit 0
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `pwsh -NoProfile -File tools/tests/VerifyArtifactLinkage.Tests.ps1`
Expected: PASS（4 assertion）。実物の artifact が無い場合は 1 件が SKIP になる。

- [ ] **Step 5: 検査が本当に効くことを変異で確かめる**

`prove-a-check-works` skill の手順である。**この Step を飛ばさないこと** — 落ちるところを
見ていない検査は「動く」と言えない。

`opencv-config.psd1` の `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL` を一時的に
コメントアウトすると、実物の artifact（共有ランタイムでビルド済み）に対して検査が
落ちるはずである。

Run: 変異を入れて `pwsh -NoProfile -File tools/verify-artifact-linkage.ps1 -Root <実物>`
Expected: exit 1。メッセージに「configured for the static runtime but has N shared-CRT
directive(s)」が出る。**戻して exit 0 に戻ることも確認する。**

- [ ] **Step 6: CI 専用レーンに足す**

`tools/dev.ps1` の `$ToolsTestScriptsSlow` に `'VerifyArtifactLinkage.Tests.ps1'` を足す。
実物の artifact を読むので `test`（秒単位）には入れない。

- [ ] **Step 7: コミット**

```bash
git add tools/verify-artifact-linkage.ps1 tools/tests/VerifyArtifactLinkage.Tests.ps1 tools/dev.ps1
git commit -m "feat(verify): read the built artifact's linkage instead of trusting the flags we sent"
```

---

### Task 4: CI を 3 platform に広げる

**Files:**
- Modify: `.github/workflows/build-opencv.yml`（matrix 化）
- Modify: `.github/workflows/ci-native.yml`（macOS / Linux job を足す）
- Modify: `.github/workflows/ci-sanitizers.yml`（Linux の LeakSanitizer job を足す）

**Interfaces:**
- Consumes: Task 1〜3 のすべて
- Produces: 各 platform の artifact が `opencv-5.0.0-<platform>-<hash>` で公開される

**設計の要点**

**必須チェックの名前を変えない。** `Windows x64 (L1 + L3)` と
`Windows x64 AddressSanitizer (L2)` は branch protection が context として要求している。
名前を変えると main が恒久的に merge 不能になる。**新しい platform は別名の job として
足す**（`macOS arm64 (L1 + L3)` など）。必須にするかは merge 後に別途決める。

Linux の ASan は LeakSanitizer を含む。**これが M3 の完了条件「Linux レーンでリーク検出」
を満たす経路**である。Windows では検出できない。

- [ ] **Step 1: build-opencv を matrix にする**

`.github/workflows/build-opencv.yml` の `jobs` を書き換える。

```yaml
jobs:
  build:
    name: OpenCV 5.0.0 ${{ matrix.platform }}
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 150
    strategy:
      fail-fast: false   # 1 platform の失敗で他を巻き込まない
      matrix:
        include:
          - platform: windows-x64
            runner: windows-2022
          - platform: macos-arm64
            runner: macos-14
          - platform: linux-x64
            runner: ubuntu-24.04

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # Ninja は macOS / Linux の generator。Windows は Visual Studio generator
      # を使うので不要。
      - name: Install Ninja
        if: matrix.platform != 'windows-x64'
        shell: pwsh
        run: |
          if ($IsMacOS) { brew install ninja }
          else { sudo apt-get update; sudo apt-get install -y ninja-build }

      - name: Resolve the configuration
        id: config
        shell: pwsh
        run: |
          Import-Module ./tools/OpenCvConfig.psm1 -Force
          $config = Get-OpenCvConfig -Platform '${{ matrix.platform }}'
          $name = Get-OpenCvArtifactName -Config $config
          "artifact-name=$name" >> $env:GITHUB_OUTPUT
          Write-Host "artifact: $name"

      - name: Build OpenCV
        shell: pwsh
        run: ./tools/opencv.ps1 build

      - name: Upload the artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ steps.config.outputs.artifact-name }}
          path: third_party/opencv/
          if-no-files-found: error
```

**`shell: pwsh` を全 step に付ける。** macOS / Linux runner の既定 shell は bash で、
`.ps1` を直接呼べない。

- [ ] **Step 2: ci-native に macOS / Linux を足す**

既存の Windows job は**そのまま残す**（名前を変えない）。下に 2 つ足す。

```yaml
  macos:
    name: macOS arm64 (L1 + L3)
    runs-on: macos-14
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Set up .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - name: Install Ninja
        run: brew install ninja
      - name: Restore OpenCV
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: ./tools/opencv.ps1 restore
      - name: Run all fast lanes
        shell: pwsh
        run: ./tools/dev.ps1 test

  linux:
    name: Linux x64 (L1 + L3)
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Set up .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - name: Install Ninja
        run: sudo apt-get update && sudo apt-get install -y ninja-build
      - name: Restore OpenCV
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: ./tools/opencv.ps1 restore
      - name: Run all fast lanes
        shell: pwsh
        run: ./tools/dev.ps1 test
```

- [ ] **Step 3: ci-sanitizers に Linux の LeakSanitizer job を足す**

```yaml
  linux-asan:
    name: Linux x64 ASan+LSan (L2)
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Install Ninja
        run: sudo apt-get update && sudo apt-get install -y ninja-build
      - name: Restore OpenCV
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: ./tools/opencv.ps1 restore
      # LeakSanitizer は Linux の ASan に含まれる。Windows の MSVC ASan には
      # 無いので、リーク検出はこのレーンだけが担う。
      - name: Run the sanitizer lane
        shell: pwsh
        env:
          ASAN_OPTIONS: detect_leaks=1
        run: ./tools/dev.ps1 test-asan
```

- [ ] **Step 4: workflow が YAML として妥当か確認する**

Run:

```
uv run --with pyyaml python -c "import yaml,glob;[print('OK',f) or yaml.safe_load(open(f,encoding='utf-8')) for f in glob.glob('.github/workflows/*.yml')]"
```

Expected: 4 ファイルすべて OK。

- [ ] **Step 5: 必須チェックの名前が変わっていないことを確認する**

Run:

```
gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.contexts[]'
grep -n 'name: Windows' .github/workflows/ci-native.yml .github/workflows/ci-sanitizers.yml
```

Expected: 両者が一致する（`Windows x64 (L1 + L3)` / `Windows x64 AddressSanitizer (L2)`）。
**一致しなければ main が merge 不能になる。**

- [ ] **Step 6: コミット**

```bash
git add .github/workflows/build-opencv.yml .github/workflows/ci-native.yml .github/workflows/ci-sanitizers.yml
git commit -m "ci: build and test on macOS and Linux alongside Windows"
```

---

### Task 5: linkage 検証を macOS / Linux に広げる

**Files:**
- Modify: `tools/verify-artifact-linkage.ps1`（`switch` に 2 platform 足す）
- Modify: `tools/tests/VerifyArtifactLinkage.Tests.ps1`

**Interfaces:**
- Consumes: Task 3 の骨格、Task 4 の CI

**設計の要点**

Task 3 が作った `switch` の `default` は「未対応 platform は失敗」である。ここに
2 つ足すが、**`default` は残す** — 4 つ目の platform を足したときに黙って通らないため。

読み取り方:
- **Linux (ELF)**: `readelf -d` の `NEEDED` エントリで動的依存を見る
- **macOS (Mach-O)**: `otool -L` で同じことをする

- [ ] **Step 1: 失敗しないはずのテストを足す**

`tools/tests/VerifyArtifactLinkage.Tests.ps1` の集計ブロックより前に追記する。

```powershell
# --- 未対応 platform は失敗する（default が残っていること） ---
#
# Task 5 で macOS / Linux を足した後も、4 つ目の platform は黙って通らないこと。
# 「実装済みの platform だけ検査し、それ以外は成功」は M1 が繰り返した欠陥である。
& pwsh -NoProfile -File $verify -Root $root -Platform 'freebsd-x64' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a platform with no implementation still fails after adding two more'
```

- [ ] **Step 2: 既に通ることを確認する**

Run: `pwsh -NoProfile -File tools/tests/VerifyArtifactLinkage.Tests.ps1`
Expected: PASS。Task 3 の `default` がまだ効いているため。**ここで落ちるなら Task 3 の
実装が壊れている。**

- [ ] **Step 3: macOS と Linux を実装する**

`switch` の `default` の**前**に 2 つ足す。

```powershell
    'linux-x64' {
        $libs = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
                  Where-Object { $_.Name -like 'libopencv_*' })
        if ($libs.Count -eq 0) {
            Write-VerifyFailure "no libopencv_* found under $Root (0 件を「違反なし」と読まない)"
        }

        # 構成が外している依存が、実際にリンクされていないことを確かめる。
        $forbidden = @('libavcodec', 'libavformat', 'libgstreamer')
        $violations = @()
        $inspected = 0
        foreach ($lib in $libs | Where-Object { $_.Extension -eq '.so' -or $_.Name -like '*.so.*' }) {
            $deps = & readelf -d $lib.FullName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-VerifyFailure "readelf failed on $($lib.Name); cannot determine linkage"
            }
            $inspected++
            foreach ($f in $forbidden) {
                if ($deps -match [regex]::Escape($f)) {
                    $violations += "$($lib.Name): links $f, which the configuration excludes"
                }
            }
        }
        if ($violations.Count -gt 0) {
            Write-VerifyFailure ((@("linkage violations:") + ($violations | ForEach-Object { "  $_" })) -join "`n")
        }
        Write-Host "==> $inspected shared libraries carry no excluded dynamic dependency" -ForegroundColor Green
    }
    'macos-arm64' {
        $libs = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
                  Where-Object { $_.Name -like 'libopencv_*' })
        if ($libs.Count -eq 0) {
            Write-VerifyFailure "no libopencv_* found under $Root (0 件を「違反なし」と読まない)"
        }

        $forbidden = @('libavcodec', 'libavformat', 'libgstreamer')
        $violations = @()
        $inspected = 0
        foreach ($lib in $libs | Where-Object { $_.Extension -eq '.dylib' }) {
            $deps = & otool -L $lib.FullName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-VerifyFailure "otool failed on $($lib.Name); cannot determine linkage"
            }
            $inspected++
            foreach ($f in $forbidden) {
                if ($deps -match [regex]::Escape($f)) {
                    $violations += "$($lib.Name): links $f, which the configuration excludes"
                }
            }
        }
        if ($violations.Count -gt 0) {
            Write-VerifyFailure ((@("linkage violations:") + ($violations | ForEach-Object { "  $_" })) -join "`n")
        }
        Write-Host "==> $inspected dylibs carry no excluded dynamic dependency" -ForegroundColor Green
    }
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `pwsh -NoProfile -File tools/tests/VerifyArtifactLinkage.Tests.ps1`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add tools/verify-artifact-linkage.ps1 tools/tests/VerifyArtifactLinkage.Tests.ps1
git commit -m "feat(verify): extend linkage verification to macOS and Linux"
```

---

### Task 6: 配布物（manifest / checksums / SBOM）と UPM 導入の成立

**Files:**
- Create: `tools/package-release.ps1`
- Create: `tools/tests/PackageRelease.Tests.ps1`
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/*/[各 .dll/.dylib/.so].meta`
- Modify: `tools/dev.ps1`
- Modify: `.gitignore`（plugin バイナリは無視、`.meta` は追跡する）

**Interfaces:**
- Produces: `tools/package-release.ps1 -OutputDir <path>` — `checksums.txt`、
  `sbom.spdx.json`、`build-manifest.json` を出力

**設計の要点**

SBOM は「成果物に何が入っているか」の申告である。**申告と実物を突き合わせる仕組みが
無ければ、M1 と同じ穴が今度は SBOM に開く。** Task 3 / 5 の linkage 検証と
`verify-opencv-artifact.ps1` の allowlist が実物側で、SBOM はその出力から作る。
**手で書かない。**

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/PackageRelease.Tests.ps1`:

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repoRoot 'tools/package-release.ps1'
$failures = @()

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$out = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-pkg-" + [guid]::NewGuid().ToString('n'))
try {
    & pwsh -NoProfile -File $script -OutputDir $out | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'package-release exits 0'

    foreach ($f in @('checksums.txt', 'sbom.spdx.json')) {
        Assert-That (Test-Path -LiteralPath (Join-Path $out $f)) "$f is produced"
    }

    # SBOM は実物から作る。artifact が bundle している component が
    # 全部入っていること — 片方だけ更新される状態を作らない。
    $sbom = Get-Content -LiteralPath (Join-Path $out 'sbom.spdx.json') -Raw | ConvertFrom-Json
    $names = @($sbom.packages | ForEach-Object { $_.name })
    foreach ($c in @('zlib', 'libpng', 'libjpeg')) {
        Assert-That (($names | Where-Object { $_ -like "*$c*" }).Count -gt 0) "the SBOM lists $c"
    }

    $lines = @(Get-Content -LiteralPath (Join-Path $out 'checksums.txt'))
    Assert-That ($lines.Count -gt 0) 'checksums.txt is not empty'
}
finally {
    Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `pwsh -NoProfile -File tools/tests/PackageRelease.Tests.ps1`
Expected: FAIL。スクリプトが存在しない。

- [ ] **Step 3: package-release.ps1 を実装する**

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    配布物一式を出力する。

    SBOM は「成果物に何が入っているか」の申告である。**手で書かない** —
    申告と実物が食い違う状態は、M1 で構成ハッシュに起きたのと同じ欠陥に
    なる。復元済み artifact の etc/licenses/ から機械的に組み立てる。
#>

param(
    [Parameter(Mandatory)][string]$OutputDir
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$config = Get-OpenCvConfig
$root = Get-OpenCvRoot -Config $config

if (-not (Test-Path -LiteralPath $root)) {
    [Console]::Error.WriteLine(@(
        "OpenCV artifact not found at $root"
        "先に './tools/opencv.ps1 restore' を実行してください。"
    ) -join "`n")
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# --- SBOM: 実物の etc/licenses/ から component を拾う ---
$licenseDir = Join-Path $root 'etc/licenses'
if (-not (Test-Path -LiteralPath $licenseDir)) {
    [Console]::Error.WriteLine("no etc/licenses in the artifact; cannot build an SBOM from evidence")
    exit 1
}

$components = @(Get-ChildItem -LiteralPath $licenseDir -File | ForEach-Object {
    # ファイル名の先頭が component 名（zlib-LICENSE -> zlib）
    ($_.Name -split '-')[0]
} | Sort-Object -Unique)

if ($components.Count -eq 0) {
    [Console]::Error.WriteLine("etc/licenses is empty; refusing to emit an SBOM that claims nothing")
    exit 1
}

$sbom = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = "opencv-unity-native-$($config.Platform)"
    documentNamespace = "https://github.com/ayutaz/OpenCVUnityNative/sbom/$($config.Platform)"
    creationInfo = [ordered]@{ creators = @('Tool: tools/package-release.ps1') }
    packages = @(
        [ordered]@{
            name = 'opencv'
            SPDXID = 'SPDXRef-Package-opencv'
            versionInfo = $config.Tag
            licenseDeclared = 'Apache-2.0'
        }
    ) + @($components | ForEach-Object {
        [ordered]@{
            name = $_
            SPDXID = "SPDXRef-Package-$_"
            licenseDeclared = 'NOASSERTION'
            comment = 'bundled by the pinned OpenCV build; see THIRD_PARTY_NOTICES.md'
        }
    })
}
$sbom | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'sbom.spdx.json') -Encoding utf8

# --- checksums ---
$pluginRoot = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native'
$lines = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File |
    Where-Object { $_.Extension -in @('.dll', '.dylib', '.so') } |
    ForEach-Object {
        $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $rel = $_.FullName.Substring($pluginRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        "$h  $rel"
    })

if ($lines.Count -eq 0) {
    [Console]::Error.WriteLine(@(
        "no native plugin found under $pluginRoot"
        "先に './tools/dev.ps1 build' を実行してください。"
        '空の checksums.txt を出さない — 「検証すべきものが無い」を成功にしない。'
    ) -join "`n")
    exit 1
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDir 'checksums.txt') -Encoding utf8

Copy-Item -LiteralPath (Join-Path $root 'build-manifest.json') `
          -Destination (Join-Path $OutputDir 'build-manifest.json') -Force

Write-Host "==> release artifacts written to $OutputDir" -ForegroundColor Green
exit 0
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `pwsh -NoProfile -File tools/tests/PackageRelease.Tests.ps1`
Expected: PASS。

- [ ] **Step 5: 空の入力で失敗することを確かめる**

`prove-a-check-works` の手順である。plugin ディレクトリを一時的にリネームして
`package-release.ps1` を実行し、**exit 1 になる**ことを見る。戻して exit 0 に戻ることも
確認する。空の `checksums.txt` を出して成功にする実装では、この確認が通らない。

- [ ] **Step 6: Plugin Import Settings を platform 別に固定する（完了条件 1 の後半）**

Unity は native plugin ごとに「どの platform 向けか」を `.meta` に持つ。**既定は
「全 platform 有効」で、3 つの binary が同時に有効だと Unity が読み込みで衝突する。**
配置ディレクトリだけでは決まらないので、`.meta` を明示的に持たせる。

`.meta` は Unity が生成するので、手で書かない。各 platform でビルドしてから Unity を
起動し、生成された `.meta` の `PluginImporter` 節が正しいことを確認する。

```
pwsh tools/dev.ps1 build            # plugin を配置
pwsh tools/dev.ps1 test-unity-editmode   # Unity が .meta を生成する
```

生成された `Runtime/Plugins/x86_64/opencv_unity_native.dll.meta` を開き、
`platformData` に `Win64` が有効・他が無効で入っていることを確認する。
なっていなければ Unity の Inspector で設定し、生成された `.meta` をコミットする。

**`.gitignore` を直す。** 現在 `Runtime/Plugins/` 全体を無視しているが、`.meta` は
**追跡しなければならない**（Unity の設定そのものなので、無いと利用者側で既定に戻る）。

```gitignore
# native plugin の binary は成果物なので追跡しない。
# ただし .meta は Unity の import 設定そのものなので追跡する —
# 無いと利用者の環境で「全 platform 有効」の既定に戻り、3 つの binary が衝突する。
Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/**/*.dll
Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/**/*.dylib
Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/**/*.so
```

**既存の `Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/` の行を削除する。**
残すと `.meta` も無視されたままになる。

- [ ] **Step 7: Git URL からの導入が成立することを確かめる（完了条件 2）**

**「package.json が在る」は「導入できる」ではない。** 実際に別の場所から参照して解決
できることを見る。ネットワーク越しの Git URL はこの時点では未 push なので、
`file:` 参照と同じ仕組みで検証できる範囲を確かめる。

`tools/tests/PackageRelease.Tests.ps1` の集計ブロックより前に追記する。

```powershell
# --- UPM として解決できる形になっているか ---
#
# 「package.json が在る」は「導入できる」ではない。Unity が要求する必須
# フィールドが揃っていること、samples の path が実在すること、
# plugin の .meta が追跡されていることを見る。
$pkgPath = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/package.json'
$pkg = Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json

foreach ($field in @('name', 'version', 'displayName', 'description', 'unity')) {
    Assert-That ($null -ne $pkg.$field -and $pkg.$field -ne '') "package.json has '$field'"
}
Assert-That ($pkg.name -eq 'com.ayutaz.opencv-unity-native') 'package name matches the documented ID'

# samples を宣言しているなら、その path が実在すること。
# 宣言だけして中身が無いと、利用者の Package Manager に空の項目が出る。
if ($pkg.PSObject.Properties.Name -contains 'samples') {
    foreach ($s in $pkg.samples) {
        $sp = Join-Path (Split-Path -Parent $pkgPath) $s.path
        Assert-That (Test-Path -LiteralPath $sp) "declared sample path exists: $($s.path)"
    }
}

# plugin の .meta が git に追跡されていること。
# binary は成果物なので無視してよいが、.meta を無視すると利用者の環境で
# 「全 platform 有効」の既定に戻り、3 つの binary が読み込みで衝突する。
Push-Location $repoRoot
try {
    $tracked = @(& git ls-files 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/**/*.meta')
    Assert-That ($tracked.Count -gt 0) 'native plugin .meta files are tracked by git'
}
finally { Pop-Location }
```

- [ ] **Step 8: CI 専用レーンに足す**

`tools/dev.ps1` の `$ToolsTestScriptsSlow` に `'PackageRelease.Tests.ps1'` を足す。

- [ ] **Step 9: コミット**

```bash
git add tools/package-release.ps1 tools/tests/PackageRelease.Tests.ps1 tools/dev.ps1 .gitignore
git add Packages/com.ayutaz.opencv-unity-native
git commit -m "feat(release): emit checksums and an SBOM built from the artifact, not by hand"
```

---

### Task 7: Unity sample と API reference

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/Samples~/BasicUsage/BasicUsage.cs`
- Create: `Packages/com.ayutaz.opencv-unity-native/Samples~/BasicUsage/README.md`
- Create: `docs/api-reference.md`
- Modify: `Packages/com.ayutaz.opencv-unity-native/package.json`（`samples` 節）

**設計の要点**

`Samples~` は末尾の `~` により Unity から**インポートされるまでコンパイルされない**。
これが UPM の sample の標準的な形である。

API reference は M2 の 9 関数 + C# の公開 API を対象にする。**まだ無い機能を書かない。**

- [ ] **Step 1: sample を書く**

```csharp
using UnityEngine;

namespace CvUnity.Samples
{
    /// <summary>
    /// Texture2D を OpenCV で処理して書き戻す最小の例。
    ///
    /// 使い方: Renderer を持つ GameObject に付け、Source に RGBA32 の
    /// Texture2D を割り当てる。
    /// </summary>
    public sealed class BasicUsage : MonoBehaviour
    {
        [SerializeField] private Texture2D _source;
        [SerializeField] private int _blurKernel = 5;

        private void Start()
        {
            if (_source == null)
            {
                Debug.LogWarning("Source texture is not assigned.");
                return;
            }

            Debug.Log($"OpenCV {CvNative.OpenCvVersion}, ABI {CvNative.AbiVersion}");

            // ToMat はテクスチャの生データを直接読む（コピー 1 回）。
            using var src = CvUnity.Unity.TextureConverter.ToMat(_source);
            using var dst = CvMat.Create(src.Rows, src.Cols, CvMatType.Bgra32);

            CvOps.GaussianBlur(src, dst, _blurKernel, _blurKernel, 0.0, 0.0);

            // 結果を新しいテクスチャへ。元の Texture2D は壊さない。
            var result = new Texture2D(_source.width, _source.height, TextureFormat.RGBA32, false);
            CvUnity.Unity.TextureConverter.ToTexture(dst, result);

            var renderer = GetComponent<Renderer>();
            if (renderer != null && renderer.material != null)
            {
                renderer.material.mainTexture = result;
            }
        }
    }
}
```

- [ ] **Step 2: package.json に samples を宣言する**

```json
  "samples": [
    {
      "displayName": "Basic Usage",
      "description": "Texture2D を OpenCV で処理して書き戻す最小の例",
      "path": "Samples~/BasicUsage"
    }
  ]
```

- [ ] **Step 3: API reference を書く**

`docs/api-reference.md` に、M2 で公開した API だけを書く。
C ABI の 9 関数（`docs/abi-ownership-and-versioning.md` §3 の allowlist）と、
C# の `CvMat` / `CvOps` / `CvNative` / `TextureConverter` / `NativeArrayExtensions`。

**所有権の契約を各所に書く** — `IntPtr` を取る overload には「呼び出しが戻るまで領域を
生かすこと」を明記する。

- [ ] **Step 4: Unity が sample を認識することを確認する**

Run: `pwsh tools/dev.ps1 test-unity-editmode`
Expected: PASS。`Samples~` はインポートされないのでコンパイルされず、既存テストに影響しない。

- [ ] **Step 5: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native docs/api-reference.md
git commit -m "docs: add a minimal Unity sample and an API reference for what M2 shipped"
```

---

### Task 8: 文書の真実化と完了判定

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/roadmap.md`, `docs/README.md`

- [ ] **Step 1: `milestone-complete` skill の手順を実行する**

roadmap の M3 完了条件を 1 件ずつ実測で照合する。**終了コードを見る。出力の PASS 行を
数えない。** 満たしていない条件があれば満たしていないと書く。

- [ ] **Step 2: CLAUDE.md を現状に合わせる**

- 「マイルストーン（現在地: ...）」
- 開発コマンドの表に platform 別の実測値
- ファイル配置の表に `tools/verify-artifact-linkage.ps1`、`tools/package-release.ps1`、`Samples~`
- **M2 の条件 7 が未達のままであることを消さない**

- [ ] **Step 3: 全レーンを回して実測値を集める**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
pwsh tools/dev.ps1 test-tools-slow
pwsh tools/dev.ps1 test-unity-editmode
pwsh tools/dev.ps1 test-unity-player
```

**それぞれの実測時間を記録する。** 伸びていたら隠さず書く。

- [ ] **Step 4: コミット**

```bash
git add CLAUDE.md README.md docs/roadmap.md docs/README.md
git commit -m "docs(m3): true up every document against what the three-platform build actually does"
```

---

## 実行時の注意

**このマイルストーンで最も間違えやすいのは Task 1 の Step 7 である。** ハッシュを変えると
既存の artifact が使えなくなり、レーンが落ちる。**そこでハッシュを元に戻して緑にしないこと** —
それはこの Task の目的そのものを無効化する。CI が新しいハッシュで再ビルドするまで、
ローカルのレーンは落ちたままが正しい。

**必須チェックの名前を変えない。** `Windows x64 (L1 + L3)` と
`Windows x64 AddressSanitizer (L2)` は branch protection の context である。

**macOS / Linux の実機がローカルに無い。** Task 4 以降の platform 固有の挙動は CI でしか
確かめられない。ローカルで確かめられないことを「確かめた」と書かないこと。
