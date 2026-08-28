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

# 1 バイトでも不正な UTF-8 シーケンスがあれば例外を投げる strict decoder。
# Get-Content -Raw の既定エンコーディング推定に頼ると、ASCII だけの
# 行（"gh workflow run build-opencv.yml" 等）はどんな codepage で読んでも
# 同じ文字列になってしまい、日本語部分だけが cp932/cp1252 で文字化けする
# 種類のバグを取りこぼす。生バイトを直接 strict decode して確認する。
$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
function Test-StrictUtf8Bytes([string]$Path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $StrictUtf8.GetString($bytes) | Out-Null
        return $true
    }
    catch {
        return $false
    }
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
            ExitCode        = $proc.ExitCode
            StdOut          = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
            StdErr          = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
            StdErrIsStrictUtf8 = (Test-StrictUtf8Bytes $stderrFile)
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
# ケース A2: レビュー第 3 ラウンドで見つかった 4 つの危険な形。
# ConvertFrom-Json 自体は例外を投げず（zero-byte / whitespace-only /
# `[]` は $null を、`42` は Int64 を返して）成功するため、
# パース部分だけを try/catch していた版ではここを素通りし、
# 直後の `.PSObject.Properties.Name` アクセスが StrictMode 下で
# 例外を投げて Invoke-Restore の try/finally の外側で restore 全体を
# 落とし、後始末も走らず壊れた manifest がそのまま残った。
# ============================================================
$dangerousShapes = [ordered]@{
    'zero-byte file'      = ''
    'empty JSON array []' = '[]'
    'bare number 42'      = '42'
    'whitespace only'     = '   '
}
foreach ($shapeName in $dangerousShapes.Keys) {
    Write-Host "== case A2 ($shapeName): must self-heal, not crash ==" -ForegroundColor Cyan
    # Set-Content ではなく File API を使う: -NoNewline を付けても
    # Set-Content は空文字列に対して厳密に 0 バイトのファイルを作らない
    # ことがあり、再現したい形（本当に空／本当に空白のみ）と
    # ずれてしまう。
    [System.IO.File]::WriteAllText($manifestPath, $dangerousShapes[$shapeName])
    $resultShape = Invoke-RestoreProcess
    Assert-That ($resultShape.ExitCode -eq 0) "case A2 ($shapeName): restore exits 0 (self-heals rather than crashing)"
    $manifestOkShape = $false
    try {
        $manifestShape = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifestOkShape = ($manifestShape.configHash -eq $configHash)
    }
    catch { $manifestOkShape = $false }
    Assert-That $manifestOkShape "case A2 ($shapeName): re-downloaded manifest parses and has the correct configHash"
}

# ============================================================
# ケース B: マニフェストの configHash は正しいが、実体のファイルが
# 足りない（download が途中で中断された木を模す）。
# 「マニフェストが正しい」だけでは足りず、allowlist 検証
# （Invoke-Verify）まで通らなければ present と言ってはならない。
# ============================================================
Write-Host '== case B: an interrupted-looking partial tree must be re-downloaded ==' -ForegroundColor Cyan
# ライブラリの置き場は platform で違う（Windows は x64/vc17/staticlib、
# Unix 系は lib）。決め打ちにすると、消す対象が存在せず「壊れた木」を作れない
# まま restore が「既に正常」と判断して何もせず、その後の存在確認だけが落ちる
# —— つまり**自己修復を一度も検証しないまま赤くなる**（実測: macOS / Linux の CI）。
$libDirRelative = if ($IsWindows) { 'x64/vc17/staticlib' } else { 'lib' }
$libDirRoot = ($libDirRelative -split '/')[0]

