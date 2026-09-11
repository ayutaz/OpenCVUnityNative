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
    Write-Error "0 の entry がある（測定が効いていない）: $($zeroKeys -join ', ')"
    exit 1
}

<#
    **単位は key の末尾で決まる。** `_ns` で終わる key はナノ秒、それ以外は
    マイクロ秒である。

    **これは 2026-09-11 のレビュー指摘（I-5 / I-2）で足した。** それまで
    payload は `unit = 'microseconds per call'` を**全 entry 共通**で持って
    おり、`first_pinvoke_ns`（ナノ秒）が入った時点で **publish する成果物が
    嘘をついていた。** しかも key 名に単位を書いた側の意図（「名前で区別
    できないと桁を取り違える」）は、**より強い信号である `unit` フィールドに
    打ち消されていた** —— 取り違えは解消せず、場所が移っただけである。

    **どの key がどちらかを列挙しない。** 列挙すると、次に `_ns` の項目を
    足した人がここを直し忘れる。**規約（接尾辞）で決める。**
#>
function Get-BenchmarkUnit {
    param([Parameter(Mandatory)][string] $Key)
    if ($Key -match '_ns$') { 'nanoseconds per call' } else { 'microseconds per call' }
}
function Get-BenchmarkUnitSuffix {
    param([Parameter(Mandatory)][string] $Key)
    if ($Key -match '_ns$') { 'ns' } else { 'us' }
}

<#
    **扱える接尾辞は `_ns` だけである。それ以外の時間単位は、黙って
    マイクロ秒として publish せずに落とす。**

    規約を守っているのは publish する側だけで、`OCVU_BENCH:` を出す C# 側
    （`BenchmarkRunner` / `GraphicsBenchmarkRunner`）には何の強制も無い ——
    将来 `*_ms` を足すと、**1000 倍ずれた数字が「マイクロ秒」として世に出る。**

    **ここは意図的に列挙である。** 「知らない接尾辞を全部拒む」形にすると
    `texture2d_to_mat`（`_mat`）のような正当な key まで落ちる。拒むのは
    **時間単位に見えるのに扱えないもの**だけで、既定（マイクロ秒）は
    `docs/performance.md` に書いてある。
#>
$unhandledUnitSuffixes = @('_ms', '_us', '_s', '_sec', '_msec', '_usec', '_nsec', '_micros', '_millis', '_nanos')
$badUnitKeys = @($results.Keys | Where-Object {
    $k = $_
    @($unhandledUnitSuffixes | Where-Object { $k.EndsWith($_) }).Count -gt 0
})
if ($badUnitKeys.Count -gt 0) {
    Write-Error ("扱えない単位の接尾辞を持つ key がある（マイクロ秒として publish しない）: " +
                 "$($badUnitKeys -join ', ')。扱えるのは '_ns' だけで、" +
                 "接尾辞が無ければマイクロ秒として扱う")
    exit 1
}

# **単位つきの表に組み替える。** 値だけの map を残さないのは、
# 読む側が単位を知らずに値を取れる形を publish しないためである。
$entries = [ordered]@{}
foreach ($k in $results.Keys) {
    $entries[$k] = [ordered]@{
        value = $results[$k]
        unit  = Get-BenchmarkUnit -Key $k
    }
}

# **測った環境を必ず併記する**（設計 §6）。数字だけ残すと、
# 測っていない環境についても言ったことになる。
$payload = [ordered]@{
    measuredAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    os         = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    arch       = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    # **全 entry 共通の `unit` は持たない。** 単位は entry ごとに在る
    # （上の Get-BenchmarkUnit）。共通の 1 つを置くと、単位の違う項目が
    # 1 つ入った瞬間に payload 全体が嘘になる。
    unitNote   = 'unit は entry ごとに持つ。key が _ns で終わればナノ秒、それ以外はマイクロ秒'
    note       = 'CI ランナーまたは開発機での実測。利用者の端末の数字ではない'
    results    = $entries
}

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutPath -Encoding utf8

Write-Host "==> benchmark: $($results.Count) 件を $OutPath へ書いた"
foreach ($k in $results.Keys) {
    Write-Host "    $k = $($results[$k]) $(Get-BenchmarkUnitSuffix -Key $k)"
}
