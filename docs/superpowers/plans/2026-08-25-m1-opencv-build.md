# M1: OpenCV 5.0.0 の再現可能ビルドとキャッシュ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** allowlist 構成の OpenCV 5.0.0 を CI がビルドして artifact として公開し、ローカルは download だけで使える状態にする。想定外の依存がバイナリに入ったら CI が落ちる。

**Architecture:** `tools/opencv.ps1` が唯一の入口で、`build`（ローカル再現用の遅い経路）と `restore`（CI が作った artifact を取る速い経路）を持つ。ビルド構成は 1 箇所（`tools/opencv-config.psd1`）に集約し、そこから構成ハッシュを算出して artifact 名に埋める。構成が変われば名前が変わるので、古い artifact が黙って使われることがない。依存 allowlist の検証は configure 時の意図ではなく**実際にビルドされたバイナリ**に対して行う。

**Tech Stack:** OpenCV 5.0.0 / CMake 3.25+ / Visual Studio 17 2022 / PowerShell 7 / GitHub Actions / 既存の GoogleTest + xUnit ハーネス

**Spec:**
- [docs/roadmap.md](../../roadmap.md) M1 節（完了条件の正本）
- [docs/unity-opencv-integration-research-and-plan.md](../../unity-opencv-integration-research-and-plan.md) §8.2 / §8.3（依存とライセンスの方針）

## Global Constraints

- **OpenCV は 5.0.0 に固定する。** 明示的に bump するまで上げない。tag は `5.0.0`。
- **module allowlist は `core,imgproc,imgcodecs,objdetect,features`。** OpenCV 5 では `features2d` は `features` に、`calib3d` は `calib`/`geometry`/`stereo`/`ptcloud` に再編されている（4.x の名前を書かない）。
- **`videoio` を含めない。FFmpeg / GStreamer / MSMF / DShow を有効にしない。**
- **CRT linkage は `/MD`（動的）。** `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`。OpenCV と自前 DLL の両方に適用する。
- **OpenCV は静的ライブラリとしてビルドする**（`BUILD_SHARED_LIBS=OFF`）。配布は `opencv_unity_native.dll` 1 個で完結させる。
- **ローカルで OpenCV をビルドしない。** `restore` が既定。`build` は CI の結果を検証するための経路。
- C ABI prefix は `ocvu_`、C# namespace は `CvUnity`、UPM package ID は `com.ayutaz.opencv-unity-native`。
- 対象 Unity は 6000.x のみ。shipped C# は netstandard2.1 / C# 9。
- C++17 以上。ABI に出るのは固定サイズ型と opaque handle のみ。
- **例外を ABI 境界の外へ出さない。** `ocvu_status` を返す `extern "C"` は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む（エラー報告関数を除く。`native/src/ocvu_error.h` 参照）。
- `Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照しない。
- CI はローカルと同じコマンドを呼ぶ。全 job に `timeout-minutes`。
- ライセンスは Apache-2.0。

## File Structure

| ファイル | 責務 |
| --- | --- |
| `tools/opencv-config.psd1` | ビルド構成の唯一の定義元。tag、module list、CMake flags。ここが変わると構成ハッシュが変わる |
| `tools/opencv.ps1` | `restore` / `build` / `verify` / `clean` の入口 |
| `tools/OpenCvConfig.psm1` | 構成の読み込みと構成ハッシュの算出。`opencv.ps1` と CI の両方から使う |
| `tools/verify-opencv-artifact.ps1` | ビルド済みツリーに対する依存 allowlist の検証 |
| `.github/workflows/build-opencv.yml` | OpenCV をビルドして artifact を公開する |
| `cmake/FindOpenCvUnityDeps.cmake` | `third_party/opencv/<hash>/` を探して OpenCV を取り込む |
| `native/src/ocvu_opencv_info.cpp` | `ocvu_get_opencv_version` / `ocvu_get_build_information` |
| `native/tests/test_opencv_link.cpp` | OpenCV がリンクされ、禁止依存が入っていないことの L1 テスト |
| `tests/Managed/CvUnity.Tests.Managed/OpenCvInfoTests.cs` | 同じことを L3 から |
| `third_party/opencv/<hash>/` | 展開先（gitignore 済み） |

---

### Task 1: ビルド構成と構成ハッシュ

構成を 1 箇所に集約し、そこから決定的なハッシュを出す。以降のすべてのタスクがこのハッシュを使う。

**Files:**
- Create: `tools/opencv-config.psd1`
- Create: `tools/OpenCvConfig.psm1`
- Test: `tools/tests/OpenCvConfig.Tests.ps1`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `Get-OpenCvConfig` → PSCustomObject（`Tag`、`Modules`、`CMakeArgs`、`Toolchain`）
- Produces: `Get-OpenCvConfigHash -Config <obj>` → 12 桁の小文字 hex 文字列
- Produces: `Get-OpenCvArtifactName -Config <obj>` → `opencv-5.0.0-windows-x64-<hash>`
- Produces: `Get-OpenCvRoot -Config <obj>` → `third_party/opencv/<hash>` の絶対パス

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/OpenCvConfig.Tests.ps1`:

```powershell
#Requires -Version 7.0
# Pester を使わず素の assert で書く。依存を増やさないため。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$config = Get-OpenCvConfig

Assert-That ($config.Tag -eq '5.0.0') 'tag is pinned to 5.0.0'
Assert-That ($config.Modules -join ',' -eq 'core,imgproc,imgcodecs,objdetect,features') 'module allowlist matches the spec'

# 4.x の名前が混ざっていないこと。OpenCV 5 では再編されている。
Assert-That (-not ($config.Modules -contains 'features2d')) 'features2d is not used (renamed to features in 5.x)'
Assert-That (-not ($config.Modules -contains 'calib3d')) 'calib3d is not used (split in 5.x)'
Assert-That (-not ($config.Modules -contains 'videoio')) 'videoio is excluded'

$args = $config.CMakeArgs -join ' '
foreach ($forbidden in @('WITH_FFMPEG=OFF', 'WITH_GSTREAMER=OFF', 'WITH_MSMF=OFF', 'WITH_DSHOW=OFF')) {
    Assert-That ($args -match [regex]::Escape($forbidden)) "flags disable $($forbidden.Split('=')[0])"
}
Assert-That ($args -match 'CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL') 'CRT is /MD'
Assert-That ($args -match 'BUILD_SHARED_LIBS=OFF') 'OpenCV is built static'

# ハッシュは決定的で、構成が変われば変わること
$hash1 = Get-OpenCvConfigHash -Config $config
$hash2 = Get-OpenCvConfigHash -Config (Get-OpenCvConfig)
Assert-That ($hash1 -eq $hash2) 'hash is deterministic across calls'
Assert-That ($hash1 -match '^[0-9a-f]{12}$') 'hash is 12 lowercase hex characters'

$mutated = Get-OpenCvConfig
$mutated.CMakeArgs = @($mutated.CMakeArgs) + '-DWITH_TIFF=ON'
Assert-That ((Get-OpenCvConfigHash -Config $mutated) -ne $hash1) 'changing a flag changes the hash'

$mutatedTag = Get-OpenCvConfig
$mutatedTag.Tag = '5.0.1'
Assert-That ((Get-OpenCvConfigHash -Config $mutatedTag) -ne $hash1) 'changing the tag changes the hash'

Assert-That ((Get-OpenCvArtifactName -Config $config) -eq "opencv-5.0.0-windows-x64-$hash1") 'artifact name embeds the hash'

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
```

