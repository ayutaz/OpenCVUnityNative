#Requires -Version 7.0
<#
    OpenCV のビルドと取得。

    既定は restore（CI が作った artifact を download する）で、build は
    ローカルで再現を検証するための遅い経路である。M1 の目的の 1 つが
    「開発ループから OpenCV のビルドコストを追い出す」ことなので、
    日常的に build を叩く運用にはしないこと。CI 実測（clone〜verify まで
    通しで）は 4 分 09 秒（`windows-2022` runner、run 32849957498）。
    ローカルでの実測はまだ無い。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('restore', 'build', 'verify', 'status', 'clean')]
    [string]$Command = 'restore',

    <#
        対象 platform。**省略すると実行中の host**（Get-OpenCvPlatform）。

        モバイルはクロスコンパイルなので host と対象が一致しない。明示しないと
        「Windows の構成で Android をビルドする」が静かに成立する ——
        **成功したように見えて中身が別物になる。**
    #>
    [ValidateSet('windows-x64', 'macos-arm64', 'linux-x64', 'android-arm64', 'ios-arm64')]
    [string]$Platform
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# CI のログは UTF-8。指定しないと Windows の PowerShell は既定の ANSI
# コードページ（日本語環境なら cp932、CI の en-US runner なら cp1252）で
# 書き出し、restore の失敗メッセージが文字化けするか、cp1252 環境では
# 日本語部分が可逆でない形で失われる。tools/verify-opencv-artifact.ps1 と
# 同じ対応。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force

$Config       = if ($Platform) { Get-OpenCvConfig -Platform $Platform } else { Get-OpenCvConfig }
$ConfigHash   = Get-OpenCvConfigHash -Config $Config
$ArtifactName = Get-OpenCvArtifactName -Config $Config
$OpenCvRoot   = Get-OpenCvRoot -Config $Config
$WorkRoot     = Join-Path $RepoRoot "build/opencv-$ConfigHash"

