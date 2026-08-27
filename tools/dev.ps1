#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test-native', 'test-asan', 'test-managed', 'test-managed-probe', 'test-tools', 'test-tools-slow', 'test-unity-editmode', 'test-unity-player', 'test', 'clean')]
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
Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force
$Platform      = Get-OpenCvPlatform

# native library のファイル名は platform で変わる。**1 箇所で決める** —
# 各所に .dll と書くと、platform を足したときに書き換え漏れが起きる
# （実測: M3 のレビューで dev.ps1 の 2 箇所と NativeLibraryResolver.cs が
# 漏れており、macOS / Linux の job は L1 も L3 も走らずに落ちる状態だった）。
$NativeLibraryName = if ($IsWindows) { 'opencv_unity_native.dll' }
                     elseif ($IsMacOS) { 'libopencv_unity_native.dylib' }
                     else { 'libopencv_unity_native.so' }
$Preset        = "$Platform-debug"
$AsanPreset    = "$Platform-asan"
$ResultsDir    = Join-Path $RepoRoot 'artifacts/test-results'

# L3 (P/Invoke) が読む native ライブラリの出力先。Visual Studio generator は
# 構成名のサブディレクトリ（Debug/）を作るが、Ninja（macOS / Linux）は単一構成
# generator なので作らない。Copy-NativePluginForUnity の $source 判定と同じ形。
$NativeOutDir  = if ($IsWindows) {
    Join-Path $RepoRoot "build/$Preset/native/Debug"
} else {
    Join-Path $RepoRoot "build/$Preset/native"
}

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
    'VerifyArtifactLinkage.Tests.ps1'
    'PackageRelease.Tests.ps1'
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
    # 出力ファイル名と配置は platform ごとに違う。Visual Studio generator は
    # 構成名のサブディレクトリ（Debug/）を作るが、Ninja は作らない。
    $buildDir = Join-Path $RepoRoot "build/$Preset/native"
    $source = if ($IsWindows) {
        Join-Path $buildDir "Debug/$NativeLibraryName"
    } elseif ($IsMacOS) {
        Join-Path $buildDir $NativeLibraryName
    } else {
        Join-Path $buildDir $NativeLibraryName
    }

    if (-not (Test-Path -LiteralPath $source)) {
        Write-DevFailure (@(
            "native plugin が見つかりません: $source"
            "先に './tools/dev.ps1 build' を実行してください。"
        ) -join "`n")
    }

    # Unity の native plugin 置き場も platform ごとに分かれる。
    $pluginDir = switch ($Platform) {
        'windows-x64' { 'x86_64' }
        'macos-arm64' { 'macOS' }
        'linux-x64'   { 'Linux/x86_64' }
    }
    $destDir = Join-Path $RepoRoot "Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/$pluginDir"
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
    if (-not (Test-Path (Join-Path $NativeOutDir $NativeLibraryName))) {
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

# tests/UnityProject/ProjectSettings/ProjectVersion.txt の m_EditorVersion から
# Unity Hub の既定インストール先を組み立てる。バージョンを合わせるのは
# uloop-launch skill と同じ考え方（ProjectVersion.txt が正本）。
function Get-UnityEditorPath {
    $versionFile = Join-Path $RepoRoot 'tests/UnityProject/ProjectSettings/ProjectVersion.txt'
    if (-not (Test-Path -LiteralPath $versionFile)) {
        Write-DevFailure "Unity プロジェクトの ProjectVersion.txt が見つかりません: $versionFile"
    }

    $match = Select-String -LiteralPath $versionFile -Pattern '^m_EditorVersion:\s*(\S+)' |
        Select-Object -First 1
    if (-not $match) {
        Write-DevFailure "m_EditorVersion を $versionFile から読み取れませんでした。"
    }
    $version = $match.Matches[0].Groups[1].Value

    $editorPath = "C:\Program Files\Unity\Hub\Editor\$version\Editor\Unity.exe"
    if (-not (Test-Path -LiteralPath $editorPath)) {
        Write-DevFailure (@(
            "Unity Editor $version が見つかりません: $editorPath"
            "Unity Hub でこのバージョンをインストールしてください。"
        ) -join "`n")
    }
    return $editorPath
}

<#
    Unity EditMode テスト（L4）。file: 参照で取り込んだ UPM パッケージが
    Unity 上で実際に動くことを検証する唯一のレーンである。

    -quit は付けない。-runTests は Test Runner がテスト完了後に自分で
    Unity を終了させる仕組みで、-quit を併用すると Unity がプロジェクトを
    開いた直後（テスト実行より先）に終了してしまい、結果 XML が一切
    書かれない（実測: ログが "Loaded All Assemblies" の直後で止まり、
    exit code だけが返る。計画書の元のコマンド例は -quit 付きだったが、
    これは Task 6 で見つかった計画の欠陥である — 公式ドキュメントも
    -runTests との併用を避けるよう明記している）。

    起動には `&` ではなく Start-Process -Wait を使う。`&` だと（この環境では）
    Unity.exe のような GUI サブシステムの実行ファイルに対して呼び出しが
    数十 ms で返ってしまい、実際のテスト実行を待たない（実測: `&` は
    $LASTEXITCODE も設定されないまま即座に返り、結果 XML が存在しない
    まま次のコードへ進んだ。Start-Process -Wait -PassThru に替えると
    Unity の実プロセス終了まで正しくブロックし、ExitCode と結果 XML の
    両方が揃って戻ってくる）。

    -quit を外しても、Unity は失敗時に終了コード 0 で戻ることがあり得る
    という懸念（元の設計判断）自体は残る。終了コードだけを見るのではなく、
    終了コードと結果 XML の failed カウントの両方を見る。結果 XML が
    無いこと自体も失敗として扱う — Unity がテストを書き出す前に落ちた
    ことを意味し、それは成功ではない。
#>
function Test-UnityEditMode {
    Build-Native

    $unity   = Get-UnityEditorPath
    $project = Join-Path $RepoRoot 'tests/UnityProject'
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    $results = Join-Path $ResultsDir 'unity-editmode.xml'
    $log     = Join-Path $ResultsDir 'unity-editmode.log'

    # -batchmode -nographics は CI とローカルで同じ条件にするため常に付ける。
    $unityArgs = @(
        '-projectPath', $project,
        '-runTests', '-testPlatform', 'EditMode',
        '-testResults', $results, '-logFile', $log,
        '-batchmode', '-nographics'
    )
    $proc = Start-Process -FilePath $unity -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow
    $exit = $proc.ExitCode

    if (-not (Test-Path -LiteralPath $results)) {
        Write-DevFailure "Unity が結果 XML を出しませんでした: $results`nログ: $log"
    }
    [xml]$xml = Get-Content -LiteralPath $results
    $failed = [int]$xml.'test-run'.failed
    $passed = [int]$xml.'test-run'.passed
    if ($exit -ne 0 -or $failed -ne 0) {
        Write-DevFailure "Unity EditMode テストが失敗しました（exit $exit、failed $failed）。`nログ: $log"
    }

    # 0 件で緑にしない。テストが 1 つも走らなかった場合、exit code も failed も 0 に
    # なるので、上の判定だけでは成功と見分けが付かない（実測: asmdef の
    # defineConstraints に未定義の記号を足すとテスト assembly がコンパイル対象から
    # 外れ、「0 passed」で exit 0 になった）。
    #
    # このレーンは完了条件 6 を担う唯一の証拠で、しかも CI では一度も走っていない。
    # asmdef の改名、UNITY_INCLUDE_TESTS の扱いの変化、test-framework の解決失敗、
    # file: 参照の破損 — どれが起きても静かに 0 件になり、緑のまま何も検証しなくなる。
    if ($passed -lt 1) {
        Write-DevFailure (@(
            "Unity EditMode でテストが 1 件も実行されませんでした（passed=$passed、failed=$failed）。"
            'テストが全部消えたか、テスト assembly がコンパイル対象から外れています。'
            '0 件の実行は成功ではありません。'
            "ログ: $log"
        ) -join "`n")
    }
    Write-Host "==> Unity EditMode: $passed passed" -ForegroundColor Green
}

<#
    Unity IL2CPP Player テスト（L5）。EditMode (Mono) では再現しない、
    IL2CPP の managed code stripping が P/Invoke 宣言を削る問題を検出する
    唯一のレーンである。link.xml の保護が効いているかは、実際に Player を
    ビルドして走らせる以外に確かめる方法が無い。

    2 回 Unity を起動する。1 回目は -executeMethod で Standalone の
    scripting backend を IL2CPP に固定するためだけの起動で、Test-UnityEditMode
    の注記どおり -executeMethod のときは -quit が正しい（-runTests のときは
    付けない、というのが Task 6 で確定した規則で、今回は逆側のケースにあたる）。
    2 回目が実際のテスト実行で、-testPlatform StandaloneWindows64 を渡すと
    Unity は Standalone Player を実際にビルドし、その中でテストを走らせて
    結果を回収する（IL2CPP ビルドを含むため 5〜20 分かかる）。

    どちらの起動も Test-UnityEditMode と同じ理由で `&` ではなく
    Start-Process -Wait -PassThru を使う。
#>
function Test-UnityPlayer {
    Build-Native

    $unity   = Get-UnityEditorPath
    $project = Join-Path $RepoRoot 'tests/UnityProject'
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    $results = Join-Path $ResultsDir 'unity-player.xml'
    $log     = Join-Path $ResultsDir 'unity-player.log'

    # 先に backend を IL2CPP に固定する。Mono のまま走らせると、
    # M2 が確かめたい stripping の問題が再現しない。
    $configureArgs = @(
        '-projectPath', $project, '-batchmode', '-nographics', '-quit',
        '-executeMethod', 'BuildPlayer.ConfigureIl2cpp', '-logFile', "$log.configure"
    )
    $configure = Start-Process -FilePath $unity -ArgumentList $configureArgs -Wait -PassThru -NoNewWindow
    if ($configure.ExitCode -ne 0) {
        Write-DevFailure "IL2CPP の設定に失敗しました。ログ: $log.configure"
    }

    $unityArgs = @(
        '-projectPath', $project,
        '-runTests', '-testPlatform', 'StandaloneWindows64',
        '-testResults', $results, '-logFile', $log,
        '-batchmode', '-nographics'
    )
    $proc = Start-Process -FilePath $unity -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow
    $exit = $proc.ExitCode

    if (-not (Test-Path -LiteralPath $results)) {
        Write-DevFailure "Unity が結果 XML を出しませんでした: $results`nログ: $log"
    }
    [xml]$xml = Get-Content -LiteralPath $results
    $failed = [int]$xml.'test-run'.failed
    $passed = [int]$xml.'test-run'.passed
    if ($exit -ne 0 -or $failed -ne 0) {
        Write-DevFailure "Unity Player テストが失敗しました（exit $exit、failed $failed）。`nログ: $log"
    }

    # 0 件で緑にしない。テストが 1 つも走らなかった場合、exit code も failed も 0 に
    # なるので、上の判定だけでは成功と見分けが付かない（実測: asmdef の
    # defineConstraints に未定義の記号を足すとテスト assembly がコンパイル対象から
    # 外れ、「0 passed」で exit 0 になった）。
    #
    # このレーンは完了条件 6 を担う唯一の証拠で、しかも CI では一度も走っていない。
    # asmdef の改名、UNITY_INCLUDE_TESTS の扱いの変化、test-framework の解決失敗、
    # file: 参照の破損 — どれが起きても静かに 0 件になり、緑のまま何も検証しなくなる。
    if ($passed -lt 1) {
        Write-DevFailure (@(
            "Unity Player でテストが 1 件も実行されませんでした（passed=$passed、failed=$failed）。"
            'テストが全部消えたか、テスト assembly がコンパイル対象から外れています。'
            '0 件の実行は成功ではありません。'
            "ログ: $log"
        ) -join "`n")
    }
    Write-Host "==> Unity Player (IL2CPP): $passed passed" -ForegroundColor Green
}

# CI 専用。L3 が本当にクラッシュ・ハング耐性を持つかを実証する
# (tools/run-managed-probe.ps1 参照)。数分かかるので test には含めない。
function Test-ManagedProbe {
    Build-Native
    if (-not (Test-Path (Join-Path $NativeOutDir $NativeLibraryName))) {
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
    'test-unity-editmode' { Reset-Results; Test-UnityEditMode }
    'test-unity-player' { Reset-Results; Test-UnityPlayer }
    'test'         { Reset-Results; Test-Tools; Test-Native; Test-Managed }
    'clean'        { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
}

Write-Host "OK: $Command" -ForegroundColor Green