- [ ] **Step 2: RED を確認する**

Run: `pwsh -NoProfile -File tools/tests/OpenCvConfig.Tests.ps1`
Expected: FAIL。`tools/OpenCvConfig.psm1` が存在しないという Import-Module のエラー。

- [ ] **Step 3: 構成を書く**

`tools/opencv-config.psd1`:

```powershell
@{
    # OpenCV のバージョンは明示的に bump するまで固定する。
    # 変更するとここから算出される構成ハッシュが変わり、
    # 古い artifact は自動的に使われなくなる。
    Tag = '5.0.0'

    # OpenCV 5 のモジュール名。4.x から再編されているので注意:
    #   features2d -> features
    #   calib3d    -> calib / geometry / stereo / ptcloud
    # BUILD_LIST は依存を自動解決するので、実際にビルドされる集合は
    # これより大きくなり得る。実測値は build-manifest.json に記録する。
    Modules = @('core', 'imgproc', 'imgcodecs', 'objdetect', 'features')

    Toolchain = @{
        Generator    = 'Visual Studio 17 2022'
        Architecture = 'x64'
        BuildType    = 'Release'
    }

    CMakeArgs = @(
        # 配布は opencv_unity_native.dll 1 個で完結させる。
        # iOS（M4）は静的リンクが必須なので、最初からその形にしておく。
        '-DBUILD_SHARED_LIBS=OFF'

        # Unity のネイティブプラグインは動的 CRT が標準。
        # MSVC の ASan もこちらを前提にしており、M0 の L2 レーンを維持できる。
        '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'

        # --- videoio 系を完全に排除する ---
        # WITH_FFMPEG は Windows で既定 ON で、configure 時に prebuilt の
        # FFmpeg プラグインを取得しに行くことがある（計画書 §8.2）。
        '-DWITH_FFMPEG=OFF'
        '-DWITH_GSTREAMER=OFF'
        '-DWITH_MSMF=OFF'
        '-DWITH_DSHOW=OFF'
        '-DWITH_V4L=OFF'

        # --- imgcodecs が引き込む codec を PNG / JPEG だけに絞る ---
        # 少ないほど third-party notice の管理量が減る。
        # bundled（BUILD_*=ON）にするのは、システムのライブラリ版に
        # 依存しないほうが再現性が高いため。
        '-DBUILD_ZLIB=ON'
        '-DBUILD_PNG=ON'
        '-DBUILD_JPEG=ON'
        '-DWITH_TIFF=OFF'
        '-DWITH_WEBP=OFF'
        '-DWITH_OPENEXR=OFF'
        '-DWITH_OPENJPEG=OFF'
        '-DWITH_JASPER=OFF'
        '-DWITH_IMGCODEC_HDR=OFF'
        '-DWITH_IMGCODEC_SUNRASTER=OFF'
        '-DWITH_IMGCODEC_PXM=OFF'
        '-DWITH_IMGCODEC_PFM=OFF'

        # --- その他の optional 依存 ---
        # IPP は Intel のバイナリ配布物で独自のライセンス条項を持つ。
        # 性能のための再検討は M7 の担当。
        '-DWITH_IPP=OFF'
        '-DWITH_PROTOBUF=OFF'
        '-DWITH_EIGEN=OFF'
        '-DWITH_OPENCL=OFF'
        '-DWITH_CUDA=OFF'
        '-DWITH_QUIRC=OFF'
        '-DWITH_ADE=OFF'
        '-DWITH_VTK=OFF'
        '-DWITH_GTK=OFF'
        '-DWITH_WIN32UI=OFF'

        # --- ビルドしないもの ---
        '-DBUILD_TESTS=OFF'
        '-DBUILD_PERF_TESTS=OFF'
        '-DBUILD_EXAMPLES=OFF'
        '-DBUILD_DOCS=OFF'
        '-DBUILD_opencv_apps=OFF'
        '-DBUILD_JAVA=OFF'
        '-DBUILD_opencv_python3=OFF'
        '-DBUILD_opencv_python_bindings_generator=OFF'
        '-DBUILD_opencv_js=OFF'
        '-DOPENCV_GENERATE_SETUPVARS=OFF'
        '-DOPENCV_GENERATE_PKGCONFIG=OFF'
    )
}
```

`tools/OpenCvConfig.psm1`:

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    ビルド構成の読み込みと構成ハッシュ。

    ハッシュは「この構成でビルドすると何ができるか」を一意に表す。
    tag、module list、CMake flags、toolchain のいずれかが変われば別の値になり、
    artifact 名が変わるので、古い成果物が黙って再利用されることがない。
    M1 の完了条件の 1 つがこれである。
#>

function Get-OpenCvConfig {
    [CmdletBinding()]
    param()

    $path = Join-Path $PSScriptRoot 'opencv-config.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "OpenCV build configuration not found at '$path'."
    }

    $raw = Import-PowerShellDataFile -LiteralPath $path
    return [pscustomobject]@{
        Tag       = [string]$raw.Tag
        Modules   = [string[]]$raw.Modules
        Toolchain = $raw.Toolchain
        CMakeArgs = [string[]]$raw.CMakeArgs
    }
}

function Get-OpenCvConfigHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    # 正規形にしてから hash を取る。引数の並び順が変わっただけで
    # ハッシュが変わると、意味の無い再ビルドが発生する。
    $canonical = @(
        "tag=$($Config.Tag)"
        "modules=$(($Config.Modules | Sort-Object) -join ',')"
        "generator=$($Config.Toolchain.Generator)"
        "arch=$($Config.Toolchain.Architecture)"
        "buildtype=$($Config.Toolchain.BuildType)"
        "cmake=$(($Config.CMakeArgs | Sort-Object) -join ' ')"
    ) -join "`n"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return -join ($digest[0..5] | ForEach-Object { $_.ToString('x2') })
}

function Get-OpenCvArtifactName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $hash = Get-OpenCvConfigHash -Config $Config
    return "opencv-$($Config.Tag)-windows-x64-$hash"
}

function Get-OpenCvRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $hash = Get-OpenCvConfigHash -Config $Config
    return Join-Path $repoRoot "third_party/opencv/$hash"
}

Export-ModuleMember -Function Get-OpenCvConfig, Get-OpenCvConfigHash,
    Get-OpenCvArtifactName, Get-OpenCvRoot
