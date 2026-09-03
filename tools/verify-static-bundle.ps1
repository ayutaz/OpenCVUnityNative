#!/usr/bin/env pwsh
<#
.SYNOPSIS
    静的ライブラリに OpenCV が実際に束ねられていることを見る（M6）。

.DESCRIPTION
    **CMake は STATIC ライブラリに依存アーカイブを取り込まない。** 何もしなければ
    出来る `.a` は自分の object だけで、`cv::` は未解決のまま残る。
    **ビルドは成功する** —— 壊れるのは Unity がリンクする段である。

    **iOS ではこれを見る検査が 2 本とも空振りしていた**（M4 のレビューで発覚）:

      - `ar t` のメンバ名を /opencv/ で照合 —— 424 member のうち当たったのは
        1 件で、しかも **OpenCV ではなくこちらの object** だった
        （OpenCV の object は alloc.cpp.o / png.c.o のように opencv を含まない）。
        **libtool が 1 バイトも束ねなくても緑になる。**
      - `nm -u | match 'cv::'` —— nm は既定で demangle しないので
        **決して真にならない**（実物には `_ZN2cv` が 156 件、`cv::` は 0 件）。

    **だから測りたいものを直接測る**: 「こちらの object が要求している `cv::` の
    シンボルを、この archive 自身が定義しているか」。**両方向を見る** ——
    未定義が 0 であることだけだと**空の archive** が通り、定義済みが 1 以上で
    あることだけだと**束ねたが自分の object が入っていない**が通る。

    **マングル名を書き並べない。** 綴りや inline namespace の有無に依存させない。

.PARAMETER Path
    見る静的ライブラリ。

.PARAMETER NmCommand
    使う nm。既定は PATH の `nm`。wasm では Emscripten 同梱の `llvm-nm` を渡す。

.PARAMETER SymbolPattern
    束ねられているべきシンボルの目印。既定はマングルされた `cv` 名前空間。

.EXAMPLE
    pwsh -File tools/verify-static-bundle.ps1 -Path .../libopencv_unity_native.a
    pwsh -File tools/verify-static-bundle.ps1 -Path x.a -NmCommand "$EMSDK/upstream/bin/llvm-nm"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$NmCommand = 'nm',
    [string]$SymbolPattern = '_ZN2cv',
    # **こちら側の目印。** 束ねた結果に自分の object が入っていることを見る。
    [string]$OwnSymbolPattern = 'ocvu_'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Fail([string[]]$Lines) {
    [Console]::Error.WriteLine(($Lines -join "`n"))
    exit 1
}

if (-not (Test-Path -LiteralPath $Path)) {
    Fail @("静的ライブラリがありません: $Path")
}

# **形も見る。** 共有ライブラリになっていたら、そもそも配る形が違う
# —— しかもビルドは成功するので、Unity に入れて初めて壊れる。
# **全部は読まない**（16 MB 級の .a を丸ごとメモリに載せない）。
$headBytes = [byte[]]::new(8)
$fs = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Path))
try { $read = $fs.Read($headBytes, 0, 8) } finally { $fs.Dispose() }
if ($read -ne 8) { Fail @("$Path が 8 バイト未満です") }
$head = [System.Text.Encoding]::ASCII.GetString($headBytes)
if ($head -ne ('!<arch>' + [char]0x0A)) {
    Fail @(
        "ar のアーカイブではありません（先頭が '!<arch>' で始まらない）: $Path"
        "先頭 8 byte: $(($headBytes | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')"
    )
}

# **nm のフラグに頼らない。** `--defined-only` / `-U` の意味は実装で割れる。
# `-g`（外部シンボルのみ）だけを使い、型の欄を自分で読む。
# archive では 'name.a(member.o):' の見出し行が混ざるので、
# 「アドレス? 型 1 文字 名前」の形に当たる行だけを拾う。
function Get-NmSymbols {
    param([string]$Archive, [switch]$UndefinedOnly)
    $out = & $NmCommand -g $Archive 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$NmCommand -g が失敗しました ($Archive): $($out -join ' ')"
    }
    $syms = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $out) {
        if ($line -notmatch '^\s*([0-9a-fA-F]+)?\s*([A-Za-z])\s+(\S+)\s*$') { continue }
        $isUndefined = ($Matches[2] -ceq 'U')
        if ($UndefinedOnly -ne $isUndefined) { continue }
        $syms.Add($Matches[3])
    }
    return @($syms)
}

