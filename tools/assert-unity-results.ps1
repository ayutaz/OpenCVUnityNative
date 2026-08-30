#Requires -Version 7.0

<#
    Unity のテスト結果 XML を判定する。

    **なぜ独立した script なのか。** CI では Unity を起動するのが game-ci の
    action で、`tools/dev.ps1` ではない（理由は .github/workflows/ci-unity.yml
    の冒頭にある）。起動の仕方が分かれても、**合否の判定だけは同じコードを
    通す。** ここが分かれると、ローカルで赤くなるものが CI で緑になり得る。

    判定は 4 つ:

      1. 結果 XML が在ること
      2. failed が 0 であること
      3. **passed が 1 以上であること**
      4. `-RequireTest` を渡したときは、**その名前のテストが実際に走っている**こと

    3 番目が要る理由は、0 件の実行が exit 0 / failed 0 と見分けが付かない
    からである。実測で踏んだ: asmdef の defineConstraints に未定義の記号を
    足すとテスト assembly がコンパイル対象から外れ、「0 passed」で exit 0 に
    なった。テストが全部消えても緑になる検査は、検査ではない。

    **4 番目は「全部消えた」ではなく「その 1 群だけ消えた」を捕まえる。**
    3 番目は passed が 1 以上ならよいので、特定のテスト群が assembly から
    外れても残りが通れば緑になる。全部入りの gating（PluginGatingTests）は
    まさにその形で消えうる —— 合図のファイルは置かれ、workflow の検査は
    「合図を書く step がある」ことしか見ないので、**誰も走らせていないのに
    誰も赤くならない。** 走ったことを結果 XML で確かめる。
#>
param(
    # 結果 XML。Unity の -testResults が書いたもの。
    [Parameter(Mandatory)]
    [string] $ResultsPath,

    # 失敗メッセージに添えるレーン名（editmode / player など）。
    [string] $Lane = 'unity',

    # 参考として案内するログの場所。無くてもよい。
    [string] $LogPath,

    # **必ず走っていてほしいテストの名前**（部分一致）。複数可。
    # 渡した名前のテストが結果 XML に 1 件も現れなければ失敗させる。
    [string[]] $RequireTest = @()
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

foreach ($required in $RequireTest) {
    # fullname で見る（クラス名・名前空間を含む）。部分一致にしてあるのは、
    # 呼ぶ側にクラス名だけを書かせるためである。
    $seen = @($xml.SelectNodes('//test-case') |
              Where-Object { $_.GetAttribute('fullname') -like "*$required*" })
    if ($seen.Count -lt 1) {
        Write-Failure @(
            "[$Lane] 走っていることを要求したテストが結果に 1 件もありません: $required"
            'テスト assembly から外れたか、名前が変わっています。'
            "**そのレーンが確かめるはずのものを確かめていない状態で緑にしない。**"
        )
    }
    Write-Host "==> [$Lane] $required ran ($($seen.Count) cases)" -ForegroundColor Green
}

Write-Host "==> [$Lane] $passed passed" -ForegroundColor Green
exit 0
