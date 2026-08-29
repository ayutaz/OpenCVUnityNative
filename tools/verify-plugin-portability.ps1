#Requires -Version 7.0

<#
    Linux の native plugin が、どれだけ新しい環境を要求するかを検査する。

    ## なぜ要るか

    共有ライブラリは、**ビルドした環境と同じかそれより新しい** glibc /
    libstdc++ でしか読み込めない。古い環境でビルドしたものは新しい環境でも
    動くが、逆は成立しない。

    v0.1.0 でこれを踏んだ。ubuntu-24.04（glibc 2.39）でビルドした `.so` が
    GLIBC_2.38 を要求し、それより古いコンテナで
    `DllNotFoundException: Unable to load DLL 'opencv_unity_native'` になった。
    **ビルドは成功し、linkage 検証も通り、配布物も作れた。** 読み込めない
    ことは、Unity を実際に動かすまで誰も知らなかった。

    公開済みの tarball も同じ状態だった——Ubuntu 22.04 の利用者は使えない。
    22.04 は現役の LTS で、Unity の Linux エディタが動く環境として一般的で
    ある。「3 platform でビルドできた」と「3 platform で動く」を取り違えて
    いた。

    ## 何を見るか

    ELF の中に現れる `GLIBC_2.x` / `GLIBCXX_3.4.x` のシンボルバージョンを
    読み、**上限を超えていないか**を見る。`readelf` に頼らず生のバイト列を
    走査するので、Windows の開発機でも動く（`nm` / `readelf` が無いために
    検査できない、という穴を作らない）。

    上限は「支える最も古い環境」で決まる。下の $MaxGlibc / $MaxGlibcxx に
    理由つきで書いてある。
#>
param(
    # 検査する .so。省略時はパッケージに置かれた Linux plugin。
    [string] $Path,

    <#
        支える最も古い環境の glibc。

        **Ubuntu 22.04 (jammy) = glibc 2.35。** ここを上限にする理由:
          - 現役の LTS で、利用者の環境として現実的に多い
          - game-ci の Unity コンテナがこの世代で、CI の Unity レーンが
            読み込めることと同義になる

        上げるときは「その環境を切り捨てる」判断である。数字だけ動かさない。
    #>
    [string] $MaxGlibc = '2.35',

    # Ubuntu 22.04 の libstdc++（GCC 12）は GLIBCXX_3.4.30 まで。
    [string] $MaxGlibcxx = '3.4.30'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $Path) {
    $Path = Join-Path $repoRoot `
        'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/Linux/x86_64/libopencv_unity_native.so'
}

if (-not (Test-Path -LiteralPath $Path)) {
    [Console]::Error.WriteLine(@(
        "plugin not found: $Path"
        '検査対象が無いのは「違反なし」ではない。先に Linux 向けにビルドすること。'
    ) -join "`n")
    exit 1
}

$bytes = [IO.File]::ReadAllBytes($Path)

# ELF であることを確かめる。別の形式を黙って「違反なし」と読まない。
if ($bytes.Length -lt 4 -or
    $bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
    [Console]::Error.WriteLine("not an ELF file: $Path")
    exit 1
}

# .dynstr に入っているシンボルバージョン名を、生のバイト列から拾う。
$text = [Text.Encoding]::ASCII.GetString($bytes)

function Get-MaxVersion([string]$Prefix, [string]$Text) {
    $found = [regex]::Matches($Text, "$Prefix(\d+(?:\.\d+)*)") |
             ForEach-Object { $_.Groups[1].Value } |
             Sort-Object -Unique
    if (-not $found) { return $null }
    return ($found | Sort-Object { [version]$_ } | Select-Object -Last 1)
}

$maxGlibcFound   = Get-MaxVersion 'GLIBC_'   $text
$maxGlibcxxFound = Get-MaxVersion 'GLIBCXX_' $text

# 1 つも見つからないのは、走査が効いていないか対象が違う。通さない。
if (-not $maxGlibcFound) {
    [Console]::Error.WriteLine(@(
        "no GLIBC_* symbol versions found in $Path"
        '0 件を「要求なし」と読まない——走査が効いていない可能性の方が高い。'
    ) -join "`n")
    exit 1
}

$violations = @()
if ([version]$maxGlibcFound -gt [version]$MaxGlibc) {
    $violations += "GLIBC: requires $maxGlibcFound but the ceiling is $MaxGlibc"
}
if ($maxGlibcxxFound -and ([version]$maxGlibcxxFound -gt [version]$MaxGlibcxx)) {
    $violations += "GLIBCXX: requires $maxGlibcxxFound but the ceiling is $MaxGlibcxx"
}

if ($violations.Count -gt 0) {
    [Console]::Error.WriteLine((@(
        "$([IO.Path]::GetFileName($Path)) は、支える予定より新しい環境を要求している:"
        ($violations | ForEach-Object { "  $_" })
        ''
        'この .so は上限の環境では読み込めない。Unity は DllNotFoundException を出すだけで'
        '理由を言わないので、ここで捕まえないと「動かないものを配る」ことになる。'
        ''
        '直し方: より古い環境でビルドする（古い環境で作ったものは新しい環境でも動く）。'
        'Linux のビルドは ubuntu:22.04 のコンテナで行うことにしてある——ランナーの'
        '世代が上がっても要求が上がらないようにするためである。'
    ) -join "`n"))
    exit 1
}

Write-Host "==> $([IO.Path]::GetFileName($Path)): GLIBC<=$maxGlibcFound, GLIBCXX<=$maxGlibcxxFound (ceilings $MaxGlibc / $MaxGlibcxx)" -ForegroundColor Green
exit 0
