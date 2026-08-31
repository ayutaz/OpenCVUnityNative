#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# $PSScriptRoot はこのファイルの置かれたディレクトリ（tools/tests）なので、
# 2 段上がると repo root になる。既存の tools/tests/*.Tests.ps1 と同じ導出。
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dev = Join-Path $repoRoot 'tools/dev.ps1'

# --- 生成物が spec と一致していること ---
& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'the generated bindings match the spec'

# --- **生成物を手で変えたら落ちること。** これが無いと検査が働いた証拠が無い ---
$header = Join-Path $repoRoot 'native/include/ocvu/infra.h'
$backup = Get-Content -LiteralPath $header -Raw
try {
    Add-Content -LiteralPath $header -Value '/* 手で足した行 */'
    & pwsh -NoProfile -File $dev verify-generated 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'editing a generated file by hand fails the check'
}
finally { Set-Content -LiteralPath $header -Value $backup -NoNewline }

# --- 戻したら通ること（後始末が効いていることの確認） ---
& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'restoring the generated file makes the check pass again'

# --- 生成物に「生成物である」と書いてあること ---
Assert-That ((Get-Content -LiteralPath $header -Raw) -match 'このファイルは生成物である') `
    'the generated header says it is generated'

# --- **実装 -> spec の逆向き。** spec -> 実装は L1 のリンクと L3 の P/Invoke が
# 見ているが、逆は誰も見ていなかった: extern "C" で ocvu_ を実装して spec に
# 書き忘れると、C ヘッダにも C# にも宣言が生まれず、export だけが残る。
# ビルドも CI も緑のまま、誰からも呼べない関数が配布物に入る。
$specDir = Join-Path $repoRoot 'bindings/spec'
$srcDir = Join-Path $repoRoot 'native/src'

# **実効 entry point で突き合わせる。** entryPoint を持つ entry（byte[] 版と
# ポインタ版のように C の 1 本へ 2 つの C# 宣言を向けるもの）は、その名前の
# 関数が実装側に存在しない。比べるべきは C から見える名前である。
$specEntryPoints = @()
foreach ($specFile in Get-ChildItem -LiteralPath $specDir -Filter '*.json') {
    if ($specFile.Name -eq 'schema.json') { continue }
    $spec = Get-Content -LiteralPath $specFile.FullName -Raw | ConvertFrom-Json
    foreach ($fn in $spec.functions) {
        $explicit = $fn.PSObject.Properties['entryPoint']
        $specEntryPoints += if ($explicit) { $explicit.Value } else { $fn.name }
    }
}
$specEntryPoints = @($specEntryPoints | Sort-Object -Unique)
Assert-That ($specEntryPoints.Count -gt 0) 'the spec scan found entry points (0 件は「違反なし」ではない)'

# コメントを先に落とす。**散文の中の extern "C" に当たらないため** ——
# native/src/ocvu_error.cpp の冒頭は、例外が extern "C" 関数を抜ける話を
# 日本語で書いている（prove-a-check-works の「述語が散文に当たる」）。
$implNames = @()
$externCount = 0
foreach ($srcFile in Get-ChildItem -LiteralPath $srcDir -Filter '*.cpp' -Recurse) {
    $code = Get-Content -LiteralPath $srcFile.FullName -Raw
    $code = [regex]::Replace($code, '/\*[\s\S]*?\*/', ' ')
    $code = [regex]::Replace($code, '//[^\r\n]*', ' ')
    $externCount += ([regex]::Matches($code, 'extern\s+"C"')).Count
    # `[^;{}()]*?` が戻り値の型を跨ぐ。lazy なので最初の ocvu_xxx( で止まり、
    # 文の区切りは越えない。
    foreach ($m in [regex]::Matches($code, 'extern\s+"C"\s+[^;{}()]*?\b(ocvu_[a-z0-9_]+)\s*\(')) {
        $implNames += $m.Groups[1].Value
    }
}
$implNames = @($implNames | Sort-Object -Unique)

Assert-That ($implNames.Count -gt 0) 'the native scan found extern "C" ocvu_* definitions (0 件は「違反なし」ではない)'
# **切れなかったときは空振りではなく落ちる。** extern "C" があるのに名前を
# 取り出せなかったら、その 1 本はこの検査の網から静かに外れている。
Assert-That ($implNames.Count -eq $externCount) `
    "every extern C block in native/src was attributed to an ocvu_ name (取り出せた $($implNames.Count) / extern C $externCount)"

$notInSpec = @($implNames | Where-Object { $specEntryPoints -notcontains $_ })
$detail = if ($notInSpec.Count -gt 0) { ' — spec に無い実装: ' + ($notInSpec -join ', ') } else { '' }
Assert-That ($notInSpec.Count -eq 0) "every extern C ocvu_* in native/src is declared in the spec$detail"

if ($script:failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($script:failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
