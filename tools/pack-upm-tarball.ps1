<#
    UPM tarball を作る。

    **なぜ専用の script にするか。** 作り方を CI とローカルで別々に書くと、
    ローカルで導入できた tarball と、実際に配る tarball が別物になる。
    このリポジトリの不変条件は「CI はローカルと同一のコマンドを呼ぶ」なので、
    `tools/dev.ps1 test-unity-tarball` と `.github/workflows/release.yml` の
    両方がここを通る。

    **なぜ package/ という中間ディレクトリを作るか。** UPM の tarball は
    npm の形式で、展開後の root に package.json が来ることを期待する。
    `tar -C Packages com.ayutaz.opencv-unity-native` のように package ID の
    ディレクトリごと固めると、UPM は展開先の root に package.json を見つけ
    られず、次のエラーで導入に失敗する（実測、Unity 6000.0.82f1）:

        Project has invalid dependencies:
          com.ayutaz.opencv-unity-native: The file [<tmp>\package.json] cannot be found

    npm pack が作るのと同じく、中身を `package/` の下に入れる。
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    # tarball の出力先ディレクトリ。無ければ作る。
    [Parameter(Mandatory)]
    [string] $OutputDir,

    # ファイル名に付ける platform 名（例 windows-x64）。省略すると付かない。
    [string] $Platform,

    # 3 platform 分の binary が入った「全部入り」を作る。-Platform とは排他。
    #
    # **配る正はこちらである。** Unity は同じ package ID を 1 つしか導入できず、
    # platform ごとに分かれた tarball では「エディタは Windows、実機は Android」
    # という構成が表現できない。
    [switch] $AllPlatforms,

    # 出来上がった tarball の上限バイト数。既定は OpenUPM の 512 MB。
    #
    # **引数にしてあるのは、落ちるところを見られるようにするためである。**
    # 現状の配布物は上限に対して 1 桁以上小さいので、既定値のままでは
    # この検査が働くところを誰も確かめられない（prove-a-check-works）。
    # **具体的な倍率をここに書かない** —— 配布物が大きくなるたびに嘘になり、
    # 実際に一度そうなった（8.4 MB のとき 63 倍、9.6 MB で 55 倍）。
    [long] $MaxBytes = 536870912
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot   = Split-Path -Parent $PSScriptRoot
$packageDir = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native'

if (-not (Test-Path -LiteralPath $packageDir)) {
    [Console]::Error.WriteLine("package が見つかりません: $packageDir")
    exit 1
}

$version = (Get-Content -LiteralPath (Join-Path $packageDir 'package.json') -Raw |
            ConvertFrom-Json).version

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$outFull = (Resolve-Path -LiteralPath $OutputDir).Path

if ($Platform -and $AllPlatforms) {
    [Console]::Error.WriteLine('-Platform と -AllPlatforms は同時に指定できません。')
    exit 1
}

<#
    全部入りの名前には版番号を入れない。

    OpenUPM の `githubReleaseAssetName` は**安定した接頭辞**で asset を選ぶので、
    版番号入りの名前だと毎回パターンを書き換えることになる
    （https://openupm.com/docs/adding-upm-package.html）。
    platform ごとの tarball は従来どおり版番号入りのまま —— OpenUPM が見るのは
    全部入りの 1 つだけである。
#>
$name = if ($AllPlatforms) {
    'com.ayutaz.opencv-unity-native.tgz'
} elseif ($Platform) {
    "com.ayutaz.opencv-unity-native-$version-$Platform.tgz"
} else {
    "com.ayutaz.opencv-unity-native-$version.tgz"
}

# platform ごとの binary の置き場所。-Platform と -AllPlatforms の両方が使う。
$PlatformBinaries = [ordered]@{
    'windows-x64' = 'Runtime/Plugins/x86_64/opencv_unity_native.dll'
    'macos-arm64' = 'Runtime/Plugins/macOS/libopencv_unity_native.dylib'
    'linux-x64'   = 'Runtime/Plugins/Linux/x86_64/libopencv_unity_native.so'
    'android-arm64' = 'Runtime/Plugins/Android/arm64-v8a/libopencv_unity_native.so'
    # **iOS だけ拡張子が違う。** アプリの外から .dylib を読み込めないので
    # 静的ライブラリを配り、IL2CPP のバイナリへ静的リンクさせる。
    'ios-arm64'     = 'Runtime/Plugins/iOS/libopencv_unity_native.a'
}