function Invoke-Checked([scriptblock]$Action, [string]$What) {
    Write-Host "==> $What" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

function Show-Status {
    Write-Host "OpenCV tag      : $($Config.Tag)"
    Write-Host "modules         : $($Config.Modules -join ', ')"
    Write-Host "config hash     : $ConfigHash"
    Write-Host "artifact name   : $ArtifactName"
    Write-Host "install root    : $OpenCvRoot"
    if (Test-Path -LiteralPath $OpenCvRoot) {
        Write-Host "state           : present" -ForegroundColor Green
    }
    else {
        Write-Host "state           : ABSENT — run './tools/opencv.ps1 restore'" -ForegroundColor Yellow
    }
}

function Invoke-Build {
    $sourceRoot = Join-Path $WorkRoot 'source'
    $buildRoot  = Join-Path $WorkRoot 'build'

    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceRoot) | Out-Null
        Invoke-Checked {
            git clone --depth 1 --branch $Config.Tag https://github.com/opencv/opencv.git $sourceRoot
        } "clone OpenCV $($Config.Tag)"
    }

    # clone した tag が本当に要求どおりか確認する。--depth 1 でも
    # tag の指定を間違えれば別物が取れるので、思い込みで進めない。
    Push-Location $sourceRoot
    try {
        $describe = git describe --tags --exact-match 2>$null
        if ($describe -ne $Config.Tag) {
            throw "Cloned tree is at '$describe' but the configuration pins '$($Config.Tag)'."
        }
    }
    finally { Pop-Location }

    # -A は Visual Studio generator 専用のオプションで、Ninja に渡すとエラーになる。
    # アーキテクチャは macOS では CMAKE_OSX_ARCHITECTURES（PlatformCMakeArgs）、
    # Linux ではネイティブ既定で決まる。
    $generatorArgs = @('-G', $Config.Toolchain.Generator)
    if ($Config.Toolchain.Generator -like 'Visual Studio*') {
        $generatorArgs += @('-A', $Config.Toolchain.Architecture)
    }

    <#
        **クロスコンパイルの platform には toolchain file を渡す。**

        `-DANDROID_ABI` のような変数は **NDK の android.toolchain.cmake が読む**
        のであって、CMake 本体は見ない。toolchain file 抜きで渡すと未使用の
        cache 変数になるだけで、**OpenCV は runner の gcc で host 向けに
        ビルドされる** —— それが `opencv-5.0.0-android-arm64-<hash>` という
        名前で公開される。**成功したように見えて中身が別物になる。**

        plugin 側（CMakePresets の toolchainFile）は塞いであったが、
        **OpenCV 側が塞がれていなかった**（レビューで発見）。同じ toolchain file を
        使う —— 別々に持つと、片方だけ直したときに気づけない。
    #>
    $crossToolchains = @{
        'android-arm64' = 'cmake/toolchains/android-arm64.cmake'
        'ios-arm64'     = 'cmake/toolchains/ios-arm64.cmake'
    }
    $toolchainArgs = @()
    if ($crossToolchains.ContainsKey($Config.Platform)) {
        $tc = Join-Path $RepoRoot $crossToolchains[$Config.Platform]
        if (-not (Test-Path -LiteralPath $tc)) {
            throw "toolchain file が見つかりません: $tc（$($Config.Platform) はクロスビルドなので必須）"
        }
        $toolchainArgs = @("-DCMAKE_TOOLCHAIN_FILE=$tc")
        Write-Host "==> cross-compiling for $($Config.Platform) via $tc" -ForegroundColor Cyan
    }

    $cmakeArgs = @(
        '-S', $sourceRoot
        '-B', $buildRoot
    ) + $generatorArgs + $toolchainArgs + @(
        "-DCMAKE_BUILD_TYPE=$($Config.Toolchain.BuildType)"
        "-DCMAKE_INSTALL_PREFIX=$OpenCvRoot"
        "-DBUILD_LIST=$($Config.Modules -join ',')"
    ) + $Config.CMakeArgs

    # configure の stdout をそのまま画面にも出しつつ変数にも残す。OpenCV の
    # トップレベル CMakeLists.txt はここで「General configuration for
    # OpenCV」summary を出力し、bundle された third-party（ZLib/libjpeg-turbo/
    # libpng 等）の実バージョンが載るのはこの summary だけである。この
    # summary は cv::getBuildInformation() が実行時に返す文字列と同じ内容
    # なので、まだビルドしていない opencv_unity_native.dll を経由しなくても
    # ここで一度に取れる。
    # 出力を溜めてから出すと、configure が固まったとき CI ログが job timeout
    # （150 分）まで無言になる。パイプの途中で書き出しつつ後段へも流す
    # （再レビュー F10）。summary の抽出はこの変数から行う。
    $configureOutputLines = & cmake @cmakeArgs 2>&1 | ForEach-Object {
        Write-Host $_   # その場で流す
        $_              # 変数にも残す（summary の抽出に使う）
    }
    if ($LASTEXITCODE -ne 0) { throw "configure OpenCV failed with exit code $LASTEXITCODE" }

    # install ターゲットの名前と --config の要否は generator で変わる。
    #
    #   Visual Studio（複数構成）: ターゲット名は 'INSTALL'、--config が要る
    #   Ninja（単一構成）        : ターゲット名は 'install'、--config は無意味
    #
    # 実測（M3 Task 4 の CI 初回）: Ninja に INSTALL を渡すと
    # 「ninja: error: unknown target 'INSTALL'」で落ちる。configure 自体は
    # 成功していたので、ここだけが platform 間で違っていた。
    $isMultiConfig = $Config.Toolchain.Generator -like 'Visual Studio*'
    $buildArgs = @('--build', $buildRoot)
    if ($isMultiConfig) {
        $buildArgs += @('--config', $Config.Toolchain.BuildType, '--target', 'INSTALL')
    } else {
        $buildArgs += @('--target', 'install')
    }

    Invoke-Checked {
        cmake @buildArgs
    } 'build and install OpenCV'

    $modules = Invoke-Verify
    $dependencyVersions = Get-OpenCvDependencyVersions -BuildInformation ($configureOutputLines -join "`n")
    Write-BuildManifest -Modules $modules -DependencyVersions $dependencyVersions
}

