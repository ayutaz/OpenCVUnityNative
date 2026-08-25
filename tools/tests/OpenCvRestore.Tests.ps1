#Requires -Version 7.0
# Pester を使わず素の assert で書く。依存を増やさないため。
#
# ここでのテストは実際に GitHub Actions artifact を download する
# （synthetic なツリーだけでは「本当に取り直せたか」を検証できないため）。
# 実行には gh の認証と、CI が作った現行構成の artifact が必要で、
# 自己修復を確認するケースはそれぞれ実測で 20〜30 秒ほどかかる。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$opencvScript = Join-Path $repoRoot 'tools/opencv.ps1'
$configPath   = Join-Path $repoRoot 'tools/opencv-config.psd1'

Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force
$config       = Get-OpenCvConfig
$configHash   = Get-OpenCvConfigHash -Config $config
$openCvRoot   = Get-OpenCvRoot -Config $config
$manifestPath = Join-Path $openCvRoot 'build-manifest.json'

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# stdout / stderr を別ファイルに分けて捕まえる。PowerShell の既定の
# ConciseView は未捕捉の throw を "Exception:" 見出しと "Line |" ブロック、
# ソース位置を指す "~~~" つきで描画する。これは書き込み先を見ないと
# 判定できない（両方混ぜて文字列として見ると、意図した多段落メッセージと
# 見分けがつかない）。
function Invoke-RestoreProcess {
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) "ocvu-restore-out-$(Get-Random).txt"
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "ocvu-restore-err-$(Get-Random).txt"
    try {
        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-File', $opencvScript, 'restore') `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
            StdErr   = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "test precondition failed: '$openCvRoot' must already hold a valid restored tree (run './tools/opencv.ps1 restore' once before running this suite)."
}

# ============================================================
# ケース A: マニフェストが壊れている（パースできない JSON）。
# 「存在する」というだけで信用してはならない — 中身を見て初めて
# 「present」と言ってよい。
# ============================================================
Write-Host '== case A: corrupt manifest must not short-circuit ==' -ForegroundColor Cyan
Set-Content -LiteralPath $manifestPath -Value 'not valid json {{{'
$resultA = Invoke-RestoreProcess
Assert-That ($resultA.ExitCode -eq 0) 'case A: restore succeeds after self-healing a corrupt manifest'
$manifestOkA = $false
try {
    $manifestA = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifestOkA = ($manifestA.configHash -eq $configHash)
}
catch { $manifestOkA = $false }
Assert-That $manifestOkA 're-downloaded manifest (case A) parses and has the correct configHash'

# ============================================================
# ケース B: マニフェストの configHash は正しいが、実体のファイルが
# 足りない（download が途中で中断された木を模す）。
# 「マニフェストが正しい」だけでは足りず、allowlist 検証
# （Invoke-Verify）まで通らなければ present と言ってはならない。
# ============================================================
Write-Host '== case B: an interrupted-looking partial tree must be re-downloaded ==' -ForegroundColor Cyan
Remove-Item -Recurse -Force (Join-Path $openCvRoot 'x64') -ErrorAction SilentlyContinue
$resultB = Invoke-RestoreProcess
Assert-That ($resultB.ExitCode -eq 0) 'case B: restore succeeds after self-healing a tree with missing files'
Assert-That (Test-Path -LiteralPath (Join-Path $openCvRoot 'x64/vc17/staticlib')) 'case B: the re-downloaded tree has its files back'

# ============================================================
# ケース C: 存在しない artifact を要求させ、失敗の見え方を見る。
# 「gh workflow run build-opencv.yml」のような具体的な指示が
# 埋め込まれていても、PowerShell の既定の例外バナー
# （"Line |" ブロック、ソース位置の "~~~"）の下に埋もれると
# クラッシュにしか見えない。バナー無しで描画されることを確認する。
# ============================================================
Write-Host '== case C: the "artifact not found" failure must not render as a crash ==' -ForegroundColor Cyan
$backupC = Get-Content -LiteralPath $configPath -Raw
try {
    (Get-Content -LiteralPath $configPath) -replace "'-DWITH_TIFF=OFF'", "'-DWITH_TIFF=OFF'`n        '-DOCVU_PROBE_C=1'" |
        Set-Content -LiteralPath $configPath
    $resultC = Invoke-RestoreProcess
    Assert-That ($resultC.ExitCode -eq 1) 'case C: restore exits 1 when the artifact does not exist'
    Assert-That ($resultC.StdErr -notmatch 'Line \|') 'case C: the failure message has no "Line |" banner'
    Assert-That ($resultC.StdErr -notmatch '~~~') 'case C: the failure message has no source-position tildes'
    Assert-That ($resultC.StdErr -match 'gh workflow run build-opencv\.yml') 'case C: the failure message names the concrete remedy'
}
finally {
    Set-Content -LiteralPath $configPath -Value $backupC -NoNewline
    Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force
    $configC = Get-OpenCvConfig
    $rootC = Get-OpenCvRoot -Config $configC
    if ($rootC -ne $openCvRoot) { Remove-Item -Recurse -Force $rootC -ErrorAction SilentlyContinue }
}

# ============================================================
# ケース D: gh が PATH に無い場合も同じ描画になること（見つからない
# artifact のケースとは別の分岐だが、同じ描画規律を課す）。
# ============================================================
Write-Host '== case D: the "gh missing" failure must not render as a crash either ==' -ForegroundColor Cyan
$ghPath = (Get-Command gh -ErrorAction SilentlyContinue).Source
$ghDir = if ($ghPath) { Split-Path -Parent $ghPath } else { $null }
if (-not $ghDir) {
    Write-Host '  SKIP  case D: gh is not resolvable on this machine, cannot test its absence meaningfully' -ForegroundColor Yellow
}
else {
    $originalPath = $env:PATH
    $backupD = Get-Content -LiteralPath $configPath -Raw
    try {
        (Get-Content -LiteralPath $configPath) -replace "'-DWITH_TIFF=OFF'", "'-DWITH_TIFF=OFF'`n        '-DOCVU_PROBE_D=1'" |
            Set-Content -LiteralPath $configPath
        $env:PATH = ($originalPath -split ';' | Where-Object { $_ -ne $ghDir }) -join ';'
        $resultD = Invoke-RestoreProcess
        Assert-That ($resultD.ExitCode -eq 1) 'case D: restore exits 1 when gh is not on PATH'
        Assert-That ($resultD.StdErr -notmatch 'Line \|') 'case D: the gh-missing message has no "Line |" banner'
        Assert-That ($resultD.StdErr -match 'gh auth login') 'case D: the gh-missing message names the remedy'
    }
    finally {
        $env:PATH = $originalPath
        Set-Content -LiteralPath $configPath -Value $backupD -NoNewline
        Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force
        $configD = Get-OpenCvConfig
        $rootD = Get-OpenCvRoot -Config $configD
        if ($rootD -ne $openCvRoot) { Remove-Item -Recurse -Force $rootD -ErrorAction SilentlyContinue }
    }
}

# 元の構成に完全に戻っていることを確認する（次のテストや人間の作業に
# 影響を残さない）。
$finalHash = Get-OpenCvConfigHash -Config (Get-OpenCvConfig)
Assert-That ($finalHash -eq $configHash) 'opencv-config.psd1 is restored to its original content (hash matches)'

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
