#!/usr/bin/env pwsh
# Unity の版と Emscripten の版の対応表が、現実と食い違っていないかを見る（M6）。
#
# **表は写しである。** Unity が同梱する Emscripten の版はこちらが決められない
# ので、`tools/emscripten-versions.psd1` は必ず「誰かが読んで書き写したもの」に
# なる。**写しは、写した先が変わった日に静かに古くなる。**
#
# だから検査を 2 つ対にする:
#
#   A（このファイル。Unity が要らない）
#       - ProjectVersion.txt の Unity 版に対応する項が表に在る
#       - workflow が pin している emsdk の版が、表と一致する
#   B（tools/assert-emscripten-version.ps1。Unity が要る）
#       - **Unity が実際に同梱している版**が、表と一致する
#
# **A だけでは「表が現実と合っているか」を誰も見ない**（表と workflow が
# 揃って古くなれば緑になる）。**B だけでは Unity レーンが動くまで気づけない。**
#
# 非 ASCII を出すので OutputEncoding を明示する（cp932 / cp1252 で化ける）。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# $PSScriptRoot は tools/tests なので 2 段上が repo root。既存の tools/tests と同じ導出。
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --- Unity の版は ProjectVersion.txt から読む。写さない ---
$projectVersionPath = Join-Path $repoRoot 'tests/UnityProject/ProjectSettings/ProjectVersion.txt'
$projectVersion = Get-Content -LiteralPath $projectVersionPath -Raw
$unityMatch = [regex]::Match($projectVersion, 'm_EditorVersion:\s*(?<v>\S+)')
Assert-That ($unityMatch.Success) 'ProjectVersion.txt states the Unity version'

$unityMinor = $null
if ($unityMatch.Success) {
    # '6000.3.16f1' -> '6000.3'。Emscripten は minor 系列ごとに変わるので、
    # patch まで表に持つと Unity を 1 つ上げるたびに表を触ることになる。
    $parts = $unityMatch.Groups['v'].Value -split '\.'
    Assert-That ($parts.Count -ge 2) "the Unity version splits into a minor series (got '$($unityMatch.Groups['v'].Value)')"
    if ($parts.Count -ge 2) { $unityMinor = "$($parts[0]).$($parts[1])" }
}

# --- 表を読む ---
$tablePath = Join-Path $repoRoot 'tools/emscripten-versions.psd1'
Assert-That (Test-Path -LiteralPath $tablePath) 'tools/emscripten-versions.psd1 exists'

$table = $null
if (Test-Path -LiteralPath $tablePath) {
    $table = Import-PowerShellDataFile -LiteralPath $tablePath
    Assert-That ($table.Keys.Count -gt 0) 'the version table is not empty (0 件なら以下の照合は何も見ない)'
}

$expectedEmscripten = $null
if ($null -ne $table -and $null -ne $unityMinor) {
    Assert-That ($table.ContainsKey($unityMinor)) "the table has an entry for Unity $unityMinor"
    if ($table.ContainsKey($unityMinor)) {
        $entry = $table[$unityMinor]
        Assert-That ($entry.ContainsKey('Emscripten') -and $entry.Emscripten -match '^\d+\.\d+\.\d+$') `
            "the entry for Unity $unityMinor states an Emscripten version (got '$($entry.Emscripten)')"
        Assert-That ($entry.ContainsKey('Commit') -and $entry.Commit -match '^[0-9a-f]{40}$') `
            "the entry for Unity $unityMinor states the Emscripten commit (40 hex)"
        $expectedEmscripten = $entry.Emscripten
    }
}

# --- workflow が pin している emsdk の版が、表と一致すること ---
#
# **workflow に数字を直書きさせない**のが目的である。直書きすると、表と
# workflow が別々に古くなり、**どちらが正しいか誰にも分からなくなる。**
#
# 拾えた数が 0 なら「一致した」ではなく**走査が効いていない**として落とす
# （M6 で emsdk を使う job を足したら、ここが 1 以上になる）。
$workflowDir = Join-Path $repoRoot '.github/workflows'
$workflowFiles = @(Get-ChildItem -LiteralPath $workflowDir -File |
    Where-Object { $_.Extension -in '.yml', '.yaml' })
Assert-That ($workflowFiles.Count -gt 0) 'the workflow directory was actually scanned'

$pinned = @()
foreach ($wf in $workflowFiles) {
    $text = Get-Content -LiteralPath $wf.FullName -Raw
    # mymindstorm/setup-emsdk の version 入力。'latest' は禁止（上流が動くと
    # こちらが何も変えていないのに壊れる —— actions の版を固定するのと同じ理由）。
    foreach ($m in [regex]::Matches($text, 'setup-emsdk@[^\r\n]*[\s\S]{0,400}?version:\s*(?<v>[^\s#]+)')) {
        $pinned += [pscustomobject]@{ File = $wf.Name; Version = $m.Groups['v'].Value.Trim("'`"") }
    }
}

# **求めるのは「表と同じ数字が書いてあること」ではなく「数字が書いていないこと」である。**
#
# 最初はリテラルと表を突き合わせる形にしていたが、**それは 2 箇所に同じ値を
# 持つことを前提にした検査**だった。workflow が表を実行時に読む形にしたので、
# **リテラルが在ること自体が欠陥**になる —— 表を直しても workflow が古いまま
# 残る経路が、そこにしか生まれない。
foreach ($p in $pinned) {
    Assert-That ($p.Version -notmatch '^\d+\.\d+') `
        "$($p.File) does not hardcode an emsdk version (got '$($p.Version)'; 表から読むこと)"
}
# **0 件を失敗にする。**
#
# 当初は「emsdk を使う job を足すまで 0 件が正しい」としていたが、
# **その根拠は失効した** —— いま emsdk を入れる job は
# build-opencv / ci-native / release の 3 本ある（M6 のレビューの指摘）。
#
# **0 件になるのは「emsdk の step が消えた」か「拾い方が壊れた」ときだけ**で、
# どちらも**この検査が何も主張していない状態**である。
# **拾えなかったことを「一致した」と読まない。**
Assert-That ($pinned.Count -gt 0) `
    "setup-emsdk の version 入力を 1 つ以上拾えた (got $($pinned.Count))"


if ($script:failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($script:failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
