#Requires -Version 7.0
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

<#
    tools/package-release.ps1 が出す配布物（checksums / SBOM / manifest）を検証する。

    SBOM は「成果物に何が入っているか」の申告であり、実物から機械的に組み立てる
    契約になっている。この検査で最も重要なのは正常系ではなく異常系: 申告すべき
    実体が無いときに、空の申告を「成功」として出してしまわないかである。

    ライセンスの配置は platform で変わる（tools/verify-opencv-artifact.ps1 と
    同じ理解）:
      Windows      etc/licenses/<file>
      macOS/Linux  share/licenses/opencv5/<file>
    片方しか見ない実装は、Unix 系のビルドで SBOM が黙って空になる。この
    マシンには macOS / Linux の実機artifactが無いので、配置だけを模した
    合成ツリーで両方の経路を確かめる。
#>

# $PSScriptRoot は tools/tests を指すので 2 段上がる。1 段だと tools/ に
# なり、tools/tools/... という存在しないパスになる（この誤りは計画書の
# Step 1 サンプルに実在した。tools/tests/VerifyArtifactLinkage.Tests.ps1 と
# 同じ書き方に揃える）。
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repoRoot 'tools/package-release.ps1'
$failures = @()

function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

function New-TempDir([string]$prefix) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("$prefix-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function New-SyntheticOpenCvRoot([string]$LicenseRelativeDir) {
    $root = New-TempDir 'ocvu-sbom-root'
    '{ "platform": "synthetic" }' | Set-Content -LiteralPath (Join-Path $root 'build-manifest.json') -Encoding utf8
    if ($LicenseRelativeDir) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $LicenseRelativeDir) | Out-Null
    }
    return $root
}

# --- 実物に対して通ること ---
$out = New-TempDir 'ocvu-pkg'
try {
    & pwsh -NoProfile -File $script -OutputDir $out | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'package-release exits 0'

    foreach ($f in @('checksums.txt', 'sbom.spdx.json')) {
        Assert-That (Test-Path -LiteralPath (Join-Path $out $f)) "$f is produced"
    }

    # SBOM は実物から作る。artifact が bundle している component が
    # 全部入っていること — 片方だけ更新される状態を作らない。
    $sbom = Get-Content -LiteralPath (Join-Path $out 'sbom.spdx.json') -Raw | ConvertFrom-Json
    $names = @($sbom.packages | ForEach-Object { $_.name })
    foreach ($c in @('zlib', 'libpng', 'libjpeg')) {
        Assert-That (@($names | Where-Object { $_ -like "*$c*" }).Count -gt 0) "the SBOM lists $c"
    }

    $lines = @(Get-Content -LiteralPath (Join-Path $out 'checksums.txt'))
    Assert-That ($lines.Count -gt 0) 'checksums.txt is not empty'
}
finally {
    Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
}

# --- SBOM: ライセンス配置が丸ごと無ければ失敗する ---
$noLicenseRoot = New-SyntheticOpenCvRoot -LicenseRelativeDir $null
$tmp = New-TempDir 'ocvu-pkg-out'
& pwsh -NoProfile -File $script -OutputDir $tmp -Root $noLicenseRoot -Platform 'windows-x64' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'no license directory at all fails rather than emitting an empty SBOM'
Remove-Item -Recurse -Force $noLicenseRoot, $tmp -ErrorAction SilentlyContinue

# --- SBOM: Windows レイアウト（etc/licenses/）が存在するが空なら失敗する ---
$emptyWinRoot = New-SyntheticOpenCvRoot -LicenseRelativeDir 'etc/licenses'
$tmp = New-TempDir 'ocvu-pkg-out'
& pwsh -NoProfile -File $script -OutputDir $tmp -Root $emptyWinRoot -Platform 'windows-x64' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an empty etc/licenses (Windows layout) fails rather than emitting an empty SBOM'
Remove-Item -Recurse -Force $emptyWinRoot, $tmp -ErrorAction SilentlyContinue

