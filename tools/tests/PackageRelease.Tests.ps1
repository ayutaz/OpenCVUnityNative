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

<#
    Plugin Import Settings（.meta）が 3 platform 分そろい、それぞれ自分の
    platform だけを有効にしていること。

    **正本は tools/plugin-meta/<platform>/ にある。** package の
    Runtime/Plugins/ ではない。binary の無い platform の .meta をそこに置くと、
    Unity から見て「asset の無い孤児」になり、mutable な package では実際に
    削除される（dev.ps1 test-unity-editmode を Windows で 1 回走らせるだけで
    macOS / Linux の .meta が消えることを実測した）。dev.ps1 の
    Copy-NativePluginForUnity が、そのとき作った binary の分だけを写す。

    **以前この検査は「.meta が 1 つ以上追跡されている」しか見ていなかった。**
    コメントは 3 platform の衝突を心配しているのに、検査は Windows 分 1 つで
    満足する。実際 macOS / Linux の .meta は 1 つも存在しないまま通っていた。
    「著者が列挙した形だけを見て、隣接する形が枠外に落ちる」という、この
    リポジトリが繰り返している欠陥そのものである。数えるのをやめ、
    **要求する 3 つを名指しして**、中身まで見る形にした。
#>
$metaBase = 'tools/plugin-meta'
$pluginMetas = @(
    @{ Platform = 'windows-x64';   Key = 'Win64';        EditorOS = 'Windows'
       Meta = "$metaBase/windows-x64/x86_64/opencv_unity_native.dll.meta" }
    @{ Platform = 'macos-arm64';   Key = 'OSXUniversal'; EditorOS = 'OSX'
       Meta = "$metaBase/macos-arm64/macOS/libopencv_unity_native.dylib.meta" }
    @{ Platform = 'linux-x64';     Key = 'Linux64';      EditorOS = 'Linux'
       Meta = "$metaBase/linux-x64/Linux/x86_64/libopencv_unity_native.so.meta" }
    @{ Platform = 'android-arm64'; Key = 'Android';      EditorOS = ''
       Meta = "$metaBase/android-arm64/Android/arm64-v8a/libopencv_unity_native.so.meta" }
    @{ Platform = 'ios-arm64';     Key = 'iOS';          EditorOS = ''
       Meta = "$metaBase/ios-arm64/iOS/libopencv_unity_native.a.meta" }
)
$allPlatformKeys = @('Win64', 'OSXUniversal', 'Linux64', 'Win', 'Android', 'iOS')

<#
    **この一覧が、いま配っている platform を全部並べていること。**

    M4 でモバイルを足したとき、上の 2 つは 3 platform のまま残った。
    害は 2 つある: Android / iOS の .meta は**中身を 1 度も見られず**、
    desktop の .meta は**モバイル向けに無効であることを問われなかった。**

    **その穴に実物が落ちた。** iOS の .meta の platform キーを `iPhone:`
    （Unity 2019 以前の名前）と書いた誤りを、この検査は最後まで通した ——
    見ていないファイルの誤りは、どんなに厳しく読んでも出てこない。
    捕まえたのは Unity 自身に問う PluginGatingTests だけである。

    **数を写さず、正本から読む。** platform が増えたらここが赤くなる。
#>
$packSource = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/pack-upm-tarball.ps1') -Raw
$packBlock = [regex]::Match($packSource, '(?ms)^\$PlatformBinaries\s*=\s*\[ordered\]@\{(.*?)^\}')
if (-not $packBlock.Success) {
    throw "tools/pack-upm-tarball.ps1 から `$PlatformBinaries を読めませんでした。書き方が変わっています。"
}
$canonicalPlatforms = @([regex]::Matches($packBlock.Groups[1].Value, "(?m)^\s*'([^']+)'\s*=") |
    ForEach-Object { $_.Groups[1].Value })