<#
    Runtime/Plugins の下に在ってよいものの一覧。
    tools/assemble-plugins.ps1 の $Allowed と同じ集合である。

    **拡張子で判定しない。** `.dll` / `.dylib` / `.so` だけを見る形では
    `libfoo.so.1`（拡張子は `.1`）・`.bundle`・`.a`・`.pdb` が素通りする。
    配る物の中身は一覧そのものが契約なので、一覧と突き合わせる。
#>
$AllowedPluginFiles = @(
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

<#
    その platform 用として固めてよい中身か。

    **-Platform 側にもこれを掛ける。** 以前は「開発機には 1 platform 分しか
    無い」で実質守られていたが、**M3.5 がその前提を壊した** —— 全部入りを
    組めるようにしたので、3 つ揃った開発機で `-Platform windows-x64` を叩くと、
    3 platform 入りの中身に「windows-x64 用」という名前が付く。
    tools/tests/PackageRelease.Tests.ps1 の負のテストも同じ前提崩れで
    書き換えている。
#>
function Test-PluginTreeContents {
    param([string[]] $ExpectedBinaries, [string] $What)

    $pluginRoot = Join-Path $packageDir 'Runtime/Plugins'
    if (-not (Test-Path -LiteralPath $pluginRoot)) { return }

    $unexpected = @()
    foreach ($file in Get-ChildItem -LiteralPath $pluginRoot -Recurse -File) {
        $rel = [System.IO.Path]::GetRelativePath($pluginRoot, $file.FullName) -replace '\\', '/'
        if ($rel -notin $AllowedPluginFiles) {
            $unexpected += "知らないファイル: $rel"
            continue
        }
        <#
            binary は、この platform のものだけが在ってよい。

            **拡張子で判定しない。** 以前は (dll|dylib|so) で拾っていたが、
            iOS の静的ライブラリは .a なので「binary ではない」と扱われ、
            **別 platform の混入を素通しした**（M4 で足したときに実測）。
            $PlatformBinaries が持つ相対パスの集合で判定する ——
            **どれが binary かの正本はそこ 1 箇所である。**
        #>
        $relFull = "Runtime/Plugins/$rel"
        if ($relFull -in $PlatformBinaries.Values -and $relFull -notin $ExpectedBinaries) {
            $unexpected += "別 platform の binary: $rel"
        }
    }

    if ($unexpected.Count -gt 0) {
        [Console]::Error.WriteLine(@(
            "$What に予期しないものが入っています:"
            ($unexpected | ForEach-Object { "  - $_" })
            '配る物の中身は一覧そのものが契約なので、知らないものは通さない。'
        ) -join "`n")
        exit 1
    }
}
$tarballPath = Join-Path $outFull $name

<#
    -Platform を渡されたなら、その platform の binary が実際に入っていることを
    確かめる。

    **これが無いと、-Platform は名前を変えるだけになる。** Windows 上で
    `-Platform macos-arm64` を実行すると、中身は Windows の .dll だけなのに
    「macOS 用」と名乗る tarball が、エラーも警告も無しに出来上がる。

    現在の release.yml では起きない——matrix の各 job が新規 checkout し、
    そのランナー上でビルドするので、Runtime/Plugins にはその platform の
    binary しか物理的に存在しない。だがそれは **release.yml の job 構成が
    たまたまそうなっている**だけで、この script 自身の保証ではない。
    job 構成が変わった瞬間に、中身の違う tarball を配ることになる。
#>
if ($Platform) {
    $expected = switch ($Platform) {
        'windows-x64' { $PlatformBinaries['windows-x64'] }
        'macos-arm64' { $PlatformBinaries['macos-arm64'] }
        'linux-x64'   { $PlatformBinaries['linux-x64'] }
        default {
            # 知らない platform 名を黙って通さない。名前だけ付いた tarball が
            # 出来るのを防ぐ。
            [Console]::Error.WriteLine(@(
                "unknown platform '$Platform'."
                "この script は windows-x64 / macos-arm64 / linux-x64 のみを知っている。"
                'platform を足すときは、対応する binary の位置もここに足すこと。'
            ) -join "`n")
            exit 1
        }
    }

    $expectedFull = Join-Path $packageDir $expected
    if (-not (Test-Path -LiteralPath $expectedFull)) {
        $present = @(Get-ChildItem -LiteralPath (Join-Path $packageDir 'Runtime/Plugins') `
                        -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -in '.dll', '.dylib', '.so' } |
                     ForEach-Object { $_.Name })
        [Console]::Error.WriteLine(@(
            "platform '$Platform' の binary がパッケージに入っていません: $expected"
            "入っていた binary: $(if ($present) { $present -join ', ' } else { '(なし)' })"
            'この platform 用としてビルドしてから固めること。名前だけ付け替えた'
            'tarball を配ると、利用者はその platform で読み込みに失敗する。'
        ) -join "`n")
        exit 1
    }
    Write-Host "==> $Platform binary present: $expected" -ForegroundColor Green

    # 名前と中身が食い違わないこと。存在検査だけでは、別 platform の binary が
    # 紛れていても通る。
    Test-PluginTreeContents -ExpectedBinaries @($expected) -What "'$Platform' の tarball"
}

<#
    -AllPlatforms は「3 つ在る」だけでなく「余計なものが無い」まで見る。

    **存在検査だけでは足りない。** -Platform の検査は存在しか見ないので、
    別 platform の binary が紛れ込んでいても通る（上のコメントのとおり、
    現在それが起きないのは release.yml の job 構成のおかげであって、
    この script の保証ではない）。全部入りでは中身の一覧そのものが契約なので、
    予期しない binary が 1 つでもあれば止める。
#>
if ($AllPlatforms) {
    $pluginRoot = Join-Path $packageDir 'Runtime/Plugins'
    $missing = @()
    foreach ($entry in $PlatformBinaries.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageDir $entry.Value))) {
            $missing += "$($entry.Key): $($entry.Value)"
        }
    }
    if ($missing.Count -gt 0) {
        [Console]::Error.WriteLine(@(
            '全部入りに必要な binary が揃っていません:'
            ($missing | ForEach-Object { "  - $_" })
            "tools/assemble-plugins.ps1 で $($PlatformBinaries.Count) platform 分を重ねてから固めること。"
        ) -join "`n")
        exit 1
    }

    Test-PluginTreeContents -ExpectedBinaries @($PlatformBinaries.Values) -What '全部入り'

    <#
        **binary に対応する .meta が在ることも見る。**

        assemble-plugins.ps1 は対で運ぶことを確かめるが、packer は assemble を
        経由せずにも呼べる（ローカルのレーン、テスト）。ここが archive を作る
        最後の門なので、ここでも見る。

        **.meta の無い binary を配ると、Unity はそれをどの platform でも
        有効な plugin として扱う** —— 全部入りではそれが取り違えになる。
    #>
    $missingMeta = @()
    foreach ($rel in $PlatformBinaries.Values) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageDir "$rel.meta"))) {
            $missingMeta += "$rel.meta"
        }
    }
    # ディレクトリの .meta も要る。無いと Unity がフォルダを import できない。
    <#
        **フォルダの .meta を直書きしない。** binary 側は $PlatformBinaries から
        自動で伸びるのに、ここだけ 4 件の直書きが残っていた —— M4 で 2 platform を
        足したとき Android / iOS のフォルダ .meta が枠外に落ちた（レビューで発見）。

        binary のパスから、その祖先ディレクトリの .meta を導く。
    #>
    #
    # **Split-Path は Windows で `\` を返す。** 区切りを正規化してから比べないと
    # 'Runtime/Plugins' との一致が成立せず、ループが 1 段行き過ぎて
    # `Runtime/Plugins.meta`（存在しない）まで要求する（実測）。
    $folderMetas = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($binRel in $PlatformBinaries.Values) {
        $dir = (Split-Path -Parent $binRel) -replace '\\', '/'
        while ($dir -and $dir -ne 'Runtime/Plugins') {
            $null = $folderMetas.Add("$dir.meta")
            $dir = (Split-Path -Parent $dir) -replace '\\', '/'
        }
    }
    foreach ($rel in @($folderMetas | Sort-Object)) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageDir $rel))) {
            $missingMeta += $rel
        }
    }
    if ($missingMeta.Count -gt 0) {
        [Console]::Error.WriteLine(@(
            '全部入りに必要な .meta が揃っていません:'
            ($missingMeta | ForEach-Object { "  - $_" })
            '**.meta の無い binary は、Unity がどの platform でも有効な plugin として'
            '扱う** —— 全部入りではそれが取り違えになる。'
            'tools/plugin-meta/<platform>/ から対で置くこと。'
        ) -join "`n")
        exit 1
    }

    Write-Host "==> all $($PlatformBinaries.Count) platform binaries present with their metas, no extras" -ForegroundColor Green
}

