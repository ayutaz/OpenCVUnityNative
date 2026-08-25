#Requires -Version 7.0
<#
    ビルド済み OpenCV ツリーの依存 allowlist を検証する。

    configure 時のフラグではなく、実際にできたファイルを見る。理由は 2 つある。
    1. BUILD_LIST は依存を自動解決するので、要求した module と実際にできる
       物は一致しない。
    2. WITH_FFMPEG=OFF を渡したつもりでも、configure が prebuilt プラグインを
       取得していれば DLL がツリーに現れる（計画書 §8.2）。フラグを見ても
       それは分からない。

    判定は allowlist（許可リストに無いものは無条件で拒否）でなければならない。
    denylist（既知の悪いものだけを拒否する）は著者が想像した名前しか拒否できず、
    「想定外の依存が紛れ込む」という本来防ぎたい事故そのものを取り逃す。
    実際に ittnotify.lib（Intel VTune 計装。BSD-3-Clause / GPL-2.0-only の
    デュアルライセンスで、GPL 側を引いた配布は本プロジェクトの方針に反する）
    が、どの denylist パターンにも一致せず allowlist OK と誤判定された。

    許可される集合は 3 つだけ:
      1. このビルド構成で受け入れると決めた OpenCV module（$PermittedOpenCvModules）。
         config が要求する 5 module に加え、BUILD_LIST の依存解決で実際に
         引き込まれ、レビュー済みの module（flann, geometry）を含む。
         opencv_ prefix を持つというだけで無条件に許可しない — videoio が
         opencv_ prefix を持ちながら許可されないのはこのため。
      2. 明示的に受け入れた third-party ライブラリ（$PermittedThirdPartyLibs）。
         実際にビルドしたツリーを見て確定した集合であり、想像で足さない。
      3. 上記のどちらにも無いものは全て拒否。

    forbidden pattern の denylist は判定そのものには使わない（もう判定を
    決めない）。拒否理由のメッセージを「なぜ嫌われているか」まで具体的に
    言うためだけの第二層として残す。一致しなければ「unrecognised」という
    汎用メッセージになる。

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
    [Console]::Error.WriteLine("OpenCV tree not found at '$Root'.")
    exit 1
}

# BUILD_LIST は依存を自動解決する。features / objdetect が flann と geometry
# を引き込むことは実際のビルドで確認済みで、レビュー済みの追加として
# ここに明示する。増えたら（=依存関係が変わったら）このリストを更新する
# という「気づいて意図的に直す」動作が allowlist の目的そのものである。
$AcceptedTransitiveModules = @('flann', 'geometry')
$PermittedOpenCvModules = @(@($config.Modules) + $AcceptedTransitiveModules | Sort-Object -Unique)

# third-party dependency の許可リスト。実際にビルドしたツリー
# （third_party/opencv/<hash>/x64/vc17/staticlib）を見て確定した集合。
# 想像で足さない — 新しい third-party が現れたら、ライセンスを確認した上で
# ここに追加するかどうかを人間が判断する。
$PermittedThirdPartyLibs = @(
    'zlib.lib'          # zlib, zlib License
    'libpng.lib'        # libpng, libpng License (Apache-2.0 互換)
    'libjpeg-turbo.lib' # libjpeg-turbo, BSD-3-Clause / IJG / zlib のトリプルライセンス
    'libclapack.lib'    # CLAPACK, BSD-3-Clause (University of Tennessee)。LAPACK 実装で core が使う
)

