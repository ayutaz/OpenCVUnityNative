#!/usr/bin/env pwsh
<#
    tools/run-benchmarks.ps1 の門が、実際に落ちることを見る。

    **このスクリプトが担当するのは「publish してはいけない入力」である。**
    数字の速い・遅いは判定しない（設計 D1）—— 判定するのは
    「測れたと言えるか」だけで、その判定が働くことを合成した結果 XML で確かめる。

    **本物の Unity は要らない。** 読んでいるのは NUnit3 の結果 XML の
    <output> ノードだけなので、その形だけを作れば同じ経路を通る。
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repoRoot 'tools/run-benchmarks.ps1'
$failures = 0

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures++ }
}

# **一時ファイルの名前を固定しない。** dev.ps1 はレーンを並べて走らせるので、
# 固定すると 2 つの実行が潰し合う（check-shared-temp-paths.sh が見ている）。
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-bench-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null

function New-ResultXml([string]$name, [string[]]$OutputLines) {
    $path = Join-Path $work $name
    $body = ($OutputLines | ForEach-Object { [System.Security.SecurityElement]::Escape($_) }) -join "`n"
    @"
<?xml version="1.0" encoding="utf-8"?>
<test-run id="2" total="1" passed="1" failed="0">
  <test-suite type="TestFixture" name="BenchmarkRunner">
    <test-case name="Measure" result="Passed">
      <output><![CDATA[$body]]></output>
    </test-case>
  </test-suite>
</test-run>
"@ | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

try {
    $out = Join-Path $work 'latest.json'

    # --- 正の対照: まっとうな入力は通り、値が書かれること ---
    $good = New-ResultXml 'good.xml' @('OCVU_BENCH: copy_to_buffer=42', 'OCVU_BENCH: startup=7')
    & pwsh -NoProfile -File $script -XmlPath $good -OutPath $out 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'a well-formed result XML is accepted'
    $written = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw | ConvertFrom-Json } else { $null }
    Assert-That ($null -ne $written -and $written.results.copy_to_buffer -eq 42 -and $written.results.startup -eq 7) `
        'the measured values reach the published payload'

    # --- **key の書き方がずれると落ちること（レビュー I-2）。** ---
    # `OCVU_BENCH:` の行は在る（既存の 2 つの門はどちらも満たす）のに、
    # 正規表現が key=value を取り出せず $results が空になる形。
    # 門が無かった頃は `results: {}` を書いて exit 0 していた。
    #
    # **camelCase では起きない。** レビューはその例を挙げたが、
    # PowerShell の `-match` は既定で大文字小文字を区別しないので
    # `[a-z0-9_]+` は `copyToBuffer` を通す（実測）。**起きるのは区切りが
    # 変わったときと、key に `-` や `.` が入ったときである** —— 両方見る。
    foreach ($shape in @(
        @{ Line = 'OCVU_BENCH: copy-to-buffer=42'; What = 'a hyphenated key' },
        @{ Line = 'OCVU_BENCH: copy_to_buffer: 42'; What = 'a ":" separator instead of "="' })) {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        $drifted = New-ResultXml ('drift-' + [guid]::NewGuid().ToString('N') + '.xml') @($shape.Line)
        & pwsh -NoProfile -File $script -XmlPath $drifted -OutPath $out 2>&1 | Out-Null
        Assert-That ($LASTEXITCODE -ne 0) "$($shape.What) (nothing parses) is rejected"
        Assert-That (-not (Test-Path -LiteralPath $out)) `
            "nothing is published when no key=value could be parsed ($($shape.What))"
    }

    # --- 0 マイクロ秒は publish しない（既存の門） ---
    $zero = New-ResultXml 'zero.xml' @('OCVU_BENCH: copy_to_buffer=0')
    & pwsh -NoProfile -File $script -XmlPath $zero -OutPath $out 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'a 0 microsecond entry is rejected'

    # --- OCVU_BENCH の行が 1 本も無い XML は名指しで落ちる（既存の門） ---
    $empty = New-ResultXml 'empty.xml' @('nothing to see here')
    & pwsh -NoProfile -File $script -XmlPath "$good;$empty" -OutPath $out 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'an XML with no OCVU_BENCH line is rejected even when the other one has them'

    # --- 存在しない XML は落ちる（既存の門） ---
    & pwsh -NoProfile -File $script -XmlPath (Join-Path $work 'nope.xml') -OutPath $out 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'a missing result XML is rejected'
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    [Console]::Error.WriteLine("`n$failures assertion(s) failed")
    exit 1
}
Write-Host '==> Benchmarks.Tests: OK' -ForegroundColor Green
