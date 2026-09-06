#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)][string]$TarballPath,
    [Parameter(Mandatory = $true)][long]$MaxBytes
)

# 配布物の大きさを測り、上限を超えたら落とす。
#
# **時間と違って、これは assert してよい**（設計 D1）—— 同じ入力から同じ
# tarball ができるので、CI ランナーの負荷に左右されない。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

if (-not (Test-Path -LiteralPath $TarballPath)) {
    # **存在しないものを 0 バイトとして通さない。** 通すと
    # 「packer が何も出さなかった」が最も小さい package として合格する。
    Write-Error "package が無い: $TarballPath"
    exit 1
}

$bytes = (Get-Item -LiteralPath $TarballPath).Length
Write-Host "==> package size: $bytes (ceiling $MaxBytes)"

if ($bytes -gt $MaxBytes) {
    Write-Error "package が上限を超えた: $bytes > $MaxBytes"
    exit 1
}

if ($bytes -eq 0) {
    Write-Error 'package が 0 バイト。packer が何も出していない'
    exit 1
}