# 名前に現れたら拒否理由を具体的に説明できるもの。
#
# もはや許可・拒否そのものを決めない（allowlist が決める）。ここでの役割は
# 「なぜこの名前が歓迎されないか」を拒否メッセージに添えることだけである。
# Pattern は -like にそのまま渡すワイルドカードパターンで、各ルールが
# 自分の一致範囲を明示する（全ルールを一律 "*...*" で包む実装だと、
# ipp のような短い断片が "clipper"（cl-ipp-er）のような無関係な名前の
# 一部に一致して誤検出する）。
$knownBadPatterns = @(
    @{ Pattern = '*videoio*';   Why = 'videoio は allowlist 外（FFmpeg / GStreamer を引き込む）' }
    @{ Pattern = '*ffmpeg*';    Why = 'FFmpeg は配布ライセンスが Apache-2.0 と別条件' }
    @{ Pattern = '*gstreamer*'; Why = 'GStreamer は allowlist 外' }
    @{ Pattern = '*ittnotify*'; Why = 'Intel ITT は BSD-3-Clause / GPL-2.0-only のデュアルライセンス。GPL 側を引いた配布を避けるため未使用のまま' }
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

function Get-RejectionReason([string]$fileName) {
    $lower = $fileName.ToLowerInvariant()
    foreach ($rule in $knownBadPatterns) {
        if ($lower -like $rule.Pattern) { return $rule.Why }
    }
    return 'allowlist に無い未知のライブラリです。ライセンスを確認したうえで、意図的に tools/verify-opencv-artifact.ps1 の許可リストへ追加してください'
}

# @() で配列化する: 一致するファイルがちょうど 1 件のとき Get-ChildItem は
# スカラーの FileInfo を返す。ラップしないと直後の $files.Count が
# StrictMode 下で PropertyNotFoundException を投げ、それでも非ゼロ終了に
# なるため「missing module の意図した拒否」と区別のつかない失敗になる。
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.lib', '*.dll', '*.a', '*.so' -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    [Console]::Error.WriteLine("No libraries found under '$Root'. Was the build produced?")
    exit 1
}

$found = @()
$violations = @()
foreach ($file in $files) {
    $lower = $file.Name.ToLowerInvariant()

    # 1. 受け入れると決めた OpenCV module か（opencv_<name><version>.(lib|a) の形で、
    #    かつ name が $PermittedOpenCvModules に入っているもの）。
    if ($file.Name -match '^opencv_(?<name>[a-z0-9_]+?)\d*\.(lib|a)$') {
        $moduleName = $Matches['name']
        if ($moduleName -in $PermittedOpenCvModules) {
            $found += $moduleName
            continue
        }
        $violations += "  $($file.Name) — OpenCV module '$moduleName' は許可リストに無い ($(Get-RejectionReason $file.Name))"
        continue
    }

    # 2. 明示的に受け入れた third-party ライブラリか。
    if ($lower -in ($PermittedThirdPartyLibs | ForEach-Object { $_.ToLowerInvariant() })) {
        continue
    }

    # 3. どちらでもなければ拒否。
    $violations += "  $($file.Name) — $(Get-RejectionReason $file.Name)"
}

if ($violations.Count -gt 0) {
    # PowerShell の Write-Error は "Write-Error: <script>:<line>" ヘッダと
    # ソース行 + キャレットのブロックでメッセージ本文を包む。この検証は
    # CI が失敗理由を一目で読めることが目的で、ソースコードの引用はその
    # 妨げにしかならない。stderr に直接書いて装飾を避ける。
    [Console]::Error.WriteLine((@(
                'OpenCV のビルド成果物に allowlist 外の依存が含まれています。'
                ''
                ($violations | Sort-Object -Unique)
                ''
                '意図した third-party なら tools/verify-opencv-artifact.ps1 の許可リストに、'
                'OpenCV module なら $PermittedOpenCvModules に追加してください。'
                'CMakeArgs を見直した場合は tools/opencv-config.psd1 の変更になり、構成ハッシュが変わって再ビルドが必要になります。'
            ) -join "`n"))
    exit 1
}

$found = @($found | Sort-Object -Unique)

$missing = @($config.Modules | Where-Object { $_ -notin $found })
if ($missing.Count -gt 0) {
    [Console]::Error.WriteLine((@(
                "要求した module がビルド成果物にありません: $($missing -join ', ')"
                "見つかったもの: $($found -join ', ')"
                'BUILD_LIST の指定か、モジュール名を確認してください。'
                'OpenCV 5 では features2d -> features、calib3d -> calib/geometry に再編されています。'
            ) -join "`n"))
    exit 1
}

$found | ForEach-Object { Write-Output $_ }
exit 0
