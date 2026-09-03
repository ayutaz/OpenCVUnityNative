#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Unity が実際に同梱している Emscripten の版が、対応表と一致することを見る（M6）。

.DESCRIPTION
    `tools/emscripten-versions.psd1` は**写し**である。Unity が何を同梱するかは
    こちらが決められないので、値は必ず「誰かが読んで書き写したもの」になる。
    **写しは、写した先が変わった日に静かに古くなる。**

    このスクリプトが、その写しを**実物と突き合わせる**。
    `tools/tests/EmscriptenVersion.Tests.ps1`（速いレーン）は表の自己整合しか
    見ないので、**表と workflow が揃って古くなれば、あちらは緑のままである。**

    **SKIP の経路を作っていない。** Unity が見つからなければ失敗する。
    このリポジトリでは SKIP は「確かめていない」であって「合格」ではなく、
    「道具が無いから検査できない」を緑で通す形は過去に穴になっている。
    **速いレーン（dev.ps1 test）には入れていない**ので、Unity を持たない
    開発者の手元を止めることはない —— 走らせるのは Unity を持つレーンである。

.PARAMETER UnityRoot
    Unity Editor の導入先（`.../Editor` の親）。省略すると OS ごとの既定を探す。
    game-ci のコンテナのように既定と違う場所に在る場合はこれで渡す。

.EXAMPLE
    pwsh -File tools/assert-emscripten-version.ps1
    pwsh -File tools/assert-emscripten-version.ps1 -UnityRoot /opt/unity/Editor
#>
[CmdletBinding()]
param(
    [string]$UnityRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Fail([string[]]$Lines) {
    [Console]::Error.WriteLine(($Lines -join "`n"))
    exit 1
}

# --- 正本から Unity の版を読む。写さない ---
$versionFile = Join-Path $RepoRoot 'tests/UnityProject/ProjectSettings/ProjectVersion.txt'
if (-not (Test-Path -LiteralPath $versionFile)) {
    Fail @("ProjectVersion.txt が見つかりません: $versionFile")
}
$m = [regex]::Match((Get-Content -LiteralPath $versionFile -Raw), 'm_EditorVersion:\s*(?<v>\S+)')
if (-not $m.Success) { Fail @("m_EditorVersion を読み取れませんでした: $versionFile") }
$unityVersion = $m.Groups['v'].Value
$parts = $unityVersion -split '\.'
if ($parts.Count -lt 2) { Fail @("Unity の版を minor 系列に分解できません: '$unityVersion'") }
$unityMinor = "$($parts[0]).$($parts[1])"

# --- 表を読む ---
$table = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'tools/emscripten-versions.psd1')
if (-not $table.ContainsKey($unityMinor)) {
    Fail @(
        "対応表に Unity $unityMinor の項がありません。"
        "tools/emscripten-versions.psd1 に足してください。"
        "値は Unity の PlaybackEngines/WebGLSupport/BuildTools/Emscripten/emscripten/"
        "emscripten-version.txt から読みます。"
    )
}
$expected = $table[$unityMinor].Emscripten

# --- Unity の導入先を決める ---
$candidates = @()
if ($UnityRoot) {
    $candidates += $UnityRoot
} else {
    if ($IsWindows) {
        $candidates += "C:\Program Files\Unity\Hub\Editor\$unityVersion\Editor"
    } elseif ($IsMacOS) {
        $candidates += "/Applications/Unity/Hub/Editor/$unityVersion/Unity.app/Contents"
    } else {
        # Linux。Unity Hub の既定と、game-ci のコンテナが置く場所。
        $candidates += "$HOME/Unity/Hub/Editor/$unityVersion/Editor"
        $candidates += '/opt/unity/Editor'
    }
}

# WebGL の支援モジュールは Editor の Data の下に在る。OS で 1 段違う。
$found = $null
foreach ($root in $candidates) {
    foreach ($rel in @('Data/PlaybackEngines/WebGLSupport', 'PlaybackEngines/WebGLSupport')) {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p) { $found = $p; break }
    }
    if ($found) { break }
}

if (-not $found) {
    Fail @(
        "Unity $unityVersion の WebGL 支援モジュールが見つかりません。"
        "探した場所:"
        ($candidates | ForEach-Object { "  $_" })
        ''
        "**これは SKIP ではなく失敗である。** 版を突き合わせる相手が居ないので、"
        "この検査は何も確かめられていない。"
        ''
        "Unity Hub で WebGL Build Support を導入するか、-UnityRoot で場所を渡してください。"
    )
}

$versionTxt = Join-Path $found 'BuildTools/Emscripten/emscripten/emscripten-version.txt'
if (-not (Test-Path -LiteralPath $versionTxt)) {
    Fail @(
        "同梱 Emscripten の版ファイルが見つかりません: $versionTxt"
        "WebGL 支援モジュールは在るのに中身が違う形なので、Unity の構成が変わった可能性がある。"
    )
}

# '3.1.39-git' のような値が入る。'-git' 以降は落として比べる
# （表は emsdk が受け取る形 '3.1.39' で持っているため）。
$actualRaw = (Get-Content -LiteralPath $versionTxt -Raw).Trim()
$actual = ($actualRaw -split '-')[0]

if ($actual -ne $expected) {
    Fail @(
        "Emscripten の版が対応表と一致しません。"
        "  Unity $unityVersion が同梱: $actualRaw  (比較に使う値: $actual)"
        "  tools/emscripten-versions.psd1 の '$unityMinor': $expected"
        ''
        "**表が古いか、Unity を上げたのに表を直していない。** LLVM はバージョン間の"
        "バイナリ互換を保証しないので、CI が emsdk で入れる版がこことずれると、"
        "CI で通った wasm が Unity のビルドで壊れる。"
        ''
        "表を実物に合わせ、emsdk を pin している workflow も一緒に直してください"
        "（tools/tests/EmscriptenVersion.Tests.ps1 が両者の一致を見ている）。"
    )
}

Write-Host "OK: Unity $unityVersion が同梱する Emscripten は $actualRaw で、対応表 ('$unityMinor' = $expected) と一致します。"
Write-Host "    読んだ場所: $versionTxt"
exit 0
