#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test-native', 'test-asan', 'test-managed', 'test-tools', 'test', 'clean')]
    [string]$Command = 'test'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# CI のログは UTF-8。指定しないと Windows の PowerShell は既定の ANSI
# コードページ（日本語環境なら cp932、CI の en-US runner なら cp1252）で
# 書き出し、失敗メッセージが文字化けするか、cp1252 環境では日本語部分が
# 可逆でない形で失われる。tools/opencv.ps1・tools/verify-opencv-artifact.ps1
# と同じ対応。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$Preset        = 'windows-x64-debug'
$AsanPreset    = 'windows-x64-asan'
$NativeOutDir  = Join-Path $RepoRoot "build/$Preset/native/Debug"
$ResultsDir    = Join-Path $RepoRoot 'artifacts/test-results'

function Invoke-Checked([scriptblock]$Action, [string]$What) {
    Write-Host "==> $What" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

function Write-DevFailure([string]$Message) {
    # throw ではなく素の stderr 書き込み + exit にする。PowerShell 7 の
    # 既定の ConciseView は未捕捉の throw を "Exception:" 見出しと
    # "Line |" ブロック・ソース位置の "~~~" つきで描画し、複数行メッセージの
    # 改行も潰される（実測: restore し忘れて `dev.ps1 test` を叩いたときの
    # CI ログで、次に打つべきコマンドを示す 2 行がまさにこの形で潰れて
    # 読みにくくなっていた）。restore を忘れるのはここで最も踏みやすい
    # 失敗経路であり、開発者が最初に読む可能性が高いメッセージでもある。
    # tools/opencv.ps1 の Write-RestoreFailure、tools/verify-opencv-artifact.ps1
    # の失敗描画と同じ形に揃える。
    [Console]::Error.WriteLine($Message)
    exit 1
}

# 結果ディレクトリを空にしてから作り直す。
# New-Item -Force は既存の中身を消さないので、L1 が落ちて L3 が走らなかった
# ときに前回の緑の managed.xml がそのまま残り、最新の結果に見えてしまう。
function Reset-Results {
    if (Test-Path $ResultsDir) {
        Remove-Item -Recurse -Force $ResultsDir
    }
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
}

# tools/*.ps1（OpenCV の構成・ハッシュ・allowlist 検証）の素の assert
# テスト。native のビルドも OpenCV artifact の実体も要らないので、
# 一番安く・一番先に落とせる。OpenCV artifact を実際に download する
# OpenCvRestore.Tests.ps1 はここに含めない — 秒単位のローカルループを
# 守るため、あちらは CI 側の担当（レビュー H2）。
$ToolsTestScripts = @(
    'OpenCvConfig.Tests.ps1'
    'ConfigInvalidation.Tests.ps1'
    'VerifyOpenCvArtifact.Tests.ps1'
)

function Test-Tools {
    foreach ($script in $ToolsTestScripts) {
        $path = Join-Path $PSScriptRoot "tests/$script"
        Invoke-Checked {
            & pwsh -NoProfile -File $path
        } "run $script (tools)"
    }
}

function Build-Native {
    Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force
    $opencvRoot = Get-OpenCvRoot -Config (Get-OpenCvConfig)
    if (-not (Test-Path -LiteralPath (Join-Path $opencvRoot 'build-manifest.json'))) {
        Write-DevFailure (@(
            "OpenCV が '$opencvRoot' にありません。"
            "先に './tools/opencv.ps1 restore' を実行してください。"
        ) -join "`n")
    }

    Invoke-Checked {
        cmake --preset $Preset "-DOCVU_OPENCV_ROOT=$opencvRoot"
    } 'configure native'
    Invoke-Checked { cmake --build --preset $Preset } 'build native'
}

function Test-Native {
    Build-Native
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    Invoke-Checked {
        ctest --preset $Preset --output-junit (Join-Path $ResultsDir 'native.xml')
    } 'run native tests (L1)'
}

function Test-Asan {
    Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force
    $opencvRoot = Get-OpenCvRoot -Config (Get-OpenCvConfig)
    if (-not (Test-Path -LiteralPath (Join-Path $opencvRoot 'build-manifest.json'))) {
        Write-DevFailure (@(
            "OpenCV が '$opencvRoot' にありません。"
            "先に './tools/opencv.ps1 restore' を実行してください。"
        ) -join "`n")
    }

    Invoke-Checked {
        cmake --preset $AsanPreset "-DOCVU_OPENCV_ROOT=$opencvRoot"
    } 'configure native (asan)'
    Invoke-Checked { cmake --build --preset $AsanPreset } 'build native (asan)'
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    Invoke-Checked {
        ctest --preset $AsanPreset --output-junit (Join-Path $ResultsDir 'native-asan.xml')
    } 'run native tests under ASan (L2)'
}

function Test-Managed {
    Build-Native
    if (-not (Test-Path (Join-Path $NativeOutDir 'opencv_unity_native.dll'))) {
        throw "Native library was not found in '$NativeOutDir' after building."
    }
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

    $env:OCVU_NATIVE_DIR = $NativeOutDir
    Invoke-Checked {
        # --blame-hang: L3 に時間の上限を与える。M2 以降ここは Mat の
        # lifecycle をネイティブ越しに回すので、ネイティブ側のデッドロックや
        # 無限ループがそのままローカルループを無限に固める。60 秒で打ち切り、
        # ハングしたテストの dump を残す。
        dotnet test (Join-Path $RepoRoot 'tests/Managed/CvUnity.Managed.sln') `
            --blame-hang --blame-hang-timeout 60s `
            --logger "junit;LogFilePath=$(Join-Path $ResultsDir 'managed.xml')" `
            --logger 'console;verbosity=normal'
    } 'run managed tests (L3)'
}

# 'test' は fail-fast である。Invoke-Checked が最初の失敗で throw するため、
# L1 が落ちた時点で L3 は実行されず、managed.xml は生成されない。
# 「L1 赤 = L3 の結果なし」が正しい状態であり、前回の結果が残って最新に
# 見えないよう、結果を書くコマンドは開始時に Reset-Results で空にする。
switch ($Command) {
    'build'        { Build-Native }
    'test-native'  { Reset-Results; Test-Native }
    'test-asan'    { Reset-Results; Test-Asan }
    'test-managed' { Reset-Results; Test-Managed }
    'test-tools'   { Test-Tools }
    'test'         { Reset-Results; Test-Tools; Test-Native; Test-Managed }
    'clean'        { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
}

Write-Host "OK: $Command" -ForegroundColor Green