# --- SBOM: Unix レイアウト（share/licenses/opencv5/）が存在するが空なら失敗する ---
#
# ここが本題。etc/licenses/ だけを見る実装は、この場合「見つからない」の
# 例外にすら入らず、単に別の場所を見ていて気づかない。このケースを踏まないと
# Unix 系だけ黙って空の SBOM が出る欠陥が再発する。
$emptyUnixRoot = New-SyntheticOpenCvRoot -LicenseRelativeDir 'share/licenses/opencv5'
$tmp = New-TempDir 'ocvu-pkg-out'
& pwsh -NoProfile -File $script -OutputDir $tmp -Root $emptyUnixRoot -Platform 'linux-x64' 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'an empty share/licenses/opencv5 (Unix layout) fails rather than emitting an empty SBOM'
Remove-Item -Recurse -Force $emptyUnixRoot, $tmp -ErrorAction SilentlyContinue

# --- SBOM: Unix レイアウトに中身があれば、そこから component が拾われる ---
# （0 件を「違反なし」と誤読していないかの正常系側の裏付け）
$populatedUnixRoot = New-SyntheticOpenCvRoot -LicenseRelativeDir 'share/licenses/opencv5'
'zlib license text' | Set-Content -LiteralPath (Join-Path $populatedUnixRoot 'share/licenses/opencv5/zlib-LICENSE') -Encoding utf8
$tmp = New-TempDir 'ocvu-pkg-out'
& pwsh -NoProfile -File $script -OutputDir $tmp -Root $populatedUnixRoot -Platform 'linux-x64' | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'a populated share/licenses/opencv5 (Unix layout) succeeds'
if (Test-Path -LiteralPath (Join-Path $tmp 'sbom.spdx.json')) {
    $unixSbom = Get-Content -LiteralPath (Join-Path $tmp 'sbom.spdx.json') -Raw | ConvertFrom-Json
    $unixNames = @($unixSbom.packages | ForEach-Object { $_.name })
    Assert-That (@($unixNames | Where-Object { $_ -like '*zlib*' }).Count -gt 0) `
        'the Unix-layout SBOM picks up zlib from share/licenses/opencv5'
}
else {
    Assert-That $false 'the Unix-layout SBOM picks up zlib from share/licenses/opencv5'
}
Remove-Item -Recurse -Force $populatedUnixRoot, $tmp -ErrorAction SilentlyContinue

# --- checksums: native plugin が無ければ失敗する（黙って空の checksums.txt を出さない） ---
#
# package-release.ps1 は checksums の対象を
# Packages/com.ayutaz.opencv-unity-native 配下の再帰走査で決める。退避先を
# その配下に残すと、退避したはずの .dll がそのまま拾われて「無い」ことを
# 検証できない（実測で踏んだ: 同じ Runtime/ 直下へリネームしたところ
# checksums に残り続けた）。退避先はパッケージの外（一時ディレクトリ）にする。
$pluginRoot = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins'
if (Test-Path -LiteralPath $pluginRoot) {
    $backupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-plugins-backup-" + [guid]::NewGuid().ToString('n'))
    Move-Item -LiteralPath $pluginRoot -Destination $backupRoot
    try {
        $tmp = New-TempDir 'ocvu-pkg-out'
        & pwsh -NoProfile -File $script -OutputDir $tmp 2>&1 | Out-Null
        Assert-That ($LASTEXITCODE -ne 0) 'a missing native plugin fails rather than emitting an empty checksums.txt'
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    finally {
        Move-Item -LiteralPath $backupRoot -Destination $pluginRoot
    }
}
else {
    Write-Host "  SKIP  no Plugins directory to remove ($pluginRoot)" -ForegroundColor Yellow
}

# --- UPM として解決できる形になっているか ---
#
# 「package.json が在る」は「導入できる」ではない。Unity が要求する必須
# フィールドが揃っていること、samples の path が実在すること、
# plugin の .meta が追跡されていることを見る。
$pkgPath = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/package.json'
$pkg = Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json

foreach ($field in @('name', 'version', 'displayName', 'description', 'unity')) {
    Assert-That ($null -ne $pkg.$field -and $pkg.$field -ne '') "package.json has '$field'"
}
Assert-That ($pkg.name -eq 'com.ayutaz.opencv-unity-native') 'package name matches the documented ID'

# samples を宣言しているなら、その path が実在すること。
# 宣言だけして中身が無いと、利用者の Package Manager に空の項目が出る。
if ($pkg.PSObject.Properties.Name -contains 'samples') {
    foreach ($s in $pkg.samples) {
        $sp = Join-Path (Split-Path -Parent $pkgPath) $s.path
        Assert-That (Test-Path -LiteralPath $sp) "declared sample path exists: $($s.path)"
    }
}

# plugin の .meta が 3 platform 分そろい、それぞれ自分の platform だけを
# 有効にしていること。
#
# binary は成果物なので git から無視してよいが、.meta を無視すると利用者の
# 環境で「全 platform 有効」の既定に戻り、3 つの binary が読み込みで衝突する。
#
# **以前ここは「.meta が 1 つ以上追跡されている」しか見ていなかった。**
# コメントは 3 platform の衝突を心配しているのに、検査は Windows 分 1 つで
# 満足する。実際 macOS / Linux の .meta は 1 つも存在しないまま通っていた。
# 「著者が列挙した形だけを見て、隣接する形が枠外に落ちる」という、この
# リポジトリが繰り返している欠陥そのものである。数えるのをやめ、
# **要求する 3 つを名指しして**、中身まで見る形にした。
$pluginBase = 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins'
$pluginMetas = @(
    @{ Platform = 'windows-x64'; Key = 'Win64'
       Meta = "$pluginBase/x86_64/opencv_unity_native.dll.meta" }
    @{ Platform = 'macos-arm64'; Key = 'OSXUniversal'
       Meta = "$pluginBase/macOS/libopencv_unity_native.dylib.meta" }
    @{ Platform = 'linux-x64';   Key = 'Linux64'
       Meta = "$pluginBase/Linux/x86_64/libopencv_unity_native.so.meta" }
)
$allPlatformKeys = @('Win64', 'OSXUniversal', 'Linux64')

Push-Location $repoRoot
try {
    $tracked = @(& git ls-files "$pluginBase/**/*.meta")
    foreach ($entry in $pluginMetas) {
        Assert-That ($tracked -contains $entry.Meta) `
            "$($entry.Platform): the plugin .meta is tracked by git ($($entry.Meta))"

        # 追跡されていても working tree に無ければ、以降の中身の検査は
        # 「1 つも見なかった」まま素通りする。実測で踏んだ: .meta を消しても
        # git ls-files は追跡を報告し続けるので、上の tracked 検査は通り、
        # 中身の検査は continue で飛ばされ、FAIL が 1 件も出なかった。
        Assert-That (Test-Path -LiteralPath $entry.Meta) `
            "$($entry.Platform): the plugin .meta exists on disk ($($entry.Meta))"
        if (-not (Test-Path -LiteralPath $entry.Meta)) { continue }
        $metaText = Get-Content -LiteralPath $entry.Meta -Raw

        # Any を有効にすると、その binary が全 platform に配られる。
        Assert-That ($metaText -match '(?m)^\s*Any:\s+enabled:\s*0\b') `
            "$($entry.Platform): the Any platform is disabled"

        # 自分の platform だけが 1、他は 0。
        foreach ($key in $allPlatformKeys) {
            $want = if ($key -eq $entry.Key) { '1' } else { '0' }
            $m = [regex]::Match($metaText, "(?m)^\s*$key`:\s+enabled:\s*(\d)")
            Assert-That ($m.Success -and $m.Groups[1].Value -eq $want) `
                "$($entry.Platform): $key is enabled=$want"
        }
    }
}
finally { Pop-Location }

# --- 配布物は 4 点そろうこと ---
#
# roadmap の M3 完了条件は manifest / checksums / THIRD_PARTY_NOTICES.md / SBOM を
# 4 点で求めている。SBOM は機械可読な一覧、通知は人が読む全文で役割が違うので、
# 片方でもう片方を代替できない。通知の同梱は当初漏れていた（Task 8 の判定で発覚）。
# 上の $out は既に片付けられている場合があるので、この節は自前で出力を作る。
$bundleOut = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-bundle-" + [guid]::NewGuid().ToString('n'))
try {
    & pwsh -NoProfile -File $script -OutputDir $bundleOut | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'package-release exits 0 for the bundle check'

    foreach ($f in @('build-manifest.json', 'checksums.txt', 'sbom.spdx.json', 'THIRD_PARTY_NOTICES.md')) {
        Assert-That (Test-Path -LiteralPath (Join-Path $bundleOut $f)) "the release bundle contains $f"
    }

# 通知が構成ハッシュを埋め込んでいないこと。
#
# 埋め込むと構成を変えるたびに黙って古くなる。M3 で実際に起きた: Platform を
# ハッシュに含めた結果、19 箇所の参照が一斉に死んだ（内容自体は正しいまま）。
    $noticesText = Get-Content -LiteralPath (Join-Path $bundleOut 'THIRD_PARTY_NOTICES.md') -Raw
    Assert-That ($noticesText -notmatch '(?<![0-9a-f])[0-9a-f]{12}(?![0-9a-f])') `
        'the notices do not hardcode a configuration hash'
}
finally { Remove-Item -Recurse -Force $bundleOut -ErrorAction SilentlyContinue }


# --- UPM tarball の形 ---
#
# UPM は展開後の root に package.json が来ることを期待する。package ID の
# ディレクトリごと固めた tarball は導入できず、Unity 6000.0.82f1 は
# "The file [<tmp>\package.json] cannot be found" で失敗する（実測）。
#
# release.yml と tools/dev.ps1 test-unity-tarball は同じ
# tools/pack-upm-tarball.ps1 を通るので、ここが守られていれば配布物も守られる。
# 逆に言うと、ここを見ていないと「配ってから気づく」ことになる。
$packer = Join-Path $repoRoot 'tools/pack-upm-tarball.ps1'
$packOut = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-packer-" + [guid]::NewGuid().ToString('n'))
try {
    # 実行中の platform を渡す。この platform の binary はビルド済みのはずで、
    # packer はそれを確かめてから固める。
    Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force
    $thisPlatform = Get-OpenCvPlatform

    $packed = & pwsh -NoProfile -File $packer -OutputDir $packOut -Platform $thisPlatform |
              Select-Object -Last 1
    Assert-That ($LASTEXITCODE -eq 0) 'pack-upm-tarball exits 0'

    <#
        -Platform が名前を変えるだけになっていないこと。

        中身を確かめずに名前だけ付け替えられると、「macOS 用」と名乗る
        Windows の .dll 入り tarball が警告も無しに出来る。現在の release.yml
        では matrix の各 job が新規 checkout するので起きないが、それは
        job 構成がたまたまそうなっているだけで、packer 自身の保証ではない。
    #>
    $otherPlatform = if ($thisPlatform -eq 'windows-x64') { 'macos-arm64' } else { 'windows-x64' }
    & pwsh -NoProfile -File $packer -OutputDir $packOut -Platform $otherPlatform 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) `
        "packing as '$otherPlatform' fails when that platform's binary is absent"

    # 知らない platform を黙って通さない。4 つ目を足すときの安全網。
    & pwsh -NoProfile -File $packer -OutputDir $packOut -Platform 'solaris-sparc' 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'packing for an unknown platform fails'

    if ($packed -and (Test-Path -LiteralPath $packed)) {
        Assert-That ((Split-Path -Leaf $packed) -like "*-$thisPlatform.tgz") `
            'the tarball name carries the platform'

        # tar の引数は相対パスにする（GNU tar は C: をホスト名と読む）。
        Push-Location (Split-Path -Parent $packed)
        try { $entries = @(& tar -tzf (Split-Path -Leaf $packed)) }
        finally { Pop-Location }

        Assert-That ($entries -contains 'package/package.json') `
            'the tarball has package/package.json at its root'

        # package ID のディレクトリで包んでいないこと。包むと UPM が
        # 導入できない形に逆戻りする。
        $wrapped = @($entries | Where-Object { $_ -like 'com.ayutaz.opencv-unity-native/*' })
        Assert-That ($wrapped.Count -eq 0) `
            'the tarball is not wrapped in the package-ID directory'

        # asmdef が入っていること。入っていないと導入はできても何も使えない。
        Assert-That (@($entries | Where-Object { $_ -like '*.asmdef' }).Count -gt 0) `
            'the tarball carries the assembly definitions'

        <#
            native binary が入っていること。

            **これは dev.ps1 test-unity-tarball 側にもあるが、あちらは CI で
            走らない**（runner に Unity が無い）。CI が実際に走らせるのは
            この節だけなので、ここに無いと「binary の入っていない tarball を
            配る」経路を CI では誰も見ていないことになる。
        #>
        $tarBinaries = @($entries | Where-Object { $_ -match '\.(dll|dylib|so)$' })
        Assert-That ($tarBinaries.Count -gt 0) `
            'the tarball carries at least one native plugin binary'
    }
    else {
        Assert-That $false 'pack-upm-tarball produced a tarball'
    }
}
finally { Remove-Item -Recurse -Force $packOut -ErrorAction SilentlyContinue }
if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
