#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    ビルド構成の読み込みと構成ハッシュ。

    ハッシュは「この構成でビルドすると何ができるか」を一意に表す。
    opencv-config.psd1 の**どのキーであれ**変われば別の値になり、artifact 名が
    変わるので、古い成果物が黙って再利用されることがない。M1 の完了条件の
    1 つがこれである。

    以前は Get-OpenCvConfig が Tag / Modules / Toolchain / CMakeArgs の
    4 プロパティだけを名指しで psd1 から抜き出し、Get-OpenCvConfigHash も
    その 4 つだけを名指しでハッシュに混ぜていた。これは列挙式（列挙した
    ものしか見ない）で、psd1 に新しいトップレベルキー（例: ContribTag）を
    足しても、Toolchain に新しいキー（例: Toolset）を足しても、Get-OpenCvConfig
    の時点で静かに落ちるため、ハッシュはおろか呼び出し側にすら届かなかった
    （レビューで実証済み: Toolchain.Toolset を書き換えてもハッシュが
    変化しない）。
    今は逆に構造的である: Get-OpenCvConfig は psd1 の全キーを保持し、
    Get-OpenCvConfigHash は Config オブジェクトを再帰的に正規化 JSON へ
    落としてからハッシュを取る。「どのキーを見るか」を列挙しない設計にする
    ことで、次に増えるキーを個別に配線し忘れるという事故そのものを構造的に
    閉じる。

    M3 Task 1 で Get-OpenCvConfig は「psd1 の全トップレベルキーをそのまま
    保持する」から「Platform / Tag / Modules / Toolchain / CMakeArgs の
    5 プロパティを明示的に組み立てる」へ変わった。Toolchain は
    psd1 の Toolchains[$Platform]（platform ごとの 1 ブロック）を選んで
    渡し、CMakeArgs は共通 CMakeArgs と PlatformCMakeArgs[$Platform] を
    結合する。理由は、「platform ごとに 1 つを選ぶ」「複数配列を結合する」
    という解決処理自体が、単純な pass-through では表現できないため。
    Toolchain ブロックの中身や CMakeArgs の要素は依然として素通しなので、
    その内側に新しいキーが増えたときは今まで通り自動的にハッシュへ混ざる。
    一方、psd1 に新しいトップレベルキー（例: ContribTag）を足したときは、
    この関数が明示的に拾わない限りハッシュに混ざらない —
    Get-OpenCvConfigHash 自体は変わらず構造的（列挙しない）だが、
    Get-OpenCvConfig の「どの 5 プロパティを組み立てるか」は列挙式に
    戻っている。新しいトップレベルキーを足すときはこの関数を必ず更新すること。
#>

<#
    実行中の platform を返す。

    PowerShell 7 の $IsWindows / $IsMacOS / $IsLinux を使う。uname に頼らない
    のは、Windows に uname が無いか、あっても MSYS のものが混ざるためである。

    アーキテクチャは RuntimeInformation から取る。macOS は Apple Silicon の
    arm64 のみ対応する（Intel Mac は M3 の対象外 — 対応するなら platform を
    1 つ足す作業になり、この関数がその増やし方を示している）。
#>
function Get-OpenCvPlatform {
    [CmdletBinding()]
    param()

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

    if ($IsWindows) {
        if ($arch -ne 'X64') { throw "Windows on $arch is not supported (x64 only)." }
        return 'windows-x64'
    }
    if ($IsMacOS) {
        if ($arch -ne 'Arm64') { throw "macOS on $arch is not supported (Apple Silicon only)." }
        return 'macos-arm64'
    }
    if ($IsLinux) {
        if ($arch -ne 'X64') { throw "Linux on $arch is not supported (x64 only)." }
        return 'linux-x64'
    }

    throw 'Unable to determine the platform. $IsWindows / $IsMacOS / $IsLinux were all false.'
}

function Get-OpenCvConfig {
    [CmdletBinding()]
    param(
        # 省略時は実行中の platform。明示すると他 platform の構成も引ける
        # （CI が全 platform のハッシュを算出するのに使う）。
        [string]$Platform
    )

    $path = Join-Path $PSScriptRoot 'opencv-config.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "OpenCV build configuration not found at '$path'."
    }

    if (-not $Platform) { $Platform = Get-OpenCvPlatform }

    $raw = Import-PowerShellDataFile -LiteralPath $path

    # 未知の platform を黙って通さない。既定に倒すと、対応していない環境で
    # 「Windows の構成で macOS をビルドする」ような事故が静かに成立する。
    if (-not $raw.Toolchains.ContainsKey($Platform)) {
        $known = ($raw.Toolchains.Keys | Sort-Object) -join ', '
        throw "Unknown platform '$Platform'. Known platforms: $known"
    }
    if (-not $raw.PlatformCMakeArgs.ContainsKey($Platform)) {
        throw "opencv-config.psd1 has a toolchain for '$Platform' but no PlatformCMakeArgs entry."
    }

    return [pscustomobject]@{
        Platform  = $Platform
        Tag       = [string]$raw.Tag
        Modules   = [string[]]$raw.Modules
        Toolchain = $raw.Toolchains[$Platform]
        CMakeArgs = [string[]](@($raw.CMakeArgs) + @($raw.PlatformCMakeArgs[$Platform]))
    }
}