```

- [ ] **Step 4: GREEN を確認する**

Run: `pwsh -NoProfile -File tools/tests/OpenCvConfig.Tests.ps1`
Expected: PASS。全 assertion が green で `all assertions passed`。

- [ ] **Step 5: `.gitignore` を確認する**

`third_party/` は M0 の時点で既に `.gitignore` にある。無い場合のみ追加する。

Run: `git check-ignore -v third_party/opencv`
Expected: `.gitignore` の該当行が表示される。表示されない場合は `third_party/` を追記する。

- [ ] **Step 6: Commit**

```bash
git add tools/opencv-config.psd1 tools/OpenCvConfig.psm1 tools/tests/OpenCvConfig.Tests.ps1
git commit -m "feat(opencv): pin the build configuration and derive a config hash"
```

---

### Task 2: 依存 allowlist の検証

**この検証は configure 時の意図ではなく、実際にビルドされたツリーに対して行う。** `BUILD_LIST` は依存を自動解決するので、要求した module と実際にできる物は一致しない。

**Files:**
- Create: `tools/verify-opencv-artifact.ps1`
- Test: `tools/tests/VerifyOpenCvArtifact.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 の `Get-OpenCvConfig`、`Get-OpenCvRoot`
- Produces: `tools/verify-opencv-artifact.ps1 -Root <path>` — 違反があれば非ゼロ終了
- Produces: 検出した module 一覧を stdout に 1 行 1 件で出力（Task 3 の manifest がこれを使う）

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/VerifyOpenCvArtifact.Tests.ps1`:

```powershell
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verify = Join-Path $repoRoot 'tools/verify-opencv-artifact.ps1'

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# 合成のツリーを作って検証する。実際の OpenCV ビルドは要らない。
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "ocvu-verify-$(Get-Random)"
function New-Tree([string[]]$libs) {
    $root = Join-Path $temp "case-$(Get-Random)"
    $libDir = Join-Path $root 'x64/vc17/staticlib'
    New-Item -ItemType Directory -Force -Path $libDir | Out-Null
    foreach ($lib in $libs) { Set-Content -Path (Join-Path $libDir $lib) -Value 'stub' }
    return $root
}

$allowed = @(
    'opencv_core500.lib', 'opencv_imgproc500.lib', 'opencv_imgcodecs500.lib',
    'opencv_objdetect500.lib', 'opencv_features500.lib', 'opencv_flann500.lib',
    'zlib.lib', 'libpng.lib', 'libjpeg-turbo.lib'
)

# 正常系
$ok = New-Tree $allowed
& pwsh -NoProfile -File $verify -Root $ok | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'a clean tree passes'

# videoio が混ざっている
$bad = New-Tree ($allowed + 'opencv_videoio500.lib')
& pwsh -NoProfile -File $verify -Root $bad 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'videoio is rejected'

# FFmpeg のプラグイン DLL が混ざっている
$ffmpegRoot = New-Tree $allowed
Set-Content -Path (Join-Path $ffmpegRoot 'x64/vc17/staticlib/opencv_videoio_ffmpeg500_64.dll') -Value 'stub'
& pwsh -NoProfile -File $verify -Root $ffmpegRoot 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a bundled FFmpeg plug-in is rejected'

# 期待した module が足りない
$missing = New-Tree @('opencv_core500.lib')
& pwsh -NoProfile -File $verify -Root $missing 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a tree missing a required module is rejected'

# 検出結果の出力
$listing = & pwsh -NoProfile -File $verify -Root $ok
Assert-That ($listing -contains 'core') 'reports the modules it found'
Assert-That ($listing -contains 'imgproc') 'reports imgproc'

Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
```

- [ ] **Step 2: RED を確認する**

Run: `pwsh -NoProfile -File tools/tests/VerifyOpenCvArtifact.Tests.ps1`
Expected: FAIL。`verify-opencv-artifact.ps1` が存在しない。

- [ ] **Step 3: 実装する**

`tools/verify-opencv-artifact.ps1`:

```powershell
#Requires -Version 7.0
<#
    ビルド済み OpenCV ツリーの依存 allowlist を検証する。

    configure 時のフラグではなく、実際にできたファイルを見る。理由は 2 つある。
    1. BUILD_LIST は依存を自動解決するので、要求した module と実際にできる
       物は一致しない。
    2. WITH_FFMPEG=OFF を渡したつもりでも、configure が prebuilt プラグインを
       取得していれば DLL がツリーに現れる（計画書 §8.2）。フラグを見ても
       それは分からない。

    検証に通ったら、見つかった module 名を 1 行 1 件で stdout に出す。
    build-manifest.json はこれを「実際にビルドされた集合」として記録する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force
$config = Get-OpenCvConfig

if (-not (Test-Path -LiteralPath $Root)) {
    Write-Error "OpenCV tree not found at '$Root'."
    exit 1
}

# 名前に現れたら即座に失格とするもの。
$forbiddenPatterns = @(
    @{ Pattern = 'videoio';   Why = 'videoio は allowlist 外（FFmpeg / GStreamer を引き込む）' }
    @{ Pattern = 'ffmpeg';    Why = 'FFmpeg は配布ライセンスが Apache-2.0 と別条件' }
    @{ Pattern = 'gstreamer'; Why = 'GStreamer は allowlist 外' }
    @{ Pattern = 'ippicv';    Why = 'IPP は Intel の独自条項。有効化は M7 で検討する' }
    @{ Pattern = 'ippiw';     Why = 'IPP は Intel の独自条項。有効化は M7 で検討する' }
    @{ Pattern = 'protobuf';  Why = 'protobuf は dnn 用で allowlist 外' }
    @{ Pattern = 'libtiff';   Why = 'TIFF は allowlist 外' }
    @{ Pattern = 'libwebp';   Why = 'WebP は allowlist 外' }
    @{ Pattern = 'openexr';   Why = 'OpenEXR は allowlist 外' }
    @{ Pattern = 'openjp';    Why = 'JPEG2000 は allowlist 外' }
    @{ Pattern = 'jasper';    Why = 'Jasper は allowlist 外' }
)

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.lib', '*.dll', '*.a', '*.so' -ErrorAction SilentlyContinue
if ($null -eq $files -or $files.Count -eq 0) {
    Write-Error "No libraries found under '$Root'. Was the build produced?"
    exit 1
}

