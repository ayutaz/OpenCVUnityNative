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

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