# $Value を「キーの並び順にも配列の並び順にも依存しない」正規形の JSON 文字列
# にする。Get-OpenCvConfigHash がこれをハッシュ入力にする。
#
#   - Hashtable / PSCustomObject: キー名でソートしてからオブジェクトとして
#     出力する（列挙順は Hashtable の実装依存で、変わってもハッシュが
#     変わってはならない）。
#   - 配列（文字列以外の IEnumerable）: このプロジェクトの配列（Modules /
#     CMakeArgs のような list）はすべて「順序を持たない集合」なので、
#     各要素を正規形にしてからソートする。並び替えただけの構成が意味も無く
#     再ビルドを起こす事故を防ぐ（既存の「reordering は不変」という契約を
#     個別の 2 フィールドだけでなく、構造全体に対して保つ）。
#   - スカラー: ConvertTo-Json に委譲する。文字列のエスケープや要素境界は
#     JSON の役目にし、区切り文字の単純な join による衝突を避ける
#     （["-DAAA=1","-DBBB=2"] と ["-DAAA=1 -DBBB=2"] が同じ文字列になる、
#     という前ラウンドの injective 性の議論と同じ理由）。
function ConvertTo-CanonicalJson {
    [CmdletBinding()]
    param([AllowNull()][Parameter(Mandatory)] $Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys) | Sort-Object
        $pairs = foreach ($key in $keys) {
            $keyJson = ConvertTo-Json -Compress -InputObject ([string]$key)
            "$($keyJson):$(ConvertTo-CanonicalJson -Value $Value[$key])"
        }
        return '{' + ($pairs -join ',') + '}'
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $props = @($Value.PSObject.Properties) | Sort-Object -Property Name
        $pairs = foreach ($prop in $props) {
            $keyJson = ConvertTo-Json -Compress -InputObject $prop.Name
            "$($keyJson):$(ConvertTo-CanonicalJson -Value $prop.Value)"
        }
        return '{' + ($pairs -join ',') + '}'
    }

    if (($Value -is [System.Collections.IEnumerable]) -and (-not ($Value -is [string]))) {
        $items = @(@($Value) | ForEach-Object { ConvertTo-CanonicalJson -Value $_ } | Sort-Object)
        return '[' + ($items -join ',') + ']'
    }

    return (ConvertTo-Json -Compress -InputObject $Value)
}

function Get-OpenCvConfigHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    # $Config を丸ごと正規化 JSON にしてからハッシュを取る。個々のキーを
    # 名指しで拾い上げない — 新しいキーが増えても、それを見るコードを
    # 個別に書き足さなくても自動的にハッシュへ混ざる。
    $canonical = ConvertTo-CanonicalJson -Value $Config
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
    return "opencv-$($Config.Tag)-$($Config.Platform)-$hash"
}

function Get-OpenCvRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $hash = Get-OpenCvConfigHash -Config $Config
    return Join-Path $repoRoot "third_party/opencv/$hash"
}

# OpenCV の configure summary（cv::getBuildInformation() が実行時に返す
# ものと同じテキスト。tools/opencv.ps1 の Invoke-Build がまだビルドして
# いない opencv_unity_native.dll を経由せず、cmake の configure stdout から
# そのまま渡す）から、bundle された third-party のバージョンだけを拾う。
#
# roadmap M1 の完了条件「build-manifest.json に依存 version を含む」を
# 満たすための入力。
#
# 全文を「<name>: ... (ver X)」で無差別に正規表現走査すると、
# C++ Compiler や CMake 自身の版数（同じ書式を使う）まで拾ってしまう。
# 「Media I/O:」section だけに絞る — ZLib / JPEG / PNG のようにバージョンを
# 持つ実際の codec 依存はここにしか出ない。「Other third-party libraries:」
# section は対象に含めない: Flatbuffers のように、ビルドしていない
# module（dnn / gapi）向けの検出結果までバージョン付きで載ることがあり、
# THIRD_PARTY_NOTICES.md がシンボルテーブル調査で「リンクされていない」と
# 確認した内容と食い違う（同ファイルの「present but not linked」節を参照）。
# libclapack はどの section にもバージョン文字列が出ない（"YES (Built-In
# libclapack)" のみ）ため、この関数は捕捉しない — 無いものを捏造しない。
function Get-OpenCvDependencyVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BuildInformation)

    $targetSections = @('Media I/O')
    $versions = [ordered]@{}
    $inTargetSection = $false

    foreach ($rawLine in ($BuildInformation -split "`r?`n")) {
        # この関数には形式の違う 2 つの入力が来る。
        #
        #   1. cmake configure の stdout（tools/opencv.ps1 の本番経路）。
        #      OpenCV の summary は message(STATUS ...) で出るので、cmake が
        #      各行の先頭に "-- " を付ける。
        #   2. cv::getBuildInformation() の戻り値（実行時・テスト）。前置は無い。
        #
        # 内容は同じだが行頭が違う。前置を剥がさずに '^\s{2}' で section header を
        # 拾う実装は 2 を通して 1 を素通しし、本番だけが常に 0 件を返していた
        # （'-' は \s ではない）。テストが 2 だけを使っていたため緑のままだった。
        # 呼び出し側にどちらか一方を強いるのではなく、ここで正規化する。
        $line = $rawLine -replace '^--\s?', ''

        if ($line -match '^\s{2}(?<header>[A-Za-z][A-Za-z0-9/ -]*?):\s*$') {
            $inTargetSection = $targetSections -contains $Matches['header'].Trim()
            continue
        }
        if (-not $inTargetSection) { continue }
        if ($line -match '^\s{4}(?<name>[A-Za-z][A-Za-z0-9_+ /-]*?):\s+.*\((?:ver\s+)?(?<version>[0-9][^\s)]*)\)\s*$') {
            $versions[$Matches['name'].Trim()] = $Matches['version']
        }
    }

    return $versions
}

Export-ModuleMember -Function Get-OpenCvPlatform, Get-OpenCvConfig, Get-OpenCvConfigHash,
    Get-OpenCvArtifactName, Get-OpenCvRoot, Get-OpenCvDependencyVersions
