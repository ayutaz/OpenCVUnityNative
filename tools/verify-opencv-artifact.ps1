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
         config が要求する module に加え、BUILD_LIST の依存解決で実際に
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
    [Parameter(Mandatory)][string]$Root,

    # 同梱ライセンスの一覧と突き合わせる公開用の通知文書。既定はリポジトリ
    # 直下。artifact ツリーの外にあるので、$Root とは別に受け取る。
    [string]$NoticesPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'THIRD_PARTY_NOTICES.md')
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
#
# stereo は calib が引き込む（2026-09-02 に実測。calib を Modules へ足した
# 最初のビルドが、まさにこの検査で落ちて分かった —— run 33589061515 の
# 4 platform が `opencv_stereo500.lib — OpenCV module 'stereo' は許可リストに
# 無い` で停止した）。**この検査が意図どおり働いた例である。**
#
# stereo は OpenCV 本体の module（ステレオ対応点探索）であって third-party
# ではない。ライセンスは OpenCV 本体と同じで、新しい bundled 依存も持ち込まない
# （同じビルドの install ログに、stereo 由来の etc/licenses は 1 件も現れない）。
# **上の 2 行（ライセンスと bundled 依存）は、いまも成立している。**
# allowlist に stereo を載せる根拠はそこであって、下の文ではない。
#
# **ここに在った次の 1 文は 2026-09-05 に失効した:**
#   「このプラグインは stereo のシンボルを 1 つも参照しないので、
#     配布する binary には入らない。」
# ocvu_compute_disparity が cv::StereoBM / cv::StereoSGBM を参照するように
# なったので、stereo は cmake/FindOpenCvUnityDeps.cmake の COMPONENTS に入り、
# **配布する binary にも入る。** **失効しても allowlist の判断は変わらない** ——
# 根拠は上の 2 行だったからである。
$AcceptedTransitiveModules = @('flann', 'geometry', 'stereo')
$PermittedOpenCvModules = @(@($config.Modules) + $AcceptedTransitiveModules | Sort-Object -Unique)

