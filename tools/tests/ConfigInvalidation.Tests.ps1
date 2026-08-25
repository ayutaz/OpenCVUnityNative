#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$base = Get-OpenCvConfig
$baseHash = Get-OpenCvConfigHash -Config $base
$baseRoot = Get-OpenCvRoot -Config $base

# 構成を変えた場合、install 先のパスそのものが変わること。
# ハッシュだけ変わってパスが同じなら、古いツリーが再利用されてしまう。
$changed = Get-OpenCvConfig
$changed.Modules = @($changed.Modules) + 'photo'
$changedHash = Get-OpenCvConfigHash -Config $changed
$changedRoot = Get-OpenCvRoot -Config $changed

Assert-That ($changedHash -ne $baseHash) 'adding a module changes the hash'
Assert-That ($changedRoot -ne $baseRoot) 'a different hash resolves to a different install root'
Assert-That ($changedRoot -like "*$changedHash*") 'the install root contains the new hash'

# 引数の並びだけが違う構成は同じハッシュになること。
# ここが変わると、意味の無い再ビルドが起きる。
$reordered = Get-OpenCvConfig
$reordered.CMakeArgs = @($reordered.CMakeArgs | Sort-Object -Descending)
Assert-That ((Get-OpenCvConfigHash -Config $reordered) -eq $baseHash) 'reordering flags does not change the hash'

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