function Write-RestoreFailure([string]$Message) {
    # throw ではなく素の stderr 書き込み + exit にする。PowerShell 7 の
    # 既定の ConciseView は未捕捉の throw を "Exception:" 見出しと
    # "Line |" ブロック・ソース位置の "~~~" つきで描画し、
    # 複数行メッセージの改行も潰される。この関数が返す具体的な次の
    # アクション（gh workflow run ... 等）がスタックトレースの下に
    # 埋もれ、スクリプトのクラッシュにしか見えなくなる。
    # verify-opencv-artifact.ps1 が採る形（[Console]::Error + exit）と
    # 揃える。
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Test-OpenCvTreeValid([string]$ManifestPath) {
    # 存在するというだけで信用しない。中断された download や壊れた木が
    # 「present」と誤判定されると、以後そのマシン（や共有キャッシュ）上の
    # restore が全員分、永久に検証も再取得もせず成功したふりをする。
    # マニフェストがパースできて期待する configHash と一致し、かつ
    # allowlist 検証（Invoke-Verify、実ファイルを見る）まで通って初めて
    # 有効とみなす。
    #
    # 判定は「無効な形をこれとこれとして潰す」のではなく「有効だと
    # 積極的に立証できなければ無効」にする。前者は書いた本人が思いついた
    # 形しか塞げない。実際、パース部分だけを try/catch していた版は
    # zero-byte・`[]`・`42`・空白のみの 4 形で、ConvertFrom-Json 自体は
    # 例外を投げず（$null や scalar を返して）成功し、その直後の
    # `.PSObject.Properties.Name` アクセスが StrictMode 下で例外を投げて
    # 素通りした（Invoke-Restore の try/finally より外側なので後始末も
    # 走らない）。検証全体を 1 つの try/catch に入れることで、
    # 「どの行で失敗するか」を将来また誰かが見落としても構造的に
    # 無効側に倒れる。
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $manifest) { return $false }
        if ($manifest -isnot [System.Management.Automation.PSCustomObject]) { return $false }
        if (-not (($manifest.PSObject.Properties.Name -contains 'configHash') -and ($manifest.configHash -eq $ConfigHash))) {
            return $false
        }
        Invoke-Verify | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

<#
    gh をレート制限に耐える形で呼ぶ。

    GitHub の API はリポジトリ単位で上限があり、複数の workflow を同時に
    走らせると当たる。**当たったときに落ちるのではなく、待って続ける。**
    上限は時間で回復するので、待てば必ず進む——落とすと人が再実行する
    ことになり、その再実行がまた上限を消費する。

    レート制限**以外**の失敗は待たずにそのまま返す。待って直るものと
    直らないものを混ぜない。
#>
function Invoke-GhWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock] $Script,
        [Parameter(Mandatory)][string] $What,
        [int] $MaxAttempts = 4
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $output = & $Script 2>&1
        if ($LASTEXITCODE -eq 0) { return ($output -join "`n") }

        $text = ($output -join "`n")
        $rateLimited = $text -match 'rate limit|secondary rate|403'
        if (-not $rateLimited -or $attempt -eq $MaxAttempts) {
            Write-Host $text
            return $null
        }

        $wait = [Math]::Pow(2, $attempt) * 15   # 30s, 60s, 120s
        Write-Host "==> $What はレート制限に当たった。$wait 秒待って再試行する（$attempt/$MaxAttempts）" -ForegroundColor Yellow
        Start-Sleep -Seconds $wait
    }
    return $null
}

