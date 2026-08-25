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

    名前の allowlist だけでは足りなかった。ittnotify.lib と同じ形の欠陥が
    一段上、「そもそも見るファイルをどう選ぶか」にもあった。旧実装は
    Get-ChildItem に -Include '*.lib','*.dll','*.a','*.so' を渡しており、
    これ自体が拡張子の denylist で、.exe や .dylib、隠し属性のファイルは
    判定にすら届かず無条件で見過ごされていた（レビューで実証済み）。
    -Include を外し -Force を付けてツリー全体を対象にし、各ファイルを
    inert（header/cmake/notice）・binary artifact（allowlist に懸ける）・
    neither（無条件で拒否）の 3 区分に分類する。

    ここには不変条件が 1 つある: **ツリーの下のどのファイルも、何かに
    積極的に認識されない限り「問題無し」の判定に到達してはならない。**
    最初の実装はこれを 2 通りの形で破っていた。
      - inert 判定を「拡張子だけ」または「場所だけ」の OR で決めていたため、
        include/ や etc/ の下にあるというだけで binary（.dll 等）が
        まるごと免除された（etc/ittnotify.dll がまさにこの検証の
        存在理由をすり抜けた）。
      - .cmake を「その拡張子である」というだけで inert にしていたため、
        staticlib 配下の evil.cmake のような未知の名前も通ってしまった。
    対策: binary artifact かどうかは拡張子だけで判定し、これを最初に行う
    （場所は binary を免除しない）。inert は拡張子と場所の両方が期待どおり
    のときだけ、かつ .cmake のような少数しか実在しない種類は拡張子や
    場所ではなく名前そのもので認識する（third-party ライブラリと同じ規律）。
    詳細は下の Test-IsInert / $InertCMakePackageFiles / $BinaryArtifactExtensions
    の定義を見よ。

    reparse point（ディレクトリ junction / symlink）も同じ不変条件を破る:
    Get-ChildItem -Recurse はその先へ降りないため、向こう側のファイルは
    列挙にすら現れず、「見つかりさえすれば allowlist に懸けられる」という
    前提そのものが崩れる。追いかけようとすると循環や実装依存の挙動を
    招くので、reparse point の存在自体を拒否する。OpenCV の install は
    これを作らないので、存在自体が異常である。

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

# --- ファイルの発見自体を allowlist にする ---
#
# 不変条件: ツリーの下のどのファイルも、何かに積極的に認識されない限り
# 「問題無し」の判定に到達してはならない。判定の順序がこれを守る鍵になる。
#   1. binary artifact かどうかは拡張子だけで決める（最初に行う）。
#      場所は一切関係無い — include/ や etc/ の下にあっても binary は
#      binary であり、置き場所によって allowlist を免除しない。
#   2. binary でなければ、拡張子と場所の両方が期待どおりのときだけ inert
#      （headers は include/ 配下の .h/.hpp、notice/text は etc/ 配下）。
#      .cmake のように実在するのがごく少数の決まった名前しか無い種類は、
#      拡張子や場所ではなく third-party ライブラリと同じ規律で名前そのもの
#      を allowlist にする — 「.cmake だから」「staticlib 配下だから」という
#      緩い条件では evil.cmake のような未知の名前も通ってしまう。
#   3. どちらでもなければ無条件で拒否する。
$BinaryArtifactExtensions = @('.lib', '.a', '.so', '.dylib', '.dll', '.exe')

# 実際にビルドしたツリー（third_party/opencv/64a038c63634）にある
# .cmake package file はこの 4 つの名前だけ。root にも x64/vc17/staticlib/
# にも同じ名前で現れるが、場所では判定しない — 名前で認識する。
$InertCMakePackageFiles = @(
    'OpenCVConfig.cmake', 'OpenCVConfig-version.cmake',
    'OpenCVModules.cmake', 'OpenCVModules-release.cmake'
)
# root 直下にある、この検証自身が書く manifest と OpenCV 本体の LICENSE。
$InertRootFiles = @('LICENSE', 'build-manifest.json')

$rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

function Get-TopLevelDir([System.IO.FileInfo]$file) {
    $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/')
    $segments = $relative -split '[\\/]'
    if ($segments.Count -gt 1) { return $segments[0] }
    return ''
}

