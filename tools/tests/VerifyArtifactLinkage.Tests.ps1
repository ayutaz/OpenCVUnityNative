#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    成果物の linkage 検証そのものを検証する。

    この検査は「読めなかったら通す」形になっていないことが最も重要なので、
    正常系より異常系を厚く見る。
#>

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verify = Join-Path $repoRoot 'tools/verify-artifact-linkage.ps1'
$failures = @()

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

# --- 実物に対して通ること ---
$config = Get-OpenCvConfig
$root = Get-OpenCvRoot -Config $config
if (Test-Path -LiteralPath $root) {
    & pwsh -NoProfile -File $verify -Root $root | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'the restored artifact matches the configured linkage'
}
else {
    Write-Host "  SKIP  no restored artifact at $root" -ForegroundColor Yellow
}

# --- 存在しないツリーは失敗にする（黙って通さない） ---
$missing = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-missing-" + [guid]::NewGuid().ToString('n'))
& pwsh -NoProfile -File $verify -Root $missing 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a missing artifact tree fails rather than passing vacuously'

# --- ライブラリが 1 つも無いツリーは失敗にする ---
#
# ここが「読めなかったら通す」の典型的な入り口である。走査して 0 件だったとき、
# 「違反が無かった」と読むと、検査が何も見ていない状態が緑になる。
$empty = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-empty-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path (Join-Path $empty 'x64/vc17/staticlib') | Out-Null
& pwsh -NoProfile -File $verify -Root $empty 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a tree with no libraries fails rather than reporting no violations'
Remove-Item -Recurse -Force $empty -ErrorAction SilentlyContinue

# --- 未対応 platform を指定したら失敗にする ---
& pwsh -NoProfile -File $verify -Root $root -Platform 'solaris-sparc' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an unsupported platform fails rather than skipping the check'

# --- 未対応 platform は失敗する（default が残っていること） ---
#
# Task 5 で macOS / Linux を足した後も、4 つ目の platform は黙って通らないこと。
# 「実装済みの platform だけ検査し、それ以外は成功」は M1 が繰り返した欠陥である。
#
# 注意: 'freebsd-x64' も 'solaris-sparc' と同じく opencv-config.psd1 の Toolchains に
# 無いため、実際には switch の default ではなく Get-OpenCvConfig の「未知の platform」
# 例外で先に exit 1 になる（Task 3 の報告が 'solaris-sparc' について記録した懸念と同じ
# 経路）。switch の default 自体（Toolchains には登録済みだが読み取りロジックが無い
# platform）は、この Windows 専用マシンでは合成できない — psd1 に 4 つ目の platform を
# 加えることは Task 5 の範囲外である。両者とも exit 1 になるという振る舞いの契約は
# このテストで正しく固定できているが、通過している経路が switch の default そのもの
# ではない点は Task 3 の懸念事項と同じ性質として申し送る。
& pwsh -NoProfile -File $verify -Root $root -Platform 'freebsd-x64' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a platform with no implementation still fails after adding two more'

# --- Linux / macOS: ライブラリが 1 つも無いツリーは失敗にする ---
#
# BUILD_SHARED_LIBS=OFF は platform 共通の CMakeArgs なので、Linux / macOS でも
# OpenCV module は .a（静的アーカイブ）としてビルドされる。Windows の同種の
# assertion（40 行目）と同じ形で、0 件を「違反なし」と読まないことを確かめる。
foreach ($p in @('linux-x64', 'macos-arm64')) {
    $emptyPlat = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-empty-$p-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path (Join-Path $emptyPlat 'lib') | Out-Null
    & pwsh -NoProfile -File $verify -Root $emptyPlat -Platform $p 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) "a $p tree with no libopencv_*.a fails rather than reporting no violations"
    Remove-Item -Recurse -Force $emptyPlat -ErrorAction SilentlyContinue
}

# --- Linux / macOS: 検査対象は見つかるが読み取れない場合も失敗にする ---
#
# 読み取りツール（ar / nm / readelf / lipo）はこの Windows マシンに 1 つも
# 存在しない。これを逆手に取り、「ライブラリは見つかるが読み取りツールが
# 実行できない」経路が黙って通らないことを実際に確かめる。
#
# **どのツールで落ちるかは検査の順序で決まる。** 現在は有効言語の検査
# （ar t）が先に走るので、実際に踏んでいるのは ar の不在である。順序を
# 変えれば nm になる。ここで見たいのは「どれで落ちたか」ではなく
# 「読めなかったときに通らないこと」なので、どちらでも成立する。
#
# PowerShell は $ErrorActionPreference = 'Stop' の下でネイティブコマンド
# 未検出を終了エラーとして投げ、verify-artifact-linkage.ps1 はこれを
# 捕まえないので、未捕捉例外がスクリプトを止めて非 0 で終わる。
# メッセージは Write-VerifyFailure の整形されたものではなく生の例外だが、
# **通らないことが目的なので合格判定は変わらない**。
foreach ($p in @('linux-x64', 'macos-arm64')) {
    $withLib = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-lib-$p-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path (Join-Path $withLib 'lib') | Out-Null
    Set-Content -LiteralPath (Join-Path $withLib 'lib/libopencv_core.a') -Value 'not a real archive' -NoNewline
    & pwsh -NoProfile -File $verify -Root $withLib -Platform $p 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) "a $p tree whose inspection tool cannot run fails rather than passing vacuously"
    Remove-Item -Recurse -Force $withLib -ErrorAction SilentlyContinue
}


# --- Linux / macOS: アセンブルされた object が入っていたら失敗にする ---
#
# roadmap の条件 5 が求める「有効言語」の検査。archive のメンバ名に
# `*.S.o` が現れたら、-DCMAKE_ASM_COMPILER=NOTFOUND が守られていない。
#
# **この負の経路は ar がある環境でしか踏めない。** Windows のこのマシンには
# 無いので、実際に確かめるのは CI の macOS / Linux job（test-tools-slow）で
# ある。ここで SKIP と出たら「確かめていない」であって「合格」ではない。
$hasAr = $null -ne (Get-Command ar -ErrorAction SilentlyContinue)
if ($hasAr) {
    foreach ($p in @('linux-x64', 'macos-arm64')) {
        $asmRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-asm-$p-" + [guid]::NewGuid().ToString('n'))
        $libDir = Join-Path $asmRoot 'lib'
        New-Item -ItemType Directory -Force -Path $libDir | Out-Null

        # ar はメンバの中身を検証しないので、名前だけ本物に似せた object を
        # 詰めた archive を作れる。狙っているのは「メンバ名を読む」経路である。
        Push-Location $libDir
        try {
            Set-Content -LiteralPath 'jsimd_arm.S.o' -Value 'placeholder' -NoNewline
            & ar rcs 'libopencv_core.a' 'jsimd_arm.S.o' 2>&1 | Out-Null
            Remove-Item -LiteralPath 'jsimd_arm.S.o' -Force
        }
        finally { Pop-Location }

        $out = & pwsh -NoProfile -File $verify -Root $asmRoot -Platform $p 2>&1
        Assert-That ($LASTEXITCODE -ne 0) `
            "a $p archive containing an assembled object fails"
        Assert-That (($out -join "`n") -match 'assembler was enabled') `
            "a $p archive containing an assembled object fails for the right reason"
        Remove-Item -Recurse -Force $asmRoot -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host '  SKIP  ar is not available; the assembled-object path was NOT verified here' -ForegroundColor Yellow
}
if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
