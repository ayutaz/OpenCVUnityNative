#Requires -Version 7.0
# Pester を使わず素の assert で書く。依存を増やさないため。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

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

# 実行中の platform で組み立てる。'windows-x64' を直書きすると macOS / Linux で
# 必ず落ち、そこで dev.ps1 test が止まって L1 も L3 も走らなくなる（M3 のレビューで発見）。
Assert-That ((Get-OpenCvArtifactName -Config $config) -eq "opencv-5.0.0-$($config.Platform)-$hash1") 'artifact name embeds the platform and the hash'

# 並び順を変えても同じハッシュになること（order-insensitive）。
# Sort-Object を将来のリファクタで取りこぼしても検知できるよう、
# 一度きりの ad hoc 確認ではなくテストスイートに残す。
$shuffled = Get-OpenCvConfig
$shuffled.CMakeArgs = @($shuffled.CMakeArgs[-1]) + @($shuffled.CMakeArgs[0..($shuffled.CMakeArgs.Count - 2)])
$shuffled.Modules = @($shuffled.Modules[-1]) + @($shuffled.Modules[0..($shuffled.Modules.Count - 2)])
Assert-That ((Get-OpenCvConfigHash -Config $shuffled) -eq $hash1) 'reordering CMakeArgs and Modules does not change the hash'

# 正規化が単射であること。区切り文字で join するだけの正規化は、
# 要素境界に区切り文字自体を含む値が来ると衝突し得る
# （["-DAAA=1","-DBBB=2"] と ["-DAAA=1 -DBBB=2"] が同じ文字列になる）。
# 今の固定構成には空白・カンマを含む flag/module は無いが、
# Task 3 / 7 で CMakeArgs が増える前提なので、ここで塞いでおく。
$collisionA = Get-OpenCvConfig
$collisionA.CMakeArgs = @('-DAAA=1', '-DBBB=2')
$collisionB = Get-OpenCvConfig
$collisionB.CMakeArgs = @('-DAAA=1 -DBBB=2')
Assert-That ((Get-OpenCvConfigHash -Config $collisionA) -ne (Get-OpenCvConfigHash -Config $collisionB)) 'CMakeArgs elements do not collide across element boundaries'

$moduleCollisionA = Get-OpenCvConfig
$moduleCollisionA.Modules = @('core', 'imgproc')
$moduleCollisionB = Get-OpenCvConfig
$moduleCollisionB.Modules = @('core,imgproc')
Assert-That ((Get-OpenCvConfigHash -Config $moduleCollisionA) -ne (Get-OpenCvConfigHash -Config $moduleCollisionB)) 'Modules elements do not collide across element boundaries'


# Get-OpenCvDependencyVersions は形式の違う 2 つの入力を受ける。ここは
# 両方を固定する。片方だけを固定していたために、本番だけが常に 0 件を
# 返す欠陥が緑のまま通っていた（再レビュー F1）:
#
#   本番 (tools/opencv.ps1)  cmake configure の stdout。message(STATUS) 経由
#                            なので cmake が各行に "-- " を前置する。
#   実行時・旧テスト          cv::getBuildInformation() の戻り値。前置は無い。
#
# 内容が同じでも行頭が違うので、前置を剥がさない実装は後者だけを通す。
# 下の $sample は後者の形。$samplePrefixed はそれに "-- " を付けた前者の形で、
# 実際の CI ログ（gh run view 32849957498 --log）と同じ字面になる。
$sampleBuildInformation = @'

General configuration for OpenCV 5.0.0 =====================================
  Version control:               5.0.0

  C/C++:
    Built as dynamic libs?:      NO
    C++ Compiler:                C:/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe  (ver 19.44.35228.0)
    3rdparty dependencies:       libclapack libjpeg-turbo libpng zlib

  Media I/O:
    ZLib:                        build (ver 1.3.2)
    JPEG:                        build-libjpeg-turbo (ver 3.1.2-70)
      SIMD Support Request:      YES
      SIMD Support:              NO
    AVIF:                        NO
    PNG:                         build (ver 1.6.57)
      SIMD Support Request:      YES
    GIF:                         YES

  Other third-party libraries:
    Lapack:                      YES (Built-In libclapack)
    Custom HAL:                  NO
    Flatbuffers:                 builtin/3rdparty (25.9.23)

  Install to:                    D:/a/OpenCVUnityNative/OpenCVUnityNative/third_party/opencv/6ba270f342e3
-----------------------------------------------------------------
'@

