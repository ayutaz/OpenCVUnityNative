<#
    platform ごとにビルドされた plugin の木を 1 つに重ねる。

    ## なぜ要るか

    Unity は同じ package ID を 1 つしか導入できない。したがって
    「エディタは Windows、ビルド対象は Android」という構成を表現するには、
    **1 つの package に複数 platform の binary が同居している**必要がある。

    ところが各 platform の binary は別々のランナーでビルドされ、
    `Runtime/Plugins/` は gitignore されているので、どの 1 台にも
    3 つ揃った状態は自然には現れない。ここがその合流点である。

    ## 何を受け取るか

    `-Source` に、それぞれ `Runtime/Plugins/` を根とする木（あるいは
    package の根）を渡す。`release.yml` は各 job が artifact 化した
    `Runtime/Plugins/` を、ローカルのレーンは公開済み tarball を展開した
    `package/Runtime/Plugins/` を渡す。

    ## 知らないものを運ばない

    **何でもコピーする形にはしない。** 配る物の中身は一覧そのものが契約なので、
    運ぶのは既知の binary と、その `.meta`、そしてディレクトリの `.meta` だけに
    限る。知らないファイルがあれば止める —— 「気づかないうちに何かが混ざる」
    経路を作らないためである。

    ## 部分的に重ねてはならない

    **binary の無い `.meta` だけを置くと Unity がそれを消す**（M3 のレビュー M4 で
    実測）。`tests/UnityProject` は package をディレクトリ参照する = mutable な
    package なので、孤児になった `.meta` は実際に削除される。
    binary と `.meta` は必ず対で置く。
#>
#Requires -Version 7.0

<#
    **位置引数を禁止している。** `pwsh -File` から呼ぶと、空白区切りで並べた
    2 つ目の値が次の引数（PackageDir）に入ってしまい、**元の木を上書き先と
    取り違えたまま静かに成功する**（実測）。名前を必ず書かせる形にする。

    複数の元は `;` 区切りの 1 つの文字列で渡す。`pwsh -File` は配列を
    展開してくれないので、こちらで割る。
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # 重ねる元。`;` 区切り。それぞれ Runtime/Plugins を含む木、または
    # Runtime/Plugins 自身。
    [Parameter(Mandatory)]
    [string] $Source,

    # 重ね先の package ディレクトリ。既定はこのリポジトリの package。
    [string] $PackageDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $PackageDir) {
    $PackageDir = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native'
}
if (-not (Test-Path -LiteralPath $PackageDir)) {
    [Console]::Error.WriteLine("package が見つかりません: $PackageDir")
    exit 1
}

# 運んでよいものの一覧。**ここに無いものは運ばない。**
$Allowed = @(
    'x86_64/opencv_unity_native.dll'
    'x86_64/opencv_unity_native.dll.meta'
    'x86_64.meta'
    'macOS/libopencv_unity_native.dylib'
    'macOS/libopencv_unity_native.dylib.meta'
    'macOS.meta'
    'Linux/x86_64/libopencv_unity_native.so'
    'Linux/x86_64/libopencv_unity_native.so.meta'
    'Linux/x86_64.meta'
    'Linux.meta'
    'Android/arm64-v8a/libopencv_unity_native.so'
    'Android/arm64-v8a/libopencv_unity_native.so.meta'
    'Android/arm64-v8a.meta'
    'Android.meta'
    'iOS/libopencv_unity_native.a'
    'iOS/libopencv_unity_native.a.meta'
    'iOS.meta'
)

# binary とその .meta の対応。片方だけ運ぶことを防ぐ。
#
# **$Allowed に足すだけでは、この対応表には入らない。** M4 で 2 platform を
# 足したとき $Allowed は 7 件増えたのにここは 3 件のままで、**「binary と
# .meta は対で運ぶ」という保証がモバイルでだけ無効になっていた**
# （レビューで発見）。binary の無い .meta を Unity は消す。
$BinaryToMeta = @{
    'x86_64/opencv_unity_native.dll'                  = 'x86_64/opencv_unity_native.dll.meta'
    'macOS/libopencv_unity_native.dylib'              = 'macOS/libopencv_unity_native.dylib.meta'
    'Linux/x86_64/libopencv_unity_native.so'          = 'Linux/x86_64/libopencv_unity_native.so.meta'
    'Android/arm64-v8a/libopencv_unity_native.so'     = 'Android/arm64-v8a/libopencv_unity_native.so.meta'
    'iOS/libopencv_unity_native.a'                    = 'iOS/libopencv_unity_native.a.meta'
}

