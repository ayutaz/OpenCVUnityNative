#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    成果物の linkage 検証そのものを検証する。

    この検査は「読めなかったら通す」形になっていないことが最も重要なので、
    正常系より異常系を厚く見る。
#>

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verify = Join-Path $repoRoot 'tools/verify-artifact-linkage.ps1'
$failures = @()

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

# --- 実物に対して通ること ---
$config = Get-OpenCvConfig
$root = Get-OpenCvRoot -Config $config
if (Test-Path -LiteralPath $root) {
    & pwsh -NoProfile -File $verify -Root $root | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'the restored artifact matches the configured linkage'
}
else {
    Write-Host "  SKIP  no restored artifact at $root" -ForegroundColor Yellow
}

# --- 存在しないツリーは失敗にする（黙って通さない） ---
$missing = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-missing-" + [guid]::NewGuid().ToString('n'))
& pwsh -NoProfile -File $verify -Root $missing 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a missing artifact tree fails rather than passing vacuously'

# --- ライブラリが 1 つも無いツリーは失敗にする ---
#
# ここが「読めなかったら通す」の典型的な入り口である。走査して 0 件だったとき、
# 「違反が無かった」と読むと、検査が何も見ていない状態が緑になる。
$empty = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-empty-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path (Join-Path $empty 'x64/vc17/staticlib') | Out-Null
& pwsh -NoProfile -File $verify -Root $empty 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a tree with no libraries fails rather than reporting no violations'
Remove-Item -Recurse -Force $empty -ErrorAction SilentlyContinue

# --- 未対応 platform を指定したら失敗にする ---
& pwsh -NoProfile -File $verify -Root $root -Platform 'solaris-sparc' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unsupported platform fails rather than skipping the check'

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