# 使い捨ての staging に package/ として置き直す。
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-upm-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
try {
    Copy-Item -LiteralPath $packageDir -Destination (Join-Path $staging 'package') -Recurse -Force

    <#
        tar の引数は必ず相対パスにする。この環境で `tar` は Git Bash の
        GNU tar に解決されることがあり、GNU tar は `C:\...` の `:` を
        「リモートホスト」と解釈して
        `Cannot connect to C: resolve failed` で落ちる（実測）。
        Windows 同梱の tar.exe は落ちないので、どちらに解決されても
        動く形にしておく。
    #>
    Push-Location $staging
    try {
        & tar -czf $name 'package'
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("tar が失敗しました（exit $LASTEXITCODE）")
            exit 1
        }
    }
    finally { Pop-Location }

    Move-Item -LiteralPath (Join-Path $staging $name) -Destination $tarballPath -Force
}
finally {
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
}

# 展開後の root に package.json が来ることを、作った直後に確かめる。
# ここを見ないと、導入できない tarball をそのまま配ることになる。
Push-Location $outFull
try {
    $entries = @(& tar -tzf $name)
}
finally { Pop-Location }

if ($entries -notcontains 'package/package.json') {
    [Console]::Error.WriteLine(@(
        "tarball の root に package/package.json がありません: $tarballPath"
        "UPM はこの形の tarball を導入できません。"
        "含まれていた先頭の項目: $(($entries | Select-Object -First 5) -join ', ')"
    ) -join "`n")
    exit 1
}

