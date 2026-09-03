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

# --- 先頭は "\0asm" + version(4) である。ここが違えば wasm ではない ---
if ($bytes.Length -lt 8 -or
    $bytes[0] -ne 0x00 -or $bytes[1] -ne 0x61 -or $bytes[2] -ne 0x73 -or $bytes[3] -ne 0x6D) {
    Fail @(
        "wasm の magic number がありません: $Path"
        "先頭 8 byte: $(($bytes | Select-Object -First 8 | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')"
        "**host 向けの object を掴んでいる可能性がある** —— クロスの設定を確かめること。"
    )
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

$offset = 8
$features = @()
$sectionCount = 0

while ($offset -lt $bytes.Length) {
    $id = $bytes[$offset]; $offset++
    $size = Read-ULeb $bytes ([ref]$offset)
    $sectionEnd = $offset + $size
    if ($sectionEnd -gt $bytes.Length) {
        Fail @("section が宣言した大きさ（$size）がファイルを超えています: $Path")
    }
    $sectionCount++

    if ($id -eq 0) {
        # custom section: 名前（LEB 長 + bytes）が先頭に在る。
        $nameStart = $offset
        $nameLen = Read-ULeb $bytes ([ref]$offset)
        $name = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $nameLen)
        $offset += $nameLen

        if ($name -eq 'target_features') {
            $count = Read-ULeb $bytes ([ref]$offset)
            for ($i = 0; $i -lt $count; $i++) {
                # 1 byte の prefix（'+' 0x2B / '-' 0x2D / '=' 0x3D）+ 名前
                $offset++
                $fLen = Read-ULeb $bytes ([ref]$offset)
                $features += [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $fLen)
                $offset += $fLen
            }
        }
        $offset = $sectionEnd
        # nameStart は使わないが、custom section の形を読んだことを明示するために残す
        $null = $nameStart
    } else {
        $offset = $sectionEnd
    }
}

# **section を 1 つも読めていないなら「違反なし」ではなく走査の失敗である。**
if ($sectionCount -eq 0) {
    Fail @("section を 1 つも読めませんでした: $Path（走査が効いていない）")
}

Write-Host "wasm: $Path"
Write-Host "  section 数            : $sectionCount"
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
