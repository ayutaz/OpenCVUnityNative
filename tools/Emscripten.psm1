#!/usr/bin/env pwsh
<#
    Emscripten の toolchain を解決し、駆動できる状態にする（M6）。

    **同梱の Emscripten は、そのままでは動かない。** 実測（2026-09-03、
    Unity 6000.3.16f1）:

        emcc: warning: config file not found: ...\emscripten\.emscripten
        emcc: error: LLVM_ROOT not set in config (...), and `clang` not found in PATH

    Unity は自分でビルドするときに config を組み立てているので、こちらから
    使うときも同じことをする必要がある。**その組み立てをここ 1 箇所に置く。**

    **取り得る出所は 2 つある:**

      unity — Unity の PlaybackEngines/WebGLSupport に同梱されたもの。
              **ローカルの正本**。Unity が実際に使う木そのものなので、
              版がずれようがない。
      emsdk — CI が入れるもの。**CI に Unity は無い**（build-opencv も
              ci-native も Unity を起動しない）ので、そちらは emsdk を使う。
              **版が Unity とずれないことは tools/assert-emscripten-version.ps1
              と tools/tests/EmscriptenVersion.Tests.ps1 が対で見る。**

    非 ASCII を出すので、呼ぶ側は OutputEncoding を設定しておくこと。
#>

Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

<#
    ProjectVersion.txt の Unity 版から、同梱 Emscripten の在り処を組み立てる。
    見つからなければ $null を返す（呼ぶ側が emsdk を見に行く）。
#>
function Get-UnityEmscriptenRoot {
    [CmdletBinding()]
    param([string]$UnityRoot)

    $versionFile = Join-Path $script:RepoRoot 'tests/UnityProject/ProjectSettings/ProjectVersion.txt'
    if (-not (Test-Path -LiteralPath $versionFile)) { return $null }
    $m = [regex]::Match((Get-Content -LiteralPath $versionFile -Raw), 'm_EditorVersion:\s*(?<v>\S+)')
    if (-not $m.Success) { return $null }
    $version = $m.Groups['v'].Value

    $candidates = @()
    if ($UnityRoot) {
        $candidates += $UnityRoot
    } elseif ($IsWindows) {
        $candidates += "C:\Program Files\Unity\Hub\Editor\$version\Editor"
    } elseif ($IsMacOS) {
        $candidates += "/Applications/Unity/Hub/Editor/$version/Unity.app/Contents"
    } else {
        $candidates += "$HOME/Unity/Hub/Editor/$version/Editor"
        $candidates += '/opt/unity/Editor'
    }

    foreach ($root in $candidates) {
        foreach ($rel in @('Data/PlaybackEngines/WebGLSupport', 'PlaybackEngines/WebGLSupport')) {
            $p = Join-Path (Join-Path $root $rel) 'BuildTools/Emscripten'
            if (Test-Path -LiteralPath (Join-Path $p 'emscripten')) { return $p }
        }
    }
    return $null
}

<#
    `.emscripten` config を書き出す。

    **リポジトリを汚さない** —— 書き出し先は build/ の下（.gitignore 済み）。
    Unity の導入先は書き込めないことがある（Program Files）ので、そちらへは
    書かない。

    **毎回書き直す。** 中身は Root から機械的に決まるので、古い config が
    残っていると「Unity を入れ替えたのに前の LLVM を指している」という、
    最も分かりにくい壊れ方をする。
#>
function Write-EmscriptenConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination
    )

    $nodeExe = if ($IsWindows) { 'node.exe' } else { 'node' }
    $node = Join-Path (Join-Path $Root 'node') $nodeExe
    if (-not (Test-Path -LiteralPath $node)) {
        # emsdk の木は node/<version>/bin/node のように 1 段深いことがある。
        $found = Get-ChildItem -LiteralPath (Join-Path $Root 'node') -Recurse -File -Filter $nodeExe -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { $node = $found.FullName }
    }

    # python は emscripten 自身の実行に要る。同梱に在ればそれを、無ければ PATH のもの。
    $pythonExe = if ($IsWindows) { 'python.exe' } else { 'python3' }
    $python = Join-Path (Join-Path $Root 'python') $pythonExe
    if (-not (Test-Path -LiteralPath $python)) {
        $cmd = Get-Command $pythonExe -ErrorAction SilentlyContinue
        $python = if ($cmd) { $cmd.Source } else { $null }
    }

    # emscripten の config は python の構文である。パスの区切りはそのまま書けないので
    # スラッシュへ寄せる（Windows でも emscripten 側はスラッシュを受ける）。
    function ToPy([string]$p) { if ($null -eq $p) { "''" } else { "'" + ($p -replace '\\', '/') + "'" } }

    # **cache は build/ の下に置く。** 既定のままだと Emscripten は
    # <EMSCRIPTEN_ROOT>/cache、つまり **Unity の導入先の中**へ書く
    # （実測: Unity 6000.3.16f1 の同梱には 1.6 GB の cache が既に在り、
    # 2026-06-27 付だった —— Unity 自身のものである）。
    #
    # **他人の導入先に書かない。** ビルドの副作用で Unity の木が変わる状態は、
    # 「動かなくなったとき何を戻せばいいか」が誰にも分からなくなる。
    #
    # **代償は初回のビルド時間である** —— Unity の cache を再利用しないので
    # sysroot をこちらで作り直す。CI は emsdk を cold から始めるのでどのみち
    # 同じ costs を払う。
    $cacheDir = Join-Path (Split-Path -Parent $Destination) 'cache'

    $lines = @(
        '# tools/Emscripten.psm1 が生成した。手で編集しても次の実行で上書きされる。'
        "CACHE = $(ToPy $cacheDir)"
        "LLVM_ROOT = $(ToPy (Join-Path $Root 'llvm'))"
        "BINARYEN_ROOT = $(ToPy (Join-Path $Root 'binaryen'))"
        "EMSCRIPTEN_ROOT = $(ToPy (Join-Path $Root 'emscripten'))"
        "NODE_JS = $(ToPy $node)"
        "PYTHON = $(ToPy $python)"
        "COMPILER_ENGINE = NODE_JS"
        "JS_ENGINES = [NODE_JS]"
    )

    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $Destination -Value ($lines -join "`n") -Encoding utf8NoBOM
    return $Destination
}

