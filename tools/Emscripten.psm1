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
    # **これは衛生の話ではなく、動くかどうかの話だった。** 設定しないまま
    # 試したとき、3 行の .cpp のコンパイルが 15 分返らなかった —— 書けない
    # 場所へ書こうとしていたためである。**cache を build/ へ移した後は
    # 初回 7 秒・2 回目 0.8 秒**（2026-09-03 実測、Windows）。
    # **「Unity の 1.6 GB の cache を再利用できなくなる分だけ遅くなる」と
    # 考えたが、逆だった。**
    $cacheDir = Join-Path (Split-Path -Parent $Destination) 'cache'

    <#
        **LLVM と binaryen の在り処を決め打ちしない。**

        木の形が出所で違う（2026-09-03 に両方を実測）:

          Unity 同梱 : <Root>/llvm/clang.exe        <Root>/binaryen/bin/wasm-opt.exe
          emsdk      : <Root>/bin/clang             <Root>/bin/wasm-opt

        最初は Unity の形だけを書いていて、**CI（emsdk）で落ちた**:

            emcc: error: '.../emsdk-main/upstream/llvm/clang ...' failed:
            [Errno 2] No such file or directory

        **手元で通ったことが CI で通る保証にならない**、の実例である。
        **在るはずの実行ファイルを探して、見つかった側を使う。**
        見つからなければ **throw する** —— 間違ったパスを config に書くと、
        エラーが出るのは emcc を呼んだ時点まで遅れる。
    #>
    function Find-ToolRoot([string]$Base, [string[]]$Relatives, [string]$Exe, [string]$What) {
        foreach ($rel in $Relatives) {
            $dir = if ($rel) { Join-Path $Base $rel } else { $Base }
            foreach ($name in @($Exe, "$Exe.exe")) {
                if (Test-Path -LiteralPath (Join-Path $dir $name)) { return $dir }
                if (Test-Path -LiteralPath (Join-Path (Join-Path $dir 'bin') $name)) { return $dir }
            }
        }
        throw "$What が見つかりません（$Exe を探しました）。Root='$Base'、探した先: $($Relatives -join ', ')"
    }

    $llvmRoot     = Find-ToolRoot $Root @('llvm', 'bin', '')       'clang'    'LLVM'
    $binaryenRoot = Find-ToolRoot $Root @('binaryen', 'bin', '')   'wasm-opt' 'binaryen'

    $lines = @(
        '# tools/Emscripten.psm1 が生成した。手で編集しても次の実行で上書きされる。'
        "CACHE = $(ToPy $cacheDir)"
        "LLVM_ROOT = $(ToPy $llvmRoot)"
        "BINARYEN_ROOT = $(ToPy $binaryenRoot)"
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
    # emsdk の emscripten-version.txt は **引用符つき**で書く（"3.1.39"）。
    # Unity 同梱は引用符なし（3.1.39-git）。両方を受ける。
    $version = (Get-Content -LiteralPath $versionTxt -Raw).Trim().Trim('"')

    $toolchainFile = Join-Path $emscriptenDir 'cmake/Modules/Platform/Emscripten.cmake'
    if (-not (Test-Path -LiteralPath $toolchainFile)) {
        throw "Emscripten の CMake toolchain が見つかりません: $toolchainFile"
    }

    <#
        **config を作るのは、既に在るものが無いときだけである。**

        emsdk は導入時に自分で `.emscripten` を書き、`EM_CONFIG` を環境に置く。
        **その上に自作の config を被せると壊れる**（2026-09-03 に CI で実測）——
        emsdk の木では node が `$EMSDK/node/<ver>/bin/node` に在り、
        **`upstream/` の下には無い。** こちらの生成器はそこを探すので
        `NODE_JS` が存在しないパスになり、**すべての try_compile が失敗した**
        （`HAVE_CXX_FSIGNED_CHAR - Failed` から始まり、最後は
        `Compiler doesn't support baseline optimization flags`）。

        **他人が用意したものを尊重する。** 自作の config は Unity 同梱
        （config を持たない）のためにだけ要る。
    #>
    if ($env:EM_CONFIG -and (Test-Path -LiteralPath $env:EM_CONFIG)) {
        $config = $env:EM_CONFIG
        Write-Verbose "既存の EM_CONFIG を使う: $config"
    } else {
        $config = Write-EmscriptenConfig -Root $Root -Destination (Join-Path $script:RepoRoot 'build/emscripten/.emscripten')
    }

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