# third-party dependency の許可リスト。実際にビルドしたツリー
# （third_party/opencv/<hash>/x64/vc17/staticlib）を見て確定した集合。
# 想像で足さない — 新しい third-party が現れたら、ライセンスを確認した上で
# ここに追加するかどうかを人間が判断する。
#
# **ファイル名ではなくライブラリ名で持つ。** 命名規約が platform で違うためで、
# 同じ zlib が Windows では zlib.lib、Unix では libzlib.a になる（実測、M3 Task 4）。
# ファイル名で持つと同じライブラリを 2 回書くことになり、片方だけ更新される。
# 判定側が 'lib' 接頭辞と拡張子を剥がしてからここと突き合わせる。
$PermittedThirdPartyLibs = @(
    'zlib'          # zlib, zlib License
    'libpng'        # libpng, libpng License (Apache-2.0 互換)
    'libjpeg-turbo' # libjpeg-turbo, BSD-3-Clause / IJG / zlib のトリプルライセンス
    'libclapack'    # CLAPACK, BSD-3-Clause (University of Tennessee)。LAPACK 実装で core が使う

    # --- arm64 (Apple Silicon) の最適化実装。Windows のビルドには現れない ---
    # KleidiCV: Arm 製の CV 最適化ライブラリ。Apache-2.0。
    # OpenCV 5 が arm64 で既定で取り込む。
    'kleidicv'
    'kleidicv_hal'
    'kleidicv_thread'
    # Tegra HAL: OpenCV 本体に同梱される arm 向け HAL の入れ物。Apache-2.0。
    'tegra_hal'

    # --- Android のビルドにだけ現れる ---
    #
    # cpufeatures: Android NDK が同梱する実行時 CPU 判定ライブラリ
    # （sources/android/cpufeatures）。**BSD-3-Clause、The Android Open Source
    # Project**（2026-08-30 に一次情報で確認:
    # https://android.googlesource.com/platform/ndk/+/master/sources/android/cpufeatures/cpu-features.c）。
    #
    # **binary 形式での再頒布に著作権表示と免責の同梱を求める**ので、
    # THIRD_PARTY_NOTICES.md に全文を入れてある。Apache-2.0 と両立する。
    'cpufeatures'
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

# etc/licenses/ 配下は「拡張子と場所」ではなく、実際にビルドしたツリー
# （third_party/opencv/6ba270f342e3/etc/licenses）にある 13 個のファイル名
# そのものを allowlist にする。.cmake package file と同じ規律。
#
# 以前はここを $topDir -eq 'etc' -and $ext -in @('.txt', '.md', '.ijg', '')
# という「場所と拡張子だけ」の判定にしていたため、OpenCV のビルドが新しい
# third-party の license ファイルを etc/licenses/ に追加しても（例:
# etc/licenses/ffmpeg-LICENSE のような想定外の名前でも）拡張子と場所さえ
# 一致すれば無条件で inert 判定に落ち、CI も THIRD_PARTY_NOTICES.md も
# 何も言わなかった（レビューで実証済み: 合成ツリーに置いた
# etc/licenses/ffmpeg-LICENSE が検出されずに素通りした）。license
# ファイルが増えるという「唯一の機械可読なシグナル」を、まさにそれを
# 見るべき場所で握りつぶしていた。
#
# 新しい third-party が bundle されるようになったら、このリストと
# THIRD_PARTY_NOTICES.md の両方を更新する（どちらか一方だけでは不十分 —
# THIRD_PARTY_NOTICES.md 冒頭の「このリストの更新手順」を参照）。
$InertLicenseFiles = @(
    'SoftFloat-COPYING.txt'
    'annoylib-LICENSE'
    'clapack-lapack_LICENSE'
    'dlpack-LICENSE'
    'flatbuffers-LICENSE.txt'
    'fonts-Rubik_OFL.txt'
    'libjpeg-turbo-LICENSE.md'
    'libjpeg-turbo-README.ijg'
    'libjpeg-turbo-README.md'
    'libpng-LICENSE'
    'libpng-README'
    'mscr-chi_table_LICENSE.txt'
    'zlib-LICENSE'

    # Android のビルドにだけ現れる（NDK の cpufeatures）。
    'cpufeatures-LICENSE'
    'cpufeatures-README.md'
)
# Valgrind の抑制ファイル。Unix 系の install だけが置く（Windows のビルドには
# 現れない — 実測で確認）。実行可能コードではなく、Valgrind に「この警告は
# 既知なので無視してよい」と伝えるテキストである。M3 の Linux レーンが
# Valgrind を使うときに読む対象でもある。
#
# 名前で認識する。拡張子 '.supp' だけを条件にすると、同じ拡張子の未知の
# ファイルが将来入ってきたときに黙って通る。
$InertValgrindFiles = @('valgrind.supp', 'valgrind_3rdparty.supp')

# root 直下にある、この検証自身が書く manifest と OpenCV 本体の LICENSE。
#
# **README.android は Android の install だけが root に置く。** 中身は
# NDK 向けの使い方の説明で、binary でも license でもない。
$InertRootFiles = @('LICENSE', 'build-manifest.json', 'README.android')

$rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

function Get-TopLevelDir([System.IO.FileInfo]$file) {
    $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/')
    $segments = $relative -split '[\\/]'
    if ($segments.Count -gt 1) { return $segments[0] }
    return ''
}

function Get-RelativePath([System.IO.FileInfo]$file) {
    return $file.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
}

function Test-IsInert([System.IO.FileInfo]$file) {
    $relative = (Get-RelativePath $file).ToLowerInvariant()
    $ext = $file.Extension.ToLowerInvariant()

    # header: include/opencv2/ 配下の .h / .hpp のみ。
    #
    # 以前は「top-level が include」かつ「拡張子が .h/.hpp」だけを見ていた。
    # それは C1 で etc/ について批判したのと同じ形（場所と拡張子で通し、
    # 由来を何も見ない）で、include/ にそのまま残っていた（再レビュー F9）。
    # OpenCV の install が置く header は必ず include/opencv2/ の下であり
    # （実測: このツリーの include/ 直下は opencv2 のみ）、そこに限定すれば
    # 「OpenCV が置いたものである」ことを積極的に認識したことになる。
    # include/ 直下や include/<別名>/ に来たものは分類されず reject される。
    #
    # **配置は platform で変わる。** Windows の install は include/opencv2/ に置くが、
    # Unix 系（macOS / Linux）は include/opencv4/opencv2/ に置く（M3 Task 4 の CI で
    # 実測: macOS の全 header が「未知」として拒否された）。**片方を決め打ちにすると、
    # 正しい成果物を拒否するか、逆に緩めすぎて由来を見なくなる。** どちらの配置でも
    # 「opencv2/ の下に在ること」は共通なので、そこを条件にする。
    # include/ 直下や opencv2/ を経由しないものは分類されず reject される。
    #
    # **Android はさらに別の配置である**（実測、M4 の CI）:
    #   Windows      include/opencv2/
    #   macOS/Linux  include/opencv4/opencv2/
    #   Android      sdk/native/jni/include/opencv2/
    #
    # Android の install は sdk/ の下に木を丸ごと作り直す。**「opencv2/ の下」
    # という共通点だけを条件にすると、任意の場所の opencv2/ を通してしまう**
    # ので、prefix を明示的に並べる —— 配置が増えるたびにここへ足す、という
    # 形にしておけば「知らない場所に置かれたヘッダ」は拒否され続ける。
    if ($relative -match '^(sdk/native/jni/)?include/(opencv[0-9]*/)?opencv2/' -and
        $ext -in @('.h', '.hpp')) { return $true }

    # Android の NDK 用 makefile。名前と場所の両方で認識する。
    # **拡張子だけで通さない** —— .mk はどこにでも置けるからである。
    if ($relative -match '^sdk/native/jni/opencv(-[a-z0-9_-]+)?\.mk$') { return $true }

    # notice/text: etc/licenses/ 配下の、名前そのものを allowlist にした
    # ファイルだけ。拡張子や場所だけでは判定しない — $InertLicenseFiles を見よ。
    #
    # 場所の条件も etc/licenses/ に限定する。以前は top-level が etc であれば
    # よく、etc/foo/bar/zlib-LICENSE も通った。名前 allowlist が主たる門に
    # なった後も、コメントは「etc/licenses/ 配下の」と書いているのに実装は
    # そう読んでいなかった（再レビュー F8）。
    #
    # license の配置も platform で変わる（Unix 系は share/licenses/ に置く）。
    # 名前 allowlist が主たる門なので、場所は「licenses/ 直下であること」に
    # 緩めつつ、任意の深さは許さない。
    #
    # 実測した配置（M3 Task 4 の CI）:
    #   Windows      etc/licenses/<name>
    #   macOS/Linux  share/licenses/opencv5/<name>
    #
    # Unix 系はパッケージ名のディレクトリを 1 階層挟む。任意の深さを許すと
    # 「licenses という語がどこかに在れば通る」になってしまうので、
    # 0 段か 1 段だけに限る。名前 allowlist は変わらず主たる門である。
    #   Android      sdk/etc/licenses/<name>
    if ($relative -match '^(sdk/)?(etc|share)/licenses/([^/]+/)?[^/]+$' -and
        $file.Name -in $InertLicenseFiles) { return $true }

    # valgrind の抑制ファイル: 名前で認識する。Unix 系の install だけが置く。
    if ($file.Name -in $InertValgrindFiles) { return $true }

    # cmake package file: 場所ではなく名前そのもので認識する。
    if ($file.Name -in $InertCMakePackageFiles) { return $true }

    # root 直下（相対パスに '/' を含まない）だけ。サブディレクトリに同名の
    # ファイルが現れても通さない。
    if ($relative -notmatch '/' -and $file.Name -in $InertRootFiles) { return $true }

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
        # Unix は 'lib' 接頭辞を付ける（libopencv_core.a）。Windows は付けない
        # （opencv_core500.lib）。version 番号の有無も違う。
        if ($file.Name -match '^(lib)?opencv_(?<name>[a-z0-9_]+?)\d*\.(lib|a)$') {
            $moduleName = $Matches['name']
            if ($moduleName -in $PermittedOpenCvModules) {
                $found += $moduleName
                continue
            }
            $violations += "  $($file.Name) — OpenCV module '$moduleName' は許可リストに無い ($(Get-RejectionReason $file.Name))"
            continue
        }

        # 明示的に受け入れた third-party ライブラリか。
        #
        # 名前を正規化してから突き合わせる。Windows は zlib.lib、Unix は
        # libzlib.a と綴りが違うだけで同じライブラリなので、拡張子と
        # 'lib' 接頭辞を落として比べる。**綴りごとに列挙しない** — 列挙は
        # platform が増えるたびに増え、片方だけ更新される形になる。
        #
        # libpng / libjpeg-turbo / libclapack のように名前自体が lib で
        # 始まるものがあるので、接頭辞を剥がした形と剥がさない形の両方で照合する。
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($lower)
        $stripped = $stem -replace '^lib', ''
        $permitted = @($PermittedThirdPartyLibs | ForEach-Object { $_.ToLowerInvariant() })
        if ($stem -in $permitted -or $stripped -in $permitted) {
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
    # **相対パスを出す。** ファイル名だけだと、拒否された理由が「未知の名前」
    # なのか「知っている名前だが想定外の場所」なのか区別できない。M3 Task 4 で
    # 実際にこれで詰まった: macOS が zlib-LICENSE を拒否したが、それが
    # etc/licenses/ に在るのか share/licenses/ に在るのかログから読めず、
    # 配置を推測で直すことになった。診断は原因を名指しできなければ役に立たない。
    $violations += "  $(Get-RelativePath $file) — 未知の種類のファイルです（拡張子 '$ext'）。inert（header/cmake/notice）か binary artifact のどちらに区分するかを決めたうえで tools/verify-opencv-artifact.ps1 を更新してください"
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

# $InertLicenseFiles に載っている名前が、公開用の通知文書にも現れることを確かめる。
#
# ここが無いと次の抜け方が残る（再レビュー F5）。OpenCV が新しい third-party の
# license ファイルを etc/licenses/ に置く -> このスクリプトが unclassified で
# 落ちる -> 直す人が $InertLicenseFiles に名前を足す -> 緑に戻る。
# THIRD_PARTY_NOTICES.md を更新しなくても、何も赤くならない。
#
# 「両方を更新せよ」という指示は $InertLicenseFiles の隣のコメントにあったが、
# 指示は検査ではない。C1 が Critical だったのは、配布物に入っているものが
# 利用者向けの表示に出ていなかったからで、その経路をここで閉じる。
if (-not (Test-Path -LiteralPath $NoticesPath)) {
    [Console]::Error.WriteLine((@(
                "通知文書が見つかりません: $NoticesPath"
                'ライセンス一覧と突き合わせられないため、検証を成功にはできません。'
                '別の場所にあるなら -NoticesPath で指定してください。'
            ) -join "`n"))
    exit 1
}

$noticesText = Get-Content -LiteralPath $NoticesPath -Raw
$undocumented = @($InertLicenseFiles | Where-Object { $noticesText -notlike "*$_*" })
if ($undocumented.Count -gt 0) {
    [Console]::Error.WriteLine((@(
                "同梱される license ファイルが THIRD_PARTY_NOTICES.md に記載されていません:"
                ($undocumented | ForEach-Object { "  $_" })
                ''
                'これらは artifact に含まれて配布されます。$InertLicenseFiles に名前を'
                '足すだけでは足りません — 利用者が読む文書にも載せてください。'
                "対象文書: $NoticesPath"
            ) -join "`n"))
    exit 1
}

$found | ForEach-Object { Write-Output $_ }
exit 0
