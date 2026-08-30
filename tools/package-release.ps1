#Requires -Version 7.0

<#
    配布物一式（checksums / SBOM / build manifest）を出力する。

    SBOM は「成果物に何が入っているか」の申告である。**手で書かない** —
    申告と実物が食い違う状態は、M1 で構成ハッシュに起きたのと同じ欠陥に
    なる。復元済み artifact のライセンス一覧から機械的に組み立てる。

    ライセンスの配置は platform で変わる（tools/verify-opencv-artifact.ps1 と
    同じ理解）:
      Windows          etc/licenses/<file>
      macOS/Linux/iOS  share/licenses/opencv5/<file>
      Android          sdk/etc/licenses/<file>   ← install の木ごと sdk/ の下

    **Android を落としていた。** verify-opencv-artifact.ps1 には sdk/ を
    教えたのに、こちらには教えていなかった（M4 のレビューで発見）。
    release.yml は tag と手動でしか起動しないので、CI が全部緑のまま
    「tag を打った瞬間に android-arm64 の job が落ちて Release が 1 件も
    作られない」状態が残っていた。
    どれか 1 つしか見ないと SBOM が黙って空になる。**全部を探し、
    見つかった全ファイルから component を拾う。どちらにも何も無ければ
    失敗する** — 0 件を「申告することが無い」ではなく「検出に失敗した」
    として扱う。
#>

param(
    [Parameter(Mandatory)][string]$OutputDir,

    # 既定は現在復元されている artifact（実行中の platform）。テストが
    # 合成ツリーを指して「ライセンスが無ければ失敗する」ことを Windows /
    # Unix どちらの配置でも確かめられるよう、明示的に上書きできるようにする
    # （tools/verify-artifact-linkage.ps1 の -Root と同じ考え方）。
    [string]$Root,
    [string]$Platform,

    <#
        checksums.txt だけを出す。

        **全部入りの package 用である。** SBOM と build-manifest は復元済みの
        OpenCV artifact（= 実行中 platform のもの）から作るので、全 platform を
        束ねる job には元が無い。**統合版を捏造せずに、出せるものだけ出す。**

        checksums.txt は package を走査して作るので、全 platform 分の binary が
        置かれていればそのまま 3 行になる。SBOM / build-manifest /
        THIRD_PARTY_NOTICES は platform ごとの物が Release に付くので、
        全部入りの中身の説明はそちらが担う。
    #>
    [switch]$ChecksumsOnly
)

# param ブロックより後に置く。Set-StrictMode を先に置くと param(...) が
# 普通の関数呼び出しとして解釈され、$OutputDir 等が束縛されない
# （tools/verify-artifact-linkage.ps1 と同じ注意。このファイルの計画書の
# 例はこの順序を誤っていた）。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

<#
    **-ChecksumsOnly は復元済みの OpenCV artifact を要求しない。**

    checksums.txt は package を走査して作るだけで、OpenCV のツリーを一度も
    読まない。ところが以前はこの script が無条件に Get-OpenCvRoot の実在を
    要求していたので、**OpenCV を復元しない job から呼ぶと必ず落ちた** ——
    まさに release.yml の publish job がそれである（3 つの artifact を束ねる
    だけで、opencv.ps1 restore を走らせない）。tag を打った瞬間に Release が
    作られずに終わる形だった。

    SBOM の生成も同じ理由でここより後ろに置く。全部入り用に「統合 SBOM」を
    出してしまうと、**1 つの platform の OpenCV 構成を名乗る偽の申告**になる
    （workflow のコメントが「捏造しない」と書いている当のもの）。
#>
if (-not $ChecksumsOnly) {
    if (-not $Platform) { $Platform = Get-OpenCvPlatform }
    $config = Get-OpenCvConfig -Platform $Platform
    if (-not $Root) { $Root = Get-OpenCvRoot -Config $config }

    if (-not (Test-Path -LiteralPath $Root)) {
        [Console]::Error.WriteLine(@(
            "OpenCV artifact not found at $Root"
            "先に './tools/opencv.ps1 restore' を実行してください。"
        ) -join "`n")
        exit 1
    }
}


<#
    **checksums を先に作る。** これは package を走査するだけで、復元済みの
    OpenCV artifact を一度も読まない。以降の SBOM / build manifest /
    notices はすべて $Root（= その platform の OpenCV ツリー）に依存するので、
    順序を逆にすると -ChecksumsOnly が「OpenCV を復元していない job」から
    呼べなくなる —— それがまさに release.yml の publish job である
    （3 つの artifact を束ねるだけで opencv.ps1 restore を走らせない）。
