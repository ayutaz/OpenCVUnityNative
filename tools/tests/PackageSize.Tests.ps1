#!/usr/bin/env pwsh
# measure-package-size.ps1 が、上限を超えた package を実際に落とすことを見る。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repoRoot 'tools/measure-package-size.ps1'
$failures = 0

# **一時ファイルの名前を固定しない。** dev.ps1 はレーンを並べて走らせるので、
# 固定すると 2 つの実行が潰し合い、落ちるのは無関係な assertion になる
# （check-shared-temp-paths.sh がこれを見ている）。
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-pkgsize-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $fake = Join-Path $work 'fake.tgz'
    [System.IO.File]::WriteAllBytes($fake, (New-Object byte[] 2048))

    # 上限を超える場合: 落ちること
    & pwsh -NoProfile -File $script -TarballPath $fake -MaxBytes 1024 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'FAIL: 上限 1024 に対して 2048 バイトの package が通った'
        $failures++
    } else {
        Write-Host 'PASS: 上限超過が落ちる'
    }

    # 上限内の場合: 通ること
    & pwsh -NoProfile -File $script -TarballPath $fake -MaxBytes 4096 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'FAIL: 上限 4096 に対して 2048 バイトの package が落ちた'
        $failures++
    } else {
        Write-Host 'PASS: 上限内は通る'
    }

    # **0 バイトの package を通してはならない。**
    # measure-package-size.ps1 にはこの分岐があったが、**どの入力も
    # 一度も到達していなかった**（上限超過・上限内・不在の 3 件だけを
    # 運転していた）。分岐が在ることは、その分岐が働くことではない。
    $zero = Join-Path $work 'zero.tgz'
    [System.IO.File]::WriteAllBytes($zero, (New-Object byte[] 0))
    & pwsh -NoProfile -File $script -TarballPath $zero -MaxBytes 4096 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'FAIL: 0 バイトの package が通った'
        $failures++
    } else {
        Write-Host 'PASS: 0 バイトの package は落ちる'
    }

    # **存在しないファイルは、0 バイトとして通してはならない。**
    & pwsh -NoProfile -File $script -TarballPath (Join-Path $work 'nope.tgz') -MaxBytes 4096 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'FAIL: 存在しない package が通った'
        $failures++
    } else {
        Write-Host 'PASS: 存在しない package は落ちる'
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Error "$failures 件失敗"; exit 1 }
Write-Host '==> PackageSize.Tests: OK'