$violations = @()
foreach ($file in $files) {
    $lower = $file.Name.ToLowerInvariant()
    foreach ($rule in $forbiddenPatterns) {
        if ($lower -like "*$($rule.Pattern)*") {
            $violations += "  $($file.Name) — $($rule.Why)"
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Error (@(
            'OpenCV のビルド成果物に allowlist 外の依存が含まれています。'
            ''
            ($violations | Sort-Object -Unique)
            ''
            'tools/opencv-config.psd1 の CMakeArgs を見直してください。'
            'フラグを変えると構成ハッシュが変わり、再ビルドが必要になります。'
        ) -join "`n")
    exit 1
}

# 実際に存在する OpenCV module を拾う（opencv_<name><version>.lib）
$found = @()
foreach ($file in $files) {
    if ($file.Name -match '^opencv_(?<name>[a-z0-9_]+?)\d*\.(lib|a)$') {
        $found += $Matches['name']
    }
}
$found = @($found | Sort-Object -Unique)

$missing = @($config.Modules | Where-Object { $_ -notin $found })
if ($missing.Count -gt 0) {
    Write-Error (@(
            "要求した module がビルド成果物にありません: $($missing -join ', ')"
            "見つかったもの: $($found -join ', ')"
            'BUILD_LIST の指定か、モジュール名を確認してください。'
            'OpenCV 5 では features2d -> features、calib3d -> calib/geometry に再編されています。'
        ) -join "`n")
    exit 1
}

$found | ForEach-Object { Write-Output $_ }
exit 0
```

- [ ] **Step 4: GREEN を確認する**

Run: `pwsh -NoProfile -File tools/tests/VerifyOpenCvArtifact.Tests.ps1`
Expected: PASS。6 つの assertion がすべて green。

- [ ] **Step 5: Commit**

```bash
git add tools/verify-opencv-artifact.ps1 tools/tests/VerifyOpenCvArtifact.Tests.ps1
git commit -m "feat(opencv): verify the dependency allowlist against the built tree"
```

---

### Task 3: ローカルビルド経路

CI が使うのと同じビルド手順を `tools/opencv.ps1 build` として実装する。**このタスクだけ 30〜60 分かかる。** 以降のタスクはこの成果物を使い回す。

**Files:**
- Create: `tools/opencv.ps1`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1 の `OpenCvConfig.psm1`、Task 2 の `verify-opencv-artifact.ps1`
- Produces: `tools/opencv.ps1 build` — `third_party/opencv/<hash>/` に install ツリーと `build-manifest.json` を作る
- Produces: `tools/opencv.ps1 status` — 現在の構成ハッシュと、ツリーの有無を表示する
- Produces: `build-manifest.json` のスキーマ（下記 Step 3）

- [ ] **Step 1: `opencv.ps1` を書く**

```powershell
#Requires -Version 7.0
<#
    OpenCV のビルドと取得。

    既定は restore（CI が作った artifact を download する）で、build は
    ローカルで再現を検証するための遅い経路である。M1 の目的の 1 つが
    「開発ループから 30〜60 分のビルドを追い出す」ことなので、
    日常的に build を叩く運用にはしないこと。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('restore', 'build', 'verify', 'status', 'clean')]
    [string]$Command = 'restore'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force

$Config       = Get-OpenCvConfig
$ConfigHash   = Get-OpenCvConfigHash -Config $Config
$ArtifactName = Get-OpenCvArtifactName -Config $Config
$OpenCvRoot   = Get-OpenCvRoot -Config $Config
$WorkRoot     = Join-Path $RepoRoot "build/opencv-$ConfigHash"

function Invoke-Checked([scriptblock]$Action, [string]$What) {
    Write-Host "==> $What" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

function Show-Status {
    Write-Host "OpenCV tag      : $($Config.Tag)"
    Write-Host "modules         : $($Config.Modules -join ', ')"
    Write-Host "config hash     : $ConfigHash"
    Write-Host "artifact name   : $ArtifactName"
    Write-Host "install root    : $OpenCvRoot"
    if (Test-Path -LiteralPath $OpenCvRoot) {
        Write-Host "state           : present" -ForegroundColor Green
    }
    else {
        Write-Host "state           : ABSENT — run './tools/opencv.ps1 restore'" -ForegroundColor Yellow
    }
}

function Invoke-Build {
    $sourceRoot = Join-Path $WorkRoot 'source'
    $buildRoot  = Join-Path $WorkRoot 'build'

    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceRoot) | Out-Null
        Invoke-Checked {
            git clone --depth 1 --branch $Config.Tag https://github.com/opencv/opencv.git $sourceRoot
        } "clone OpenCV $($Config.Tag)"
    }

    # clone した tag が本当に要求どおりか確認する。--depth 1 でも
    # tag の指定を間違えれば別物が取れるので、思い込みで進めない。
    Push-Location $sourceRoot
    try {
        $describe = git describe --tags --exact-match 2>$null
        if ($describe -ne $Config.Tag) {
            throw "Cloned tree is at '$describe' but the configuration pins '$($Config.Tag)'."
        }
    }
    finally { Pop-Location }

    $cmakeArgs = @(
        '-S', $sourceRoot
        '-B', $buildRoot
        '-G', $Config.Toolchain.Generator
        '-A', $Config.Toolchain.Architecture
        "-DCMAKE_BUILD_TYPE=$($Config.Toolchain.BuildType)"
        "-DCMAKE_INSTALL_PREFIX=$OpenCvRoot"
        "-DBUILD_LIST=$($Config.Modules -join ',')"
    ) + $Config.CMakeArgs

    Invoke-Checked { cmake @cmakeArgs } 'configure OpenCV'
    Invoke-Checked {
        cmake --build $buildRoot --config $Config.Toolchain.BuildType --target INSTALL
    } 'build and install OpenCV'

    Invoke-Verify
    Write-BuildManifest
}

function Invoke-Verify {
    $verify = Join-Path $PSScriptRoot 'verify-opencv-artifact.ps1'
    Write-Host '==> verify dependency allowlist' -ForegroundColor Cyan
    $modules = & pwsh -NoProfile -File $verify -Root $OpenCvRoot
    if ($LASTEXITCODE -ne 0) { throw 'dependency allowlist verification failed' }
    return $modules
}

function Write-BuildManifest {
    $modules = Invoke-Verify
    $compiler = (cmake --system-information 2>$null |
        Select-String -Pattern '^CMAKE_CXX_COMPILER_VERSION ' |
        Select-Object -First 1) -replace '^CMAKE_CXX_COMPILER_VERSION\s+', ''

    $manifest = [ordered]@{
        schema           = 1
        opencvTag        = $Config.Tag
        configHash       = $ConfigHash
        artifactName     = $ArtifactName
        platform         = 'windows-x64'
        generator        = $Config.Toolchain.Generator
        buildType        = $Config.Toolchain.BuildType
        cxxCompiler      = ($compiler -replace '"', '').Trim()
        requestedModules = @($Config.Modules)
        builtModules     = @($modules)
        cmakeArgs        = @($Config.CMakeArgs)
    }

    $path = Join-Path $OpenCvRoot 'build-manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "wrote $path" -ForegroundColor Green
}

switch ($Command) {
    'status'  { Show-Status }
    'build'   { Invoke-Build }
    'verify'  { Invoke-Verify | Out-Null; Write-Host 'allowlist OK' -ForegroundColor Green }
    'clean'   {
        Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $WorkRoot -ErrorAction SilentlyContinue
    }
    'restore' { throw "restore は Task 5 で実装する。いまは './tools/opencv.ps1 build' を使うこと。" }
}
```

- [ ] **Step 2: `status` が動くことを確認する**

Run: `pwsh -NoProfile -File tools/opencv.ps1 status`
Expected: 構成ハッシュと artifact 名が表示され、`state : ABSENT` になる。

- [ ] **Step 3: ビルドする（時間がかかる）**

Run: `pwsh -NoProfile -File tools/opencv.ps1 build`
Expected: 30〜60 分で完了し、末尾に `allowlist OK` 相当の検証を通って `wrote .../build-manifest.json`。

**実測時間を記録すること。** 以降のタスクと CI の `timeout-minutes` の根拠になる。

- [ ] **Step 4: 成果物を確認する**

Run:

```powershell
pwsh -NoProfile -File tools/opencv.ps1 status
Get-Content (Join-Path (pwsh -NoProfile -Command "Import-Module ./tools/OpenCvConfig.psm1; Get-OpenCvRoot -Config (Get-OpenCvConfig)") 'build-manifest.json')
```

Expected: `state : present`。manifest の `builtModules` に `core imgproc imgcodecs objdetect features` が含まれ、**`videoio` が含まれない**。`builtModules` が `requestedModules` より多い場合は依存の自動解決によるもので正常。その差分をレポートに書くこと。

- [ ] **Step 5: README に追記する**

`README.md` の Development 節に追加:

```markdown
OpenCV is not built locally. `tools/opencv.ps1 restore` fetches a prebuilt
artifact produced by CI; `tools/opencv.ps1 build` reproduces that build
locally and takes 30-60 minutes, so use it only to verify what CI produced.
```

- [ ] **Step 6: Commit**

```bash
git add tools/opencv.ps1 README.md
git commit -m "feat(opencv): add the local reproducible build path"
```

---

### Task 4: CI が OpenCV をビルドして artifact を公開する

**Files:**
- Create: `.github/workflows/build-opencv.yml`

**Interfaces:**
- Consumes: Task 1〜3 の `tools/opencv.ps1 build`、`Get-OpenCvArtifactName`
- Produces: `build-opencv.yml` — artifact 名は `Get-OpenCvArtifactName` の出力と一致する
- Produces: artifact の中身は `third_party/opencv/<hash>/` の全内容（`build-manifest.json` を含む）

- [ ] **Step 1: ワークフローを書く**

```yaml
name: build-opencv

