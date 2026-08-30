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
      4. `-RequireTest` を渡したときは、**その名前のテストが Passed で終わっている**こと
      5. `-RequireOutput` を渡したときは、**その文字列がテストの出力に現れている**こと

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

    **`Passed` であることまで見る。** NUnit3 は `[Ignore]` や `Assume` の失敗も
    `<test-case result="Skipped">` / `"Inconclusive"` として出力し、`failed` にも
    数えない。存在だけを見ると、`[Ignore]` を付けるだけで 4 番目が満たされる。

    **5 番目は、4 番目でも捕まらないものを捕まえる。** テストが走って通っても、
    **弱い側の分岐を通っただけ**かもしれない —— 全部入りの gating は「3 つ
    揃っているはず」という合図が届かなければ「1 つ以上」しか要求せず、その
    ときの出力は意図どおり動いた場合と 1 バイトも違わない。**入力（合図を
    書く step が在ること）をいくら検査しても、届いたことの証明にはならない。**
    テスト自身が出力した事実（`native plugins present: 3`）を要求すれば、
    合図の経路が壊れた時点で赤くなる。
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
    # 渡した名前のテストが Passed で 1 件も現れなければ失敗させる。
    [string[]] $RequireTest = @(),

    # **テストの出力に必ず現れていてほしい文字列**（部分一致）。複数可。
    # 「テストが走った」より強く、「**どの分岐を通ったか**」を見る。
    [string[]] $RequireOutput = @()
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

<#
    **';' 区切りも受ける。**

    `pwsh -NoProfile -File` から呼ぶと配列が正しく渡らず、**2 つ目以降が
    黙って捨てられる**（実測。4 件を渡したのに 1 件しか要求されなかった）。
    黙って弱くなるので、呼ぶ側の作法に依存しない形にする。workflow は
    splat で配列を渡し、dev.ps1 は ';' で繋いだ 1 つの文字列を渡す。
#>
$RequireTest   = @($RequireTest   | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() })
$RequireOutput = @($RequireOutput | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() })

# **空文字を弾く。** -like "**" は何にでも当たるので、空を渡すと
# 「要求したことになっているが何も要求していない」状態が exit 0 で通り、
# しかも安心させる行まで出る。呼ぶ側でガードしても、判定を分けないという
# 不変条件の下ではここに要る。
foreach ($required in @($RequireTest + $RequireOutput)) {
    if ([string]::IsNullOrWhiteSpace($required)) {
        Write-Failure @(
            "[$Lane] -RequireTest / -RequireOutput に空の値が渡されました。"
            '**何も要求しない要求**は、通っても何の証拠にもならない。渡さないこと。'
        )
    }
}

foreach ($required in $RequireTest) {
    # fullname で見る（クラス名・名前空間を含む）。部分一致にしてあるのは、
    # 呼ぶ側にクラス名だけを書かせるためである。
    $matching = @($xml.SelectNodes('//test-case') |
                  # -clike にする。-like は大小文字を区別せず、* ? [ を
                  # ワイルドカードとして解釈する（この波が -cmatch で潰したのと
                  # 同じ罠をここに残さない）。
                  Where-Object { $_.GetAttribute('fullname') -clike "*$required*" })
    # **Passed であることまで見る。** Skipped / Inconclusive は failed に
    # 数えられないので、存在だけを見ると [Ignore] で満たせてしまう。
    $seen = @($matching | Where-Object { $_.GetAttribute('result') -eq 'Passed' })
    if ($seen.Count -lt 1) {
        $states = @($matching | ForEach-Object { $_.GetAttribute('result') } | Sort-Object -Unique)
        Write-Failure @(
            "[$Lane] 走って通っていることを要求したテストが結果にありません: $required"
            "見つかった test-case: $($matching.Count) 件（result: $(if ($states) { $states -join ', ' } else { 'なし' })）"
            'テスト assembly から外れたか、名前が変わったか、Ignore されています。'
            "**そのレーンが確かめるはずのものを確かめていない状態で緑にしない。**"
        )
    }
    Write-Host "==> [$Lane] $required passed ($($seen.Count) cases)" -ForegroundColor Green
}

foreach ($required in $RequireOutput) {
    # NUnit3 は TestContext.WriteLine の出力を test-case の <output> に入れる。
    $hit = @($xml.SelectNodes('//output') |
             Where-Object { $_.InnerText -and $_.InnerText.Contains($required) })
    if ($hit.Count -lt 1) {
        Write-Failure @(
            "[$Lane] テストの出力に現れることを要求した文字列がありません: $required"
            '**テストが通ったことと、確かめたかった分岐を通ったことは別である。**'
            'このレーンは強い側の主張を検査していない状態で緑になろうとしている。'
        )
    }
    Write-Host "==> [$Lane] output says: $required" -ForegroundColor Green
}

Write-Host "==> [$Lane] $passed passed" -ForegroundColor Green
exit 0