$destPlugins = Join-Path $PackageDir 'Runtime/Plugins'
New-Item -ItemType Directory -Force -Path $destPlugins | Out-Null

$sources = @($Source -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($sources.Count -eq 0) {
    [Console]::Error.WriteLine('-Source に少なくとも 1 つのパスが要ります。')
    exit 1
}

$copied = 0
foreach ($src in $sources) {
    if (-not (Test-Path -LiteralPath $src)) {
        [Console]::Error.WriteLine("source が見つかりません: $src")
        exit 1
    }

    # Runtime/Plugins を含む木でも、Runtime/Plugins 自身でも受ける。
    $root = $src
    foreach ($candidate in @('Runtime/Plugins', 'package/Runtime/Plugins')) {
        $probe = Join-Path $src $candidate
        if (Test-Path -LiteralPath $probe) { $root = $probe; break }
    }

    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
    if ($files.Count -eq 0) {
        [Console]::Error.WriteLine("source が空です: $src (解決先 $root)")
        exit 1
    }

    foreach ($file in $files) {
        $rel = [System.IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/'
        if ($rel -notin $Allowed) {
            [Console]::Error.WriteLine(@(
                "知らないファイルが plugin の木に入っています: $rel"
                "元: $src"
                '配る物の中身は一覧そのものが契約なので、知らないものは運ばない。'
                '足すときは tools/assemble-plugins.ps1 の $Allowed にも足すこと。'
            ) -join "`n")
            exit 1
        }

        # binary を運ぶなら、その .meta も同じ木に在ること。
        if ($BinaryToMeta.ContainsKey($rel)) {
            $metaPath = Join-Path $root $BinaryToMeta[$rel]
            if (-not (Test-Path -LiteralPath $metaPath)) {
                [Console]::Error.WriteLine(@(
                    "binary に対応する .meta がありません: $rel"
                    '**binary の無い .meta を置くと Unity がそれを消す**ので、対で運ぶ。'
                ) -join "`n")
                exit 1
            }
        }

        # **逆も見る。** binary の .meta だけが在る木（artifact の取りこぼし、
        # build が meta のコピー後に失敗した木）は、孤児の .meta を運ぶことに
        # なる。後段の -AllPlatforms が結局止めるが、止まる場所が離れて
        # 原因が読みにくい。その場で断つ。
        $ownerBinary = ($BinaryToMeta.GetEnumerator() |
                        Where-Object { $_.Value -eq $rel } |
                        ForEach-Object { $_.Key })
        if ($ownerBinary) {
            $binPath = Join-Path $root $ownerBinary
            if (-not (Test-Path -LiteralPath $binPath)) {
                [Console]::Error.WriteLine(@(
                    ".meta に対応する binary がありません: $rel"
                    "元: $src"
                    '孤児の .meta は Unity に消されるので、運ぶ前に断る。'
                ) -join "`n")
                exit 1
            }
        }

        $target = Join-Path $destPlugins $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++
    }
}

Write-Host "==> assembled $copied files into $destPlugins" -ForegroundColor Green

# 何が揃ったかを見せる。揃っていないことは packer が -AllPlatforms で止める。
#
# **拡張子で binary を見分けない。** 以前は ('.dll','.dylib','.so') で
# 拾っており、**iOS の .a が報告から漏れて 5 platform 揃っていても 4 件と
# 表示された**（PR での空撃ちで実測）。判定側は通っていたので害は表示だけ
# だが、**数え直そうとした人に嘘の手がかりを渡す。**
# この script が既に持っている $Allowed（.meta を除いたもの）から導く。
$binaryRelatives = @($Allowed | Where-Object { $_ -notlike '*.meta' })
$present = @(Get-ChildItem -LiteralPath $destPlugins -Recurse -File |
             ForEach-Object {
                 $rel = [IO.Path]::GetRelativePath($destPlugins, $_.FullName).Replace([char]92, [char]47)
                 if ($rel -in $binaryRelatives) { $_.Name }
             })
Write-Host "==> binaries: $(if ($present) { ($present | Sort-Object) -join ', ' } else { '(なし)' })"