<#
    使える Emscripten を 1 つ決めて返す。

    返すのは hashtable:
      Root                — toolchain の根（llvm / binaryen / emscripten を含む）
      Source              — 'unity' か 'emsdk'
      Version             — emscripten-version.txt の値（'3.1.39-git' のような生の値）
      EmCC / EmPP / EmAr  — 実行ファイルのパス
      CMakeToolchainFile  — 同梱の Emscripten.cmake
      ConfigFile          — 生成した .emscripten

    **見つからなければ throw する。** 「無いので飛ばす」経路を作らない。
#>
function Get-EmscriptenToolchain {
    [CmdletBinding()]
    param(
        # 明示的に渡す（CI が emsdk を入れた場所など）。環境変数 OCVU_EMSCRIPTEN_ROOT でも可。
        [string]$Root,
        [string]$UnityRoot
    )

    $source = $null
    if (-not $Root -and $env:OCVU_EMSCRIPTEN_ROOT) { $Root = $env:OCVU_EMSCRIPTEN_ROOT }
    if ($Root) {
        $source = 'emsdk'
    } else {
        $Root = Get-UnityEmscriptenRoot -UnityRoot $UnityRoot
        $source = 'unity'
    }

    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) {
        throw @(
            'Emscripten の toolchain が見つかりません。'
            '次のどちらかを用意してください:'
            '  - Unity Hub で WebGL Build Support を導入する（ローカルの正本）'
            '  - 環境変数 OCVU_EMSCRIPTEN_ROOT に emsdk の upstream ディレクトリを渡す（CI 用）'
            ''
            '版は tools/emscripten-versions.psd1 が正本で、'
            'tools/assert-emscripten-version.ps1 が Unity の実物と突き合わせます。'
        ) -join "`n"
    }

    $emscriptenDir = Join-Path $Root 'emscripten'
    $versionTxt = Join-Path $emscriptenDir 'emscripten-version.txt'
    if (-not (Test-Path -LiteralPath $versionTxt)) {
        throw "Emscripten の版ファイルが見つかりません: $versionTxt (Root='$Root')"
    }
    $version = (Get-Content -LiteralPath $versionTxt -Raw).Trim()

    $toolchainFile = Join-Path $emscriptenDir 'cmake/Modules/Platform/Emscripten.cmake'
    if (-not (Test-Path -LiteralPath $toolchainFile)) {
        throw "Emscripten の CMake toolchain が見つかりません: $toolchainFile"
    }

    # 同梱には emcc（拡張子なし）と emcc.bat が並ぶ。**py を直接呼ぶ**ことで
    # OS ごとの分岐と、.bat が config を見つけられない問題を同時に避ける。
    $config = Write-EmscriptenConfig -Root $Root -Destination (Join-Path $script:RepoRoot 'build/emscripten/.emscripten')

    return @{
        Root               = $Root
        Source             = $source
        Version            = $version
        EmCC               = Join-Path $emscriptenDir 'emcc.py'
        EmPP               = Join-Path $emscriptenDir 'em++.py'
        EmAr               = Join-Path $emscriptenDir 'emar.py'
        CMakeToolchainFile = $toolchainFile
        ConfigFile         = $config
        Python             = $(
            $exe = if ($IsWindows) { 'python.exe' } else { 'python3' }
            $bundled = Join-Path (Join-Path $Root 'python') $exe
            if (Test-Path -LiteralPath $bundled) { $bundled }
            else { (Get-Command $exe -ErrorAction SilentlyContinue)?.Source }
        )
    }
}

Export-ModuleMember -Function Get-EmscriptenToolchain, Get-UnityEmscriptenRoot, Write-EmscriptenConfig
