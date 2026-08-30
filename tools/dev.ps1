#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test-native', 'test-asan', 'test-managed', 'test-managed-probe', 'test-tools', 'test-tools-slow', 'test-unity-editmode', 'test-unity-player', 'test-unity-tarball', 'test', 'clean')]
    [string]$Command = 'test',

    <#
        test-unity-tarball を**全部入り**に対して走らせるとき、他 platform の
        plugin 木がある場所（';' 区切り）。

        **このマシンでビルドできるのは 1 platform 分だけ**なので、全部入りを
        作るには他 platform の binary を外から持ってくるしかない。公開済みの
        release から取るのが今のところ唯一の経路である:

            gh release download --pattern "*macos-arm64.tgz" --pattern "*linux-x64.tgz"   # 版を固定しない = 最新

        **どの版を混ぜたかは出力から分からない。** 版を固定しないのは、古い版を
        名指しし続けて「Windows だけ新しい」混成を作らないためだが、代わりに
        「いつ落としたか」で中身が変わる。`gh release list --limit 1` で版を
        確かめてから使うこと —— **ABI 版は関数を足しても上がらない**ので、
        C# 側の完全一致検査ではこのずれを検出できない。
            tar -xzf ...   # package/Runtime/Plugins が出てくる
            ./tools/dev.ps1 test-unity-tarball -PluginSource "<mac>/package;<linux>/package"

        **渡さなければ従来どおり 1 platform 分で走る。** 黙って全部入りの
        ふりをしない —— それをやると、レーンは緑なのに何も確かめていない
        状態になる。
    #>
    [string]$PluginSource,

    <#
        **ビルドの対象 platform。** 省略すると実行中の host（Get-OpenCvPlatform）。

        既存の 3 platform は「実行中の OS = 対象」だったので host 判定で足りたが、
        **モバイルはクロスコンパイル**なので一致しない。明示しないと
        「Windows の構成で Android をビルドする」が静かに成立する ——
        成功したように見えて中身が別物になる。

        `build` だけが受ける。テストのレーンは host で実行するものなので、
        クロスの対象を渡す意味が無い（渡されたら止める）。
    #>
    [ValidateSet('windows-x64', 'macos-arm64', 'linux-x64', 'android-arm64', 'ios-arm64')]
    [string]$Platform
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
<#
    **対象 platform。** -Platform が渡されればそれ、無ければ実行中の host。

    $HostPlatform は「いま動いている OS」で、$Platform は「何向けにビルドするか」
    である。**クロスコンパイルでは両者が一致しない** —— 一致すると決めてかかると、
    出力ファイル名も plugin の置き場所も host のものになる。
#>
$HostPlatform  = Get-OpenCvPlatform
if (-not $Platform) { $Platform = $HostPlatform }

# native library のファイル名は platform で変わる。**1 箇所で決める** —
# 各所に .dll と書くと、platform を足したときに書き換え漏れが起きる
# （実測: M3 のレビューで dev.ps1 の 2 箇所と NativeLibraryResolver.cs が
# 漏れており、macOS / Linux の job は L1 も L3 も走らずに落ちる状態だった）。
#
# **host ではなく対象 platform で決まる。** クロスビルドでは「Windows で
# 動かして Android の .so を作る」があるので、$IsWindows で分岐すると
# .dll を探しに行って見つからない。
$NativeLibraryName = switch ($Platform) {
    'windows-x64'   { 'opencv_unity_native.dll' }
    'macos-arm64'   { 'libopencv_unity_native.dylib' }
    'linux-x64'     { 'libopencv_unity_native.so' }
    'android-arm64' { 'libopencv_unity_native.so' }
    # iOS は静的ライブラリ。アプリの外から共有ライブラリを読み込めない。
    'ios-arm64'     { 'libopencv_unity_native.a' }
    default { throw "unknown platform '$Platform': ライブラリのファイル名が決まっていない。" }
}
$Preset        = "$Platform-debug"
$AsanPreset    = "$Platform-asan"
$ResultsDir    = Join-Path $RepoRoot 'artifacts/test-results'

