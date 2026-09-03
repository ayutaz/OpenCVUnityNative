#!/usr/bin/env pwsh
<#
.SYNOPSIS
    wasm の binary が、要求した機能（SIMD 等）を有効にして作られたかを見る（M6）。

.DESCRIPTION
    **「ビルドが通った」を SIMD の証拠にしない。**

    clang は wasm の object / モジュールに `target_features` という custom
    section を書き込み、**有効化された機能の名前をそこに並べる。**
    これは「その binary が何を要求して作られたか」の一次情報であり、
    こちらが送った flag ではなく**出来た物**を読む。

    **外部の道具に頼らない。** wasm の section 構造を直接読む ——
    このリポジトリには先例が 2 つある（`verify-plugin-portability.ps1` が
    readelf に頼らず ELF を読み、`verify-android-page-size.ps1` が
    program header を読む）。**道具が無いから検査できない、という穴を作らない。**

    **文字列検索にしない。** binary の中に "simd128" という並びが
    たまたま現れることはある（パス名、デバッグ情報、定数）。
    **section を辿って、機能の一覧としてそこに載っていること**を見る。

.PARAMETER Path
    見る wasm ファイル（.o / .wasm / .a の中の 1 つ）。

.PARAMETER Require
    在ることを要求する機能の名前。既定は simd128。

.PARAMETER Forbid
    無いことを要求する機能の名前（threads を非ゴールにしているので既定で atomics）。

.EXAMPLE
    pwsh -File tools/verify-wasm-features.ps1 -Path build/.../probe.o
    pwsh -File tools/verify-wasm-features.ps1 -Path x.o -Require simd128 -Forbid atomics
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string[]]$Require = @('simd128'),
    [string[]]$Forbid  = @('atomics')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Fail([string[]]$Lines) {
    [Console]::Error.WriteLine(($Lines -join "`n"))
    exit 1
}

if (-not (Test-Path -LiteralPath $Path)) {
    Fail @("wasm ファイルが見つかりません: $Path")
}

$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))

