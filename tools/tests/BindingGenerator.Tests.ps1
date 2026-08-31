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

if ($script:failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($script:failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