#>
# --- checksums ---

# **配る binary の名前を、正本から読む。写さない。**
# 読めなければ落とす —— 空の一覧で進むと、以降の走査が 1 件も拾わず、
# 「plugin が無い」という誤った診断になる。
$packerPath = Join-Path $repoRoot 'tools/pack-upm-tarball.ps1'
$packerText = Get-Content -LiteralPath $packerPath -Raw
$packerBlock = [regex]::Match($packerText, '(?ms)^\$PlatformBinaries\s*=\s*\[ordered\]@\{(.*?)^\}')
if (-not $packerBlock.Success) {
    [Console]::Error.WriteLine("tools/pack-upm-tarball.ps1 から `$PlatformBinaries を読めませんでした。書き方が変わっています。")
    exit 1
}
$knownPluginNames = @([regex]::Matches($packerBlock.Groups[1].Value, "=\s*'Runtime/Plugins/([^']+)'") |
    ForEach-Object { Split-Path -Leaf $_.Groups[1].Value } | Sort-Object -Unique)
if ($knownPluginNames.Count -lt 3) {
    [Console]::Error.WriteLine("配る binary の名前を $($knownPluginNames.Count) 件しか読めませんでした（3 件以上あるはず）。")
    exit 1
}
$pluginRoot = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native'
$lines = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File |
    # **拡張子を列挙しない。** iOS の静的ライブラリは .a なので、
    # ('.dll','.dylib','.so') では **binary が 1 つも見つからず**、
    # 「先に dev.ps1 build を実行してください」という的外れな指示が出る。
    # 実測: release.yml の空撃ちで ios-arm64 がこれで落ちた（run 33340116600）。
    # **配る経路は tag と手動でしか走らないので、CI は緑のままだった。**
    # 正本（pack-upm-tarball.ps1 の $PlatformBinaries）が持つファイル名で照合する。
    Where-Object { $_.Name -in $knownPluginNames } |
    ForEach-Object {
        $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $rel = $_.FullName.Substring($pluginRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        "$h  $rel"
    })

if ($lines.Count -eq 0) {
    [Console]::Error.WriteLine(@(
        "no native plugin found under $pluginRoot"
        "先に './tools/dev.ps1 build' を実行してください。"
        '空の checksums.txt を出さない — 「検証すべきものが無い」を成功にしない。'
    ) -join "`n")
    exit 1
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDir 'checksums.txt') -Encoding utf8

if ($ChecksumsOnly) {
    Write-Host "==> checksums.txt only ($($lines.Count) binaries)" -ForegroundColor Green
    return
}

# --- SBOM: 実物のライセンス一覧から component を拾う ---
$licenseDirs = @(@(
    Join-Path $Root 'etc/licenses'
    Join-Path $Root 'share/licenses'
    # Android は install の木ごと sdk/ の下に作り直す（実測: build-opencv の
    # ログに sdk/etc/licenses/cpufeatures-LICENSE が出る）。
    Join-Path $Root 'sdk/etc/licenses'
    Join-Path $Root 'sdk/share/licenses'
) | Where-Object { Test-Path -LiteralPath $_ })

if ($licenseDirs.Count -eq 0) {
    [Console]::Error.WriteLine(@(
        "no license directory found under $Root (looked for etc/licenses, share/licenses, sdk/etc/licenses, sdk/share/licenses)"
        'cannot build an SBOM from evidence'
    ) -join "`n")
    exit 1
}

$licenseFiles = @($licenseDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Recurse })

$components = @($licenseFiles | ForEach-Object {
    # ファイル名の先頭が component 名（zlib-LICENSE -> zlib）
    ($_.Name -split '-')[0]
} | Sort-Object -Unique)

if ($components.Count -eq 0) {
    [Console]::Error.WriteLine(@(
        "no license files found under $($licenseDirs -join ', ')"
        'refusing to emit an SBOM that claims nothing'
    ) -join "`n")
    exit 1
}