<#
    全部入りなら、**期待した数の binary が実際に archive の中に在る**ことまで見る。
    ディレクトリを見ただけでは、tar が取りこぼした場合に気づけない。

    **数を直書きしない。** $PlatformBinaries から導く —— platform を足したときに
    片方だけ直して片方が古いまま、という状態を作らない。

    拡張子で拾うのもやめた。iOS の静的ライブラリは .a で、拡張子の一覧を
    別に持つと**そこも直し忘れる**。$PlatformBinaries が持つファイル名で照合する。
#>
if ($AllPlatforms) {
    # **重複を数えない。** 同じファイル名（Android と Linux はどちらも
    # libopencv_unity_native.so）が別ディレクトリに在るので、名前ではなく
    # 相対パスの一致で数える。
    $packedPaths = @($PlatformBinaries.Values | Where-Object {
        $rel = $_
        @($entries | Where-Object { $_ -like "package/$rel" }).Count -gt 0
    })
    if ($packedPaths.Count -ne $PlatformBinaries.Count) {
        $absent = @($PlatformBinaries.GetEnumerator() |
                    Where-Object { $_.Value -notin $packedPaths } |
                    ForEach-Object { "$($_.Key): $($_.Value)" })
        [Console]::Error.WriteLine(@(
            "全部入りの archive に binary が $($packedPaths.Count) 個しかありません（$($PlatformBinaries.Count) 個であるべき）。"
            '入っていないもの:'
            ($absent | ForEach-Object { "  - $_" })
        ) -join "`n")
        exit 1
    }
    Write-Host "==> archive contains all $($PlatformBinaries.Count) platform binaries" -ForegroundColor Green
}

<#
    上限を超えていないこと。

    **workflow ではなく packer に置く。** 呼ぶ側が 2 つ（release.yml と
    dev.ps1）あり、片方だけに置くともう片方が素通しする。
#>
$actualBytes = (Get-Item -LiteralPath $tarballPath).Length
if ($actualBytes -gt $MaxBytes) {
    # **不合格の成果物を置き去りにしない。** 残すと、次に $OutputDir を見た人
    # （や script）が「作られている」ことを合格と読み違えうる。
    Remove-Item -LiteralPath $tarballPath -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine(@(
        "tarball が上限を超えています: $actualBytes バイト > $MaxBytes バイト"
        'OpenUPM は 512 MB 未満を求める（https://openupm.com/docs/adding-upm-package.html）。'
        '超過した tarball は削除した。'
    ) -join "`n")
    exit 1
}

Write-Host "==> $name ($($entries.Count) entries, $actualBytes bytes)" -ForegroundColor Green
$tarballPath