$depVersions = Get-OpenCvDependencyVersions -BuildInformation $sampleBuildInformation
Assert-That ($depVersions['ZLib'] -eq '1.3.2') 'ZLib version is extracted from Media I/O'
Assert-That ($depVersions['JPEG'] -eq '3.1.2-70') 'JPEG (libjpeg-turbo) version is extracted, hyphen and all'
Assert-That ($depVersions['PNG'] -eq '1.6.57') 'PNG version is extracted'
Assert-That (-not $depVersions.Contains('SIMD Support Request')) 'a 6-space-indented sub-item is not mistaken for a dependency'
Assert-That (-not $depVersions.Contains('GIF')) 'a versionless entry (no "(ver X)") is not included'

# C++ Compiler も "(ver X.Y.Z)" という同じ書式を使うが、これは
# ツールチェーン自身のバージョンであって bundle された third-party
# ではないので、Media I/O: 以外の section を対象にしない設計が
# これを拾わないことを確認する。
Assert-That (-not $depVersions.Contains('C++ Compiler')) 'the C++ compiler version (same "(ver X)" format, different section) is not mistaken for a dependency'

# Flatbuffers は「Other third-party libraries:」に本物の "(ver 相当)" の
# 括弧付きバージョンで現れるが、dnn/gapi 用の検出結果であり、この構成の
# 実際のビルドには linked されていない（THIRD_PARTY_NOTICES.md の
# symbol-table 検証で確認済み）。Media I/O: だけを対象にする設計が
# これを拾わないことを確認する — 拾ってしまうと THIRD_PARTY_NOTICES.md の
# 「present but not linked」という判断と build-manifest.json が食い違う。
Assert-That (-not $depVersions.Contains('Flatbuffers')) 'Flatbuffers (present but not linked into this configuration) is not included'

# libclapack はどの section にもバージョン文字列が出ない
# ("YES (Built-In libclapack)" のみ)。無いものを捏造しないことを確認する。
Assert-That (-not $depVersions.Contains('Lapack')) 'libclapack has no reported version and is not fabricated'

# --- 本番の入力形式（cmake configure stdout）での回帰テスト ---
#
# 抽出器がこの形式に対して 0 件を返していたのが再レビュー F1。テストが
# 前置無しの形式しか使っていなかったため、CI は緑のまま manifest の
# dependencyVersions だけが常に空になっていた。両形式が同じ結果を返す
# ことをここで固定する。
$samplePrefixed = ($sampleBuildInformation -split "`r?`n" | ForEach-Object { "-- $_" }) -join "`n"

$fromPlain    = Get-OpenCvDependencyVersions -BuildInformation $sampleBuildInformation
$fromPrefixed = Get-OpenCvDependencyVersions -BuildInformation $samplePrefixed

Assert-That ($fromPrefixed.Count -gt 0) 'cmake configure stdout ("-- " 前置) からも version を抽出できる'
Assert-That ($fromPrefixed.Count -eq $fromPlain.Count) '前置の有無で抽出件数が変わらない'
foreach ($key in $fromPlain.Keys) {
    Assert-That ($fromPrefixed[$key] -eq $fromPlain[$key]) "前置の有無で $key のバージョンが一致する"
}

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

