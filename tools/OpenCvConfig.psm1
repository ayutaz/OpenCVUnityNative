#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    ビルド構成の読み込みと構成ハッシュ。

    ハッシュは「この構成でビルドすると何ができるか」を一意に表す。
    tag、module list、CMake flags、toolchain のいずれかが変われば別の値になり、
    artifact 名が変わるので、古い成果物が黙って再利用されることがない。
    M1 の完了条件の 1 つがこれである。
#>

function Get-OpenCvConfig {
    [CmdletBinding()]
    param()

    $path = Join-Path $PSScriptRoot 'opencv-config.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "OpenCV build configuration not found at '$path'."
    }

    $raw = Import-PowerShellDataFile -LiteralPath $path
    return [pscustomobject]@{
        Tag       = [string]$raw.Tag
        Modules   = [string[]]$raw.Modules
        Toolchain = $raw.Toolchain
        CMakeArgs = [string[]]$raw.CMakeArgs
    }
}

function Get-OpenCvConfigHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    # 正規形にしてから hash を取る。引数の並び順が変わっただけで
    # ハッシュが変わると、意味の無い再ビルドが発生する。
    $canonical = @(
        "tag=$($Config.Tag)"
        "modules=$(($Config.Modules | Sort-Object) -join ',')"
        "generator=$($Config.Toolchain.Generator)"
        "arch=$($Config.Toolchain.Architecture)"
        "buildtype=$($Config.Toolchain.BuildType)"
        "cmake=$(($Config.CMakeArgs | Sort-Object) -join ' ')"
    ) -join "`n"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return -join ($digest[0..5] | ForEach-Object { $_.ToString('x2') })
}

function Get-OpenCvArtifactName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $hash = Get-OpenCvConfigHash -Config $Config
    return "opencv-$($Config.Tag)-windows-x64-$hash"
}

function Get-OpenCvRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $hash = Get-OpenCvConfigHash -Config $Config
    return Join-Path $repoRoot "third_party/opencv/$hash"
}

Export-ModuleMember -Function Get-OpenCvConfig, Get-OpenCvConfigHash,
    Get-OpenCvArtifactName, Get-OpenCvRoot