on:
  workflow_dispatch:
  push:
    paths:
      - 'tools/opencv-config.psd1'
      - 'tools/OpenCvConfig.psm1'
      - 'tools/opencv.ps1'
      - 'tools/verify-opencv-artifact.ps1'
      - '.github/workflows/build-opencv.yml'

concurrency:
  group: build-opencv-${{ github.ref }}
  cancel-in-progress: false

jobs:
  windows:
    name: OpenCV 5.0.0 Windows x64
    runs-on: windows-2022
    # ローカル実測は 30-60 分。cold runner と CI の変動を見込んで倍を取る。
    timeout-minutes: 150

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Resolve the configuration
        id: config
        shell: pwsh
        run: |
          Import-Module ./tools/OpenCvConfig.psm1 -Force
          $config = Get-OpenCvConfig
          $name = Get-OpenCvArtifactName -Config $config
          $hash = Get-OpenCvConfigHash -Config $config
          "artifact-name=$name" >> $env:GITHUB_OUTPUT
          "config-hash=$hash"   >> $env:GITHUB_OUTPUT
          Write-Host "artifact: $name"

      # ローカルと同一のコマンドを呼ぶ。CI 専用の手順は作らない。
      - name: Build OpenCV
        shell: pwsh
        run: ./tools/opencv.ps1 build

      - name: Show the manifest
        shell: pwsh
        run: Get-Content "third_party/opencv/${{ steps.config.outputs.config-hash }}/build-manifest.json"

      - name: Upload the artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ steps.config.outputs.artifact-name }}
          path: third_party/opencv/${{ steps.config.outputs.config-hash }}/
          if-no-files-found: error
          # Actions artifact の上限。90 日を超えて保持することはできないため、
          # 期限切れ後は restore が明示的に失敗して再実行を促す（tools/opencv.ps1）。
          retention-days: 90
```

- [ ] **Step 2: 手動実行して緑を確認する**

Run:

```bash
git add .github/workflows/build-opencv.yml
git commit -m "ci(opencv): build the pinned configuration and publish the artifact"
git push -u origin <branch>
gh workflow run build-opencv.yml --ref <branch>
gh run watch $(gh run list --workflow=build-opencv.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Expected: success。所要時間を記録する。

- [ ] **Step 3: artifact の中身を確認する**

Run:

```bash
gh run download <run-id> --name <artifact-name> --dir /tmp/ocv-check
cat /tmp/ocv-check/build-manifest.json
ls /tmp/ocv-check/x64/vc17/staticlib | head -20
```

Expected: `build-manifest.json` があり、`builtModules` に `videoio` が無い。`opencv_core500.lib` 等の静的ライブラリが存在する。

**「upload ステップが設定されている」ことと「実際に上がった」ことは別である。** 必ず download して中身を見ること。

- [ ] **Step 4: Commit**

Step 2 で commit 済み。追加の変更があればここで commit する。

---

### Task 5: restore（CI の artifact を download する）

**Files:**
- Modify: `tools/opencv.ps1`

**Interfaces:**
- Consumes: Task 4 の artifact 名の規約
- Produces: `tools/opencv.ps1 restore` — artifact を `third_party/opencv/<hash>/` に展開する。既に存在すれば何もしない

- [ ] **Step 1: `restore` を実装する**

`tools/opencv.ps1` の `Invoke-Build` の下に追加:

```powershell
function Invoke-Restore {
    if (Test-Path -LiteralPath (Join-Path $OpenCvRoot 'build-manifest.json')) {
        Write-Host "OpenCV $($Config.Tag) ($ConfigHash) is already present." -ForegroundColor Green
        return
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw @(
            'gh CLI が見つかりません。restore は GitHub Actions の artifact を取得します。'
            'https://cli.github.com/ を入れて `gh auth login` するか、'
            'ローカルで再現する場合は `./tools/opencv.ps1 build` を使ってください（30-60 分）。'
        ) -join "`n"
    }

    New-Item -ItemType Directory -Force -Path $OpenCvRoot | Out-Null

    Write-Host "==> download artifact '$ArtifactName'" -ForegroundColor Cyan
    & gh run download --name $ArtifactName --dir $OpenCvRoot 2>&1 | Write-Host

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $OpenCvRoot 'build-manifest.json'))) {
        Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
        throw @(
            "artifact '$ArtifactName' を取得できませんでした。"
            ''
            '考えられる原因:'
            '  1. この構成でまだ一度もビルドしていない'
            '  2. artifact が失効した（GitHub Actions の保持上限は 90 日）'
            '  3. gh が認証されていない（`gh auth status` で確認）'
            ''
            '1 と 2 のどちらでも、対処は build ワークフローの再実行です:'
            '  gh workflow run build-opencv.yml'
            ''
            'ローカルで再現する場合は `./tools/opencv.ps1 build`（30-60 分）。'
        ) -join "`n"
    }

    # download した物が本当に期待の構成か確認する。
    # artifact 名が一致していても中身が壊れている可能性はある。
    $manifest = Get-Content -LiteralPath (Join-Path $OpenCvRoot 'build-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.configHash -ne $ConfigHash) {
        Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
        throw "artifact の configHash は '$($manifest.configHash)' で、期待する '$ConfigHash' と異なります。"
    }

    Invoke-Verify | Out-Null
    Write-Host "restored OpenCV $($Config.Tag) ($ConfigHash)" -ForegroundColor Green
}
```

`switch` の `'restore'` を差し替える:

```powershell
    'restore' { Invoke-Restore }