function Invoke-Restore {
    $manifestPath = Join-Path $OpenCvRoot 'build-manifest.json'

    if (Test-Path -LiteralPath $manifestPath) {
        if (Test-OpenCvTreeValid $manifestPath) {
            Write-Host "OpenCV $($Config.Tag) ($ConfigHash) is already present." -ForegroundColor Green
            return
        }
        # 自己修復する: 手で直させるのではなく、壊れている／不完全な木は
        # 消して取り直す。中断された download や、破損したキャッシュを
        # 次の人がリンクエラーで気づくよりずっと安く直る。
        Write-Host "既存の $OpenCvRoot は不完全または検証に失敗したため、取り直します。" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-RestoreFailure (@(
            'gh CLI が見つかりません。restore は GitHub Actions の artifact を取得します。'
            'https://cli.github.com/ を入れて `gh auth login` するか、'
            'ローカルで再現する場合は `./tools/opencv.ps1 build` を使ってください（CI 実測 4 分 09 秒。ローカルは未計測）。'
        ) -join "`n")
    }

    New-Item -ItemType Directory -Force -Path $OpenCvRoot | Out-Null

    # download の途中で中断されても（Ctrl+C、プロセスの強制終了）、
    # 半端な木を残さない。$succeeded が立たない限り必ず取り除く。
    $succeeded = $false
    try {
        Write-Host "==> download artifact '$ArtifactName'" -ForegroundColor Cyan
        # **実行 ID を指定して 1 つだけ取る。**
        #
        # `gh run download --name <名前>` は名前だけを指定すると、その名前を持つ
        # artifact を**すべての実行から**取ってきて同じディレクトリへ展開しようと
        # する。同じ構成で build を複数回走らせると同名の artifact が増えるので
        # （実測: 6 個）、2 つ目の展開で「The file exists」になって失敗する。
        #
        # 構成ハッシュが同じなら中身も同じはずなので、どれを取っても等価である。
        # 最新の成功した実行のものを選ぶ。
        <#
            **artifact を名前で 1 回引く。** 以前はここで成功した実行を 20 件
            列挙し、**その 1 件ずつに artifact を問い合わせていた**——1 回の
            restore で最大 21 回の API 呼び出しになる。

            3 platform × 複数 workflow を同時に走らせると、これが積み上がって
            レート制限に当たる。実測（2026-08-29、v0.1.1 のリリース時）:

                error fetching artifacts: HTTP 403: API rate limit exceeded
                for installation

            **失敗したのは成果物でもコードでもなく、探し方だった。** artifact の
            一覧は名前で絞り込めるので、1 回で済む。expired かどうかも同じ
            応答に入っているので、失効を「見つからない」と混同せずに言える。
        #>
        $encodedName = [uri]::EscapeDataString($ArtifactName)
        $found = Invoke-GhWithRetry -What "look up artifact '$ArtifactName'" -Script {
            & gh api "repos/:owner/:repo/actions/artifacts?name=$encodedName&per_page=100" `
                 --jq '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | reverse | .[0] | .workflow_run.id'
        }

        $runId = if ($found -and $found -ne 'null') { $found.Trim() } else { $null }

        if (-not $runId) {
            <#
                **「まだ無い」と「いま作っている最中」を区別する。**

                OpenCV の構成を変えた PR では、build-opencv と他のレーンが
                同時に走る。artifact ができるより先に restore が動くので、
                **「この構成でまだビルドしていない」という同じ文言が出る** ——
                しかし取るべき行動は逆で、こちらは待って再実行すればよい。

                実測（M4、2026-08-30）: モバイルを足した最初の PR で
                `Plugin ios-arm64` がこれで落ちた。**artifact は 20 分後に
                正しく公開された** —— 構成にもコードにも問題は無かった。

                失敗の経路でだけ 1 回余分に API を呼ぶ。レート制限を気にする
                のは成功の経路である（上の注記を参照）。
            #>
            $running = Invoke-GhWithRetry -What 'check for a build-opencv run in progress' -Script {
                & gh api "repos/:owner/:repo/actions/workflows/build-opencv.yml/runs?status=in_progress&per_page=1" `
                     --jq '.workflow_runs | length'
            }
            $queued = Invoke-GhWithRetry -What 'check for a queued build-opencv run' -Script {
                & gh api "repos/:owner/:repo/actions/workflows/build-opencv.yml/runs?status=queued&per_page=1" `
                     --jq '.workflow_runs | length'
            }
            $busy = (($running -as [int]) + ($queued -as [int])) -gt 0

            if ($busy) {
                Write-RestoreFailure (@(
                    "artifact '$ArtifactName' はまだ公開されていませんが、**build-opencv が現在実行中です。**"
                    ''
                    'この構成を変えた直後に、他のレーンが同時に走ったときに起きます。'
                    '構成にもコードにも問題はありません —— build-opencv の完了を待って'
                    'このレーンを再実行してください。'
                ) -join "`n")
            }

            Write-RestoreFailure (@(
                "artifact '$ArtifactName' を持つ成功した実行が見つかりません。"
                ''
                'この構成でまだビルドしていないか、artifact が失効しています。'
                '（build-opencv は実行中でも待機中でもありません。）'
                '  gh workflow run build-opencv.yml'
            ) -join "`n")
        }

        & gh run download $runId --name $ArtifactName --dir $OpenCvRoot 2>&1 | Write-Host

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $manifestPath)) {
            Write-RestoreFailure (@(
                "artifact '$ArtifactName' を取得できませんでした。"
                ''
                '考えられる原因:'
                '  1. この構成でまだ一度もビルドしていない'
                '  2. artifact が失効した（GitHub Actions の保持上限は 90 日）'
                '  3. gh が認証されていない（`gh auth status` で確認）'
                '  4. API のレート制限に当たった（同時に多くの workflow を走らせた）'
                ''
                '1 と 2 のどちらでも、対処は build ワークフローの再実行です:'
                '  gh workflow run build-opencv.yml'
                ''
                'ローカルで再現する場合は `./tools/opencv.ps1 build`（CI 実測 4 分 09 秒。ローカルは未計測）。'
            ) -join "`n")
        }

        # download した物が本当に期待の構成か確認する。
        # artifact 名が一致していても中身が壊れている可能性はある。
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.configHash -ne $ConfigHash) {
            Write-RestoreFailure "artifact の configHash は '$($manifest.configHash)' で、期待する '$ConfigHash' と異なります。"
        }

        # ここでの失敗（新しく取得した artifact が allowlist を通らない）は
        # 通常起き得ない — CI 自身が publish 前に同じ検証を通している
        # はずだから。それでも起きたら、生の throw を素通りさせず
        # Write-RestoreFailure を通す。$succeeded が立たないまま
        # 下の finally に落ちるので、後始末（$OpenCvRoot の削除）は
        # 変わらず起こる。
        try {
            Invoke-Verify | Out-Null
        }
        catch {
            Write-RestoreFailure (@(
                "artifact '$ArtifactName' は取得できましたが、allowlist 検証に失敗しました。"
                ''
                $_.Exception.Message
                ''
                'CI が公開した artifact 自体が壊れているか、想定外の依存を含んでいる可能性があります。'
                'build ワークフローのログを確認するか、再実行してください:'
                '  gh workflow run build-opencv.yml'
            ) -join "`n")
        }
        $succeeded = $true
    }
    finally {
        if (-not $succeeded) {
            Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
        }
    }

    Write-Host "restored OpenCV $($Config.Tag) ($ConfigHash)" -ForegroundColor Green
}