# 読めたのに空、を通さない（空なら以降の突き合わせが常に成立する）。
Assert-That ($canonicalPlatforms.Count -ge 3) `
    "the canonical platform list was parsed from pack-upm-tarball.ps1 ($($canonicalPlatforms.Count) entries)"
$metaCheckMissing = @($canonicalPlatforms | Where-Object { $_ -notin $pluginMetas.Platform })
Assert-That ($metaCheckMissing.Count -eq 0) `
    "every shipped platform has its .meta checked here (missing: $($metaCheckMissing -join ', '))"

Push-Location $repoRoot
try {
    $tracked = @(& git ls-files "$metaBase/**/*.meta")
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

        <#
            **Editor を見る。** 以前この検査は Player 側の 3 キーしか見て
            おらず、`.so` の .meta に `Editor: OS: Windows` と書いても
            3 件全部 PASS した。**守りたい性質そのもの——「Windows の
            Editor が .so を読もうとしないこと」——が枠外に落ちていた。**
            これも「著者が列挙した形だけを見る」欠陥の再発である。
        #>
        $editor = [regex]::Match($metaText, '(?m)^\s*Editor:\s+enabled:\s*(\d)([\s\S]*?)(?=^\s{4}\w+:)')
        if ($entry.EditorOS) {
            Assert-That ($editor.Success -and $editor.Groups[1].Value -eq '1') `
                "$($entry.Platform): the Editor platform is enabled"
            Assert-That ($editor.Success -and $editor.Groups[2].Value -match "OS:\s*$($entry.EditorOS)\b") `
                "$($entry.Platform): the Editor entry is limited to OS $($entry.EditorOS)"
        }
        else {
            # **モバイルはエディタで動かない。** 有効にすると Unity が
            # エディタ上でその binary を読もうとする。
            Assert-That ($editor.Success -and $editor.Groups[1].Value -eq '0') `
                "$($entry.Platform): the Editor platform is disabled (モバイルはエディタで動かない)"
        }

        # 自分の platform だけが 1、他は 0。
        foreach ($key in $allPlatformKeys) {
            $want = if ($key -eq $entry.Key) { '1' } else { '0' }
            $m = [regex]::Match($metaText, "(?m)^\s*$key`:\s+enabled:\s*(\d)")
            Assert-That ($m.Success -and $m.Groups[1].Value -eq $want) `
                "$($entry.Platform): $key is enabled=$want"
        }
    }

    <#
        **正本とコピー先が一致していること。** dev.ps1 の
        Copy-NativePluginForUnity が持つ platform → ディレクトリの対応と、
        ここに書いた path は独立に書かれている。片方を変えてももう片方は
        気づかないので、実行中の platform について実際に突き合わせる。
    #>
    Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force
    $thisPlatform = Get-OpenCvPlatform
    $thisEntry = $pluginMetas | Where-Object { $_.Platform -eq $thisPlatform }
    if ($thisEntry) {
        $relative = $thisEntry.Meta -replace "^$([regex]::Escape($metaBase))/$thisPlatform/", ''
        $placed = Join-Path $repoRoot "Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/$relative"
        Assert-That (Test-Path -LiteralPath $placed) `
            "the built package carries this platform's .meta at the path dev.ps1 uses ($relative)"
    }
    else {
        Write-Host "  SKIP  no .meta entry for the running platform ($thisPlatform)" -ForegroundColor Yellow
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

    <#
        構成ハッシュの扱い。

        **リポジトリの通知には焼き込まない。** 埋め込むと構成を変えるたびに
        黙って古くなる。M3 で実際に起きた: Platform をハッシュに含めた結果、
        19 箇所の参照が一斉に死んだ（内容自体は正しいまま）。

        **配布物の通知には入っていてよい。** package-release.ps1 が実行時に
        生きた構成から書くので、古くなりようがない。以前この検査は配布物側を
        見ており、生成ヘッダに正しい値が入った途端に落ちた——検査が守りたい
        性質（古くなる値を残さない）ではなく、たまたま同じ見た目のものを
        禁じていたためである。**古くなり得る場所だけを見る**形に直した。

        そのうえで、配布物側は「入っていること」と「値が現在の構成と
        一致すること」を見る。生成しているつもりで固定値を書いてしまう
        誤りは、これで捕まる。
    #>
    $repoNotices = Get-Content -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Raw
    Assert-That ($repoNotices -notmatch '(?<![0-9a-f])[0-9a-f]{12}(?![0-9a-f])') `
        'the tracked notices do not hardcode a configuration hash'

    $noticesText = Get-Content -LiteralPath (Join-Path $bundleOut 'THIRD_PARTY_NOTICES.md') -Raw
    $liveHash = Get-OpenCvConfigHash -Config (Get-OpenCvConfig)
    Assert-That ($noticesText -match [regex]::Escape($liveHash)) `
        'the bundled notices carry the live configuration hash'
    Assert-That ($noticesText -match [regex]::Escape((Get-OpenCvPlatform))) `
        'the bundled notices name the platform they were built for'
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

    <#
        **単体 platform で固める前に、他 platform の binary を退避する。**

        packer は「名前と中身が食い違わない」ことを見るようになったので、
        3 platform 揃った木で -Platform windows-x64 を叩くと正当に拒否される。
        開発機に 3 つ揃うのは M3.5 以降ふつうに起こる（全部入りのレーンを
        1 回走らせれば残る）ので、**木の状態に頼らず、退避してから確かめる。**
    #>
    #
    # **一覧を直書きしない。** M4 で 5 platform に増えたとき、ここは 3 件の
    # ままだった —— **モバイルの binary が残ったまま単体 platform で固めようと
    # して、packer が正しく拒否した**（実測。テストの側が古かった）。
    # 上で $expectedRelative から導いた $allBinaries を使う。
    $singleStash = @()
    $mine = 'Runtime/Plugins/' + ($allBinaries | Where-Object {
        switch ($thisPlatform) {
            'windows-x64' { $_ -like 'x86_64/*' }
            'macos-arm64' { $_ -like 'macOS/*' }
            'linux-x64'   { $_ -like 'Linux/*' }
            default       { $false }
        }
    } | Select-Object -First 1)
    foreach ($rel in @($allBinaries | ForEach-Object { "Runtime/Plugins/$_" })) {
        if ($rel -eq $mine) { continue }
        $full = Join-Path $repoRoot "Packages/com.ayutaz.opencv-unity-native/$rel"
        if (Test-Path -LiteralPath $full) {
            $to = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-stash-" + [guid]::NewGuid().ToString('n'))
            Move-Item -LiteralPath $full -Destination $to -Force
            $singleStash += @{ From = $to; To = $full }
        }
    }

    try {
        $packed = & pwsh -NoProfile -File $packer -OutputDir $packOut -Platform $thisPlatform |
                  Select-Object -Last 1
        Assert-That ($LASTEXITCODE -eq 0) 'pack-upm-tarball exits 0'
    }
    finally {
        foreach ($s in $singleStash) { Move-Item -LiteralPath $s.From -Destination $s.To -Force }
    }

    <#
        -Platform が名前を変えるだけになっていないこと。

        中身を確かめずに名前だけ付け替えられると、「macOS 用」と名乗る
        Windows の .dll 入り tarball が警告も無しに出来る。現在の release.yml
        では matrix の各 job が新規 checkout するので起きないが、それは
        job 構成がたまたまそうなっているだけで、packer 自身の保証ではない。
    #>
    $otherPlatform = if ($thisPlatform -eq 'windows-x64') { 'macos-arm64' } else { 'windows-x64' }

    <#
        **その platform の binary が「無い」状態を、ここで作る。**

        以前はローカルの木に実行中 platform の binary しか無いことに頼っていたが、
        M3.5 で全部入りを作れるようにしたので、開発機に 3 つ揃っていることが
        普通に起こる。そのとき -Platform macos-arm64 は正当に成功するので、
        この検査は「落ちるはず」を主張したまま緑にならなくなる（実測で踏んだ）。

        依存するのは木の状態ではなく、退避してから確かめるという手順にする。
    #>
    $otherBinary = switch ($otherPlatform) {
        'windows-x64' { Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/x86_64/opencv_unity_native.dll' }
        'macos-arm64' { Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/macOS/libopencv_unity_native.dylib' }
        default       { $null }
    }
    $otherStash = $null
    if ($otherBinary -and (Test-Path -LiteralPath $otherBinary)) {
        $otherStash = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-other-" + [guid]::NewGuid().ToString('n'))
        Move-Item -LiteralPath $otherBinary -Destination $otherStash -Force
    }
    try {
        & pwsh -NoProfile -File $packer -OutputDir $packOut -Platform $otherPlatform 2>&1 | Out-Null
        Assert-That ($LASTEXITCODE -ne 0) `
            "packing as '$otherPlatform' fails when that platform's binary is absent"
    }
    finally {
        if ($otherStash) { Move-Item -LiteralPath $otherStash -Destination $otherBinary -Force }
    }

    # 知らない platform を黙って通さない。4 つ目を足すときの安全網。
    & pwsh -NoProfile -File $packer -OutputDir $packOut -Platform 'solaris-sparc' 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'packing for an unknown platform fails'

    <#
        全部入り（-AllPlatforms）の検査。

        **このマシンには 1 platform 分の binary しか無い**ので、正常系は
        3 つ揃った木を合成してから確かめる。ここで見たいのは packer の判定で
        あって実物のビルドではないので、他 platform 分は中身のある偽物で足りる
        —— 判定は「その位置にファイルが在るか」であり、中身は読まない。
    #>
    $allOut = Join-Path $packOut 'allplatforms'
    New-Item -ItemType Directory -Force -Path $allOut | Out-Null

    $pluginRoot = Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins'
    # **正本は tools/dev.ps1 の $script:AllPlatformBinaries と
    # tools/pack-upm-tarball.ps1 の $PlatformBinaries である。** ここに書くのは
    # 3 箇所目なので、上の「3 箇所で一致する」検査がずれを捕まえる。
    $allBinaries = @(
        'x86_64/opencv_unity_native.dll'
        'macOS/libopencv_unity_native.dylib'
        'Linux/x86_64/libopencv_unity_native.so'
        'Android/arm64-v8a/libopencv_unity_native.so'
        'iOS/libopencv_unity_native.a'
    )

    <#
        **binary だけでなく `.meta` も揃える。**

        `dev.ps1 build` が置くのは実行中 platform の分だけなので、CI の
        Windows / macOS runner では他 platform の `.meta` が存在しない
        （`tools/plugin-meta/` は windows 2 / macos 2 / linux 3 ファイル）。
        binary だけを placeholder で補うと、archive の `.meta` が 2 つに
        なって「7 つ在ること」が成り立たない。

        **著者のローカルでこれが見えなかったのは、全部入りのレーンを走らせた
        残骸として 3 platform 分の `.meta` が残っていたためである。**
        木の状態に頼らず、正本（`tools/plugin-meta/`）から揃える —— 本番で
        `assemble-plugins.ps1` がしているのと同じことをする。
    #>
    $created = @()
    foreach ($rel in $allBinaries) {
        $full = Join-Path $pluginRoot $rel
        if (-not (Test-Path -LiteralPath $full)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            Set-Content -LiteralPath $full -Value 'placeholder for the packer check' -NoNewline
            $created += $full
        }
    }

    $metaSourceRoot = Join-Path $repoRoot 'tools/plugin-meta'
    foreach ($platformDir in @(Get-ChildItem -LiteralPath $metaSourceRoot -Directory)) {
        foreach ($meta in @(Get-ChildItem -LiteralPath $platformDir.FullName -Recurse -File)) {
            $rel = [System.IO.Path]::GetRelativePath($platformDir.FullName, $meta.FullName)
            $full = Join-Path $pluginRoot $rel
            if (-not (Test-Path -LiteralPath $full)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
                Copy-Item -LiteralPath $meta.FullName -Destination $full -Force
                $created += $full
            }
        }
    }

    try {
        $allPacked = & pwsh -NoProfile -File $packer -OutputDir $allOut -AllPlatforms |
                     Select-Object -Last 1
        Assert-That ($LASTEXITCODE -eq 0) `
            "-AllPlatforms packs when all $($allBinaries.Count) binaries are present"

        if ($allPacked -and (Test-Path -LiteralPath $allPacked)) {
            # **名前に版番号を入れない。** OpenUPM の githubReleaseAssetName は
            # 安定した接頭辞で asset を選ぶ。
            Assert-That ((Split-Path -Leaf $allPacked) -eq 'com.ayutaz.opencv-unity-native.tgz') `
                'the all-in-one tarball has a stable, version-free name'

            Push-Location (Split-Path -Parent $allPacked)
            try { $allEntries = @(& tar -tzf (Split-Path -Leaf $allPacked)) }
            finally { Pop-Location }

            # **拡張子で拾わない。** iOS の静的ライブラリは .a なので、
            # (dll|dylib|so) の一覧では黙って抜ける。相対パスで照合する。
            $packedBins = @($allBinaries | Where-Object {
                $rel = $_
                @($allEntries | Where-Object { $_ -eq "package/Runtime/Plugins/$rel" }).Count -eq 1
            })
            Assert-That ($packedBins.Count -eq $allBinaries.Count) `
                "the all-in-one archive carries all $($allBinaries.Count) binaries (saw $($packedBins.Count))"

            # **>= ではなく = で見る。** 「3 つ以上」だと、7 つ在るべきところが
            # 4 つでも通ってしまう。この archive の中身は一覧そのものが契約である。
            $packedMetas = @($allEntries |
                Where-Object { $_ -like 'package/Runtime/Plugins/*' -and $_ -like '*.meta' })
            # **数を直書きしない。** tools/plugin-meta/ にある .meta の総数から
            # 導く —— platform を足したときに片方だけ古くなるのを避ける。
            $expectedMetaCount = @(Get-ChildItem (Join-Path $repoRoot 'tools/plugin-meta') -Recurse -File -Filter '*.meta').Count
            Assert-That ($packedMetas.Count -eq $expectedMetaCount) `
                "the all-in-one archive carries all $expectedMetaCount plugin metas (saw $($packedMetas.Count): $($packedMetas -join ', '))"
        }

        # 負 1: binary が 1 つ欠けたら止まる。
        $victim = Join-Path $pluginRoot 'macOS/libopencv_unity_native.dylib'
        $stash  = "$victim.stash"
        Move-Item -LiteralPath $victim -Destination $stash -Force
        try {
            & pwsh -NoProfile -File $packer -OutputDir $allOut -AllPlatforms 2>&1 | Out-Null
            Assert-That ($LASTEXITCODE -ne 0) '-AllPlatforms fails when a platform binary is missing'
        }
        finally { Move-Item -LiteralPath $stash -Destination $victim -Force }

        # 負 2: 知らない binary が混ざったら止まる。**存在検査だけでは通ってしまう形。**
        $stray = Join-Path $pluginRoot 'x86_64/stray.dll'
        Set-Content -LiteralPath $stray -Value 'not ours' -NoNewline
        try {
            & pwsh -NoProfile -File $packer -OutputDir $allOut -AllPlatforms 2>&1 | Out-Null
            Assert-That ($LASTEXITCODE -ne 0) '-AllPlatforms fails when an unexpected binary is present'
        }
        finally { Remove-Item -LiteralPath $stray -Force -ErrorAction SilentlyContinue }

        # 負 3: 上限を超えたら止まる。**引数にしてあるので、ここで実際に落とせる。**
        & pwsh -NoProfile -File $packer -OutputDir $allOut -AllPlatforms -MaxBytes 1000 2>&1 | Out-Null
        Assert-That ($LASTEXITCODE -ne 0) 'the size guard rejects a tarball over the limit'

        # 負 4: -Platform と -AllPlatforms は同時に使えない。
        & pwsh -NoProfile -File $packer -OutputDir $allOut -AllPlatforms -Platform 'windows-x64' 2>&1 | Out-Null
        Assert-That ($LASTEXITCODE -ne 0) '-Platform and -AllPlatforms are mutually exclusive'
    }
    finally {
        foreach ($f in $created) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

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

# --- リリースノート ---
#
# release.yml は --notes-file .github/release-notes.md を渡す。
# **ファイルが在るだけでは足りない。** 空でも gh は成功するので、
# 中身の無い Release ができあがる。
#
# 加えて、ノートは利用者が最初に読むものなので、導入できない経路
# （Git URL）と検証方法に触れていることを見る。書き忘れると、
# 「README を参照」と言われた先に何も無い、というこの PR で実際に
# 起きた形を繰り返す。
$notesPath = Join-Path $repoRoot '.github/release-notes.md'
Assert-That (Test-Path -LiteralPath $notesPath) 'the release notes file exists'

if (Test-Path -LiteralPath $notesPath) {
    # 空ファイルでは Get-Content -Raw が $null を返す。そのまま .Trim() を
    # 呼ぶと「null に対するメソッド呼び出し」で落ち、非 0 では終わるが
    # 何が悪いのか読めない。理由の分かる失敗にする。
    $notes = (Get-Content -LiteralPath $notesPath -Raw)
    if ($null -eq $notes) { $notes = '' }
    Assert-That ($notes.Trim().Length -gt 200) 'the release notes are not effectively empty'

    foreach ($needle in @('SHA256SUMS.txt', 'Git URL', 'manifest.json')) {
        Assert-That ($notes -match [regex]::Escape($needle)) `
            "the release notes mention '$needle'"
    }

    # workflow が実際にこのファイルを指していること。片方だけ直しても
    # 気づけないので、両方を突き合わせる。
    $workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/release.yml') -Raw
    Assert-That ($workflow -match '--notes-file\s+\.github/release-notes\.md') `
        'release.yml reads the notes from that file'
    Assert-That ($workflow -notmatch '--notes\s+"') `
        'release.yml does not inline the notes (escaping them by hand is where they break)'
}

# --- 全部入りの platform 一覧が 3 箇所で一致する（M4 Task 7）---
#
# **platform を足すときに直す場所が 3 つある**（packer / assembler / dev.ps1）。
# roadmap は「2 か所を直すことになる」と書いていたが、実際は dev.ps1 の
# 「揃っているか」を見る側もある。**ずれると、揃っていないのに全部入りとして
# 扱う（またはその逆）が起きる。**
$packText     = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/pack-upm-tarball.ps1') -Raw
$assembleText = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/assemble-plugins.ps1') -Raw
$devText      = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/dev.ps1') -Raw

$expectedRelative = @(
    'x86_64/opencv_unity_native.dll'
    'macOS/libopencv_unity_native.dylib'
    'Linux/x86_64/libopencv_unity_native.so'
    'Android/arm64-v8a/libopencv_unity_native.so'
    'iOS/libopencv_unity_native.a'
)

<#
    **引用符ごと厳密に照合する。**

    最初は部分一致で見ていたが、`'iOS/libopencv_unity_native.a.meta'` が
    `iOS/libopencv_unity_native.a` を含むので、**binary の行を消しても通った**
    （実測）。「.meta は在るが binary が無い」は、まさにこの検査が捕まえたい
    状態である —— binary の無い .meta を置くと Unity がそれを消す。
#>
foreach ($rel in $expectedRelative) {
    $quoted = "'" + [regex]::Escape($rel) + "'"
    Assert-That ($packText -match $quoted) "pack-upm-tarball.ps1 knows $rel"
    Assert-That ($assembleText -match $quoted) `
        "assemble-plugins.ps1 carries $rel (packer だけでは全部入りに入らない)"
    Assert-That ($devText -match $quoted) `
        "dev.ps1 counts $rel when deciding whether the tree is all-platform"
}

# **iOS の静的ライブラリを拡張子で取りこぼさない。** .a は dll/dylib/so の
# どれでもないので、拡張子の一覧で拾う実装だと黙って抜ける。
# **説明文に書いてあるだけで満たせない形にする。**
#
# 最初は行に (dll|dylib|so) が出るかだけを見ていたが、ブロックコメントの中の
# 説明文に当たって落ちた —— 行頭 # を落とすだけではブロックコメントを
# 除けない。このリポジトリが繰り返し潰してきた穴と同じ形である。
#
# 実際の欠陥は「-match の演算子で拡張子を判定している」ことなので、
# その形だけを禁じる。散文はいくら書いてよい。
#
# **この説明を行コメントで書いているのは、ブロックコメントにすると
# 閉じ記号を散文の中に書けないからである** —— 実際、最初はブロックコメントで
# 書いて途中で閉じてしまい、**5 行の散文がコマンドとして実行されていた。**
# exit 0 のまま stderr に 33 行出ており、CI の必須レーンで毎回混ざっていた
# （レビューが実測で見つけた）。
$packLines = @(Get-Content -LiteralPath (Join-Path $repoRoot 'tools/pack-upm-tarball.ps1'))
Assert-That (@($packLines | Where-Object { $_ -match "-match\s+'[^']*dll\|dylib\|so" }).Count -eq 0) `
    'pack-upm-tarball.ps1 does not -match a dll/dylib/so extension list to identify shipped binaries (iOS の .a が抜ける)'

<#
    **.meta の GUID が重複していないこと。**

    重複すると Unity が片方を無視する。**どちらが無視されるかは決まっていない**
    ので、「ある環境では動くが別の環境では動かない」という最も追いにくい形になる。
#>
$metaGuids = @()
foreach ($m in Get-ChildItem (Join-Path $repoRoot 'tools/plugin-meta') -Recurse -Filter '*.meta') {
    if ((Get-Content -LiteralPath $m.FullName -Raw) -match 'guid:\s*([0-9a-f]{32})') {
        $metaGuids += $Matches[1]
    }
}
Assert-That ($metaGuids.Count -ge 12) `
    "plugin-meta has at least 12 .meta files with a guid (saw $($metaGuids.Count))"
Assert-That ((@($metaGuids | Sort-Object -Unique)).Count -eq $metaGuids.Count) `
    'every .meta guid is unique (重複すると Unity が片方を黙って無視する)'

# binary と .meta は対で運ばれる。**binary の無い .meta を置くと Unity に
# 消される**（M3 のレビュー M4）ので、対応する .meta が実在することを見る。
$metaExpectations = @{
    'windows-x64'   = 'x86_64/opencv_unity_native.dll.meta'
    'macos-arm64'   = 'macOS/libopencv_unity_native.dylib.meta'
    'linux-x64'     = 'Linux/x86_64/libopencv_unity_native.so.meta'
    'android-arm64' = 'Android/arm64-v8a/libopencv_unity_native.so.meta'
    'ios-arm64'     = 'iOS/libopencv_unity_native.a.meta'
}
foreach ($entry in $metaExpectations.GetEnumerator()) {
    $metaPath = Join-Path $repoRoot "tools/plugin-meta/$($entry.Key)/$($entry.Value)"
    Assert-That (Test-Path -LiteralPath $metaPath) "tools/plugin-meta/$($entry.Key) has $($entry.Value)"
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