# --- psd1 に新しい top-level キーを足すとハッシュが動く ---
#
# Get-OpenCvConfig がキーを名指しで列挙すると、psd1 に足したキーが構成に
# 入らず「構成を変えたのにハッシュが動かない」状態になる。M1 の H3 は
# Get-OpenCvConfigHash について同じ欠陥を閉じたが、列挙を Get-OpenCvConfig へ
# 移すと 1 段上で再発する（M3 Task 1 の初回実装が実際にそうなっていた:
# ContribTag を足してもハッシュが 4785d98e9aad のまま動かなかった）。
#
# 実ファイルを一時的に書き換えて確かめる。読み取り専用の検査では、
# 「列挙している実装」と「していない実装」を区別できない。
$configPath = Join-Path $PSScriptRoot '../opencv-config.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
$backup = Get-Content -LiteralPath $configPath -Raw
try {
    $baseline = Get-OpenCvConfigHash -Config (Get-OpenCvConfig -Platform 'windows-x64')

    # 将来ありうる top-level キーを足す（contrib の tag など）
    ($backup -replace "(?m)^(\s*)Tag = '5\.0\.0'", "`$1Tag = '5.0.0'`n`$1OcvuHashProbeKey = 'probe'") |
        Set-Content -LiteralPath $configPath -NoNewline

    $withNewKey = Get-OpenCvConfigHash -Config (Get-OpenCvConfig -Platform 'windows-x64')
    Assert-That ($withNewKey -ne $baseline) `
        'adding a new top-level key to opencv-config.psd1 changes the hash'
}
finally {
    Set-Content -LiteralPath $configPath -Value $backup -NoNewline
    # 復元できたことを確かめる。ここが崩れると以降のテストが嘘の値で走る。
    $restored = Get-OpenCvConfigHash -Config (Get-OpenCvConfig -Platform 'windows-x64')
    Assert-That ($restored -eq $baseline) 'opencv-config.psd1 is restored to its original content'
}

# --- CMakePresets に全 platform 分が在り、名前が platform と一致する ---
#
# preset 名を platform 名から機械的に導くので、片方だけ足して他方を忘れると
# 「preset が無い」という実行時エラーになる。ここで先に落とす。
$presetsPath = Join-Path $repoRoot 'CMakePresets.json'
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

# --- manifest に platform を決め打ちしていないこと ---
#
# opencv.ps1 の Write-BuildManifest が platform を文字列で持っていると、
# macOS / Linux でビルドしても windows-x64 と記録され、manifest が実物と
# 食い違う。「成果物に何が入っているか」の申告が嘘になるので、M3 の SBOM
# にもそのまま伝播する（M3 Task 2 のレビューで実際に見つかった）。
#
# 実行時の値は CI でしか確かめられないので、ここではソースを検査する。
# 検査対象が構成から取っていることを見るのが目的で、値そのものではない。
$opencvScript = Join-Path $PSScriptRoot '../opencv.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
$manifestSource = Get-Content -LiteralPath $opencvScript -Raw

Assert-That ($manifestSource -notmatch "platform\s*=\s*'[a-z0-9-]+'") `
    'the build manifest does not hardcode a platform string'
Assert-That ($manifestSource -match 'platform\s*=\s*\$Config\.Platform') `
    'the build manifest takes its platform from the configuration'

# --- install ターゲット名を generator に応じて選んでいること ---
#
# 'INSTALL'（大文字）は Visual Studio generator のターゲット名で、Ninja には
# 存在しない。決め打ちすると macOS / Linux のビルドが
# 「ninja: error: unknown target 'INSTALL'」で落ちる（M3 Task 4 の CI 初回で
# 実際に両方落ちた。configure は成功しており、ここだけが違っていた）。
#
# 実行時の挙動は CI でしか確かめられないので、ソースを検査する。
$opencvSource = Get-Content -LiteralPath $opencvScript -Raw

Assert-That ($opencvSource -match "Generator -like 'Visual Studio\*'") `
    'the build step branches on the generator rather than assuming one'
Assert-That ($opencvSource -match "--target', 'install'") `
    'single-config generators get the lowercase install target'


# --- Linux のビルドコンテナ: 設定と workflow が一致すること ---
#
# イメージ名は 2 箇所に書かれる。opencv-config.psd1（構成ハッシュに入る正本）と、
# workflow の container: 指定（GitHub Actions は job 開始前に解決するので、
# 設定ファイルから読めない）である。
#
# **片方だけ動かすと、構成ハッシュが指す artifact と実際にビルドされる
# 環境が食い違う。** ハッシュは「同じ構成なら同じ成果物」を意味するはず
# なので、この食い違いはその前提を壊す。2 箇所に同じ事実を書かざるを得ない
# 以上、ずれたことを機械が言う必要がある。
$config = Get-OpenCvConfig -Platform 'linux-x64'
$expectedImage = $config.Toolchain.Container
Assert-That ($null -ne $expectedImage -and $expectedImage -ne '') `
    'the linux-x64 toolchain declares a build container'

if ($expectedImage) {
    $workflows = @(
        '.github/workflows/build-opencv.yml'
        '.github/workflows/ci-native.yml'
        '.github/workflows/ci-sanitizers.yml'
        '.github/workflows/release.yml'
    )
    foreach ($wf in $workflows) {
        $path = Join-Path $repoRoot $wf
        Assert-That (Test-Path -LiteralPath $path) "workflow exists: $wf"
        if (-not (Test-Path -LiteralPath $path)) { continue }

        $text = Get-Content -LiteralPath $path -Raw
        Assert-That ($text -match "container:.*$([regex]::Escape($expectedImage))") `
            "$wf uses the container declared in opencv-config.psd1 ($expectedImage)"

        # 古い runner で直接ビルドしていないこと。container: を足しても
        # 別の job が ubuntu-24.04 で .so を作っていたら意味が無い。
        Assert-That ($text -notmatch "(?m)^\s*container:\s*ubuntu-24") `
            "$wf does not build in a bare ubuntu-24 container"
    }

    # ci-unity は job をコンテナにできない（game-ci が docker を使うため）ので、
    # 設定から読んで docker run する形になっている。読めていることを見る。
    $unity = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/ci-unity.yml') -Raw
    Assert-That ($unity -match 'opencv-config\.psd1') `
        'ci-unity.yml derives the build image from opencv-config.psd1'
    Assert-That ($unity -match 'verify-plugin-portability') `
        'ci-unity.yml verifies the plugin portability before running Unity'
}
if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