$sbom = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = "opencv-unity-native-$($config.Platform)"
    documentNamespace = "https://github.com/ayutaz/OpenCVUnityNative/sbom/$($config.Platform)"
    creationInfo = [ordered]@{ creators = @('Tool: tools/package-release.ps1') }
    packages = @(
        [ordered]@{
            name = 'opencv'
            SPDXID = 'SPDXRef-Package-opencv'
            versionInfo = $config.Tag
            licenseDeclared = 'Apache-2.0'
        }
    ) + @($components | ForEach-Object {
        [ordered]@{
            name = $_
            SPDXID = "SPDXRef-Package-$_"
            licenseDeclared = 'NOASSERTION'
            comment = 'bundled by the pinned OpenCV build; see THIRD_PARTY_NOTICES.md'
        }
    })
}
$sbom | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $OutputDir 'sbom.spdx.json') -Encoding utf8


# --- build manifest ---
$manifestSource = Join-Path $Root 'build-manifest.json'
if (-not (Test-Path -LiteralPath $manifestSource)) {
    [Console]::Error.WriteLine("no build-manifest.json found under $Root")
    exit 1
}
Copy-Item -LiteralPath $manifestSource `
          -Destination (Join-Path $OutputDir 'build-manifest.json') -Force

# ライセンス通知も配布物に含める。roadmap の M3 完了条件は
# 「artifact manifest、checksums、THIRD_PARTY_NOTICES.md、SBOM」を 4 点で
# 求めている。SBOM は機械可読な一覧、通知は人が読む全文で役割が違うので、
# 片方でもう片方を代替できない。
$noticesSource = Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md'
if (-not (Test-Path -LiteralPath $noticesSource)) {
    [Console]::Error.WriteLine(@(
        "THIRD_PARTY_NOTICES.md not found at $noticesSource"
        '通知を欠いた配布物を出さない — 配るものの中身を説明する文書である。'
    ) -join "`n")
    exit 1
}
<#
    **通知に platform 固有のヘッダを足してから同梱する。**

    リポジトリの THIRD_PARTY_NOTICES.md は 1 つで、全 platform が同じ本文を
    配っていた。ところが実際に入っている component は platform で違う——
    v0.1.0 の実測では、macOS の成果物に clapack が無い（Apple の Accelerate を
    使うため）のに、macOS の配布物は CLAPACK のライセンス全文を含んでいた。

    法的には過剰開示なので危険ではない。しかし文書は「this build」を名乗って
    いるのに build ごとに変わらず、SBOM（実物から生成され platform 差が出る）
    と食い違う。読む人にはどちらが本当か分からない。

    本文を platform ごとに書き分けるのではなく、**実物から拾った component の
    一覧をヘッダに載せる。** 材料は SBOM と同じ $components——同じ証拠から
    作るので、SBOM と通知が食い違いようがない。
#>
$noticesBody = Get-Content -LiteralPath $noticesSource -Raw

$noticesHeader = @(
    '<!-- このヘッダは tools/package-release.ps1 が配布時に生成する。'
    '     リポジトリの THIRD_PARTY_NOTICES.md には無い。 -->'
    ''
    "# この配布物について（$($config.Platform)）"
    ''
    "- **platform**: $($config.Platform)"
    "- **OpenCV**: $($config.Tag)"
    "- **構成ハッシュ**: $(Get-OpenCvConfigHash -Config $config)"
    ''
    "この成果物のライセンスディレクトリに実際に存在した component は次の $($components.Count) 件である"
    '（同梱の `sbom.spdx.json` と同じ証拠から機械的に拾っている）:'
    ''
    ($components | ForEach-Object { "- ``$_``" })
    ''
    '**以下の本文は全 platform 共通で、上の一覧に無い component の節も含む。**'
    'それらはこの platform の成果物には入っていない。本文を platform ごとに'
    '削らないのは、削る判断そのものが間違えやすく、過剰に載せる側の誤りは'
    '害が小さいからである。どれが実際に入っているかは上の一覧が正本になる。'
    ''
    '---'
    ''
) -join "`n"

# 生成したヘッダが空でないこと。空のヘッダを黙って足すと、
# 「platform を書いた」つもりで何も書いていない配布物ができる。
if ($components.Count -lt 1 -or $noticesHeader -notmatch [regex]::Escape($config.Platform)) {
    [Console]::Error.WriteLine('failed to build the platform-specific notices header')
    exit 1
}

Set-Content -LiteralPath (Join-Path $OutputDir 'THIRD_PARTY_NOTICES.md') `
            -Value ($noticesHeader + $noticesBody) -Encoding utf8

Write-Host "==> release artifacts written to $OutputDir" -ForegroundColor Green
exit 0
