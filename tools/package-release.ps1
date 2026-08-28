#Requires -Version 7.0

<#
    配布物一式（checksums / SBOM / build manifest）を出力する。

    SBOM は「成果物に何が入っているか」の申告である。**手で書かない** —
    申告と実物が食い違う状態は、M1 で構成ハッシュに起きたのと同じ欠陥に
    なる。復元済み artifact のライセンス一覧から機械的に組み立てる。

    ライセンスの配置は platform で変わる（tools/verify-opencv-artifact.ps1 と
    同じ理解）:
      Windows      etc/licenses/<file>
      macOS/Linux  share/licenses/opencv5/<file>
    片方しか見ないと、Unix 系の SBOM が黙って空になる。**両方を探し、
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
    [string]$Platform
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

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# --- SBOM: 実物のライセンス一覧から component を拾う ---
$licenseDirs = @(@(
    Join-Path $Root 'etc/licenses'
    Join-Path $Root 'share/licenses'
) | Where-Object { Test-Path -LiteralPath $_ })

if ($licenseDirs.Count -eq 0) {
    [Console]::Error.WriteLine(@(
        "no license directory found under $Root (looked for etc/licenses and share/licenses)"
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

# --- checksums ---
$pluginRoot = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native'
$lines = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File |
    Where-Object { $_.Extension -in @('.dll', '.dylib', '.so') } |
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

    リポジトリの THIRD_PARTY_NOTICES.md は 1 つで、3 platform とも同じ本文を
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
    '**以下の本文は 3 platform 共通で、上の一覧に無い component の節も含む。**'
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
