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

# CI のログは UTF-8。指定しないと Windows の PowerShell は既定の ANSI
# コードページで書き出し、失敗の理由が読めなくなる。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force
$config = Get-OpenCvConfig

if (-not (Test-Path -LiteralPath $Root)) {
    Write-Error "OpenCV tree not found at '$Root'."
    exit 1
}

# 名前に現れたら即座に失格とするもの。
#
# Pattern は -like にそのまま渡すワイルドカードパターンで、各ルールが
# 自分の一致範囲を明示する（全ルールを一律 "*...*" で包む実装だと、
# ipp のような短い断片が "clipper"（cl-ipp-er）のような無関係な名前の
# 一部に一致して誤検出する）。
$forbiddenPatterns = @(
    @{ Pattern = '*videoio*';   Why = 'videoio は allowlist 外（FFmpeg / GStreamer を引き込む）' }
    @{ Pattern = '*ffmpeg*';    Why = 'FFmpeg は配布ライセンスが Apache-2.0 と別条件' }
    @{ Pattern = '*gstreamer*'; Why = 'GStreamer は allowlist 外' }
    # IPP のライブラリ名は ippicv.lib / ippiw.lib だけではない。外部 IPP
    # （WITH_IPP=ON + IPPROOT）は ippcoremt.lib / ippsmt.lib / ippimt.lib /
    # ippccmt.lib / ippcvmt.lib / ippvmmt.lib を、Integration Wrappers は
    # ipp_iw.lib を生成する（OpenCVFindIPP.cmake / OpenCVFindIPPIW.cmake）。
    # いずれも ipp で「始まる」ので、前方一致（末尾のみワイルドカード）で
    # 十分かつ安全。部分文字列一致（*ipp*）にすると clipper.lib のような
    # 無関係なファイル名の途中にたまたま ipp を含むものまで拾ってしまう。
    # OpenCV 自身の module 名は opencv_ で始まり ipp を名乗らないので衝突しない。
    @{ Pattern = 'ipp*';        Why = 'IPP は Intel の独自条項。有効化は M7 で検討する' }
    @{ Pattern = '*protobuf*';  Why = 'protobuf は dnn 用で allowlist 外' }
    @{ Pattern = '*libtiff*';   Why = 'TIFF は allowlist 外' }
    @{ Pattern = '*libwebp*';   Why = 'WebP は allowlist 外' }
    @{ Pattern = '*openexr*';   Why = 'OpenEXR は allowlist 外' }
    # OpenCV 5 は OpenEXR を vendor しなくなったが、環境に prebuilt が
    # あると IlmImf という別名でリンクされ得る（openexr という文字列を含まない）。
    @{ Pattern = '*ilmimf*';    Why = 'OpenEXR は allowlist 外（IlmImf という別名でも配布される）' }
    @{ Pattern = '*openjp*';    Why = 'JPEG2000 は allowlist 外' }
    @{ Pattern = '*jasper*';    Why = 'Jasper は allowlist 外' }
)

# @() で配列化する: 一致するファイルがちょうど 1 件のとき Get-ChildItem は
# スカラーの FileInfo を返す。ラップしないと直後の $files.Count が
# StrictMode 下で PropertyNotFoundException を投げ、それでも非ゼロ終了に
# なるため「missing module の意図した拒否」と区別のつかない失敗になる。
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.lib', '*.dll', '*.a', '*.so' -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Error "No libraries found under '$Root'. Was the build produced?"
    exit 1
}

$violations = @()
foreach ($file in $files) {
    $lower = $file.Name.ToLowerInvariant()
    foreach ($rule in $forbiddenPatterns) {
        if ($lower -like $rule.Pattern) {
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
