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
[CmdletBinding()]
param(
    # tarball の出力先ディレクトリ。無ければ作る。
    [Parameter(Mandatory)]
    [string] $OutputDir,

    # ファイル名に付ける platform 名（例 windows-x64）。省略すると付かない。
    [string] $Platform
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

$name = if ($Platform) {
    "com.ayutaz.opencv-unity-native-$version-$Platform.tgz"
} else {
    "com.ayutaz.opencv-unity-native-$version.tgz"
}
$tarballPath = Join-Path $outFull $name

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

Write-Host "==> $name ($($entries.Count) entries)" -ForegroundColor Green
$tarballPath