function Invoke-Verify {
    $verify = Join-Path $PSScriptRoot 'verify-opencv-artifact.ps1'
    Write-Host '==> verify dependency allowlist' -ForegroundColor Cyan
    $modules = & pwsh -NoProfile -File $verify -Root $OpenCvRoot
    if ($LASTEXITCODE -ne 0) { throw 'dependency allowlist verification failed' }
    return $modules
}

function Write-BuildManifest([string[]]$Modules, [System.Collections.Specialized.OrderedDictionary]$DependencyVersions) {
    <#
        compiler の version を取り出す。

        **接頭辞を剥ぐのではなく、version そのものを取り出す。** 以前は
        'CMAKE_CXX_COMPILER_VERSION\s+' を消して残りを値として扱っていたが、
        それは「行が想定どおりの形をしている」ことを前提にしていた。macOS の
        実物は想定外で、v0.1.0 の manifest に `== 15.0.0.15000309` という値が
        入った（先頭の `== ` が残った）。Windows と Linux は正常だったので、
        著者が見た 2 つの形だけが通り、3 つ目が枠外に落ちた形である。

        数字とドットの並びを直接拾えば、行の飾りが何であっても正しく取れる。
        取れなかったら**失敗させる** — 壊れた値を manifest に書くくらいなら
        止まる方がよい。manifest は「実際に何でビルドしたか」の申告であり、
        そこに嘘が入ると manifest を持つ意味が無くなる。
    #>
    $compilerLine = (cmake --system-information 2>$null |
        Select-String -Pattern '^CMAKE_CXX_COMPILER_VERSION ' |
        Select-Object -First 1)
    if (-not $compilerLine) {
        throw "cmake --system-information did not report CMAKE_CXX_COMPILER_VERSION"
    }
    $versionMatch = [regex]::Match([string]$compilerLine, '(\d+(?:\.\d+)+)')
    if (-not $versionMatch.Success) {
        throw @(
            "could not parse a compiler version out of: $compilerLine"
            'manifest に壊れた値を書くくらいなら止まる。'
        ) -join "`n"
    }
    $compiler = $versionMatch.Groups[1].Value

    $manifest = [ordered]@{
        schema              = 1
        opencvTag           = $Config.Tag
        configHash          = $ConfigHash
        artifactName        = $ArtifactName
        # 構成から取る。決め打ちにすると manifest が実物と食い違い、
        # 「成果物に何が入っているか」の申告が嘘になる（M3 Task 2 のレビューで
        # 発見。macOS / Linux でビルドしても windows-x64 と記録されていた）。
        platform            = $Config.Platform
        generator           = $Config.Toolchain.Generator
        buildType           = $Config.Toolchain.BuildType
        cxxCompiler         = $compiler
        requestedModules    = @($Config.Modules)
        builtModules        = @($modules)
        cmakeArgs           = @($Config.CMakeArgs)
        # bundle された third-party の実バージョン。roadmap M1 の完了条件
        # 「build-manifest.json に依存 version を含む」を満たす。
        # Get-OpenCvDependencyVersions を参照 — "Media I/O:" section の
        # バージョン付きエントリのみで、libclapack のようにバージョンが
        # 報告されないものはここに現れない（捏造しない）。
        dependencyVersions  = $DependencyVersions
    }

    $path = Join-Path $OpenCvRoot 'build-manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "wrote $path" -ForegroundColor Green
}

switch ($Command) {
    'status'  { Show-Status }
    'build'   { Invoke-Build }
    'verify'  { Invoke-Verify | Out-Null; Write-Host 'allowlist OK' -ForegroundColor Green }
    'clean'   {
        Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $WorkRoot -ErrorAction SilentlyContinue
    }
    'restore' { Invoke-Restore }
}