```

- [ ] **Step 2: 失効時の挙動を確認する**

存在しない構成を一時的に作って、明示的なメッセージで失敗することを確認する。

Run:

```powershell
# 一時的に構成を変えてハッシュを変え、存在しない artifact を要求させる
Copy-Item tools/opencv-config.psd1 /tmp/opencv-config.bak
(Get-Content tools/opencv-config.psd1) -replace "'-DWITH_TIFF=OFF'", "'-DWITH_TIFF=OFF'`n        '-DOCVU_PROBE=1'" | Set-Content tools/opencv-config.psd1
pwsh -NoProfile -File tools/opencv.ps1 restore
```

Expected: FAIL。「artifact を取得できませんでした」と、**build ワークフローを再実行せよという具体的な指示**が出る。黙って失敗しないこと。

復帰: `Copy-Item /tmp/opencv-config.bak tools/opencv-config.psd1 -Force`

- [ ] **Step 3: 正常系を確認する**

Run: `pwsh -NoProfile -File tools/opencv.ps1 clean; pwsh -NoProfile -File tools/opencv.ps1 restore`
Expected: artifact が download され、`restored OpenCV 5.0.0 (<hash>)`。**所要時間を記録する**（build の 30〜60 分と対比する数字になる）。

- [ ] **Step 4: 冪等性を確認する**

Run: `pwsh -NoProfile -File tools/opencv.ps1 restore`
Expected: `is already present` と表示され、再 download しない。

- [ ] **Step 5: Commit**

```bash
git add tools/opencv.ps1
git commit -m "feat(opencv): restore the CI-built artifact instead of building locally"
```

---

### Task 6: 構成変更が古い artifact を無効化することの検証

M1 の完了条件の 1 つ。**「ハッシュが変わる」だけでなく「古い物が使われない」ことまで確認する。**

**Files:**
- Create: `tools/tests/ConfigInvalidation.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 の hash 関数、Task 5 の `restore`

- [ ] **Step 1: テストを書く**

`tools/tests/ConfigInvalidation.Tests.ps1`:

```powershell
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$base = Get-OpenCvConfig
$baseHash = Get-OpenCvConfigHash -Config $base
$baseRoot = Get-OpenCvRoot -Config $base

# 構成を変えた場合、install 先のパスそのものが変わること。
# ハッシュだけ変わってパスが同じなら、古いツリーが再利用されてしまう。
$changed = Get-OpenCvConfig
$changed.Modules = @($changed.Modules) + 'photo'
$changedHash = Get-OpenCvConfigHash -Config $changed
$changedRoot = Get-OpenCvRoot -Config $changed

Assert-That ($changedHash -ne $baseHash) 'adding a module changes the hash'
Assert-That ($changedRoot -ne $baseRoot) 'a different hash resolves to a different install root'
Assert-That ($changedRoot -like "*$changedHash*") 'the install root contains the new hash'

# 引数の並びだけが違う構成は同じハッシュになること。
# ここが変わると、意味の無い再ビルドが起きる。
$reordered = Get-OpenCvConfig
$reordered.CMakeArgs = @($reordered.CMakeArgs | Sort-Object -Descending)
Assert-That ((Get-OpenCvConfigHash -Config $reordered) -eq $baseHash) 'reordering flags does not change the hash'

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
```

- [ ] **Step 2: 実行する**

Run: `pwsh -NoProfile -File tools/tests/ConfigInvalidation.Tests.ps1`
Expected: PASS。Task 1 の実装が正しければ実装変更なしで通る。通らない場合は `Get-OpenCvRoot` がハッシュを使っていない。

- [ ] **Step 3: Commit**

```bash
git add tools/tests/ConfigInvalidation.Tests.ps1
git commit -m "test(opencv): prove a configuration change invalidates the cached artifact"
```

---

### Task 7: ハーネスを OpenCV にリンクする

M0 の 3 レーンを、OpenCV がリンクされた状態で維持する。ここで初めて ABI が OpenCV に触れる。

**Files:**
- Create: `cmake/FindOpenCvUnityDeps.cmake`
- Create: `native/src/ocvu_opencv_info.cpp`
- Create: `native/tests/test_opencv_link.cpp`
- Create: `tests/Managed/CvUnity.Tests.Managed/OpenCvInfoTests.cs`
- Modify: `native/include/opencv_unity_native.h`
- Modify: `native/CMakeLists.txt`
- Modify: `native/tests/CMakeLists.txt`
- Modify: `CMakeLists.txt`
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs`
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvNative.cs`
- Modify: `tools/dev.ps1`

**Interfaces:**
- Consumes: Task 5 の `third_party/opencv/<hash>/`
- Produces: `ocvu_status ocvu_get_opencv_version(char* buffer, int32_t buffer_size, int32_t* out_required_size)` — `"5.0.0"` を UTF-8 で返す。バッファ規約は `ocvu_get_last_error_message` と同一（不足時は `OCVU_STATUS_BUFFER_TOO_SMALL`）
- Produces: `ocvu_status ocvu_get_build_information(char* buffer, int32_t buffer_size, int32_t* out_required_size)` — `cv::getBuildInformation()` の内容
- Produces: C# 側 `CvNative.OpenCvVersion` → `string`、`CvNative.GetBuildInformation()` → `string`

- [ ] **Step 1: 失敗する L1 テストを書く**

`native/tests/test_opencv_link.cpp`:

```cpp
#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "opencv_unity_native.h"

namespace {

std::string ReadStringApi(ocvu_status (*api)(char*, int32_t, int32_t*)) {
    int32_t required = 0;
    EXPECT_EQ(api(nullptr, 0, &required), OCVU_STATUS_BUFFER_TOO_SMALL);
    if (required <= 1) {
        return std::string();
    }
    std::vector<char> buffer(static_cast<size_t>(required));
    EXPECT_EQ(api(buffer.data(), required, &required), OCVU_STATUS_OK);
    return std::string(buffer.data());
}

}  // namespace

TEST(OpenCvLink, ReportsThePinnedVersion) {
    EXPECT_EQ(ReadStringApi(&ocvu_get_opencv_version), "5.0.0");
}

TEST(OpenCvLink, VersionApiFollowsTheSameBufferContract) {
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_opencv_version(nullptr, 0, nullptr), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_get_opencv_version(nullptr, 0, &required), OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(required, 6);  // "5.0.0" + NUL

    char small[3] = {0};
    EXPECT_EQ(ocvu_get_opencv_version(small, 3, &required), OCVU_STATUS_BUFFER_TOO_SMALL);
    EXPECT_EQ(required, 6);
}

TEST(OpenCvLink, BuildInformationIsAvailable) {
    const std::string info = ReadStringApi(&ocvu_get_build_information);
    EXPECT_NE(info.find("OpenCV"), std::string::npos);
}

/*
 * 依存 allowlist を「ビルドスクリプトの grep」ではなく「リンク済みバイナリへの
 * テスト」にする。cv::getBuildInformation() は実際にリンクされた構成を返すので、
 * ここが緑であることは configure 時の意図ではなく成果物の性質を示す。
 */
TEST(OpenCvLink, ForbiddenDependenciesAreAbsentFromTheLinkedBinary) {
    std::string info = ReadStringApi(&ocvu_get_build_information);
    for (char& c : info) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }

    // "FFMPEG: NO" のような行は許される。"YES" と組になっている場合だけが問題。
    for (const char* forbidden : {"ffmpeg:                      yes",
                                  "gstreamer:                   yes"}) {
        EXPECT_EQ(info.find(forbidden), std::string::npos)
            << "linked OpenCV reports '" << forbidden << "'";
    }
}
```

- [ ] **Step 2: RED を確認する**

`native/tests/CMakeLists.txt` の `ocvu_tests` のソース一覧に `test_opencv_link.cpp` を足してから実行する。

Run: `pwsh tools/dev.ps1 test-native`
Expected: FAIL。`ocvu_get_opencv_version` が未定義。

- [ ] **Step 3: OpenCV を見つける CMake を書く**

`cmake/FindOpenCvUnityDeps.cmake`:

```cmake
# tools/opencv.ps1 が展開した OpenCV を取り込む。
#
# find_package(OpenCV) をそのまま呼ばないのは、システムに入っている
# 別バージョンを拾ってしまうと「再現可能なビルド」が崩れるため。
# 構成ハッシュで決まる 1 つのツリーだけを見る。

if(NOT DEFINED OCVU_OPENCV_ROOT OR OCVU_OPENCV_ROOT STREQUAL "")
    message(FATAL_ERROR
        "OCVU_OPENCV_ROOT が指定されていません。"
        "tools/dev.ps1 経由で呼ぶか、'./tools/opencv.ps1 restore' を先に実行してください。")
endif()

if(NOT EXISTS "${OCVU_OPENCV_ROOT}/build-manifest.json")
    message(FATAL_ERROR
        "OpenCV が '${OCVU_OPENCV_ROOT}' にありません。"
        "'./tools/opencv.ps1 restore' を実行してください（失敗する場合はメッセージに従うこと）。")
endif()

set(OpenCV_DIR "${OCVU_OPENCV_ROOT}" CACHE PATH "" FORCE)
find_package(OpenCV ${OCVU_OPENCV_REQUIRED_VERSION} EXACT REQUIRED
    COMPONENTS core imgproc
    NO_DEFAULT_PATH
    PATHS "${OCVU_OPENCV_ROOT}")

message(STATUS "OpenCV ${OpenCV_VERSION} from ${OCVU_OPENCV_ROOT}")
```

トップレベル `CMakeLists.txt` の `add_subdirectory(native)` の前に追加:

```cmake
option(OCVU_WITH_OPENCV "Link against the pinned OpenCV build" ON)
set(OCVU_OPENCV_ROOT "" CACHE PATH "Root of the restored OpenCV tree")
set(OCVU_OPENCV_REQUIRED_VERSION "5.0.0" CACHE STRING "")

if(OCVU_WITH_OPENCV)
    include(${CMAKE_SOURCE_DIR}/cmake/FindOpenCvUnityDeps.cmake)
endif()
```

- [ ] **Step 4: ABI を実装する**

`native/include/opencv_unity_native.h` の `extern "C"` ブロックに追加:

```c
/*
 * リンクされている OpenCV のバージョン文字列（例 "5.0.0"）を UTF-8 で書く。
 * バッファ規約は ocvu_get_last_error_message と同一。buffer が NULL または
 * 小さすぎる場合は OCVU_STATUS_BUFFER_TOO_SMALL を返し、これは失敗ではない。
 */
OCVU_API ocvu_status ocvu_get_opencv_version(char* buffer,
                                             int32_t buffer_size,
                                             int32_t* out_required_size);

/*
 * cv::getBuildInformation() の内容を UTF-8 で書く。
 * どの依存が有効なリンクになっているかを実行時に確認するために使う。
 * バッファ規約は ocvu_get_opencv_version と同一。
 */
OCVU_API ocvu_status ocvu_get_build_information(char* buffer,
                                                int32_t buffer_size,
                                                int32_t* out_required_size);
```

`native/src/ocvu_opencv_info.cpp`:

```cpp
#include <cstring>
#include <string>

#include <opencv2/core/utility.hpp>
#include <opencv2/core/version.hpp>

#include "ocvu_error.h"

namespace {

/*
 * 文字列を返す ABI の共通実装。
 * out_required_size は常に「NUL を含むバイト数」を受け取る。
 * buffer が不足している場合は BUFFER_TOO_SMALL を返すが、これは
 * サイズ問い合わせの正常な結果であって失敗ではない
 * （opencv_unity_native.h の OCVU_STATUS_LIST の注記を参照）。
 */
ocvu_status write_string(const std::string& value,
                         char* buffer,
                         int32_t buffer_size,
                         int32_t* out_required_size) {
    if (out_required_size == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "out_required_size is NULL");
    }

    const size_t length = value.size();
    const int32_t required = static_cast<int32_t>(length) + 1;
    *out_required_size = required;

    if (buffer == nullptr || buffer_size < required) {
        return OCVU_STATUS_BUFFER_TOO_SMALL;
    }

    std::memcpy(buffer, value.c_str(), length);
    buffer[length] = '\0';
    return OCVU_STATUS_OK;
}

}  // namespace

extern "C" ocvu_status ocvu_get_opencv_version(char* buffer,
                                               int32_t buffer_size,
                                               int32_t* out_required_size) {
    OCVU_TRY_BEGIN
    return write_string(CV_VERSION, buffer, buffer_size, out_required_size);
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_get_build_information(char* buffer,
                                                  int32_t buffer_size,
                                                  int32_t* out_required_size) {
    OCVU_TRY_BEGIN
    return write_string(cv::getBuildInformation(), buffer, buffer_size,
                        out_required_size);
    OCVU_TRY_END
}
```

`native/CMakeLists.txt` の `OCVU_SOURCES` に `src/ocvu_opencv_info.cpp` を足し、両ターゲットに OpenCV をリンクする:

```cmake
if(OCVU_WITH_OPENCV)
    target_link_libraries(opencv_unity_native PRIVATE ${OpenCV_LIBS})
    target_link_libraries(ocvu_static PUBLIC ${OpenCV_LIBS})
endif()
```

- [ ] **Step 5: `dev.ps1` が OpenCV の場所を渡すようにする**

`tools/dev.ps1` の `Build-Native` を修正:

```powershell
function Build-Native {
    Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force
    $opencvRoot = Get-OpenCvRoot -Config (Get-OpenCvConfig)
    if (-not (Test-Path -LiteralPath (Join-Path $opencvRoot 'build-manifest.json'))) {
        throw @(
            "OpenCV が '$opencvRoot' にありません。"
            "先に './tools/opencv.ps1 restore' を実行してください。"
        ) -join "`n"
    }

    Invoke-Checked {
        cmake --preset $Preset "-DOCVU_OPENCV_ROOT=$opencvRoot"
    } 'configure native'
    Invoke-Checked { cmake --build --preset $Preset } 'build native'
}
```

ASan 側の `Test-Asan` にも同じ `-DOCVU_OPENCV_ROOT` を渡すこと。

- [ ] **Step 6: GREEN を確認する**

Run: `pwsh tools/dev.ps1 test-native`
Expected: PASS。`OpenCvLink.*` の 4 テストが green。

- [ ] **Step 7: L3 を書く**

`Packages/.../Runtime/Interop/NativeMethods.cs` に追加:

```csharp
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_opencv_version(
            byte[] buffer, int bufferSize, out int requiredSize);

        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_get_build_information(
            byte[] buffer, int bufferSize, out int requiredSize);
```

`Packages/.../Runtime/Core/CvNative.cs` に追加（`ToStatus` は既存）:

```csharp
        /// <summary>リンクされている OpenCV のバージョン文字列。</summary>
        public static string OpenCvVersion => ReadString(
            NativeMethods.ocvu_get_opencv_version);

        /// <summary>リンクされている OpenCV のビルド構成。</summary>
        public static string GetBuildInformation() => ReadString(
            NativeMethods.ocvu_get_build_information);

        private delegate int StringApi(byte[] buffer, int bufferSize, out int requiredSize);

        /// <summary>
        /// 文字列を返す ABI の 2 回呼びイディオム。1 回目の BufferTooSmall は
        /// 失敗ではなくサイズ問い合わせの正常な結果である。
        /// </summary>
        private static string ReadString(StringApi api)
        {
            int required;
            api(null, 0, out required);
            if (required <= 1)
            {
                return string.Empty;
            }

            var buffer = new byte[required];
            var status = ToStatus(api(buffer, buffer.Length, out required));
            if (status != CvStatus.Ok)
            {
                return string.Empty;
            }

            return Encoding.UTF8.GetString(buffer, 0, required - 1);
        }
