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
    $lines += @($texts -split "`n" | Where-Object { $_ -match 'OCVU_BENCH:' })
}

# **0 件を「速かった」と読まない。** 1 本も拾えなかったなら、
# Player/Graphics が走らなかったか、名前が変わったかである。
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
