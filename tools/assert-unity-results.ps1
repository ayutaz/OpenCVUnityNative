#Requires -Version 7.0

<#
    Unity のテスト結果 XML を判定する。

    **なぜ独立した script なのか。** CI では Unity を起動するのが game-ci の
    action で、`tools/dev.ps1` ではない（理由は .github/workflows/ci-unity.yml
    の冒頭にある）。起動の仕方が分かれても、**合否の判定だけは同じコードを
    通す。** ここが分かれると、ローカルで赤くなるものが CI で緑になり得る。

    判定は 3 つ:

      1. 結果 XML が在ること
      2. failed が 0 であること
      3. **passed が 1 以上であること**

    3 番目が要る理由は、0 件の実行が exit 0 / failed 0 と見分けが付かない
    からである。実測で踏んだ: asmdef の defineConstraints に未定義の記号を
    足すとテスト assembly がコンパイル対象から外れ、「0 passed」で exit 0 に
    なった。テストが全部消えても緑になる検査は、検査ではない。
#>
param(
    # 結果 XML。Unity の -testResults が書いたもの。
    [Parameter(Mandatory)]
    [string] $ResultsPath,

    # 失敗メッセージに添えるレーン名（editmode / player など）。
    [string] $Lane = 'unity',

    # 参考として案内するログの場所。無くてもよい。
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Write-Failure([string[]]$Lines) {
    if ($LogPath) { $Lines += "ログ: $LogPath" }
    [Console]::Error.WriteLine(($Lines -join "`n"))
    exit 1
}

if (-not (Test-Path -LiteralPath $ResultsPath)) {
    Write-Failure @(
        "[$Lane] Unity が結果 XML を出しませんでした: $ResultsPath"
        'XML が無いのは「失敗が 0 件」ではなく「実行そのものが成立しなかった」である。'
    )
}

try {
    [xml]$xml = Get-Content -LiteralPath $ResultsPath -Raw
}
catch {
    Write-Failure @(
        "[$Lane] 結果 XML を読めませんでした: $ResultsPath"
        $_.Exception.Message
    )
}

# StrictMode 下では、存在しない要素へのアクセスが例外になる。そのまま
# 落ちても非 0 では終わるが、何が悪いのか読めない生の例外が出るだけになる
# （実測で踏んだ）。SelectSingleNode なら見つからないときに $null を返す。
$run = $xml.SelectSingleNode('/test-run')
if ($null -eq $run) {
    Write-Failure @(
        "[$Lane] 結果 XML に test-run 要素がありません: $ResultsPath"
        '想定した形式ではないものを「合格」と読まない。'
    )
}

$passed = [int]$run.GetAttribute('passed')
$failed = [int]$run.GetAttribute('failed')

if ($failed -ne 0) {
    $names = @($xml.SelectNodes('//test-case[@result="Failed"]') |
               ForEach-Object { "  $($_.fullname)" } | Select-Object -First 10)
    Write-Failure (@("[$Lane] テストが $failed 件失敗しました（passed=$passed）。") + $names)
}

if ($passed -lt 1) {
    Write-Failure @(
        "[$Lane] テストが 1 件も実行されませんでした（passed=$passed、failed=$failed）。"
        'テストが全部消えたか、テスト assembly がコンパイル対象から外れています。'
        '**0 件の実行は成功ではありません。**'
    )
}

Write-Host "==> [$Lane] $passed passed" -ForegroundColor Green
exit 0
