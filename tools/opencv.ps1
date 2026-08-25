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
    [string]$Command = 'restore'
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

$Config       = Get-OpenCvConfig
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

    $cmakeArgs = @(
        '-S', $sourceRoot
        '-B', $buildRoot
        '-G', $Config.Toolchain.Generator
        '-A', $Config.Toolchain.Architecture
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
    $configureOutputLines = & cmake @cmakeArgs 2>&1
    $configureOutputLines | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "configure OpenCV failed with exit code $LASTEXITCODE" }

    Invoke-Checked {
        cmake --build $buildRoot --config $Config.Toolchain.BuildType --target INSTALL
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
        & gh run download --name $ArtifactName --dir $OpenCvRoot 2>&1 | Write-Host

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $manifestPath)) {
            Write-RestoreFailure (@(
                "artifact '$ArtifactName' を取得できませんでした。"
                ''
                '考えられる原因:'
                '  1. この構成でまだ一度もビルドしていない'
                '  2. artifact が失効した（GitHub Actions の保持上限は 90 日）'
                '  3. gh が認証されていない（`gh auth status` で確認）'
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
    $compiler = (cmake --system-information 2>$null |
        Select-String -Pattern '^CMAKE_CXX_COMPILER_VERSION ' |
        Select-Object -First 1) -replace '^CMAKE_CXX_COMPILER_VERSION\s+', ''

    $manifest = [ordered]@{
        schema              = 1
        opencvTag           = $Config.Tag
        configHash          = $ConfigHash
        artifactName        = $ArtifactName
        platform            = 'windows-x64'
        generator           = $Config.Toolchain.Generator
        buildType           = $Config.Toolchain.BuildType
        cxxCompiler         = ($compiler -replace '"', '').Trim()
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
