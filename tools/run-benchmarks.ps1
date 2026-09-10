#!/usr/bin/env pwsh
<#
    Unity の結果 XML から OCVU_BENCH: の行を集めて artifacts/benchmarks/ へ書く。

    **判定しない。** 時間の閾値は共有ランナーの上でフレークになるので、
    このスクリプトは「測れたか」だけを見る（設計 D1）。

    **ログではなく結果 XML の //output を読む。** brief 原案は Debug.Log を
    artifacts/test-results/player.log から grep する形だったが、実測で
    2 つとも実物と違うと分かった（controller の裁定）: このリポジトリの
    確立した型は TestContext.WriteLine で、NUnit3 がそれを結果 XML の
    <output> ノードへ入れる。tools/assert-unity-results.ps1 -RequireOutput
    と同じ読み方をここでも使う。
#>
param(
    # Unity の -testResults が書いた結果 XML。複数可 —— GPU に依らない経路は
    # unity-player.xml（test-unity-player）、GPU に依る経路は
    # unity-graphics.xml（test-unity-graphics）に分かれている。
    #
    # **';' 区切りの 1 文字列も受ける。** tools/assert-unity-results.ps1 と
    # 同じ理由: `pwsh -NoProfile -File` で外部プロセスとして呼ぶと、
    # PowerShell の配列は「同じ -XmlPath の下に複数値」としては渡らない
    # ——子プロセス側は 1 個目しか -XmlPath に束ねず、2 個目以降を
    # 「対応する named parameter が無い positional 引数」として拒否する
    # （実測: dev.ps1 の Invoke-Benchmark と同じ呼び方で試して確認した）。
    [Parameter(Mandatory = $true)][string[]]$XmlPath,
    [Parameter(Mandatory = $true)][string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# 呼ぶ側の作法に依存しない形にする（';' 区切りの 1 文字列でも、配列でも）。
$XmlPath = @($XmlPath | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($XmlPath.Count -eq 0) {
    Write-Error '-XmlPath に値がありません。'
    exit 1
}

# **存在しない XML は黙って飛ばさず落とす。** 「片方しか無かったので
# 半分だけ書いた」を成功にしない —— どのレーンが飛んだのかを名指しする。
foreach ($path in $XmlPath) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "結果 XML が無い: $path"
        exit 1
    }
}

$lines = @()
foreach ($path in $XmlPath) {
    [xml]$xml = Get-Content -LiteralPath $path -Raw
    $texts = @($xml.SelectNodes('//output') | ForEach-Object { $_.InnerText })
    $fileLines = @($texts -split "`n" | Where-Object { $_ -match 'OCVU_BENCH:' })

    # **下限は XML ごとに見る。** 2 つの XML を連結してから 0 件かどうかを
    # 見ていた版は、片方の benchmark 本体が丸ごと消えても（メソッド名を
    # 変える／[Category("Graphics")] を外して該当レーンから消す、いずれも
    # 実測）もう片方の行が残るので `$lines.Count -eq 0` に一度も当たらず、
    # 静かに通っていた。**空だったファイルを名指しで落とす。**
    if ($fileLines.Count -eq 0) {
        Write-Error "OCVU_BENCH の行が 1 本も無い: $path。このレーンの benchmark 本体が走っていないか、名前が変わった"
        exit 1
    }

    $lines += $fileLines
}

# **0 件を「速かった」と読まない。** 1 本も拾えなかったなら、
# Player/Graphics が走らなかったか、名前が変わったかである。
# （上のファイル単位の検査が先に落とすはずだが、$XmlPath が空配列の
# 呼び出しを構造的に塞ぐため、ここにも残す。）
if ($lines.Count -eq 0) {
    Write-Error 'OCVU_BENCH の行が 1 本も無い。Player/Graphics が走っていないか、名前が変わった'
    exit 1
}

$results = [ordered]@{}
foreach ($line in $lines) {
    if ($line -match 'OCVU_BENCH:\s*([a-z0-9_]+)=(\d+)') {
        $results[$Matches[1]] = [long]$Matches[2]
    }
}

# **1 行も解釈できなかったことを「成功」にしない。**
#
# 上の 2 つの門は `OCVU_BENCH:` を含む**行**を数えているだけで、
# その行から key=value を**取り出せたか**は見ていない。key の書き方が
# 少しずれるだけで（`[a-z0-9_]+` は camelCase を通さない）、
# 行は在るのに $results が空のまま `results: {}` を書いて exit 0 する ——
# **測っていないものを、測ったふりをして publish する形である。**
#
# 0 マイクロ秒の検査も同じ理由で空振りする（entry が 1 つも無ければ
# $zeroKeys も空になる）。**空を「違反なし」と読まない。**
if ($results.Count -eq 0) {
    Write-Error ("OCVU_BENCH: の行は $($lines.Count) 本あるのに、key=value を 1 つも取り出せなかった。" +
                 "key の書き方が 'OCVU_BENCH: <key>=<整数>'（key は英小文字・数字・_）から外れている")
    exit 1
}

# **0 マイクロ秒を publish しない。** 0 は「速かった」ではなく
# 「測定が効いていない」と区別がつかない。`BenchmarkRunner.Report`
# （test-unity-player レーンの繰り返し計測）は既にこれを自分で assert
# しているが、`MeasureFirstPInvoke`（温めない単発測定）はそれを通らない
# ので値が 0 になる余地が現実にある（実測で 1 µs を公開しており、桁として
# 0 に近い）。**判定は controller（このスクリプト）の裁定に置く** ——
# テスト側に Assert.Greater を足すと、必須チェック Unity Standalone (Linux)
# にフレークを持ち込む（単発測定は温まっていないので 0 と出る回があり得る）。
# ここで一括して名指しし、0 の entry があれば exit 1 にする。
$zeroKeys = @($results.Keys | Where-Object { $results[$_] -eq 0 })
if ($zeroKeys.Count -gt 0) {
    Write-Error "0 マイクロ秒の entry がある（測定が効いていない）: $($zeroKeys -join ', ')"
    exit 1
}

# **測った環境を必ず併記する**（設計 §6）。数字だけ残すと、
# 測っていない環境についても言ったことになる。
$payload = [ordered]@{
    measuredAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    os         = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    arch       = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    unit       = 'microseconds per call'
    note       = 'CI ランナーまたは開発機での実測。利用者の端末の数字ではない'
    results    = $results
}

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutPath -Encoding utf8

Write-Host "==> benchmark: $($results.Count) 件を $OutPath へ書いた"
foreach ($k in $results.Keys) { Write-Host "    $k = $($results[$k]) us" }