Remove-Item -Recurse -Force (Join-Path $openCvRoot $libDirRoot) -ErrorAction SilentlyContinue
Assert-That (-not (Test-Path -LiteralPath (Join-Path $openCvRoot $libDirRelative))) `
    'case B: the library directory was actually removed before restore ran'

$resultB = Invoke-RestoreProcess
Assert-That ($resultB.ExitCode -eq 0) 'case B: restore succeeds after self-healing a tree with missing files'
Assert-That (Test-Path -LiteralPath (Join-Path $openCvRoot $libDirRelative)) 'case B: the re-downloaded tree has its files back'

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
    Assert-That $resultC.StdErrIsStrictUtf8 'case C: stderr bytes are valid UTF-8 (not the console codepage)'
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
# gh を PATH から外す方法を 2 度間違えたので、その経緯を残す。
#
#   1 回目: Get-Command gh（-All 無し）で 1 件だけ取り、そのディレクトリを
#           PATH から引いた。開発機では gh が 1 箇所なので通る。runner では
#           複数箇所にあり gh が残ったまま restore が走って、「artifact が
#           無い」という別の分岐が検査されていた。exit 1 も "Line |" 無しも
#           満たすので、remedy の assertion だけが落ちた。
#   2 回目: -All で全部集めて -notin で引いた。これも runner で落ちた。
#           PATH の要素と Split-Path の戻り値は、末尾の \ の有無・大文字小文字・
#           相対表記などで文字列としては一致しないことがある。
#
# どちらも「著者の環境ではこう見える」形に依存していた。文字列比較をやめて、
# 各ディレクトリに gh の実体があるかどうかで決める。PATH の書式に依存しない。
# PATH の区切り文字は platform で違う（Windows は ';'、Unix 系は ':'）。
# 決め打ちにすると Unix で PATH 全体が 1 要素になり、gh を含むディレクトリを
# 除去できない — 実測: macOS / Linux の CI で「gh がまだ 1〜2 個見える」と
# 前提チェックが落ちた。.NET が platform ごとの正しい文字を持っているので
# それを使う（自分で分岐を書くと 3 つ目の platform で同じことが起きる）。
$PathSeparator = [System.IO.Path]::PathSeparator

function Test-DirectoryHasGh([string]$dir) {
    if (-not $dir) { return $false }
    foreach ($name in @('gh.exe', 'gh.cmd', 'gh.bat', 'gh')) {
        if (Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf) { return $true }
    }
    return $false
}

$ghDirs = @(($env:PATH -split $PathSeparator) | Where-Object { Test-DirectoryHasGh $_ })
if ($ghDirs.Count -eq 0 -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host '  SKIP  case D: gh is not resolvable on this machine, cannot test its absence meaningfully' -ForegroundColor Yellow
}
else {
    $originalPath = $env:PATH
    $backupD = Get-Content -LiteralPath $configPath -Raw
    try {
        (Get-Content -LiteralPath $configPath) -replace "'-DWITH_TIFF=OFF'", "'-DWITH_TIFF=OFF'`n        '-DOCVU_PROBE_D=1'" |
            Set-Content -LiteralPath $configPath
        $env:PATH = ($originalPath -split $PathSeparator | Where-Object { $_ -and -not (Test-DirectoryHasGh $_) }) -join $PathSeparator

        # 前提が成立したことを確かめてから本題に入る。ここが崩れたまま先に進むと、
        # 別の失敗経路を「gh が無い場合」として検査してしまう。
        #
        # 確認は子プロセスで行う。restore を走らせるのは Start-Process が起こす
        # 別の pwsh であり、この検査が意味を持つのはその子から見て gh が引けない
        # ことである。親プロセスの Get-Command はコマンド解決をキャッシュし得るので、
        # 親で見えないことは子で見えないことを保証しない。
        $ghProbe = & pwsh -NoProfile -Command '@(Get-Command gh -All -ErrorAction SilentlyContinue).Count'
        Assert-That ("$ghProbe".Trim() -eq '0') "case D: gh is actually unreachable from the child process (saw '$ghProbe')"

        $resultD = Invoke-RestoreProcess
        Assert-That ($resultD.ExitCode -eq 1) 'case D: restore exits 1 when gh is not on PATH'
        Assert-That ($resultD.StdErr -notmatch 'Line \|') 'case D: the gh-missing message has no "Line |" banner'
        Assert-That ($resultD.StdErr -match 'gh auth login') 'case D: the gh-missing message names the remedy'
        Assert-That $resultD.StdErrIsStrictUtf8 'case D: stderr bytes are valid UTF-8 (not the console codepage)'
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
