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
    param(
        [string]$Name,
        [string[]]$Symbols,
        [bool]$ShouldPass,
        # 指定すると、標準出力（+ 標準エラー）にこの文字列が含まれることも要求する。
        # **「除外した」のような、落とすだけで終わらせない挙動を証明するために要る**
        # ——終了コードだけでは、非 ocvu_ の export を報告しているか無視しているかを
        # 区別できない。
        [string]$ExpectOutputContains
    )

    $file = Join-Path $work ((New-Guid).ToString() + '.txt')
    Set-Content -LiteralPath $file -Value $Symbols -Encoding utf8

    $output = & pwsh -NoProfile -File $script -SymbolListPath $file 2>&1
    $ok = ($LASTEXITCODE -eq 0)

    $outputOk = $true
    if ($ExpectOutputContains) {
        $outputOk = ($output | Out-String).Contains($ExpectOutputContains)
    }

    if ($ok -eq $ShouldPass -and $outputOk) {
        Write-Host "PASS: $Name"
        return 0
    }
    $why = @()
    if ($ok -ne $ShouldPass) { $why += "期待は $(if ($ShouldPass) { '成功' } else { '失敗' })" }
    if (-not $outputOk) { $why += "出力に '$ExpectOutputContains' を含むこと" }
    Write-Host "FAIL: $Name (exit=$LASTEXITCODE, $($why -join ' / '))"
    if (-not $outputOk) { Write-Host "--- actual output ---`n$($output -join [Environment]::NewLine)" }
    return 1
}

<#
    **entryPoint の折り畳みが「実在する name を指すこと」を、合成した spec で
    確かめる。** 本物の bindings/spec を書き換えずに、`-SpecDir` で差し替えた
    使い捨ての spec ディレクトリに対して verify-exported-symbols.ps1 を
    走らせる。
#>
function Test-SpecCase {
    param(
        [string]$Name,
        [string]$SpecJson,
        [string[]]$Symbols,
        [bool]$ShouldPass,
        [string]$ExpectOutputContains
    )

    $specWork = Join-Path $work ("spec-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $specWork | Out-Null
    Set-Content -LiteralPath (Join-Path $specWork 'synthetic.json') -Value $SpecJson -Encoding utf8

    $symFile = Join-Path $work ((New-Guid).ToString() + '.txt')
    Set-Content -LiteralPath $symFile -Value $Symbols -Encoding utf8

    $output = & pwsh -NoProfile -File $script -SpecDir $specWork -SymbolListPath $symFile 2>&1
    $ok = ($LASTEXITCODE -eq 0)

    $outputOk = $true
    if ($ExpectOutputContains) {
        $outputOk = ($output | Out-String).Contains($ExpectOutputContains)
    }

    if ($ok -eq $ShouldPass -and $outputOk) {
        Write-Host "PASS: $Name"
        return 0
    }
    $why = @()
    if ($ok -ne $ShouldPass) { $why += "期待は $(if ($ShouldPass) { '成功' } else { '失敗' })" }
    if (-not $outputOk) { $why += "出力に '$ExpectOutputContains' を含むこと" }
    Write-Host "FAIL: $Name (exit=$LASTEXITCODE, $($why -join ' / '))"
    if (-not $outputOk) { Write-Host "--- actual output ---`n$($output -join [Environment]::NewLine)" }
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

    <#
        **方向 (b) のうち非 ocvu_ の場合を、この suite から到達可能にする。**

        `$actual` を作るときの `ocvu_*` フィルタは、third-party のシンボルが
        紛れても検査が意味を失わないために要る（維持する）。ただし、
        以前はこの分岐へ到達する入力が 1 つも無く、「落とすだけで実は
        何も報告していない」まま緑になり得た。ここで実際に到達させ、
        (1) 通ること（third-party のシンボルは spec との比較対象にならない）と
        (2) 何を捨てたかを報告すること、の両方を検査する。
    #>
    $failures += Test-Case '非 ocvu_ の export は比較から除外されて通る' `
        ($expected + 'some_other_library_symbol') $true '非 ocvu_'

    <#
        **entryPoint が実在の name を指すことの検証。**

        `synthetic.json` は本物の spec には無い、この検査専用の合成 spec
        （`-SpecDir` で差し替える）。schema 検証は通らないので、この
        スクリプトが実際に読む 2 フィールド（name / entryPoint）だけを持つ。
    #>
    $goodSpec = @'
{
  "functions": [
    { "name": "ocvu_synthetic_foo" },
    { "name": "ocvu_synthetic_foo_ptr", "entryPoint": "ocvu_synthetic_foo" }
  ]
}
'@
    $badSpec = @'
{
  "functions": [
    { "name": "ocvu_synthetic_foo" },
    { "name": "ocvu_synthetic_foo_ptr", "entryPoint": "ocvu_synthetic_bar" }
  ]
}
'@

    $failures += Test-SpecCase 'entryPoint が既存の name を指せば通る' `
        $goodSpec @('ocvu_synthetic_foo') $true
    $failures += Test-SpecCase '存在しない名前を指す entryPoint は落ちる' `
        $badSpec @('ocvu_synthetic_foo') $false 'entryPoint'
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Error "$failures 件失敗"; exit 1 }
Write-Host '==> ExportedSymbols.Tests: OK'
