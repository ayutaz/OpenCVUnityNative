#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    L3 のクラッシュ・ハング耐性を実証する。

    通常のテストと逆で、**成功したら失敗**である。ネイティブが落ちた／固まったときに
    dotnet test が有限時間で非ゼロ終了することを確かめるのが目的なので、
    非ゼロ終了こそが期待する結果になる。

    cmake/run_expect_failure.cmake が L1 / L2 でやっていることの L3 版である。
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'tests/Managed/CvUnity.Tests.Managed/CvUnity.Tests.Managed.csproj'
$failures = @()

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

function Invoke-Probe([string]$testName, [int]$timeoutSeconds) {
    $start = Get-Date
    # --blame-hang がハングを有限時間で殺す。この上限が効いていることが検査対象。
    & dotnet test $project `
        --filter "FullyQualifiedName~$testName" `
        --blame-hang --blame-hang-timeout "${timeoutSeconds}s" `
        --nologo 2>&1 | Out-Null
    $exit = $LASTEXITCODE
    $elapsed = (Get-Date) - $start
    return [pscustomobject]@{ ExitCode = $exit; Seconds = $elapsed.TotalSeconds }
}

Write-Host '== L3 probe: native segfault must turn the run red ==' -ForegroundColor Cyan
$seg = Invoke-Probe 'Probe_NativeSegfault' 60
Assert-That ($seg.ExitCode -ne 0) 'a native segfault makes dotnet test exit non-zero'
Assert-That ($seg.Seconds -lt 120) "the segfault run finished in bounded time ($([int]$seg.Seconds)s)"

Write-Host '== L3 probe: native hang must be killed and turn the run red ==' -ForegroundColor Cyan
$hang = Invoke-Probe 'Probe_NativeHang' 30
Assert-That ($hang.ExitCode -ne 0) 'a native hang makes dotnet test exit non-zero'
Assert-That ($hang.Seconds -lt 180) "the hang was killed rather than running forever ($([int]$hang.Seconds)s)"

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