# **ar のアーカイブなら、中の wasm member を全部見る。**
#
# 配るのは `.a` なので、**配る物そのものを検査できるべきである。**
# アーカイブを渡されて「wasm ではない」と言うだけだと、**検査の対象が
# 成果物からずれる**（呼ぶ側が中身を取り出す手順を自分で書くことになり、
# そこが検査の外になる）。
#
# **「最初の 1 つ」を見るのは恣意的である**（2026-09-03 に踏んだ ——
# 最初の member はこちらの object で、OpenCV の SIMD コードは後ろの
# member に入っていた）。**全 member の和を取る。**
#
# ar の形式: "!<arch>" + LF のあと、60 バイトのヘッダ
# （名前 16 / 日時 12 / uid 6 / gid 6 / mode 8 / 大きさ 10 / 終端 2）と
# 本体が並び、本体は 2 バイト境界に揃う。
$modules = @()
if ($bytes.Length -ge 8 -and
    [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -eq ('!<arch>' + [char]0x0A)) {
    $pos = 8
    while ($pos + 60 -le $bytes.Length) {
        $sizeText = [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 48, 10).Trim()
        [int64]$memberSize = 0
        if (-not [int64]::TryParse($sizeText, [ref]$memberSize)) { break }
        $body = $pos + 60
        if ($body + 4 -le $bytes.Length -and
            $bytes[$body] -eq 0x00 -and $bytes[$body + 1] -eq 0x61 -and
            $bytes[$body + 2] -eq 0x73 -and $bytes[$body + 3] -eq 0x6D) {
            $m = [byte[]]::new($memberSize)
            [Array]::Copy($bytes, [int64]$body, $m, [int64]0, $memberSize)
            $modules += , $m
        }
        $pos = $body + $memberSize
        if ($pos % 2 -ne 0) { $pos++ }
    }
    if ($modules.Count -eq 0) {
        Fail @(
            "ar のアーカイブですが、中に wasm の member が 1 つもありません: $Path"
            "**host 向けの object を詰めた archive の可能性がある。**"
        )
    }
} else {
    $modules = @(, $bytes)
}

# --- どの module も先頭は wasm の magic number であること ---
foreach ($m in $modules) {
    if ($m.Length -lt 8 -or
        $m[0] -ne 0x00 -or $m[1] -ne 0x61 -or $m[2] -ne 0x73 -or $m[3] -ne 0x6D) {
        Fail @(
            "wasm の magic number がありません: $Path"
            "先頭 8 byte: $(($m | Select-Object -First 8 | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')"
            "**host 向けの object を掴んでいる可能性がある** —— クロスの設定を確かめること。"
        )
    }
}

# LEB128（符号なし）を読む。offset は参照で進める。
function Read-ULeb([byte[]]$Buf, [ref]$Offset) {
    $result = 0; $shift = 0
    while ($true) {
        if ($Offset.Value -ge $Buf.Length) { throw "LEB128 の途中でファイルが終わりました (offset=$($Offset.Value))" }
        $b = $Buf[$Offset.Value]; $Offset.Value++
        $result = $result -bor (([int]($b -band 0x7F)) -shl $shift)
        if (($b -band 0x80) -eq 0) { break }
        $shift += 7
        if ($shift -gt 35) { throw 'LEB128 が長すぎます' }
    }
    return $result
}

$featureSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$sectionCount = 0

foreach ($buf in $modules) {
    $offset = 8
    while ($offset -lt $buf.Length) {
        $id = $buf[$offset]; $offset++
        $size = Read-ULeb $buf ([ref]$offset)
        $sectionEnd = $offset + $size
        if ($sectionEnd -gt $buf.Length) {
            Fail @("section が宣言した大きさ（$size）がファイルを超えています: $Path")
        }
        $sectionCount++

        if ($id -eq 0) {
            # custom section: 名前（LEB 長 + bytes）が先頭に在る。
            $nameLen = Read-ULeb $buf ([ref]$offset)
            $name = [System.Text.Encoding]::UTF8.GetString($buf, $offset, $nameLen)
            $offset += $nameLen
            if ($name -eq 'target_features') {
                $count = Read-ULeb $buf ([ref]$offset)
                for ($i = 0; $i -lt $count; $i++) {
                    $offset++   # '+' / '-' / '=' の prefix
                    $fLen = Read-ULeb $buf ([ref]$offset)
                    $null = $featureSet.Add([System.Text.Encoding]::UTF8.GetString($buf, $offset, $fLen))
                    $offset += $fLen
                }
            }
        }
        $offset = $sectionEnd
    }
}

$features = @($featureSet | Sort-Object)

# **section を 1 つも読めていないなら「違反なし」ではなく走査の失敗である。**
if ($sectionCount -eq 0) {
    Fail @("section を 1 つも読めませんでした: $Path（走査が効いていない）")
}

Write-Host "wasm: $Path"
Write-Host "  wasm module 数        : $($modules.Count)"
Write-Host "  section 数（合計）    : $sectionCount"
Write-Host "  target_features       : $(if ($features.Count -gt 0) { $features -join ', ' } else { '(無し)' })"

$missing = @($Require | Where-Object { $_ -notin $features })
$present = @($Forbid  | Where-Object { $_ -in $features })

if ($missing.Count -gt 0) {
    Fail @(
        "要求した機能が target_features にありません: $($missing -join ', ')"
        "  在ったもの: $(if ($features.Count -gt 0) { $features -join ', ' } else { '(無し)' })"
        ""
        "**flag が届いていない。** CMAKE_C_FLAGS / CMAKE_CXX_FLAGS に -msimd128 が"
        "入っているか、toolchain 側で上書きされていないかを確かめること"
        "（同梱の Emscripten.cmake を include した**後**に書く必要がある）。"
    )
}

if ($present.Count -gt 0) {
    Fail @(
        "禁じた機能が有効になっています: $($present -join ', ')"
        "  在ったもの: $($features -join ', ')"
        ""
        "**threads は M6 の非ゴールである**（別 profile として後続）。"
        "-pthread / -matomics が紛れ込んでいないか確かめること。"
    )
}

Write-Host "OK: 要求 [$($Require -join ', ')] は在り、禁止 [$($Forbid -join ', ')] は無い。"
exit 0
