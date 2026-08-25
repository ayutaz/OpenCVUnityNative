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

# 実際にビルドしたツリー（third_party/opencv/<hash>/x64/vc17/staticlib、
# ITT を無効化した構成）にあった集合そのもの。想像で足さない。
$allowed = @(
    'opencv_core500.lib', 'opencv_imgproc500.lib', 'opencv_imgcodecs500.lib',
    'opencv_objdetect500.lib', 'opencv_features500.lib', 'opencv_flann500.lib',
    'zlib.lib', 'libpng.lib', 'libjpeg-turbo.lib', 'libclapack.lib'
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

# 期待した module が足りない。
# 終了コードだけでなくメッセージ内容も見る: $files が Get-ChildItem の
# 戻り値そのもの（単一ファイルだとスカラーになる）だと StrictMode 下で
# $files.Count が PropertyNotFoundException を投げ、それでも非ゼロ終了に
# なるため「意図した拒否」と「クラッシュ」を終了コードだけでは区別できない。
$missing = New-Tree @('opencv_core500.lib')
$missingOutput = & pwsh -NoProfile -File $verify -Root $missing 2>&1 | Out-String
Assert-That ($LASTEXITCODE -ne 0) 'a tree missing a required module is rejected'
Assert-That ($missingOutput -match 'imgproc') 'the rejection message names a missing module'

# 外部 IPP（WITH_IPP=ON + IPPROOT）は ippicv / ippiw ではなく
# ippcoremt.lib / ippsmt.lib / ippvmmt.lib 等のファイル名で配布される。
$externalIpp = New-Tree ($allowed + @('ippcoremt.lib', 'ippsmt.lib', 'ippvmmt.lib'))
& pwsh -NoProfile -File $verify -Root $externalIpp 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'external IPP runtime libraries (ippcoremt.lib etc.) are rejected'

# IPP Integration Wrappers はアンダースコア入りの ipp_iw.lib という名前。
$ippIw = New-Tree ($allowed + 'ipp_iw.lib')
& pwsh -NoProfile -File $verify -Root $ippIw 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'the IPP Integration Wrappers library (ipp_iw.lib) is rejected'

# clipper は features モジュールが引き込み得る実在のライブラリ名で、
# 'ipp' を単純な部分文字列として禁止すると "cl-ipp-er" に一致して誤検出する
# （'ipp*' の前方一致で回避している）。allowlist 化後は clipper.lib も
# 単に「許可リストに無い」という理由で拒否されるべきで、IPP と誤って
# 名指しされてはならない。
$clipper = New-Tree ($allowed + 'clipper.lib')
$clipperOutput = & pwsh -NoProfile -File $verify -Root $clipper 2>&1 | Out-String
Assert-That ($LASTEXITCODE -ne 0) 'clipper.lib is rejected (not on the permitted third-party list)'
# ファイル名の "clipper.lib" 自体が部分文字列として "ipp" を含むので、単純な
# 文字列一致では確認できない。IPP 向けの拒否理由文言（Get-RejectionReason の
# 'ipp*' ルール由来）が誤って付いていないことを、その理由文言自体で確認する。
Assert-That ($clipperOutput -notmatch 'Intel の独自条項') 'clipper.lib is not misidentified as an IPP library'

# OpenEXR は openexr という文字列を含まない IlmImf という名前でも配布される。
$ilmImf = New-Tree ($allowed + 'IlmImf-3_1.lib')
& pwsh -NoProfile -File $verify -Root $ilmImf 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'OpenEXR under its IlmImf name is rejected'

# allowlist は「見覚えのないものは拒否する」形でなければならない。
# denylist（既知の悪いものだけを拒否する）は著者が想像した名前しか拒否できない。
# 実際に ittnotify.lib（Intel VTune 計装、BSD-3-Clause / GPL-2.0-only の
# デュアルライセンス）が denylist をすり抜けて allowlist OK と判定された
# ことがある。同じ失敗をどんな未知の名前についても再発させないため、
# 「許可リストに無いものは無条件で拒否」を検証する。
$unrecognised = New-Tree ($allowed + 'unexpected-thirdparty.lib')
$unrecognisedOutput = & pwsh -NoProfile -File $verify -Root $unrecognised 2>&1 | Out-String
Assert-That ($LASTEXITCODE -ne 0) 'a library with no entry in the allowlist is rejected'
Assert-That ($unrecognisedOutput -match 'unexpected-thirdparty\.lib') 'the rejection message names the unrecognised file'

# ittnotify.lib はどの forbidden pattern にも一致しないため、denylist 実装
# ではここを通過してしまっていた（allowlist OK と誤判定）。allowlist 化後は
# 「許可リストに無い」という理由だけで拒否されるべきで、この項目のために
# 新しい pattern を追加する必要があってはならない。
$itt = New-Tree ($allowed + 'ittnotify.lib')
& pwsh -NoProfile -File $verify -Root $itt 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'ittnotify.lib (Intel ITT, GPL-2.0-only の一方を持つデュアルライセンス) is rejected'

# レビューで見つかった 3 つの迂回経路。ファイル名レベルの allowlist 化
# （ittnotify.lib の一件）だけでは足りず、その一段上、ファイルの
# 「発見のされ方」自体が denylist（-Include の拡張子一覧、既定の隠し
# ファイル除外）になっていた。想像しなかった拡張子・属性を持つファイルは
# 判定にすら届かず、実質的に無条件で通っていた。

# 未知の実行可能ファイル（.exe）。旧実装の -Include '*.lib','*.dll','*.a','*.so'
# に .exe は無く、存在自体が判定に渡らなかった。
$unexpectedExe = New-Tree $allowed
Set-Content -Path (Join-Path $unexpectedExe 'x64/vc17/staticlib/protoc.exe') -Value 'stub'
& pwsh -NoProfile -File $verify -Root $unexpectedExe 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unexpected .exe is rejected'

# 未知の共有ライブラリ（.dylib）。M3/M4 で macOS / iOS が対象になれば
# 現実に登場し得る拡張子で、これも旧 -Include には無かった。
$unexpectedDylib = New-Tree $allowed
Set-Content -Path (Join-Path $unexpectedDylib 'x64/vc17/staticlib/libunwanted.dylib') -Value 'stub'
& pwsh -NoProfile -File $verify -Root $unexpectedDylib 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unexpected .dylib is rejected'

# 隠し属性付きの未知の .lib。旧実装の Get-ChildItem に -Force が無く、
# 既定では隠しファイルを列挙しないため、拡張子が合っていても見えなかった。
$hiddenRoot = New-Tree $allowed
$hiddenPath = Join-Path $hiddenRoot 'x64/vc17/staticlib/hidden-bad.lib'
Set-Content -Path $hiddenPath -Value 'stub'
(Get-Item -LiteralPath $hiddenPath -Force).Attributes = (Get-Item -LiteralPath $hiddenPath -Force).Attributes -bor [System.IO.FileAttributes]::Hidden
& pwsh -NoProfile -File $verify -Root $hiddenRoot 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a hidden unrecognised .lib is rejected'

# レビュー第 3 ラウンド: 「見つかりさえすれば、名前 allowlist に懸けられる」
# だけでは足りなかった。inert 判定を拡張子だけ（$InertExtensions の .cmake）
# または場所だけ（$InertTopLevelDirs の include/etc）のどちらか一方で
# 決めていたため、"場所だけ" ルールが binary をまるごと免除していた。
# etc/ittnotify.dll がまさにこの検証の存在理由そのものをすり抜けた。

# .cmake が staticlib 配下ならどこでも inert、というのは緩すぎる。
# 実際のツリーにある .cmake は OpenCVConfig.cmake 等の決まった名前だけで、
# 「拡張子が .cmake だから」というだけで無条件に許してはならない。
$evilCmake = New-Tree $allowed
Set-Content -Path (Join-Path $evilCmake 'x64/vc17/staticlib/evil.cmake') -Value 'stub'
& pwsh -NoProfile -File $verify -Root $evilCmake 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unrecognised .cmake file under staticlib is rejected'

# include/ 配下だからといって無条件に inert にすると、binary が
# 紛れ込んでも場所だけで免除されてしまう。
$evilInclude = New-Tree $allowed
New-Item -ItemType Directory -Force -Path (Join-Path $evilInclude 'include') | Out-Null
Set-Content -Path (Join-Path $evilInclude 'include/evil.dll') -Value 'stub'
& pwsh -NoProfile -File $verify -Root $evilInclude 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a binary under include/ is rejected regardless of location'

# etc/ 配下も同様。しかもこれは本検証の存在理由そのもの
# （ittnotify）が、置き場所を変えるだけですり抜けるという最悪の形。
$evilEtc = New-Tree $allowed
New-Item -ItemType Directory -Force -Path (Join-Path $evilEtc 'etc') | Out-Null
Set-Content -Path (Join-Path $evilEtc 'etc/ittnotify.dll') -Value 'stub'
& pwsh -NoProfile -File $verify -Root $evilEtc 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'ittnotify.dll under etc/ is rejected (location must never exempt a binary)'

# レビュー C1: etc/licenses/ の inert 判定が「場所と拡張子」だけだったため、
# 名前を一切見ておらず、OpenCV が新しい third-party の license ファイルを
# 追加しても検出できなかった。実測: 合成ツリーに etc/licenses/ffmpeg-LICENSE
# を置いたところ、旧実装は検出せず exit 0 で通過した。$InertLicenseFiles に
# よる名前 allowlist 化がこれを塞ぐことを確認する。
$knownLicenseFiles = @(
    'SoftFloat-COPYING.txt', 'annoylib-LICENSE', 'clapack-lapack_LICENSE',
    'dlpack-LICENSE', 'flatbuffers-LICENSE.txt', 'fonts-Rubik_OFL.txt',
    'libjpeg-turbo-LICENSE.md', 'libjpeg-turbo-README.ijg', 'libjpeg-turbo-README.md',
    'libpng-LICENSE', 'libpng-README', 'mscr-chi_table_LICENSE.txt', 'zlib-LICENSE'
)
function New-TreeWithLicenses([string[]]$libs, [string[]]$licenseFiles) {
    $root = New-Tree $libs
    $licenseDir = Join-Path $root 'etc/licenses'
    New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
    foreach ($f in $licenseFiles) { Set-Content -Path (Join-Path $licenseDir $f) -Value 'stub' }
    return $root
}

# 実物と同じ 13 個の license ファイルを持つツリーは通る。名前 allowlist が
# 実在するファイルまで拒否してしまわないことの担保。
$withLicenses = New-TreeWithLicenses $allowed $knownLicenseFiles
& pwsh -NoProfile -File $verify -Root $withLicenses | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'a tree with exactly the known etc/licenses/ files passes'

# 未知の license ファイルが 1 つ紛れ込むと拒否される。C1 で実証されたのは
# 拡張子無しの ffmpeg-LICENSE のケース: 場所と拡張子だけの判定では、
# 空文字列の拡張子も許容範囲に入っており、名前を見ないので通ってしまっていた。
$unknownLicense = New-TreeWithLicenses $allowed ($knownLicenseFiles + 'ffmpeg-LICENSE')
$unknownLicenseOutput = & pwsh -NoProfile -File $verify -Root $unknownLicense 2>&1 | Out-String
Assert-That ($LASTEXITCODE -ne 0) 'an unrecognised file under etc/licenses/ (e.g. ffmpeg-LICENSE) is rejected'
Assert-That ($unknownLicenseOutput -match 'ffmpeg-LICENSE') 'the rejection message names the unrecognised license file'

# ディレクトリ junction。Get-ChildItem -Recurse は reparse point の先へ
# 降りていかないため、その向こうにあるファイル（payload.dll）は
# 列挙にすら現れない。追いかけるのではなく、reparse point の存在自体を
# 拒否する。OpenCV の install はこれを作らないので、存在自体が異常である。
$junctionRoot = New-Tree $allowed
$junctionTarget = Join-Path $temp "junction-target-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
Set-Content -Path (Join-Path $junctionTarget 'payload.dll') -Value 'stub'
New-Item -ItemType Junction -Path (Join-Path $junctionRoot 'x64/vc17/staticlib/linked') -Target $junctionTarget | Out-Null
& pwsh -NoProfile -File $verify -Root $junctionRoot 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a reparse point (directory junction) under the tree is rejected'

# レビューで「既に落ちる」と確認済みの 2 件。回帰しないよう固定する。
$suspicious = New-Tree ($allowed + 'suspicious')
& pwsh -NoProfile -File $verify -Root $suspicious 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unrecognised extensionless file is rejected'

$upperCaseLib = New-Tree ($allowed + 'unwanted.LIB')
& pwsh -NoProfile -File $verify -Root $upperCaseLib 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unrecognised library with an uppercase extension (unwanted.LIB) is rejected'

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
