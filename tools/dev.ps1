#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test-native', 'test-asan', 'test-managed', 'test-managed-probe', 'test-tools', 'test-tools-slow', 'test', 'clean')]
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

# tools/*.ps1（OpenCV の構成・ハッシュ・allowlist 検証）の素の assert テスト。
#
# 2 段に分かれている。分岐の基準は「重要度」ではなく実測の所要時間である。
# ローカルループは秒単位を死守するという M0 の不変条件が、どちらに置くかを決める。
#
#   Fast（local + CI）  : 各 3 秒。ハッシュ導出と構成の読み取りだけで、
#                         OpenCV の実体も subprocess の大量生成も要らない。
#   Slow（CI のみ）      : VerifyOpenCvArtifact は 22 のケースごとに
#                         pwsh -NoProfile を起動する設計で、この環境では
#                         起動が 1 回 1〜1.5 秒かかるため単体で 69 秒（実測）。
#                         OpenCvRestore は実際に artifact を download する。
#
# 実測（このマシン、増分ビルド時）:
#   test（この分割後）                     65 秒
#   test（Slow も含めていたとき）          117 秒
#   test-tools（Fast 2 本）                18 秒
#
# 65 秒の大半はこの一覧ではなく、OpenCV をリンクしたこと自体である
# （test-native 単体 28 秒、うち毎回 6.7 秒は find_package を含む再 configure）。
# Slow を外して 117 -> 65 秒になったが、M0 当時の約 20 秒には戻らない。
# その差は M1 が受け入れた前提であり、この分割では解消しない。
#
# Slow を CI 専用にしても検証は失われない。CLAUDE.md が定めるとおり
# merge 可否を決めるのは CI であり、Slow は必須チェックの中で必ず走る
# （ci-native.yml の "Run the slow tools tests"）。レビュー H2 は
# 「どのレーンからも走らない」ことを問題にしており、CI で走れば満たされる。
$ToolsTestScriptsFast = @(
    'OpenCvConfig.Tests.ps1'
    'ConfigInvalidation.Tests.ps1'
)

$ToolsTestScriptsSlow = @(
    'VerifyOpenCvArtifact.Tests.ps1'
    'OpenCvRestore.Tests.ps1'
)

function Invoke-ToolsTestList {
    param([string[]] $Scripts)

    foreach ($script in $Scripts) {
        $path = Join-Path $PSScriptRoot "tests/$script"
        Invoke-Checked {
            & pwsh -NoProfile -File $path
        } "run $script (tools)"
    }
}

function Test-Tools {
    Invoke-ToolsTestList -Scripts $ToolsTestScriptsFast
}

# CI 専用。ローカルで叩いても動くが数分かかる。
function Test-ToolsSlow {
    Invoke-ToolsTestList -Scripts $ToolsTestScriptsSlow
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

    Copy-NativePluginForUnity
}

<#
    ビルドした DLL を UPM パッケージの Plugins へ写す。

    Unity は Packages/<id>/Runtime/Plugins/x86_64/ に置かれた DLL を native plugin
    として読む。ビルドのたびにここへ写しておかないと、Unity 側は「古い DLL のまま
    緑」という最も紛らわしい状態になる — テストは通るのに、検証しているのは
    今ビルドしたコードではない。だから Build-Native の末尾にぶら下げ、
    忘れようがない位置に置く。

    成果物なのでコミットしない（.gitignore 済み）。
#>
function Copy-NativePluginForUnity {
    $source = Join-Path $RepoRoot 'build/windows-x64-debug/native/Debug/opencv_unity_native.dll'
    if (-not (Test-Path -LiteralPath $source)) {
        Write-DevFailure (@(
            "native plugin が見つかりません: $source"
            "先に './tools/dev.ps1 build' を実行してください。"
        ) -join "`n")
    }

    $destDir = Join-Path $RepoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64'
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $source -Destination $destDir -Force
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
        #
        # Category!=Probe: HarnessProbeTests は意図的に落ちる／固まるための
        # プローブで、通常の実行に含めると常に赤くなる。実行は
        # test-managed-probe (tools/run-managed-probe.ps1) が名指しで行う。
        dotnet test (Join-Path $RepoRoot 'tests/Managed/CvUnity.Managed.sln') `
            --filter "Category!=Probe" `
            --blame-hang --blame-hang-timeout 60s `
            --logger "junit;LogFilePath=$(Join-Path $ResultsDir 'managed.xml')" `
            --logger 'console;verbosity=normal'
    } 'run managed tests (L3)'
}

# CI 専用。L3 が本当にクラッシュ・ハング耐性を持つかを実証する
# (tools/run-managed-probe.ps1 参照)。数分かかるので test には含めない。
function Test-ManagedProbe {
    Build-Native
    if (-not (Test-Path (Join-Path $NativeOutDir 'opencv_unity_native.dll'))) {
        throw "Native library was not found in '$NativeOutDir' after building."
    }
    $env:OCVU_NATIVE_DIR = $NativeOutDir
    Invoke-Checked {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run-managed-probe.ps1')
    } 'run L3 crash/hang probes (test-managed-probe)'
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
    'test-managed-probe' { Test-ManagedProbe }
    'test-tools'   { Test-Tools }
    'test-tools-slow' { Test-ToolsSlow }
    'test'         { Reset-Results; Test-Tools; Test-Native; Test-Managed }
    'clean'        { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
}

Write-Host "OK: $Command" -ForegroundColor Green
