#Requires -Version 7.0
<#
    OpenCV のビルドと取得。

    既定は restore（CI が作った artifact を download する）で、build は
    ローカルで再現を検証するための遅い経路である。M1 の目的の 1 つが
    「開発ループから 30〜60 分のビルドを追い出す」ことなので、
    日常的に build を叩く運用にはしないこと。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('restore', 'build', 'verify', 'status', 'clean')]
    [string]$Command = 'restore'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

    Invoke-Checked { cmake @cmakeArgs } 'configure OpenCV'
    Invoke-Checked {
        cmake --build $buildRoot --config $Config.Toolchain.BuildType --target INSTALL
    } 'build and install OpenCV'

    $modules = Invoke-Verify
    Write-BuildManifest -Modules $modules
}

function Invoke-Restore {
    if (Test-Path -LiteralPath (Join-Path $OpenCvRoot 'build-manifest.json')) {
        Write-Host "OpenCV $($Config.Tag) ($ConfigHash) is already present." -ForegroundColor Green
        return
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw @(
            'gh CLI が見つかりません。restore は GitHub Actions の artifact を取得します。'
            'https://cli.github.com/ を入れて `gh auth login` するか、'
            'ローカルで再現する場合は `./tools/opencv.ps1 build` を使ってください（30-60 分）。'
        ) -join "`n"
    }

    New-Item -ItemType Directory -Force -Path $OpenCvRoot | Out-Null

    Write-Host "==> download artifact '$ArtifactName'" -ForegroundColor Cyan
    & gh run download --name $ArtifactName --dir $OpenCvRoot 2>&1 | Write-Host

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $OpenCvRoot 'build-manifest.json'))) {
        Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
        throw @(
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
            'ローカルで再現する場合は `./tools/opencv.ps1 build`（30-60 分）。'
        ) -join "`n"
    }

    # download した物が本当に期待の構成か確認する。
    # artifact 名が一致していても中身が壊れている可能性はある。
    $manifest = Get-Content -LiteralPath (Join-Path $OpenCvRoot 'build-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.configHash -ne $ConfigHash) {
        Remove-Item -Recurse -Force $OpenCvRoot -ErrorAction SilentlyContinue
        throw "artifact の configHash は '$($manifest.configHash)' で、期待する '$ConfigHash' と異なります。"
    }

    Invoke-Verify | Out-Null
    Write-Host "restored OpenCV $($Config.Tag) ($ConfigHash)" -ForegroundColor Green
}

function Invoke-Verify {
    $verify = Join-Path $PSScriptRoot 'verify-opencv-artifact.ps1'
    Write-Host '==> verify dependency allowlist' -ForegroundColor Cyan
    $modules = & pwsh -NoProfile -File $verify -Root $OpenCvRoot
    if ($LASTEXITCODE -ne 0) { throw 'dependency allowlist verification failed' }
    return $modules
}

function Write-BuildManifest([string[]]$Modules) {
    $compiler = (cmake --system-information 2>$null |
        Select-String -Pattern '^CMAKE_CXX_COMPILER_VERSION ' |
        Select-Object -First 1) -replace '^CMAKE_CXX_COMPILER_VERSION\s+', ''

    $manifest = [ordered]@{
        schema           = 1
        opencvTag        = $Config.Tag
        configHash       = $ConfigHash
        artifactName     = $ArtifactName
        platform         = 'windows-x64'
        generator        = $Config.Toolchain.Generator
        buildType        = $Config.Toolchain.BuildType
        cxxCompiler      = ($compiler -replace '"', '').Trim()
        requestedModules = @($Config.Modules)
        builtModules     = @($modules)
        cmakeArgs        = @($Config.CMakeArgs)
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