```

`tests/Managed/CvUnity.Tests.Managed/OpenCvInfoTests.cs`:

```csharp
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class OpenCvInfoTests
    {
        [Fact]
        public void OpenCvVersion_MatchesThePinnedVersion()
        {
            Assert.Equal("5.0.0", CvNative.OpenCvVersion);
        }

        [Fact]
        public void BuildInformation_CrossesTheBoundaryIntact()
        {
            var info = CvNative.GetBuildInformation();

            Assert.Contains("OpenCV", info);
            Assert.DoesNotContain('\0', info);
        }

        [Fact]
        public void LinkedOpenCv_DoesNotEnableForbiddenDependencies()
        {
            // 依存 allowlist を実行時のバイナリに対して検査する。
            // ビルドスクリプトの意図ではなく、実際にリンクされた構成を見る。
            var info = CvNative.GetBuildInformation().ToLowerInvariant();

            Assert.DoesNotContain("ffmpeg:                      yes", info);
            Assert.DoesNotContain("gstreamer:                   yes", info);
        }
    }
}
```

- [ ] **Step 8: 全レーンを確認する**

Run:

```powershell
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
```

Expected: 両方 PASS。**`dev.ps1 test` の所要時間を記録する。** OpenCV をリンクしてもローカルループが秒単位に留まっていることが M1 の要点の 1 つである。1 分を超えるなら報告すること。

- [ ] **Step 9: Commit**

```bash
git add cmake/FindOpenCvUnityDeps.cmake native/src/ocvu_opencv_info.cpp \
        native/tests/test_opencv_link.cpp native/include/opencv_unity_native.h \
        native/CMakeLists.txt native/tests/CMakeLists.txt CMakeLists.txt \
        tools/dev.ps1 Packages/com.ayutaz.opencv-unity-native/Runtime \
        tests/Managed/CvUnity.Tests.Managed/OpenCvInfoTests.cs
git commit -m "feat(native): link the pinned OpenCV and expose version and build info"
```

---

### Task 8: CI と文書

**Files:**
- Modify: `.github/workflows/ci-native.yml`
- Modify: `.github/workflows/ci-sanitizers.yml`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `docs/roadmap.md`
- Create: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Consumes: Task 1〜7 のすべて

- [ ] **Step 1: CI が OpenCV を restore するようにする**

`ci-native.yml` と `ci-sanitizers.yml` の checkout の後、テスト実行の前に追加:

```yaml
      - name: Restore OpenCV
        shell: pwsh
        env:
          GH_TOKEN: ${{ github.token }}
        run: ./tools/opencv.ps1 restore
```

`timeout-minutes` を見直す（restore の実測時間を加算する）。

- [ ] **Step 2: 第三者 notice を書く**

`imgcodecs` を有効にしたので、bundled の zlib / libpng / libjpeg-turbo がバイナリに入る。計画書 §8.3 の方針に従い、実際に何が入ったかを manifest から確認して記載する。

Run: `Get-Content third_party/opencv/<hash>/build-manifest.json`

`THIRD_PARTY_NOTICES.md` に、確認できた各ライブラリのライセンス種別と出典を書く。**推測で書かない。** OpenCV のソースツリー（`3rdparty/`）にある実際の LICENSE ファイルを出典として引く。

- [ ] **Step 3: 文書を更新する**

`milestone-complete` skill のステップ 4 に従って、以下が現状と一致するか確認して直す:

- `CLAUDE.md` の「リポジトリの現状」（OpenCV がもう無いとは書けない）、開発コマンドの表（`tools/opencv.ps1` が増えた）、ファイル配置、現在地（M1 完了、次は M2）
- `README.md` の status callout と Requirements（`gh` CLI が restore に必要）
- `docs/roadmap.md` の現在地

- [ ] **Step 4: 完了条件と照合する**

`milestone-complete` skill の手順を実行する。`docs/roadmap.md` の M1 完了条件 7 項目を 1 つずつ実測で照合し、表にする。

- [ ] **Step 5: Commit して PR**

`CLAUDE.md` の「変更を main へ入れるまで」に従う。**PR を出す前に、差分を書いていない別エージェントでレビューする。** レビュー結果は PR 本文に書く。

---

## Self-Review

**Spec coverage（`docs/roadmap.md` M1 完了条件）**

| 完了条件 | 対応タスク |
| --- | --- |
| `build-opencv.yml` が固定 tag・固定 flags でビルドし構成ハッシュ付き artifact を公開 | Task 1（ハッシュ）、Task 4（ワークフロー） |
| `tools/opencv.ps1 restore` が download・展開する（ローカルビルドは発生しない） | Task 5 |
| `tools/opencv.ps1 build` がローカル再現用に存在する | Task 3 |
| videoio / FFmpeg / GStreamer が無効であることを機械的に検証し、有効なら非ゼロ終了 | Task 2（ツリー検証）、Task 7 Step 1（リンク済みバイナリへのテスト） |
| `build-manifest.json` が artifact に含まれる | Task 3 Step 1、Task 4 Step 3 |
| 構成を変えると artifact のハッシュが変わり、古いキャッシュが使われない | Task 6 |
| M0 のハーネスが OpenCV にリンクした状態で全レーン通過を維持 | Task 7 Step 8 |

**Global Constraints の遵守**

- OpenCV 5.0.0 固定 / module allowlist / videoio 排除 — Task 1 の構成と Task 1 のテスト
- `/MD` / 静的 OpenCV — Task 1 の `CMakeArgs` と Task 1 のテスト
- ローカルでビルドしない — Task 5 が既定経路、Task 3 は明示的に遅い経路と位置づけ
- 例外バリア — Task 7 の両 ABI 関数が `OCVU_TRY_BEGIN` / `OCVU_TRY_END`
- UnityEngine 非依存 — Task 7 の C# は `Runtime/Core` と `Runtime/Interop` のみ、hook が検査する
- CI がローカルと同一コマンド — Task 4 は `./tools/opencv.ps1 build`、Task 8 は `restore`
- 全 job に `timeout-minutes` — Task 4、Task 8 Step 1

**未解決事項（実装中に確定する）**

- `builtModules` が `requestedModules` より多くなる（`features` は `flann` に依存する等）。Task 3 Step 4 で実測して記録する
- `cv::getBuildInformation()` の出力書式は OpenCV のバージョンに依存する。Task 7 Step 1 のテストが期待する文字列は Task 7 Step 6 の実測に合わせて調整する。**書式を推測で決め打ちしないこと**
- OpenCV の install レイアウト（`x64/vc17/staticlib` かどうか）は生成器と構成に依存する。Task 3 Step 4 で実測し、Task 2 のテストの合成ツリーがそれと一致しているか確認する
