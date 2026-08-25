#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test-native', 'test-asan', 'test-managed', 'test', 'clean')]
    [string]$Command = 'test'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

# 結果ディレクトリを空にしてから作り直す。
# New-Item -Force は既存の中身を消さないので、L1 が落ちて L3 が走らなかった
# ときに前回の緑の managed.xml がそのまま残り、最新の結果に見えてしまう。
function Reset-Results {
    if (Test-Path $ResultsDir) {
        Remove-Item -Recurse -Force $ResultsDir
    }
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
}

function Build-Native {
    Invoke-Checked { cmake --preset $Preset } 'configure native'
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
    Invoke-Checked { cmake --preset $AsanPreset } 'configure native (asan)'
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
    'test'         { Reset-Results; Test-Native; Test-Managed }
    'clean'        { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
}

Write-Host "OK: $Command" -ForegroundColor Green