# L3 (P/Invoke) が読む native ライブラリの出力先。Visual Studio generator は
# 構成名のサブディレクトリ（Debug/）を作るが、Ninja（macOS / Linux）は単一構成
# generator なので作らない。Copy-NativePluginForUnity の $source 判定と同じ形。
#
# **Visual Studio generator だけが構成名のサブディレクトリを作る。** それを
# 使うのは windows-x64 の preset だけで、他はすべて Ninja である —— host が
# Windows でも、Android 向けの preset は Ninja なのでサブディレクトリを作らない。
$NativeOutDir  = if ($Platform -eq 'windows-x64') {
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
    # **対象 platform の OpenCV を引く。** host のものを引くと、Android 向けの
    # ビルドに x86_64 の .a をリンクしようとする（Test-Asan は host 専用なので
    # あちらは既定のままでよい）。
    $opencvRoot = Get-OpenCvRoot -Config (Get-OpenCvConfig -Platform $Platform)
    if (-not (Test-Path -LiteralPath (Join-Path $opencvRoot 'build-manifest.json'))) {
        Write-DevFailure (@(
            "OpenCV が '$opencvRoot' にありません。"
            "先に './tools/opencv.ps1 restore -Platform $Platform' を実行してください。"
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
        'windows-x64'   { 'x86_64' }
        'macos-arm64'   { 'macOS' }
        'linux-x64'     { 'Linux/x86_64' }
        'android-arm64' { 'Android/arm64-v8a' }
        'ios-arm64'     { 'iOS' }
        default { throw "unknown platform '$Platform': plugin の置き場所が決まっていない。" }
    }
    $pluginRoot = Join-Path $RepoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins'
    $destDir = Join-Path $pluginRoot $pluginDir
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $source -Destination $destDir -Force

    <#
        Plugin Import Settings（.meta）も一緒に置く。

        **binary と .meta は必ず同時に現れなければならない。** 片方だけだと
        Unity が壊れた状態を見る:

        - .meta が無い binary → Unity が既定の設定を作る。既定は「全 platform
          有効」で、3 つの binary が読み込みで衝突する
        - binary が無い .meta → Unity から見ると「asset の無い孤児」で、
          mutable な package では**実際に削除される**。追跡していた頃は
          dev.ps1 test-unity-editmode を 1 回走らせるだけで、macOS / Linux の
          .meta が working tree から消えた（実測）

        だから .meta の正本は tools/plugin-meta/<platform>/ に置き、Plugins/ は
        丸ごと成果物にした（.gitignore 済み）。ここは Runtime/Plugins を根とした
        鏡像なので、そのままコピーすればフォルダの .meta も含めて揃う。
    #>
    $metaSource = Join-Path $PSScriptRoot "plugin-meta/$Platform"
    if (-not (Test-Path -LiteralPath $metaSource)) {
        Write-DevFailure (@(
            "Plugin Import Settings が見つかりません: $metaSource"
            'platform を足したときは tools/plugin-meta/<platform>/ も足すこと。'
            '.meta の無い binary は Unity で「全 platform 有効」の既定になり、'
            '複数 platform の binary が読み込みで衝突する。'
        ) -join "`n")
    }
    Copy-Item -Path (Join-Path $metaSource '*') -Destination $pluginRoot -Recurse -Force

    # 置いたつもりで置けていない状態を作らない。binary の隣に .meta があること
    # を確かめる（コピー元の構造が変わっても気づける）。
    $expectedMeta = Join-Path $destDir "$NativeLibraryName.meta"
    if (-not (Test-Path -LiteralPath $expectedMeta)) {
        Write-DevFailure (@(
            "binary の隣に .meta がありません: $expectedMeta"
            "コピー元: $metaSource"
            'tools/plugin-meta/<platform>/ は Runtime/Plugins を根とした鏡像である必要がある。'
        ) -join "`n")
    }
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
<#
    **全部入りに入るべき binary の一覧。正本はここ 1 箇所。**

    以前は 2 箇所に同じ 3 行を書いていた。platform を足したときに片方だけ
    直して片方が古いまま、という状態を作らないために 1 つにまとめる
    （M4 で 3 -> 5 に増えたときに実際に踏みかけた）。

    **tools/pack-upm-tarball.ps1 の $PlatformBinaries と同じ集合であること。**
    あちらは packer の正本で、こちらは「揃っているか」を見る側である。
    ずれると、揃っていないのに全部入りとして扱う（またはその逆）が起きる。
    tools/tests/PackageRelease.Tests.ps1 が両者を突き合わせる。
#>
$script:AllPlatformBinaries = @(
    'x86_64/opencv_unity_native.dll'
    'macOS/libopencv_unity_native.dylib'
    'Linux/x86_64/libopencv_unity_native.so'
    'Android/arm64-v8a/libopencv_unity_native.so'
    'iOS/libopencv_unity_native.a'
)


<#
    「3 つ揃っているはず」という合図を、**木から導出して**置く。

    ## なぜ「消す」ではなく「導出する」なのか

    最初は EditMode / Player のレーンで無条件に消していた。CI の手順を
    ローカルで再現した人が `tests/UnityProject/` に置き去りを作るからである。
    **しかしそれは、3 platform 同居の開発機で検査を黙って無効にする。**

    `test-unity-tarball -PluginSource` は実リポジトリの `Runtime/Plugins` に
    重ねて後始末をしない（roadmap にもそう書いてある）。つまり**条件 2 の証拠を
    再現した開発機では、その後の EditMode は 3 platform 同居の木で走る。**
    そこで合図を消すと「ちょうど 3 つ」の assertion が無効になり、出力は
    1 platform のときと見分けが付かない —— しかも `-RequireTest` の行が
    「gating は走った」と積極的に安心させる。

    導出にすれば、置き去りがあってもなくても結果が同じになる。**合図は
    状態ではなく、木から計算される値である。**
#>
<#
    **gating を実際に行うテストの名前。** クラス名だけを要求すると、この 4 件を
    消して残り 2 件（0 件で緑にしない検査と、数を報告する検査）だけにしても
    満たせてしまう。`ci-unity.yml` の matrix にも同じ 4 件が並ぶ。
#>
$script:GatingTestNames = @(
    'PluginGatingTests.ExactlyOnePluginTargetsThisEditorOs'
    'PluginGatingTests.EachPluginTargetsOnlyItsOwnEditorOs'
    'PluginGatingTests.NoPluginIsEnabledForEveryPlatform'
    'PluginGatingTests.EachPluginIsEnabledOnlyForItsOwnStandaloneTarget'
)

function Sync-AllPlatformsMarker {
    param([Parameter(Mandatory)][string] $ProjectPath)

    $pluginRoot = Join-Path $RepoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins'
    $present = @($script:AllPlatformBinaries |
                 Where-Object { Test-Path -LiteralPath (Join-Path $pluginRoot $_) })

    $marker = Join-Path $ProjectPath 'ocvu-expect-all-platforms'
    if ($present.Count -eq $script:AllPlatformBinaries.Count) {
        Set-Content -LiteralPath $marker -Value '1' -NoNewline -Encoding utf8
        Write-Host "==> $($present.Count) platform 分が揃っているので、テストに $($present.Count) つを要求させる" -ForegroundColor Cyan
    } else {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
}


function Test-UnityEditMode {
    Build-Native

    $unity   = Get-UnityEditorPath
    $project = Join-Path $RepoRoot 'tests/UnityProject'
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    $results = Join-Path $ResultsDir 'unity-editmode.xml'
    $log     = Join-Path $ResultsDir 'unity-editmode.log'

    # 合図は木から導出する（置き去りがあってもなくても結果が変わらない）。
    Sync-AllPlatformsMarker -ProjectPath $project


    # -batchmode -nographics は CI とローカルで同じ条件にするため常に付ける。
    $unityArgs = @(
        '-projectPath', $project,
        '-runTests', '-testPlatform', 'EditMode',
        '-testResults', $results, '-logFile', $log,
        '-batchmode', '-nographics'
    )
    $proc = Start-Process -FilePath $unity -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow
    $exit = $proc.ExitCode

    if ($exit -ne 0) {
        Write-DevFailure "Unity EditMode が exit $exit で終了しました。`nログ: $log"
    }

    <#
        合否の判定は tools/assert-unity-results.ps1 に出してある。

        **CI では Unity を起動するのが game-ci の action で、この関数では
        ない**（理由は .github/workflows/ci-unity.yml の冒頭にある）。
        起動の仕方が分かれても、**判定だけは同じコードを通す** — ここが
        分かれると、ローカルで赤くなるものが CI で緑になり得る。

        「0 件で緑にしない」もその script が持っている。理由はそちらに書いた。
    #>
    Invoke-Checked {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'assert-unity-results.ps1') `
            -ResultsPath $results -Lane 'editmode' -LogPath $log `
            -RequireTest ($script:GatingTestNames -join ';')
    } 'assert the editmode results'
}


<#
    UPM tarball としての導入を、Unity に実際に解決させて確かめる（M3 完了条件 2）。

    「package.json が在る」「tar が作れる」は「導入できる」ではない。UPM が
    tarball を展開し、asmdef を解決し、native plugin を読み、その package の
    テストが走って初めて「導入できた」と言える。だからこのレーンは、
    リポジトリ内の file: 参照ではなく **tarball だけ** を指した使い捨ての
    プロジェクトを作り、そこで EditMode テストを走らせる。

    tests/UnityProject/ をそのまま書き換えないのは、既存の L4 が
    「リポジトリ内の package を直接参照する」経路を担っているからで、
    どちらか一方で他方を代替できない。file: のディレクトリ参照は
    tarball の中身が壊れていても通ってしまう。

    Library/ を持って行かないので、Unity は import からやり直す。既存の L4 より
    かなり遅い。CI とローカルの手動確認のためのレーンで、`test` には含めない。
#>
function Test-UnityTarball {
    Build-Native

    # 他 platform の木を渡されたら重ねる。ここで初めて 3 platform が揃う。
    $allPlatforms = $false
    if ($PluginSource) {
        $assembler = Join-Path $PSScriptRoot 'assemble-plugins.ps1'
        & pwsh -NoProfile -File $assembler -Source $PluginSource
        if ($LASTEXITCODE -ne 0) {
            Write-DevFailure "plugin の木を重ねられませんでした（exit $LASTEXITCODE）"
        }
        $allPlatforms = $true
    }
    else {
        <#
            **渡されなくても、木に既に 3 つ揃っているなら全部入りとして扱う。**

            packer は名前と中身が食い違うことを拒むので、3 つ揃った木で
            単体 platform として固めようとすると落ちる。全部入りのレーンを
            1 回走らせた開発機ではそれが普通に起こる。

            ここで黙って 1 platform 分に見せかけることはしない —— どちらの
            構成で走ったかを必ず表示する。「レーンを回した」と「そのレーンが
            何を見たか」は別である。
        #>
        $pluginRoot = Join-Path $RepoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins'
        $present = @($script:AllPlatformBinaries |
                     Where-Object { Test-Path -LiteralPath (Join-Path $pluginRoot $_) })
        if ($present.Count -eq $script:AllPlatformBinaries.Count) {
            Write-Host "==> $($present.Count) platform 分が既に揃っているので全部入りとして検査する" -ForegroundColor Cyan
            $allPlatforms = $true
        }
    }

    $unity   = Get-UnityEditorPath

    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-tarball-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    try {
        # release.yml と同じ作り方で tarball にする。作り方が違うと、
        # ここで通ったものが配布物では通らない。
        # release.yml と同じ script で作る。作り方が分かれると、ここで
        # 導入できた tarball と実際に配る tarball が別物になる。
        $upmDir = Join-Path $work 'upm'
        $packer = Join-Path $PSScriptRoot 'pack-upm-tarball.ps1'
        # platform を渡す。packer がその platform の binary の実在を確かめるので、
        # 「何か 1 つでも入っている」ではなく「意図した binary が入っている」に
        # なる。
        $tgz = if ($allPlatforms) {
            & pwsh -NoProfile -File $packer -OutputDir $upmDir -AllPlatforms | Select-Object -Last 1
        } else {
            & pwsh -NoProfile -File $packer -OutputDir $upmDir -Platform $Platform | Select-Object -Last 1
        }
        if ($LASTEXITCODE -ne 0 -or -not $tgz -or -not (Test-Path -LiteralPath $tgz)) {
            Write-DevFailure "UPM tarball を作れませんでした（exit $LASTEXITCODE）"
        }

        # native plugin が本当に入ったか。入っていない tarball でも UPM の
        # 解決自体は通るので、ここで見ないと「導入できた」の意味が変わる。
        Push-Location (Split-Path -Parent $tgz)
        try { $listed = @(& tar -tzf (Split-Path -Leaf $tgz)) }
        finally { Pop-Location }
        # **「何か 1 つでも入っている」で満足しない。** 今ビルドした platform の
        # binary が入っていることを見る。dev.ps1 は $NativeLibraryName に
        # 実行中 platform の綴りを 1 箇所で持っているので、それを使う。
        # 「何かしら」で見ると、古い binary が Plugins に残っているだけで
        # 通ってしまう。
        <#
            全部入りなら**正本の全件**が揃っていること。**1 つでも通る形に
            しない** —— それでは全部入りを確かめたことにならない。

            **数も拡張子も書かない。** 以前はここに `3` と
            `\.(dll|dylib|so)$` が直書きされており、M4 で 5 platform に
            なったとき **2 通りに壊れた**: 期待する数が 3 のまま古くなり、
            拡張子の列挙は iOS の `.a` を binary と認めなかった。
            **packer 側の同じ欠陥は直したのに、こちらは残っていた。**

            正本は同じファイルの $script:AllPlatformBinaries である。
            そこから期待するパスを作れば、platform が増えたときに
            この検査も一緒に増える。
        #>
        if ($allPlatforms) {
            $wantBins = @($script:AllPlatformBinaries |
                ForEach-Object { "package/Runtime/Plugins/$_" })
            $allBins = @($listed | Where-Object { $_ -in $wantBins })
            if ($allBins.Count -ne $wantBins.Count) {
                $absent = @($wantBins | Where-Object { $_ -notin $allBins })
                Write-DevFailure (@(
                    "全部入りの tarball に binary が $($allBins.Count) 個しかありません（$($wantBins.Count) 個であるべき）: $tgz"
                    "入っていないもの: $($absent -join ', ')"
                    "archive に在った binary: $(if ($allBins) { $allBins -join ', ' } else { '(なし)' })"
                ) -join "`n")
            }
            Write-Host "==> tarball contains all $($wantBins.Count) platform binaries" -ForegroundColor Green
        }

        $binaries = @($listed | Where-Object { $_ -like "*/$NativeLibraryName" })
        if ($binaries.Count -lt 1) {
            # 診断も正本から。拡張子を列挙すると iOS の .a が「binary では
            # ない」ことになり、**失敗の原因を探す人に嘘の手がかりを渡す。**
            $anyBinary = @($listed | Where-Object {
                $rel = $_ -replace '^package/Runtime/Plugins/', ''
                $rel -in $script:AllPlatformBinaries })
            Write-DevFailure (@(
                "tarball に $NativeLibraryName が入っていません: $tgz"
                "入っていた binary: $(if ($anyBinary) { $anyBinary -join ', ' } else { '(なし)' })"
                'この platform 用にビルドしてから固めること。'
            ) -join "`n")
        }
        Write-Host "==> tarball contains $NativeLibraryName" -ForegroundColor Green

        # 使い捨ての Unity プロジェクトを作る。Library/ 等は持って行かない。
        $project = Join-Path $work 'UnityProject'
        $source  = Join-Path $RepoRoot 'tests/UnityProject'
        # 合図はここでは除かない。**コピーの後で木から導出して置き直す**ので、
        # 置き去りが混ざっても結果は変わらない（Sync-AllPlatformsMarker）。
        $skip    = @('Library', 'Temp', 'Logs', 'obj', 'Build', 'UserSettings')
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        Get-ChildItem -LiteralPath $source -Force |
            Where-Object { $_.Name -notin $skip } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $project -Recurse -Force }

        <#
            参照を tarball に差し替える。ディレクトリ参照が 1 つでも残ると、
            tarball が壊れていても緑になる。

            **manifest.json だけでは足りない。** packages-lock.json は
            `"version": "file:../../../Packages/com.ayutaz.opencv-unity-native"`
            を固定して持っており、これを持って行くと UPM がそちらで解決し得る。
            レーンが避けようとしているディレクトリ参照そのものが lock に
            残っている。消してから解決させる。
        #>
        $lockPath = Join-Path $project 'Packages/packages-lock.json'
        if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }

        $manifestPath = Join-Path $project 'Packages/manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw
        $tgzUri = 'file:' + ($tgz -replace '\\', '/')
        $manifest = $manifest -replace
            '"com\.ayutaz\.opencv-unity-native":\s*"[^"]*"',
            ('"com.ayutaz.opencv-unity-native": "' + $tgzUri + '"')
        Set-Content -LiteralPath $manifestPath -Value $manifest -NoNewline -Encoding utf8

        if ($manifest -notmatch [regex]::Escape($tgzUri)) {
            Write-DevFailure "manifest.json の参照を tarball に差し替えられませんでした: $manifestPath"
        }

        $results = Join-Path $ResultsDir 'unity-tarball.xml'
        $log     = Join-Path $ResultsDir 'unity-tarball.log'
        $unityArgs = @(
            '-projectPath', $project,
            '-runTests', '-testPlatform', 'EditMode',
            '-testResults', $results, '-logFile', $log,
            '-batchmode', '-nographics'
        )
        <#
            タイムアウトを付ける。CLAUDE.md の不変条件「テストは必ずタイムアウト
            付きサブプロセスで実行し」に従う。

            このレーンは Library/ をゼロから作るぶん最も固まりやすい。
            ハングしたまま待ち続けると、開発ループが止まったのか進んでいるのか
            区別できなくなる——「クラッシュは赤いテストでなければならない」の
            ハング版である。実測は約 3 分なので、その 5 倍を上限にする。
        #>
        $timeoutMs = 15 * 60 * 1000

        <#
            全部入りを検査していることを、テスト側にも伝える。

            PluginGatingTests が捕まえたい欠陥（別 platform の .meta が自分の
            platform でも有効）は、**3 platform 分が同居していないと原理的に
            現れない。** 1 platform 分の木でも同じ 5 件が緑になるので、
            **出力からはどちらを確かめたのか分からない。** この合図が
            置かれているときだけ「3 つ揃っていること」を要求させる。

            **環境変数ではなくファイルで渡す。** CI では Unity を起動するのが
            game-ci の action で、**コンテナへ渡る環境変数は固定の一覧である** ——
            任意の名前は届かない。届かなければテストは「合図が無い」分岐に落ち、
            **要素 1 個でも緑になる**。同じ合図をローカルと CI の両方で使える形に
            しておく（ワークスペースはコンテナに mount される）。
        #>
        Sync-AllPlatformsMarker -ProjectPath $project

        $proc = Start-Process -FilePath $unity -ArgumentList $unityArgs -PassThru -NoNewWindow
        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill($true) } catch { }
            Write-DevFailure (@(
                "Unity が $($timeoutMs / 60000) 分で終わらなかったので打ち切りました。"
                'ハングは緑にも赤にもならないので、明示的に失敗させる。'
                "ログ: $log"
            ) -join "`n")
        }
        $exit = $proc.ExitCode

        <#
            **判定は共通の script に寄せる。**

            ここだけ自前で XML を読んでいたので、`-RequireTest` を足したときに
            **3 platform を実際に同居させて走らせる唯一のローカルレーンだけが、
            gating が走ったことを要求しない**状態になっていた。CLAUDE.md の
            「合否の判定は assert-unity-results.ps1 をローカルと CI の両方が
            通る」とも食い違う。

            全部入りのときは、**結果として `native plugins present: 5` が
            出ていること**まで要求する。合図が届かなければ gating は
            「1 つ以上」しか要求せず、そのときの出力は意図どおり動いた場合と
            1 バイトも違わない —— 入力を検査しても届いたことの証明にはならない。
        #>
        if (-not (Test-Path -LiteralPath $results)) {
            Write-DevFailure "Unity が結果 XML を出しませんでした: $results`nログ: $log"
        }
        if ($exit -ne 0) {
            Write-DevFailure "tarball 導入後の EditMode テストが exit $exit で終了しました。`nログ: $log"
        }

        $assertArgs = @(
            '-ResultsPath', $results
            '-Lane', 'tarball'
            '-LogPath', $log
        )
        $assertArgs += @('-RequireTest', ($script:GatingTestNames -join ';'))
        if ($allPlatforms) {
            $assertArgs += @('-RequireOutput', 'native plugins present: 5 [')
        }
        Invoke-Checked {
            & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'assert-unity-results.ps1') @assertArgs
        } 'assert the tarball results'

        [xml]$xml = Get-Content -LiteralPath $results
        $passed = [int]$xml.'test-run'.passed

        <#
            **テストが通ったことは、tarball で解決された証拠にならない。**
            テストは tests/UnityProject/Assets/Tests/ にあってパッケージの中には
            無いので、ディレクトリ参照で解決されても同じ数だけ通る。
            上の lock 削除が効かなかった場合、緑のまま何も証明しない。

            UPM が解決後に書き戻す packages-lock.json を読んで、参照が本当に
            tarball だったかを見る。ここまでやって初めて「tarball から導入
            できた」と言える。
        #>
        if (-not (Test-Path -LiteralPath $lockPath)) {
            Write-DevFailure (@(
                "UPM が packages-lock.json を書き戻しませんでした: $lockPath"
                'どの参照で解決されたかを確かめられないので、合格にしない。'
            ) -join "`n")
        }
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $entry = $lock.dependencies.'com.ayutaz.opencv-unity-native'
        if (-not $entry -or $entry.version -notlike '*.tgz') {
            Write-DevFailure (@(
                'UPM は tarball ではない参照で解決しました。このレーンは何も証明していません。'
                "解決された参照: $(if ($entry) { $entry.version } else { '(項目なし)' })"
                "期待: .tgz で終わる file: 参照"
                "ログ: $log"
            ) -join "`n")
        }
        Write-Host "==> UPM tarball install: $passed passed (resolved from $($entry.version))" -ForegroundColor Green
    }
    finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
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

    # 合図は木から導出する（置き去りがあってもなくても結果が変わらない）。
    Sync-AllPlatformsMarker -ProjectPath $project


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

    if ($exit -ne 0) {
        Write-DevFailure "Unity Player が exit $exit で終了しました。`nログ: $log"
    }

    <#
        合否の判定は tools/assert-unity-results.ps1 に出してある。

        **CI では Unity を起動するのが game-ci の action で、この関数では
        ない**（理由は .github/workflows/ci-unity.yml の冒頭にある）。
        起動の仕方が分かれても、**判定だけは同じコードを通す** — ここが
        分かれると、ローカルで赤くなるものが CI で緑になり得る。

        「0 件で緑にしない」もその script が持っている。理由はそちらに書いた。
    #>
    Invoke-Checked {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'assert-unity-results.ps1') `
            -ResultsPath $results -Lane 'player' -LogPath $log
    } 'assert the player results'
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

<#
    **クロスの対象を受け取れるのは build だけ。**

    テストのレーンは実行中の host で走るので、クロスの対象を渡されても
    走らせようがない。黙って host 向けに走らせると「Android を検査したつもり」
    になる —— このリポジトリが繰り返し潰してきた「通るのに何も証明していない」
    形そのものである。
#>
if ($PSBoundParameters.ContainsKey('Platform') -and $Command -ne 'build') {
    Write-DevFailure (@(
        "-Platform は build のときだけ使えます（渡された command: $Command）。"
        'テストのレーンは実行中の host で走るので、クロスの対象を渡す意味がありません。'
        "クロスビルドした成果物を検査するなら、実機か CI の該当 job で行うこと。"
    ) -join "`n")
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
    'test-unity-tarball' { Reset-Results; Test-UnityTarball }
    'test'         { Reset-Results; Test-Tools; Test-Native; Test-Managed }
    'clean'        { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
}

Write-Host "OK: $Command" -ForegroundColor Green