$undefinedRaw = @(Get-NmSymbols -Archive $Path -UndefinedOnly | Where-Object { $_ -like "*$SymbolPattern*" })
$defined      = @(Get-NmSymbols -Archive $Path                 | Where-Object { $_ -like "*$SymbolPattern*" })

# **archive では「未定義が 0」を求めてはいけない。**
# nm は **member ごとに**シンボルを報告するので、A.o が B.o の定義を参照して
# いれば、A.o の側では未定義として出る。**束ねた直後でもそうなる**
# （2026-09-03 に実測: 正しく束ねた archive でも `_ZN2cv4add2Eii` が
# 未定義として 1 件出た。最初この検査はそれで落ちていた）。
#
# **見るべきは差集合である** —— この archive のどこにも定義が無い未定義。
# それが 0 なら、リンカはこの archive だけで解決できる。
$definedSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$defined, [System.StringComparer]::Ordinal)
$undefined = @($undefinedRaw | Where-Object { -not $definedSet.Contains($_) })

Write-Host "static bundle: $Path"
Write-Host "  nm                            : $NmCommand"
Write-Host "  $SymbolPattern を含む定義済み          : $($defined.Count)"
Write-Host "  同・未定義（member ごと）      : $($undefinedRaw.Count)"
Write-Host "  **archive 内に定義が無い未定義**: $($undefined.Count)"

# **こちらの object が入っていることも見る。**
#
# docstring は「定義済みが 1 以上であることだけだと『束ねたが自分の object が
# 入っていない』が通る」と書いていたが、**その保護は成立していなかった**
# （M6 のレビューが実測）—— 自分の object が入っていなければ `cv::` を
# 参照する未定義がそもそも生じないので、差集合は 0 のままになり、
# **両方向とも通る**（OpenCV は内部で自己完結している）。
#
# **「塞いだ」と書いてあることが、次に検査を足す判断を止める。**
# 実害の確率は低い（MRI script の addlib が静かに失敗する必要がある）が、
# 1 行で閉じるなら閉じる。
$ours = @(Get-NmSymbols -Archive $Path | Where-Object { $_ -like "*$OwnSymbolPattern*" })
Write-Host "  $OwnSymbolPattern を含む定義済み   : $($ours.Count)"
if ($ours.Count -eq 0) {
    Fail @(
        "この archive は $OwnSymbolPattern を 1 つも定義していません: $Path"
        ""
        "**束ねた結果に、こちらの object が入っていない。** MRI script の"
        "addlib が静かに失敗したか、束ねる順序が違う可能性がある。"
        "**OpenCV だけが入った archive は、配っても何も呼べない。**"
    )
}

# **両方向を見る。** どちらか一方だけだと、別の壊れ方が通る。
if ($defined.Count -eq 0) {
    Fail @(
        "この archive は $SymbolPattern を 1 つも定義していません: $Path"
        ""
        "**OpenCV が束ねられていない。** CMake は STATIC ライブラリに依存アーカイブを"
        "取り込まないので、束ねる step が動いていないか、束ねる相手が空だった。"
        "ビルドは成功するので、**Unity がリンクする段まで誰も気づかない。**"
    )
}

if ($undefined.Count -gt 0) {
    $sample = ($undefined | Select-Object -First 5) -join ', '
    Fail @(
        "$SymbolPattern を含む未定義シンボルが $($undefined.Count) 件残っています: $Path"
        "  例: $sample"
        ""
        "**束ね方が部分的である。** 束ねる入力に足りないアーカイブがある可能性が高い"
        "（OpenCV 本体は入ったが 3rdparty が漏れている、など）。"
    )
}

Write-Host "OK: OpenCV が束ねられており、$SymbolPattern の未解決は残っていない。"
exit 0