function Test-IsInert([System.IO.FileInfo]$file) {
    $topDir = (Get-TopLevelDir $file).ToLowerInvariant()
    $ext = $file.Extension.ToLowerInvariant()

    # header: include/ 配下の .h / .hpp。拡張子と場所の両方が条件。
    if ($topDir -eq 'include' -and $ext -in @('.h', '.hpp')) { return $true }

    # notice/text: etc/ 配下の、実際にビルドしたツリーで見つかったのと
    # 同じ種類のファイル（拡張子無しの LICENSE/README 系も含む）。
    if ($topDir -eq 'etc' -and $ext -in @('.txt', '.md', '.ijg', '')) { return $true }

    # cmake package file: 場所ではなく名前そのもので認識する。
    if ($file.Name -in $InertCMakePackageFiles) { return $true }

    if ($topDir -eq '' -and $file.Name -in $InertRootFiles) { return $true }

    return $false
}

# reparse point（ディレクトリ junction / symlink）はそもそも辿らない —
# Get-ChildItem -Recurse はその先へ降りないため、向こう側のファイルは
# 列挙にすら現れない。「見つかりさえすれば allowlist に懸けられる」という
# 前提が、reparse point の向こうでは成立しない。追いかけて解決しようと
# すると循環や実装依存の挙動を招くので、存在自体を拒否する。OpenCV の
# install はこれを作らないので、存在自体が異常である。
$reparsePoints = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
if ($reparsePoints.Count -gt 0) {
    $names = ($reparsePoints | ForEach-Object { $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') }) -join ', '
    [Console]::Error.WriteLine("reparse point（ディレクトリ junction / symlink）がツリーに含まれています: $names`nOpenCV の install はこれを作りません。向こう側は列挙できないため、追いかけずに拒否します。")
    exit 1
}

# -Include を付けない: 対象拡張子を先に決め打ちすると、まさに今回のバグ
# （想像しなかった拡張子が判定に届かない）を再発させる。-Force で隠し・
# システムファイルも対象にする。
#
# @() で配列化する: 一致するファイルがちょうど 1 件のとき Get-ChildItem は
# スカラーの FileInfo を返す。ラップしないと直後の $files.Count が
# StrictMode 下で PropertyNotFoundException を投げ、それでも非ゼロ終了に
# なるため「missing module の意図した拒否」と区別のつかない失敗になる。
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    [Console]::Error.WriteLine("No files found under '$Root'. Was the build produced?")
    exit 1
}

$found = @()
$violations = @()
foreach ($file in $files) {
    $lower = $file.Name.ToLowerInvariant()
    $ext = $file.Extension.ToLowerInvariant()

    # 1. binary artifact かどうかを最初に、拡張子だけで決める。場所は
    #    binary を免除しない — これが include/evil.dll と etc/ittnotify.dll
    #    を構造的に閉じる部分である。
    if ($ext -in $BinaryArtifactExtensions) {
        # 受け入れると決めた OpenCV module か（opencv_<name><version>.(lib|a)
        # の形で、かつ name が $PermittedOpenCvModules に入っているもの）。
        if ($file.Name -match '^opencv_(?<name>[a-z0-9_]+?)\d*\.(lib|a)$') {
            $moduleName = $Matches['name']
            if ($moduleName -in $PermittedOpenCvModules) {
                $found += $moduleName
                continue
            }
            $violations += "  $($file.Name) — OpenCV module '$moduleName' は許可リストに無い ($(Get-RejectionReason $file.Name))"
            continue
        }

        # 明示的に受け入れた third-party ライブラリか。
        if ($lower -in ($PermittedThirdPartyLibs | ForEach-Object { $_.ToLowerInvariant() })) {
            continue
        }

        # どちらでもなければ拒否。
        $violations += "  $($file.Name) — $(Get-RejectionReason $file.Name)"
        continue
    }

    # 2. binary でなければ、拡張子と場所の両方が期待どおりのときだけ inert。
    if (Test-IsInert $file) { continue }

    # 3. inert でも binary artifact でもない、未知の種類のファイルは
    #    無条件で拒否する。
    $violations += "  $($file.Name) — 未知の種類のファイルです（拡張子 '$ext'）。inert（header/cmake/notice）か binary artifact のどちらに区分するかを決めたうえで tools/verify-opencv-artifact.ps1 を更新してください"
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
