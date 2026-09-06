#!/usr/bin/env pwsh
# verify-exported-symbols.ps1 が、食い違いを実際に捕まえることを見る。
#
# **実物の binary は使わない。** シンボルの一覧を外から与えられる形にして
# あるので、合成した入力で全分岐を毎回通せる（実物に頼ると、
# 「たまたま一致している」ときに分岐が 1 本も動かない）。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repoRoot 'tools/verify-exported-symbols.ps1'
$failures = 0

# **一時ファイルの名前を固定しない**（check-shared-temp-paths.sh が見ている）。
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-exports-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Test-Case {
    param([string]$Name, [string[]]$Symbols, [bool]$ShouldPass)

    $file = Join-Path $work ((New-Guid).ToString() + '.txt')
    Set-Content -LiteralPath $file -Value $Symbols -Encoding utf8

    & pwsh -NoProfile -File $script -SymbolListPath $file 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)

    if ($ok -eq $ShouldPass) {
        Write-Host "PASS: $Name"
        return 0
    }
    Write-Host "FAIL: $Name (exit=$LASTEXITCODE, 期待は $(if ($ShouldPass) { '成功' } else { '失敗' }))"
    return 1
}

try {
    # spec に在る関数名を正本から読む。**写さない。**
    #
    # **`entryPoint` を持つ entry は集約する** —— verify-exported-symbols.ps1
    # と同じ規則（C# 側だけの別 overload で、C の export は 1 本）。ここで
    # `name` だけを使うと、`ocvu_mat_copy_from_buffer_ptr` のような C# 専用
    # entry を「完全一致は通る」の入力に混ぜてしまい、この負の対照自体が
    # 常に赤くなる形になる（実測）。
    $specDir = Join-Path $repoRoot 'bindings/spec'
    $expected = @(
        Get-ChildItem -LiteralPath $specDir -Filter '*.json' |
            Where-Object { $_.Name -ne 'schema.json' } |
            ForEach-Object {
                (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).functions |
                    ForEach-Object {
                        $entryPoint = $_.PSObject.Properties['entryPoint']
                        if ($entryPoint -and $entryPoint.Value) { $entryPoint.Value } else { $_.name }
                    }
            }
    ) | Sort-Object -Unique

    if ($expected.Count -lt 10) {
        Write-Error "spec から関数名が拾えていない（$($expected.Count) 件）"
        exit 1
    }

    $failures += Test-Case '完全一致は通る' $expected $true
    $failures += Test-Case '1 本足りないと落ちる' ($expected | Select-Object -Skip 1) $false
    $failures += Test-Case '知らないものが 1 本あると落ちる' ($expected + 'ocvu_not_in_spec') $false
    $failures += Test-Case '空は落ちる' @() $false
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Error "$failures 件失敗"; exit 1 }
Write-Host '==> ExportedSymbols.Tests: OK'
