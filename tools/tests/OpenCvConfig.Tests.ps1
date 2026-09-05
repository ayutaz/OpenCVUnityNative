#Requires -Version 7.0
# Pester を使わず素の assert で書く。依存を増やさないため。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$config = Get-OpenCvConfig

Assert-That ($config.Tag -eq '5.0.0') 'tag is pinned to 5.0.0'
# **Modules を写さない。正本から読む。** 以前はここに 5 つの名前をリテラルで
# 書いていたが、module を 1 つ足すたびにこの 1 行だけが嘘になった（実際 calib で
# 踏んだ）。いま見るのは「OpenCV 側がビルドする module」と「bindings/spec が
# 境界に出している module」の関係である。
#
# spec の module 名は OpenCV の module 名と一致していなければならない ——
# ただし例外が 3 つある:
#   - infra は OpenCV の module ではなく、この ABI 自身（版・エラー・status 表）を指す
#   - geometry は Modules に書いていないが、features / objdetect の依存として
#     OpenCV が推移的にビルドする（実測。cmake/FindOpenCvUnityDeps.cmake の
#     COMPONENTS には意図の宣言として明示してある）
#   - stereo も Modules に書いていないが、calib が推移的に引くので OpenCV 側は
#     既にビルドしている（2026-09-05 に COMPONENTS へ足した。構成ハッシュは不変）
$specModulesNotBuiltDirectly = @('infra', 'geometry', 'stereo')
$specModules = @(
    Get-ChildItem -Path (Join-Path $PSScriptRoot '../../bindings/spec') -Filter '*.json' |
        Where-Object { $_.Name -ne 'schema.json' } |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
)
Assert-That ($specModules.Count -gt 0) 'the spec directory was actually scanned (0 件なら走査が効いていない)'

$unmatched = @($specModules | Where-Object { $specModulesNotBuiltDirectly -notcontains $_ -and $config.Modules -notcontains $_ })
Assert-That ($unmatched.Count -eq 0) `
    "every spec module is built by OpenCV (見つからないもの: $($unmatched -join ', '))"

# **逆向きも見る。** 上だけだと「spec に無い module を Modules へ足す」が通る ——
# それは**この repo でいちばん高い変更**である（構成ハッシュが変わり 5 platform 分の
# OpenCV を作り直す）。境界に出さない module をビルドしても成果物が膨らむだけなので、
# 足すなら spec も同時に増えるはずである。
#
# `flann` のように「依存として必要だが自分では呼ばない」module は Modules に
# 書かない（推移的に引かれる）ので、この向きの例外は今のところ無い。
$unexpected = @($config.Modules | Where-Object { $specModules -notcontains $_ })
Assert-That ($unexpected.Count -eq 0) `
    "every built module is exposed through the spec (spec に無いのに Modules に在る: $($unexpected -join ', '))"

# core は常に要る（Mat がこれに載っている）。
Assert-That ($config.Modules -contains 'core') 'core is always built'

# 4.x の名前が混ざっていないこと。OpenCV 5 では再編されている。
Assert-That (-not ($config.Modules -contains 'features2d')) 'features2d is not used (renamed to features in 5.x)'
Assert-That (-not ($config.Modules -contains 'calib3d')) 'calib3d is not used (split in 5.x)'
Assert-That (-not ($config.Modules -contains 'videoio')) 'videoio is excluded'

$args = $config.CMakeArgs -join ' '
foreach ($forbidden in @('WITH_FFMPEG=OFF', 'WITH_GSTREAMER=OFF', 'WITH_MSMF=OFF', 'WITH_DSHOW=OFF')) {
    Assert-That ($args -match [regex]::Escape($forbidden)) "flags disable $($forbidden.Split('=')[0])"
}
Assert-That ($args -match 'CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL') 'CRT is /MD'
Assert-That ($args -match 'BUILD_SHARED_LIBS=OFF') 'OpenCV is built static'

# ハッシュは決定的で、構成が変われば変わること
$hash1 = Get-OpenCvConfigHash -Config $config
$hash2 = Get-OpenCvConfigHash -Config (Get-OpenCvConfig)
Assert-That ($hash1 -eq $hash2) 'hash is deterministic across calls'
Assert-That ($hash1 -match '^[0-9a-f]{12}$') 'hash is 12 lowercase hex characters'

$mutated = Get-OpenCvConfig
$mutated.CMakeArgs = @($mutated.CMakeArgs) + '-DWITH_TIFF=ON'
Assert-That ((Get-OpenCvConfigHash -Config $mutated) -ne $hash1) 'changing a flag changes the hash'

$mutatedTag = Get-OpenCvConfig
$mutatedTag.Tag = '5.0.1'
Assert-That ((Get-OpenCvConfigHash -Config $mutatedTag) -ne $hash1) 'changing the tag changes the hash'

# 実行中の platform で組み立てる。'windows-x64' を直書きすると macOS / Linux で
# 必ず落ち、そこで dev.ps1 test が止まって L1 も L3 も走らなくなる（M3 のレビューで発見）。
Assert-That ((Get-OpenCvArtifactName -Config $config) -eq "opencv-5.0.0-$($config.Platform)-$hash1") 'artifact name embeds the platform and the hash'

# 並び順を変えても同じハッシュになること（order-insensitive）。
# Sort-Object を将来のリファクタで取りこぼしても検知できるよう、
# 一度きりの ad hoc 確認ではなくテストスイートに残す。
$shuffled = Get-OpenCvConfig
$shuffled.CMakeArgs = @($shuffled.CMakeArgs[-1]) + @($shuffled.CMakeArgs[0..($shuffled.CMakeArgs.Count - 2)])
$shuffled.Modules = @($shuffled.Modules[-1]) + @($shuffled.Modules[0..($shuffled.Modules.Count - 2)])
Assert-That ((Get-OpenCvConfigHash -Config $shuffled) -eq $hash1) 'reordering CMakeArgs and Modules does not change the hash'

# 正規化が単射であること。区切り文字で join するだけの正規化は、
# 要素境界に区切り文字自体を含む値が来ると衝突し得る
# （["-DAAA=1","-DBBB=2"] と ["-DAAA=1 -DBBB=2"] が同じ文字列になる）。
# 今の固定構成には空白・カンマを含む flag/module は無いが、
# Task 3 / 7 で CMakeArgs が増える前提なので、ここで塞いでおく。
$collisionA = Get-OpenCvConfig
$collisionA.CMakeArgs = @('-DAAA=1', '-DBBB=2')
$collisionB = Get-OpenCvConfig
$collisionB.CMakeArgs = @('-DAAA=1 -DBBB=2')
Assert-That ((Get-OpenCvConfigHash -Config $collisionA) -ne (Get-OpenCvConfigHash -Config $collisionB)) 'CMakeArgs elements do not collide across element boundaries'

$moduleCollisionA = Get-OpenCvConfig
$moduleCollisionA.Modules = @('core', 'imgproc')
$moduleCollisionB = Get-OpenCvConfig
$moduleCollisionB.Modules = @('core,imgproc')
Assert-That ((Get-OpenCvConfigHash -Config $moduleCollisionA) -ne (Get-OpenCvConfigHash -Config $moduleCollisionB)) 'Modules elements do not collide across element boundaries'


# Get-OpenCvDependencyVersions は形式の違う 2 つの入力を受ける。ここは
# 両方を固定する。片方だけを固定していたために、本番だけが常に 0 件を
# 返す欠陥が緑のまま通っていた（再レビュー F1）:
#
#   本番 (tools/opencv.ps1)  cmake configure の stdout。message(STATUS) 経由
#                            なので cmake が各行に "-- " を前置する。
#   実行時・旧テスト          cv::getBuildInformation() の戻り値。前置は無い。
#
# 内容が同じでも行頭が違うので、前置を剥がさない実装は後者だけを通す。
# 下の $sample は後者の形。$samplePrefixed はそれに "-- " を付けた前者の形で、
# 実際の CI ログ（gh run view 32849957498 --log）と同じ字面になる。
$sampleBuildInformation = @'

General configuration for OpenCV 5.0.0 =====================================
  Version control:               5.0.0

  C/C++:
    Built as dynamic libs?:      NO
    C++ Compiler:                C:/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe  (ver 19.44.35228.0)
    3rdparty dependencies:       libclapack libjpeg-turbo libpng zlib

  Media I/O:
    ZLib:                        build (ver 1.3.2)
    JPEG:                        build-libjpeg-turbo (ver 3.1.2-70)
      SIMD Support Request:      YES
      SIMD Support:              NO
    AVIF:                        NO
    PNG:                         build (ver 1.6.57)
      SIMD Support Request:      YES
    GIF:                         YES

  Other third-party libraries:
    Lapack:                      YES (Built-In libclapack)
    Custom HAL:                  NO
    Flatbuffers:                 builtin/3rdparty (25.9.23)

  Install to:                    D:/a/OpenCVUnityNative/OpenCVUnityNative/third_party/opencv/6ba270f342e3
-----------------------------------------------------------------
'@

$depVersions = Get-OpenCvDependencyVersions -BuildInformation $sampleBuildInformation
Assert-That ($depVersions['ZLib'] -eq '1.3.2') 'ZLib version is extracted from Media I/O'
Assert-That ($depVersions['JPEG'] -eq '3.1.2-70') 'JPEG (libjpeg-turbo) version is extracted, hyphen and all'
Assert-That ($depVersions['PNG'] -eq '1.6.57') 'PNG version is extracted'
Assert-That (-not $depVersions.Contains('SIMD Support Request')) 'a 6-space-indented sub-item is not mistaken for a dependency'
Assert-That (-not $depVersions.Contains('GIF')) 'a versionless entry (no "(ver X)") is not included'

# C++ Compiler も "(ver X.Y.Z)" という同じ書式を使うが、これは
# ツールチェーン自身のバージョンであって bundle された third-party
# ではないので、Media I/O: 以外の section を対象にしない設計が
# これを拾わないことを確認する。
Assert-That (-not $depVersions.Contains('C++ Compiler')) 'the C++ compiler version (same "(ver X)" format, different section) is not mistaken for a dependency'

# Flatbuffers は「Other third-party libraries:」に本物の "(ver 相当)" の
# 括弧付きバージョンで現れるが、dnn/gapi 用の検出結果であり、この構成の
# 実際のビルドには linked されていない（THIRD_PARTY_NOTICES.md の
# symbol-table 検証で確認済み）。Media I/O: だけを対象にする設計が
# これを拾わないことを確認する — 拾ってしまうと THIRD_PARTY_NOTICES.md の
# 「present but not linked」という判断と build-manifest.json が食い違う。
Assert-That (-not $depVersions.Contains('Flatbuffers')) 'Flatbuffers (present but not linked into this configuration) is not included'

# libclapack はどの section にもバージョン文字列が出ない
# ("YES (Built-In libclapack)" のみ)。無いものを捏造しないことを確認する。
Assert-That (-not $depVersions.Contains('Lapack')) 'libclapack has no reported version and is not fabricated'

# --- 本番の入力形式（cmake configure stdout）での回帰テスト ---
#
# 抽出器がこの形式に対して 0 件を返していたのが再レビュー F1。テストが
# 前置無しの形式しか使っていなかったため、CI は緑のまま manifest の
# dependencyVersions だけが常に空になっていた。両形式が同じ結果を返す
# ことをここで固定する。
$samplePrefixed = ($sampleBuildInformation -split "`r?`n" | ForEach-Object { "-- $_" }) -join "`n"

$fromPlain    = Get-OpenCvDependencyVersions -BuildInformation $sampleBuildInformation
$fromPrefixed = Get-OpenCvDependencyVersions -BuildInformation $samplePrefixed

Assert-That ($fromPrefixed.Count -gt 0) 'cmake configure stdout ("-- " 前置) からも version を抽出できる'
Assert-That ($fromPrefixed.Count -eq $fromPlain.Count) '前置の有無で抽出件数が変わらない'
foreach ($key in $fromPlain.Keys) {
    Assert-That ($fromPrefixed[$key] -eq $fromPlain[$key]) "前置の有無で $key のバージョンが一致する"
}

# --- platform ごとに構成とハッシュが分かれる ---
#
# 現在ハッシュに platform が入っておらず、macOS でビルドしても Windows と同じ
# ハッシュを名乗れてしまう。M1 が「古い成果物が黙って再利用されない」ために
# 作った仕組みの穴なので、platform が違えば必ず違うハッシュになることを固定する。
$platforms = @('windows-x64', 'macos-arm64', 'linux-x64')
$hashes = @{}
foreach ($p in $platforms) {
    $cfg = Get-OpenCvConfig -Platform $p
    Assert-That ($cfg.Platform -eq $p) "Get-OpenCvConfig -Platform $p returns that platform"
    Assert-That ($null -ne $cfg.Toolchain.Generator) "$p has a generator"
    $hashes[$p] = Get-OpenCvConfigHash -Config $cfg
}

Assert-That (($hashes.Values | Sort-Object -Unique).Count -eq $platforms.Count) `
    'every platform produces a distinct config hash'

foreach ($p in $platforms) {
    $name = Get-OpenCvArtifactName -Config (Get-OpenCvConfig -Platform $p)
    Assert-That ($name -eq "opencv-5.0.0-$p-$($hashes[$p])") `
        "the artifact name for $p embeds that platform and its hash"
}

# 実行中の platform を既定にする。引数なしの呼び出しが壊れないこと。
$current = Get-OpenCvPlatform
Assert-That ($current -in $platforms) "Get-OpenCvPlatform returns a known platform (saw '$current')"
Assert-That ((Get-OpenCvConfig).Platform -eq $current) 'Get-OpenCvConfig defaults to the running platform'

# 未知の platform は黙って通さない。認識できなかったものは失敗側に落とす。
$rejected = $false
try { Get-OpenCvConfig -Platform 'solaris-sparc' | Out-Null }
catch { $rejected = $true }
Assert-That $rejected 'an unknown platform is rejected rather than silently defaulted'

# --- psd1 に新しい top-level キーを足すとハッシュが動く ---
#
# Get-OpenCvConfig がキーを名指しで列挙すると、psd1 に足したキーが構成に
# 入らず「構成を変えたのにハッシュが動かない」状態になる。M1 の H3 は
# Get-OpenCvConfigHash について同じ欠陥を閉じたが、列挙を Get-OpenCvConfig へ
# 移すと 1 段上で再発する（M3 Task 1 の初回実装が実際にそうなっていた:
# ContribTag を足してもハッシュが 4785d98e9aad のまま動かなかった）。
#
# 実ファイルを一時的に書き換えて確かめる。読み取り専用の検査では、
# 「列挙している実装」と「していない実装」を区別できない。
$configPath = Join-Path $PSScriptRoot '../opencv-config.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
$backup = Get-Content -LiteralPath $configPath -Raw
try {
    $baseline = Get-OpenCvConfigHash -Config (Get-OpenCvConfig -Platform 'windows-x64')

    # 将来ありうる top-level キーを足す（contrib の tag など）
    ($backup -replace "(?m)^(\s*)Tag = '5\.0\.0'", "`$1Tag = '5.0.0'`n`$1OcvuHashProbeKey = 'probe'") |
        Set-Content -LiteralPath $configPath -NoNewline

    $withNewKey = Get-OpenCvConfigHash -Config (Get-OpenCvConfig -Platform 'windows-x64')
    Assert-That ($withNewKey -ne $baseline) `
        'adding a new top-level key to opencv-config.psd1 changes the hash'
}
finally {
    Set-Content -LiteralPath $configPath -Value $backup -NoNewline
    # 復元できたことを確かめる。ここが崩れると以降のテストが嘘の値で走る。
    $restored = Get-OpenCvConfigHash -Config (Get-OpenCvConfig -Platform 'windows-x64')
    Assert-That ($restored -eq $baseline) 'opencv-config.psd1 is restored to its original content'
}

# --- CMakePresets に全 platform 分が在り、名前が platform と一致する ---
#
# preset 名を platform 名から機械的に導くので、片方だけ足して他方を忘れると
# 「preset が無い」という実行時エラーになる。ここで先に落とす。
$presetsPath = Join-Path $repoRoot 'CMakePresets.json'
$presets = Get-Content -LiteralPath $presetsPath -Raw | ConvertFrom-Json
$configureNames = @($presets.configurePresets | ForEach-Object { $_.name })

foreach ($p in @('windows-x64', 'macos-arm64', 'linux-x64')) {
    Assert-That ("$p-debug" -in $configureNames) "CMakePresets has a configure preset '$p-debug'"
    Assert-That ("$p-asan" -in $configureNames) "CMakePresets has a configure preset '$p-asan'"
}

# build / test preset も同数あること。configure だけ足して build を忘れると
# cmake --build --preset が失敗する。
$buildNames = @($presets.buildPresets | ForEach-Object { $_.name })
$testNames = @($presets.testPresets | ForEach-Object { $_.name })

<#
    **クロスビルドの preset には test preset を作らない。**

    Android / iOS 向けにビルドした GoogleTest は host で実行できないので、
    test preset を置いても走らせようがない。**「あるのに誰も走らせていない」
    レーンを作らない**（M1 のレビュー H2 と同じ形）。

    代わりに L1 の役目を負うのは実機の smoke test である
    （docs/m4-device-verification.md）。**これは弱い代替であり、そう書いてある。**

    ここに名前を直書きするのではなく、preset が toolchainFile を持つかで
    判別する —— クロスビルドであることの唯一の印がそれだからである。
#>
$crossPresets = @($presets.configurePresets |
                  Where-Object { $_.PSObject.Properties.Name -contains 'toolchainFile' } |
                  ForEach-Object { $_.name })
Assert-That ($crossPresets.Count -gt 0) `
    'at least one configure preset is a cross build (0 件なら下の除外は空振りしている)'

foreach ($n in $configureNames) {
    Assert-That ($n -in $buildNames) "there is a build preset for '$n'"
    if ($n -in $crossPresets) {
        Assert-That (-not ($n -in $testNames)) `
            "'$n' is a cross build and has no test preset (host で実行できないものを走らせるふりをしない)"
        continue
    }
    Assert-That ($n -in $testNames) "there is a test preset for '$n'"
}

# --- manifest に platform を決め打ちしていないこと ---
#
# opencv.ps1 の Write-BuildManifest が platform を文字列で持っていると、
# macOS / Linux でビルドしても windows-x64 と記録され、manifest が実物と
# 食い違う。「成果物に何が入っているか」の申告が嘘になるので、M3 の SBOM
# にもそのまま伝播する（M3 Task 2 のレビューで実際に見つかった）。
#
# 実行時の値は CI でしか確かめられないので、ここではソースを検査する。
# 検査対象が構成から取っていることを見るのが目的で、値そのものではない。
$opencvScript = Join-Path $PSScriptRoot '../opencv.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
$manifestSource = Get-Content -LiteralPath $opencvScript -Raw

Assert-That ($manifestSource -notmatch "platform\s*=\s*'[a-z0-9-]+'") `
    'the build manifest does not hardcode a platform string'
Assert-That ($manifestSource -match 'platform\s*=\s*\$Config\.Platform') `
    'the build manifest takes its platform from the configuration'

# --- install ターゲット名を generator に応じて選んでいること ---
#
# 'INSTALL'（大文字）は Visual Studio generator のターゲット名で、Ninja には
# 存在しない。決め打ちすると macOS / Linux のビルドが
# 「ninja: error: unknown target 'INSTALL'」で落ちる（M3 Task 4 の CI 初回で
# 実際に両方落ちた。configure は成功しており、ここだけが違っていた）。
#
# 実行時の挙動は CI でしか確かめられないので、ソースを検査する。
$opencvSource = Get-Content -LiteralPath $opencvScript -Raw

Assert-That ($opencvSource -match "Generator -like 'Visual Studio\*'") `
    'the build step branches on the generator rather than assuming one'
Assert-That ($opencvSource -match "--target', 'install'") `
    'single-config generators get the lowercase install target'



# --- workflow ファイルの一覧を作る ---
#
# **拡張子で絞らない。** GitHub Actions は `.yml` と `.yaml` を同じに扱う。
# `-Filter '*.yml'` で列挙していた版は、`.yaml` で置かれた workflow を
# **以下の全検査から丸ごと落としていた**。レビューで実測: timeout-minutes 無し・
# cache 無し・テスト結果を upload せず・コンテナの中で sudo を使う job を
# `new-lane.yaml` として置くと、4 つの不変条件を同時に破って assertion が
# 1 件も出ないまま `all assertions passed` になった。既存の workflow を
# `.yaml` へ改名しても同じである。
#
# **さらにループを閉じる。** 認識した数と git が追跡している数を突き合わせる。
# こうしておくと、このディレクトリに何が置かれても「検査される」か
# 「赤くなる」かのどちらかにしかならない——「静かに検査対象から外れる」が
# 構造上ありえなくなる。列挙の条件を将来また狭めた人は、その場で落ちる。
$workflowDir = Join-Path $repoRoot '.github/workflows'
$workflowFiles = @(
    Get-ChildItem -LiteralPath $workflowDir -File |
        Where-Object { $_.Extension -in '.yml', '.yaml' } |
        Sort-Object Name
)

#
# 突き合わせは「git が追跡している workflow が 1 つ残らず検査対象に入って
# いるか」という向きで見る。逆向き（数の一致）にすると、**まだコミットして
# いない新しい workflow を置いただけでローカルの `dev.ps1 test` が赤くなる**
# ——正当な作業手順が赤くなる検査は、遠からず誰かに緩められる。追跡されて
# いないファイルは拡張子で列挙される時点で必ず検査対象に入るので、この
# 向きだけで「検査されるか赤くなるか」は成り立つ。
$trackedWorkflows = @(& git -C $repoRoot ls-files '.github/workflows/*')
Assert-That ($trackedWorkflows.Count -gt 0) `
    'git lists the workflow files (0 件なら以下の workflow 検査は全部空振りする)'

$inspectedPaths = @($workflowFiles | ForEach-Object { ".github/workflows/$($_.Name)" })
$notInspected = @($trackedWorkflows | Where-Object { $_ -notin $inspectedPaths })
Assert-That ($notInspected.Count -eq 0) `
    "every tracked file under .github/workflows is inspected (inspected $($workflowFiles.Count) / tracked $($trackedWorkflows.Count))"
$notInspected | ForEach-Object { Write-Host "      not inspected: $_" }

# 必須の workflow が消えていないこと。**拡張子は見ない。** 「`ci-native.yml` が
# 在ること」を条件にすると、`.yaml` へ改名しただけで「無い」ことになり、
# ここも上と同じ穴を持つ。見るのは拡張子を除いた名前である。
$workflowStems = @($workflowFiles | ForEach-Object { $_.BaseName })
foreach ($stem in @(
    'build-opencv'
    'ci-lint'
    'ci-native'
    'ci-sanitizers'
    'ci-unity'
    'codeql'
    'nightly'
    'release'
)) {
    Assert-That ($stem -in $workflowStems) "workflow exists: $stem (.yml でも .yaml でもよい)"
}


# --- workflow を job に切り分ける ---
#
# ここから下の workflow 検査は「ファイルの中に 1 つでも在るか」ではなく
# 「**その job に**在るか」を見る。ファイル単位の検査には、同じ workflow に
# 同種の job が複数在るとき片方だけで通ってしまう穴がある。**実際に通した**:
# restore を呼ぶ job に cache を要求する検査が ci-native の windows job の
# cache で満足してしまい、後から足した macos / linux と ci-sanitizers の
# linux-asan の 3 つがキャッシュ無しのまま残っていた。
#
# YAML パーサは持ち込まない。PowerShell 標準に ConvertFrom-Yaml は無く、
# 外部モジュールを足すと「その依存が 3 platform の CI 全部に在る」ことを
# 別途保証する羽目になる（このテストは 3 platform の ci-native で走る）。
# 代わりに、このリポジトリの workflow が全部守っているインデント規約
# （job は 2、job の属性は 4、step は 6 スペース）で切る。
#
# **規約が崩れたときに黙って通ってはならない。** 切った結果を検算し、
# 辻褄が合わなければ $null を返して呼び出し側で落とす:
#
#   1. top-level に `jobs:` が在る
#   2. その中に 2 スペースの key が 1 つ以上在る
#   3. **緩く数えた 2 スペースの key の数と、job として認識した数が等しい**
#   4. `jobs:` と最初の job の間に空行・コメント以外が無い
#      （最初の job を取りこぼした兆候）
#   5. 各 job が 4 スペースの `runs-on:` か `uses:` を持つ
#   6. `steps:` を持つ job から 6 スペースの step が 1 つ以上取れる
#
# **3 が要るのはレビューで実証された欠陥のためである。** 以前の job 開始判定は
# コロンの直後に行末が来ることを要求していたので、`  linux:  # コンテナで走る`
# という正当な YAML（GitHub はそのまま動かす）を job と認識できず、**その job の
# 本文が前の job に吸収された**。結果、timeout-minutes と cache step を消しても
# `all assertions passed` になり、しかも吸収した側の名前で assertion が二重に
# 出るので、ログを読んでも「linux が消えた」ことが分からなかった。
# `  "linux":` のような引用形式も同じ形で飲み込まれる。
#
# 正規表現を広げるだけでは、次に誰かが思いつく書き方でまた漏れる。**認識できない
# 2 スペース key が 1 つでも在れば、消えるのではなく赤くなる**ようにしてある。
#
# 「job を認識できなかった」を「違反なし」と読まないこと自体が、この
# リポジトリが何度も踏んだ欠陥（.claude/skills/prove-a-check-works）の
# 裏返しである。切れなくなったら検査が空振りするのではなく落ちる。

# job の key。行末コメント（`  linux:  # ...`）と引用形式（`  "linux":`）を許す。
$JobKeyPattern = '^  (?<name>[A-Za-z0-9_.-]+|"[^"]+"|''[^'']+''):\s*(#.*)?$'
# 上を通らない 2 スペース key を見つけるための、わざと緩いパターン。
# コメント行（`  # ...`）だけは除く——YAML として正当で、job ではない。
$LooseJobKeyPattern = '^  [^\s#]'

function Get-WorkflowJob {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    $workflowName = Split-Path -Leaf $Path

    $jobsAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^jobs:\s*$') { $jobsAt = $i; break }
    }
    if ($jobsAt -lt 0) { return $null }

    # jobs: セクションの終わり = 次の top-level key（列 0 が非空白・非コメント）
    $sectionEnd = $lines.Count - 1
    for ($i = $jobsAt + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^[^\s#]') { $sectionEnd = $i - 1; break }
    }

    $starts = @()
    $loose = @()
    for ($i = $jobsAt + 1; $i -le $sectionEnd; $i++) {
        if ($lines[$i] -match $JobKeyPattern) { $starts += $i }
        if ($lines[$i] -match $LooseJobKeyPattern) { $loose += $i }
    }
    if ($starts.Count -eq 0) { return $null }

    # **数の突き合わせ。** 緩く数えた key の数と一致しないなら、認識できない
    # 書き方の job が在る。その job は「無かったこと」にされ、本文が隣の job に
    # 吸収されて検査を素通りする——だから空振りさせずにここで落とす。
    if ($loose.Count -ne $starts.Count) {
        $unrecognised = @($loose | Where-Object { $_ -notin $starts })
        Write-Host "      $workflowName has $($loose.Count) two-space keys under jobs: but only $($starts.Count) look like jobs" -ForegroundColor Yellow
        $unrecognised | ForEach-Object { Write-Host "        line $($_ + 1): $($lines[$_])" -ForegroundColor Yellow }
        return $null
    }

    # jobs: の直後から最初の job までに中身があってはならない。あるなら
    # 最初の job を取りこぼしている（= 2 スペース規約が崩れている）。
    for ($i = $jobsAt + 1; $i -lt $starts[0]; $i++) {
        if ($lines[$i] -notmatch '^\s*(#.*)?$') { return $null }
    }

    $jobs = @()
    for ($j = 0; $j -lt $starts.Count; $j++) {
        $from = $starts[$j]
        $to = if ($j + 1 -lt $starts.Count) { $starts[$j + 1] - 1 } else { $sectionEnd }
        $body = @($lines[$from..$to])

        # job らしい形をしていないなら、切り出しそのものを信用しない。
        if (@($body | Where-Object { $_ -match '^    (runs-on|uses):' }).Count -eq 0) { return $null }

        # `-   name:` のようにダッシュの後の空白が 1 個でない書き方も正当な
        # YAML である。空白ちょうど 1 個を要求していた版はそれを step 境界と
        # 認めず、前の step に融合させていた（融合すると `if: always()` を
        # 前の step から継承したように見える）。
        $stepStarts = @()
        for ($k = 0; $k -lt $body.Count; $k++) {
            if ($body[$k] -match '^      -\s+\S') { $stepStarts += $k }
        }
        if (@($body | Where-Object { $_ -match '^    steps:\s*$' }).Count -gt 0 -and $stepStarts.Count -eq 0) {
            return $null
        }

        $steps = @()
        for ($s = 0; $s -lt $stepStarts.Count; $s++) {
            $sFrom = $stepStarts[$s]
            $sTo = if ($s + 1 -lt $stepStarts.Count) { $stepStarts[$s + 1] - 1 } else { $body.Count - 1 }
            # `, ` を付けて配列のまま 1 要素として積む（付けないと平坦化されて
            # step の境界が消える）。
            $steps += , @($body[$sFrom..$sTo])
        }

        $null = $body[0] -match $JobKeyPattern
        $jobName = $Matches['name'].Trim('"', "'")

        $jobs += [pscustomobject]@{
            Workflow = $workflowName
            Stem     = [System.IO.Path]::GetFileNameWithoutExtension($workflowName)
            Name     = $jobName
            Lines    = $body
            # コメントを除いた本文。「# dev.ps1 test を呼ぶ」のような散文を
            # 「呼んでいる」と読み違えないため。
            Commands = @($body | Where-Object { $_ -notmatch '^\s*#' })
            Steps    = $steps
        }
    }

    # job が 1 件でも配列で返す（呼び出し側が $null と空を区別できるように）。
    return , $jobs
}

# `key:` の行と、それに続く「より深くインデントされた行」をまとめて 1 つの塊で
# 返す。`path: |` のように値が複数行に渡る書き方でも値の全体を見られるように
# するためである（1 行だけ見る検査は、複数行に分けられた時点で空振りする）。
function Get-YamlValueBlock {
    # $Lines は Mandatory にしない。必須の [string[]] は要素の空文字を
    # 弾くので、空行を含む job / step の本文をそのまま渡せなくなる。
    #
    # -Indent を渡すとその深さの key だけを拾う。深さを問わない形だと
    # 「最初に見つかった同名の key」で確定してしまい、run: の中に同じ語が
    # 出てくる job で、見たかった属性を取り逃す。
    param(
        [string[]]$Lines = @(),
        [Parameter(Mandatory)][string]$Key,
        [int]$Indent = -1
    )

    $out = @()
    $indent = -1
    foreach ($line in $Lines) {
        if ($indent -lt 0) {
            if ($line -match "^(?<pad>\s+)$([regex]::Escape($Key)):(\s|`$)") {
                if ($Indent -ge 0 -and $Matches['pad'].Length -ne $Indent) { continue }
                $indent = $Matches['pad'].Length
                $out += $line
            }
            continue
        }
        if ($line -match '^\s*$') { $out += $line; continue }
        $pad = $line.Length - $line.TrimStart().Length
        if ($pad -gt $indent) { $out += $line } else { break }
    }
    if ($indent -lt 0) { return $null }
    return ($out -join "`n")
}

# step 単位の `if:` を返す（無ければ空文字）。step の属性は 8 スペースで、
# 開始行に直接書く `      - if:` の形も同じ深さである。`with:` の中など、
# より深い階層の if は step の条件ではないので対象にしない。
function Get-StepIf {
    param([string[]]$Step = @())

    $found = @()
    foreach ($line in $Step) {
        if ($line -match '^(      -\s+|        )if:\s*(?<v>\S.*?)\s*$') { $found += $Matches['v'] }
    }
    return ($found -join ' | ')
}

# **既定引数の起動も「呼んでいる」と数える。**
#
# `tools/dev.ps1` の既定は `test`、`tools/opencv.ps1` の既定は `restore`
# である（どちらも param() の [string]$Command の既定値）。引数を省いた
# `./tools/dev.ps1` / `./tools/opencv.ps1` は他と同じレーンを走らせるのに、
# 引数を書いた形しか見ていない検査からは**静かに外れる**。レビューで実測:
# ci-native の windows job を `./tools/dev.ps1` に直して結果 upload の step を
# 消しても、`./tools/opencv.ps1` に直して cache の step を消しても、
# どちらも `all assertions passed` になった。後者は 2026-08-29 に CI を
# 全部赤くしたレート制限を、無検査で戻せることを意味する。
#
# 引数なしの分岐は `(?!\s+[-\w])` で「別のサブコマンドが続かないこと」を
# 要求する。`dev.ps1 build` や `opencv.ps1 verify` はここで外れる。
$DevTestLanePattern  = 'dev\.ps1(\s+test(-asan)?(?![-\w])|(?!\s+[-\w]))'
$OpenCvRestorePattern = 'opencv\.ps1(\s+restore(?![-\w])|(?!\s+[-\w]))'

$allJobs = @()
foreach ($wf in $workflowFiles) {
    $jobs = Get-WorkflowJob -Path $wf.FullName
    Assert-That ($null -ne $jobs) `
        "$($wf.Name) can be split into jobs (切れなければ以下の job 単位の検査は空振りする)"
    if ($null -eq $jobs) { continue }
    $allJobs += $jobs
}
Assert-That ($allJobs.Count -gt 0) 'at least one CI job was recognised across the workflows'


# --- Linux のビルドコンテナ: 設定と workflow が一致すること ---
#
# イメージ名は 2 箇所に書かれる。opencv-config.psd1（構成ハッシュに入る正本）と、
# workflow の container: 指定（GitHub Actions は job 開始前に解決するので、
# 設定ファイルから読めない）である。
#
# **片方だけ動かすと、構成ハッシュが指す artifact と実際にビルドされる
# 環境が食い違う。** ハッシュは「同じ構成なら同じ成果物」を意味するはず
# なので、この食い違いはその前提を壊す。2 箇所に同じ事実を書かざるを得ない
# 以上、ずれたことを機械が言う必要がある。
#
# **対象は固定リストではなく `container:` を持つ全 job である。** 4 本の
# workflow を名指ししていた版は nightly を見落としていた——そこにも
# `container: ubuntu:22.04` が在るのに、である。psd1 のイメージを変えると
# 名指しした 4 本は意図どおり赤くなるが、**nightly だけが古いコンテナで
# Linux plugin をビルドし続け、その verify-plugin-portability.ps1 は
# 誰も配っていない環境の glibc 上限を報告し続ける。**「固定していたはずの
# 下限が固定でなくなった」を捕まえるためのレーンが、まさにそれを見逃す形になる。
#
# **照合は部分一致ではなく集合の一致で行う。** 「正本のイメージ名が
# `container:` の中のどこかに出てくるか」を見ていた版は、レビューで
# 実測の抜け道が出た: release.yml の matrix に `linux-arm64` を足し、
# `${{ matrix.platform == 'linux-x64' && 'ubuntu:22.04'
#      || matrix.platform == 'linux-arm64' && 'ubuntu:24.04' || '' }}`
# と書くと **`all assertions passed` になる**——`ubuntu:22.04` が式の中に
# 在るので部分一致は満たされ、それを補うはずだった `-notmatch 'ubuntu-24'`
# は**コンテナのイメージ名がコロン区切り（`ubuntu:24.04`）なので構造上
# 決して一致しない死んだ検査**だった。つまり「これを防ぐ」と書いてある
# 当のケースが素通りしていた。
#
# だから宣言されたイメージ名を**全部**取り出して集合として突き合わせる。
# 死んでいた `ubuntu-24` の行はこの照合に吸収されるので消した。
#
# **読めない書式は「違反なし」ではなく落とす側に倒す。** 関数呼び出しや
# 入れ子の書き方を黙って素通しすると、この検査は在るのに効かない状態に
# なる（このリポジトリが何度も踏んだ形。.claude/skills/prove-a-check-works）。
function Get-DeclaredContainerImage {
    # `container:` の宣言から、宣言されているイメージ名の集合を返す。
    # Recognised = $false は「読めなかった」であって「違反なし」ではない。
    param([Parameter(Mandatory)][string]$Block)

    $unreadable = [pscustomobject]@{ Recognised = $false; Images = @() }

    $lines = @($Block -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(#.*)?$' })
    if ($lines.Count -eq 0) { return $unreadable }

    if ($lines[0] -match '^\s*container:\s*(?<v>\S.*?)\s*$') {
        # インラインの値。入れ子と同居する形は読めない。
        if ($lines.Count -ne 1) { return $unreadable }
        $value = $Matches['v']
    }
    elseif ($lines[0] -match '^\s*container:\s*$') {
        # `container:` の下に `image:` を置く写像形式。
        $imageLines = @($lines | Select-Object -Skip 1 | Where-Object { $_ -match '^\s*image:\s*\S' })
        if ($imageLines.Count -ne 1) { return $unreadable }
        $null = $imageLines[0] -match '^\s*image:\s*(?<v>\S.*?)\s*$'
        $value = $Matches['v']
    }
    else { return $unreadable }

    # 行末コメントを落とす。イメージ名に " #" は現れない。
    $value = ($value -replace '\s+#.*$', '').Trim()

    if ($value -notlike '*${{*') {
        # 素のスカラ。引用符だけ剥がす。
        return [pscustomobject]@{ Recognised = $true; Images = @($value.Trim('"', "'")) }
    }

    # 式と地の文の混在（`prefix-${{ ... }}`）は静的に読めない。
    if ($value -match '^\$\{\{(?<expr>.*)\}\}$') { $expr = $Matches['expr'] }
    else { return $unreadable }

    # **literal の「位置」を見る。** `matrix.platform == 'linux-x64'` の
    # 'linux-x64' は比較の右辺であってイメージ名ではない。イメージ名として
    # 使われるのは `&&` / `||` の直後（と式の先頭）に置かれた literal だけ。
    # それ以外の位置に literal が来る書き方は読めないので落とす。
    $images = @()
    foreach ($m in [regex]::Matches($expr, "'(?<lit>[^']*)'")) {
        $before = $expr.Substring(0, $m.Index).TrimEnd()
        if ($before -eq '' -or $before -match '(&&|\|\|)$') { $images += $m.Groups['lit'].Value; continue }
        if ($before -match '(==|!=|<=|>=|<|>)$') { continue }
        return $unreadable
    }

    # literal を除いた残りが識別子と演算子だけであること。`format(...)` の
    # ような関数呼び出しは展開結果を静的に読めない。
    if (([regex]::Replace($expr, "'[^']*'", ' ')) -notmatch '^[\sA-Za-z0-9_.&|=!<>-]*$') { return $unreadable }

    return [pscustomobject]@{ Recognised = $true; Images = @($images | Where-Object { $_ -ne '' }) }
}

$linuxConfig = Get-OpenCvConfig -Platform 'linux-x64'
$expectedImage = $linuxConfig.Toolchain.Container
Assert-That ($null -ne $expectedImage -and $expectedImage -ne '') `
    'the linux-x64 toolchain declares a build container'

if ($expectedImage) {
    $containerJobs = @()
    foreach ($job in $allJobs) {
        # job の属性は 4 スペース。step の中に出てくる語は対象にしない。
        $block = Get-YamlValueBlock -Lines $job.Lines -Key 'container' -Indent 4
        if ($null -eq $block) { continue }
        $containerJobs += $job

        $declared = Get-DeclaredContainerImage -Block $block
        Assert-That $declared.Recognised `
            "$($job.Workflow) job '$($job.Name)' declares its container in a form this check can read (読めない書式は「違反なし」にしない)"
        if (-not $declared.Recognised) { continue }

        # matrix で振り分ける形
        # （`${{ matrix.platform == 'linux-x64' && 'ubuntu:22.04' || '' }}`）も
        # 通す。見るのは「宣言され得るイメージ名の集合が、構成の正本
        # ちょうど 1 つと一致するか」である。
        $sawImages = @($declared.Images | Sort-Object -Unique)
        Assert-That (($sawImages -join ',') -eq $expectedImage) `
            "$($job.Workflow) job '$($job.Name)' can only run in the container declared in opencv-config.psd1 (expected: $expectedImage / saw: $($sawImages -join ', '))"
    }

    Assert-That ($containerJobs.Count -gt 0) `
        'at least one job declares a build container (0 件なら上の検査は空振りしている)'
}

# --- ci-unity: コンテナに入れられない唯一のレーン ---
#
# ci-unity は job を `container:` にできない（game-ci が docker を使うので
# docker in docker になる）。したがって上の container 検査の対象外であり、
# 代わりに設定から読んで自分で docker run する。**この 2 本が ci-unity に
# 対する唯一の歯止めである** —— しかも ci-unity は「Linux の plugin を実際に
# Unity で読み込む」唯一のレーンでもある。
#
# **ファイル全文の正規表現で見ていた版は、コメント 1 行で満たせた。**
# レビューで 2 つ実測された:
#
#   (a) `image=$(grep ... tools/opencv-config.psd1 ...)` を
#       `image=ubuntu:24.04` に書き換えても、上の説明コメントに
#       `tools/opencv-config.psd1` の語が残るので緑になる。**v0.1.0 で
#       実際に配った欠陥（新しい glibc を要求する .so）そのものを、それを
#       検出するために書かれた検査が素通りさせる。**
#   (b) portability の step を丸ごと `#` でコメントアウトしても、コメントの
#       中に `verify-plugin-portability` の語が残るので緑になる。
#
# だから他の検査と同じ機構に載せる: job を取り、**コメントを除いた行**で、
# step 単位に数える。
$ciUnityJobs = @($allJobs | Where-Object { $_.Stem -eq 'ci-unity' })
Assert-That ($ciUnityJobs.Count -gt 0) `
    'ci-unity has at least one job (0 件なら下の検査は空振りする)'

# **対象は「Unity を実際に起動する job」に限る。**
#
# 2026-08-30 から ci-unity には他 2 platform の plugin をビルドするだけの job が
# 在る。そちらはコンテナも移植性の検査も使わない —— 作った binary は Unity に
# 読み込まれず、`.meta` の解釈だけが問われるからである。ci-unity の全 job を
# 対象にしたままだと、この 2 本は関係の無い job で落ちる。
#
# **絞ったぶん、絞った先が空でないことを必ず見る。** 述語を書き損じて 0 件に
# なると、下の検査はまとめて空振りし、しかも緑になる。
$unityJobs = @($ciUnityJobs | Where-Object {
    @($_.Commands | Where-Object { $_ -match 'uses:\s*game-ci/unity-test-runner@' }).Count -gt 0
})
Assert-That ($unityJobs.Count -gt 0) `
    'ci-unity has at least one job that launches Unity (0 件なら下の検査は空振りする)'

foreach ($job in $unityJobs) {
    $imageSteps = @()
    $portabilitySteps = @()
    foreach ($step in $job.Steps) {
        $cmds = @($step | Where-Object { $_ -notmatch '^\s*#' })
        if (@($cmds | Where-Object { $_ -match 'opencv-config\.psd1' }).Count -gt 0) {
            $imageSteps += , $cmds
        }
        if (@($cmds | Where-Object {
                $_ -match '^\s*(run:\s*)?(&\s+)?\./tools/verify-plugin-portability\.ps1(\s|$)'
            }).Count -gt 0) {
            $portabilitySteps += , $cmds
        }
    }

    Assert-That ($imageSteps.Count -eq 1) `
        "$($job.Workflow) job '$($job.Name)' derives the build image from opencv-config.psd1 in exactly one step (saw $($imageSteps.Count))"

    # **イメージ名を直書きしていないこと。** psd1 から読む行を残したまま
    # 隣に直書きを足す、という形を塞ぐ。
    if ($imageSteps.Count -eq 1) {
        $hardcoded = @($imageSteps[0] | Where-Object { $_ -match 'ubuntu:' })
        Assert-That ($hardcoded.Count -eq 0) `
            "$($job.Workflow) job '$($job.Name)' does not hardcode a container image next to reading it from opencv-config.psd1"
        if ($hardcoded.Count -gt 0) { $hardcoded | ForEach-Object { Write-Host "      $_" } }
    }

    Assert-That ($portabilitySteps.Count -eq 1) `
        "$($job.Workflow) job '$($job.Name)' runs verify-plugin-portability.ps1 in exactly one step before Unity (saw $($portabilitySteps.Count))"
}


# --- ci-unity が 3 platform 同居で Unity を走らせる ---
#
# M3.5 は「全部入りの package で、Unity が自分の platform の binary だけを読む」
# ことを見る検査（PluginGatingTests、EditMode 6 件）を足した。**ところが自動で
# 走る唯一の場所には Linux の .so しか無く、6 件は要素 1 個の集合を検査して
# 緑になっていた** —— 取り違えが起こりうる状況が CI では一度も成立しない。
# roadmap の M3.5 条件 3 を「満たすが未実証」に留めていた理由がこれである。
#
# 2 つを見る:
#   1. 他 platform を重ねる step が在ること
#   2. 「3 つ揃っているはず」という合図をテストに渡す step が在ること
#
# **2 が無くなると静かに弱くなる。** 合図が無いときテストは「1 つ以上」しか
# 要求しないので、重ねるのをやめても・重ね損ねても緑のままになる。
#
# 合図の名前は **C# 側の定数を正本として読む**。ここに文字列を書くと、
# 名前を変えたときに「workflow は書くがテストは読まない」状態が緑で通る。
$gatingTestPath = Join-Path $repoRoot 'tests/UnityProject/Assets/Tests/EditMode/PluginGatingTests.cs'
$markerName = $null
if (Test-Path -LiteralPath $gatingTestPath) {
    # **コメントを落としてから読む。** 全文に当てると、説明の中に書かれた
    # 定義の見た目（`ExpectAllPlatformsMarker = "…"`）を正本と取り違える。
    # このファイルが他の 3 箇所で潰したのと同じ形である。
    $gatingCode = @(Get-Content -LiteralPath $gatingTestPath |
                    Where-Object { $_ -notmatch '^\s*(//|///|\*|/\*)' }) -join "`n"
    if ($gatingCode -match 'ExpectAllPlatformsMarker\s*=\s*"([^"]+)"') {
        $markerName = $Matches[1]
    }
}
Assert-That ($null -ne $markerName) `
    'PluginGatingTests declares the all-platforms marker name (読めなければ下の検査は空振りする)'

if ($markerName) {
    foreach ($job in $unityJobs) {
        $assembleSteps = @()
        $markerSteps = @()
        foreach ($step in $job.Steps) {
            $cmds = @($step | Where-Object { $_ -notmatch '^\s*#' })
            if (@($cmds | Where-Object { $_ -match '\./tools/assemble-plugins\.ps1(\s|$)' }).Count -gt 0) {
                $assembleSteps += , $cmds
            }
            if (@($cmds | Where-Object { $_ -match [regex]::Escape($markerName) }).Count -gt 0) {
                $markerSteps += , $cmds
            }
        }

        Assert-That ($assembleSteps.Count -eq 1) `
            "$($job.Workflow) job '$($job.Name)' assembles the other platforms in exactly one step (saw $($assembleSteps.Count))"
        Assert-That ($markerSteps.Count -eq 1) `
            "$($job.Workflow) job '$($job.Name)' writes '$markerName' so the tests demand every platform (saw $($markerSteps.Count))"

        # **「合図を書いた」は「テストが走った」ではない。**
        #
        # 合図を置いても、PluginGatingTests が assembly から外れれば誰も
        # 読まない。そのとき CI は `==> [EditMode] 10 passed` で緑になる ——
        # failed は 0 で passed は 1 以上だからである。**このブランチの主張
        # （CI が 3 要素の集合に gating を当てる）が丸ごと消えても、誰も
        # 赤くならない。** 走ったことを結果 XML で確かめさせる。
        $requireSteps = @()
        foreach ($step in $job.Steps) {
            $cmds = @($step | Where-Object { $_ -notmatch '^\s*#' })
            # **-match は既定で大文字小文字を区別しない。** 素の 'RequireTest'
            # だと、同じ step にある `matrix.requireTest`（小文字の r）に当たって
            # しまい、**受け渡しを消しても緑になる**（実測）。-cmatch にしたうえで
            # 「引数として渡す」「値を代入する」のどちらかの形を要求する。
            if (@($cmds | Where-Object { $_ -cmatch '(-RequireTest\b|RequireTest\s*=)' }).Count -gt 0 -and
                @($cmds | Where-Object { $_ -cmatch '(-RequireOutput\b|RequireOutput\s*=)' }).Count -gt 0) {
                $requireSteps += , $cmds
            }
        }
        Assert-That ($requireSteps.Count -eq 1) `
            "$($job.Workflow) job '$($job.Name)' passes both RequireTest and RequireOutput to assert-unity-results.ps1 in exactly one step (saw $($requireSteps.Count))"

        # **依存が落ちたときに skip で済ませない。**
        #
        # GitHub は required status check を "successful, skipped, or neutral"
        # で通す（2026-08-30 に文書で確認）。素の `needs:` だけだと、材料を作る
        # job が落ちた瞬間にこの job は skip になり、**必須チェックが緑と同じ
        # 意味を持ったまま merge を許す。** job 側に `cancelled()` を含む `if:`
        # を置くと、依存が落ちても走って赤くなる。
        $needsLines = @($job.Commands | Where-Object { $_ -match '^    needs:' })
        if ($needsLines.Count -gt 0) {
            <#
                **`cancelled()` の語が在るかを見ると逆効果になる。**

                レビューで 3 通り実測された。ゆるい述語（行のどこかに
                `cancelled()`）は次の 2 つを通してしまう:

                  if: ${{ cancelled() }}                              ← `!` の脱落
                  if: ${{ github.event_name == 'push' && !cancelled() }}

                前者は「キャンセルされたときだけ走る」= 事実上ゼロ、後者は
                「PR では走らない」。**どちらも必須チェック 2 本を毎回 skip に
                する** —— 素の `needs:` より悪い（あちらは依存が落ちたときだけ
                skip、こちらは無条件）。番人を足したつもりで穴を恒久化する。

                同じファイルの `if: always()` の検査が既にこれを解いている
                （複合条件を通さない）。同じ厳しさをここにも当てる。

                **`always()` を受理しないのは意図である。** この workflow は
                `cancel-in-progress: true` を宣言しているので、`always()` に
                すると追い越された古い run が Unity のビルドを最後まで走らせ、
                その宣言の目的を打ち消す。
            #>
            $guard = @($job.Commands | Where-Object {
                # `${{ }}` を必須にする。裸の `if: !cancelled()` は YAML の
                # タグ指示子として解析エラーになるし、`}}` 欠落も同じく壊れる。
                # **受理する形を 1 つに絞る。**
                $_ -match '^    if:\s*\$\{\{\s*!\s*cancelled\(\)\s*\}\}\s*$'
            })
            Assert-That ($guard.Count -gt 0) `
                "$($job.Workflow) job '$($job.Name)' has needs: and guards against skipping with exactly if: !cancelled() (ゆるい条件は必須チェックを常時 skip にしうる)"
        }
    }

    # ローカルのレーンも同じ合図を書く。**名前が分かれると、片方だけが
    # 全部入りを検査していることになる。**
    #
    # **全文の -match では、コメント 1 行で満たせる。** レビューで実測された:
    # 書く処理を消して `# ocvu-expect-all-platforms を書くのは無効化している`
    # と置くだけで緑になり、tarball レーンは 3 platform を固めておきながら
    # 何も証明しなくなる。**このファイルが 2 箇所で自分の失敗として記録して
    # いる形そのもの**なので、workflow 側と同じ機構（コメントを落として行を
    # 数える）に載せる。
    $devLines = @(Get-Content -LiteralPath (Join-Path $repoRoot 'tools/dev.ps1') |
                  Where-Object { $_ -notmatch '^\s*#' })
    # 名前が出てくるのは 1 行だけ（合図のパスを組み立てる行）。そこから
    # 導出した変数に対して Set-Content と Remove-Item の両方があること ——
    # **書くだけの実装は、置き去りを消せない。**
    $devNames = @($devLines | Where-Object { $_ -match [regex]::Escape($markerName) })
    Assert-That ($devNames.Count -eq 1) `
        "tools/dev.ps1 names the marker ('$markerName') in exactly one statement (saw $($devNames.Count))"
    Assert-That (@($devLines | Where-Object { $_ -match 'Set-Content\s+-LiteralPath\s+\$marker' }).Count -eq 1) `
        'tools/dev.ps1 writes the marker in exactly one statement'
    Assert-That (@($devLines | Where-Object { $_ -match 'Remove-Item\s+-LiteralPath\s+\$marker' }).Count -eq 1) `
        'tools/dev.ps1 removes the marker when the tree is not all-platform (書くだけでは置き去りを消せない)'

    # **4 箇所目は .gitignore である。** ここだけ突き合わせないと、名前を
    # 変えたときに古い綴りが残り、合図ファイルが追跡対象に現れる。誰かが
    # commit すると、**1 platform しか無いローカルのレーンが全部 3 つを
    # 要求して落ちる**（.gitignore のコメント自身がその危険を書いている）。
    # **「書いてあるか」ではなく「無視されるか」を git に聞く。** 全文の
    # -match は、8 行上で捨てたばかりの形である —— コメント行でも満たせるし、
    # `!` を付けた否定行（= 能動的に追跡へ戻す）でも満たせる。後者のほうが
    # 悪い: 誰かが commit すると 1 platform しか無いローカルのレーンが 3 つを
    # 要求して落ちる。意味そのものを聞けば、どちらも捕まる。
    & git -C $repoRoot check-ignore -q "tests/UnityProject/$markerName"
    Assert-That ($LASTEXITCODE -eq 0) `
        "git ignores the marker at tests/UnityProject/$markerName (書いてあることではなく、無視されることを見る)"

    # 要求する名前が実際に宣言されていること。**空文字だけになると、
    # assert-unity-results.ps1 の照合は部分一致なので何にでも当たり、
    # 「要求したことになっているが何も要求していない」状態になる。**
    $unityWorkflow = @(Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/ci-unity.yml'))
    $declaredRequires = @($unityWorkflow | Where-Object {
        $_ -match '^\s*requireTest:\s*\S' -and $_ -notmatch "requireTest:\s*''"
    })
    Assert-That ($declaredRequires.Count -eq 1) `
        "ci-unity.yml declares exactly one non-empty requireTest lane (saw $($declaredRequires.Count))"
    Assert-That (@($declaredRequires | Where-Object { $_ -match 'PluginGatingTests' }).Count -eq 1) `
        "ci-unity.yml requires the plugin gating tests to have run (saw: $($declaredRequires -join ', '))"

    # **入力ではなく結果を要求していること。** テストが走って通っても、合図が
    # 届かなければ「1 つ以上」の分岐を通っただけかもしれない。そのときの出力は
    # 意図どおり動いた場合と 1 バイトも違わない。
    $declaredOutputs = @($unityWorkflow | Where-Object {
        $_ -match '^\s*requireOutput:\s*\S' -and $_ -notmatch "requireOutput:\s*''"
    })
    Assert-That ($declaredOutputs.Count -eq 1) `
        "ci-unity.yml declares exactly one non-empty requireOutput lane (saw $($declaredOutputs.Count))"
    # **数を写さない。正本から導く。**
    #
    # ここに `5` と書いていたので、**platform を 6 つにしたときに
    # 「1 箇所だけ直すと別レーンが赤くなる」形**になっていた（M6 のレビューで
    # 発覚）。**この検査自身が古い数を強制していた**のが最も悪い ——
    # 直す側から見ると「どちらが正しいのか」が分からなくなる。
    #
    # 正本は tools/dev.ps1 の $script:AllPlatformBinaries である。
    $devPs1 = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/dev.ps1') -Raw
    $binBlock = [regex]::Match($devPs1, '\$script:AllPlatformBinaries\s*=\s*@\((?<body>[\s\S]*?)\)')
    Assert-That ($binBlock.Success) 'dev.ps1 から $AllPlatformBinaries を読み取れる'
    $platformCount = @([regex]::Matches($binBlock.Groups['body'].Value, "'[^']+'")).Count
    Assert-That ($platformCount -ge 3) "正本から platform 数を数えられた (got $platformCount)"

    Assert-That (@($declaredOutputs | Where-Object { $_ -match "native plugins present: $platformCount \[" }).Count -eq 1) `
        "ci-unity.yml requires the tests to report every platform ($platformCount; saw: $($declaredOutputs -join ', '))"
}


# --- コンテナで走る job に sudo を残さない ---
#
# コンテナは root で走るので sudo は入っていない。`sudo apt-get ...` を
# 残すと `sudo: not found` で落ちる。**実測で踏んだ**: Linux をコンテナ化
# したとき、ci-sanitizers の Ninja 導入 step を消し忘れて exit 127 になった。
#
# 「コンテナ化したときに一緒に消すべきもの」は目で追うと漏れる。job が
# container: を持つなら、その job の run: に sudo が無いことを機械が見る。
foreach ($job in $allJobs) {
    $containerLines = @($job.Lines | Where-Object { $_ -match '^    container:' })
    if ($containerLines.Count -eq 0) { continue }

    <#
        **container: が条件式のとき、その job は「常にコンテナ」ではない。**

        M4 で build-opencv の container を
        `${{ matrix.platform == 'linux-x64' && 'ubuntu:22.04' || '' }}` に
        したまま、モバイル（コンテナ外の ubuntu runner）で `sudo apt-get` を
        使う step を足したところ、この検査が落ちた。**検査は正しく反応したが、
        前提のほうが変わっていた。**

        条件式の container を持つ job では、**コンテナに入る platform を
        除外する `if:` が付いた step の sudo は許す。** 付いていない sudo は
        従来どおり止める —— そちらは実際にコンテナの中で走るからである。
    #>
    $conditionalContainer = @($containerLines | Where-Object { $_ -match '\$\{\{' }).Count -gt 0

    if ($conditionalContainer) {
        # step ごとに見る。`if:` を持たない step の sudo だけを数える。
        $sudoLines = @()
        foreach ($step in $job.Steps) {
            $cmds = @($step | Where-Object { $_ -notmatch '^\s*#' })
            $guarded = @($cmds | Where-Object { $_ -match '^\s*(-\s+)?if:\s*\S' }).Count -gt 0
            if ($guarded) { continue }
            $sudoLines += @($cmds | Where-Object { $_ -match '(^|\s)sudo\s' })
        }
        Assert-That ($sudoLines.Count -eq 0) `
            "$($job.Workflow) job '$($job.Name)' has a conditional container and uses sudo only in guarded steps (saw $($sudoLines.Count) unguarded)"
        continue
    }

    $sudoLines = @($job.Commands | Where-Object { $_ -match '(^|\s)sudo\s' })
    Assert-That ($sudoLines.Count -eq 0) `
        "$($job.Workflow) job '$($job.Name)' runs in a container and does not use sudo"
    if ($sudoLines.Count -gt 0) { $sudoLines | ForEach-Object { Write-Host "      $_" } }
}

# --- 説明のつもりのコメントが、道具の指示文にならないこと ---
#
# shellcheck は行頭が `# shellcheck ` のコメントを**指示文**として読む。
# 説明を書くつもりでその形にすると、続きが指示として解釈されて
# SC1072 / SC1073 の構文エラーになる。
#
# **同じ誤りを 2 回踏んだ** —— 1 度目は説明そのもの、2 度目はその説明を
# 説明する行である。目で読んでも「コメントだから安全」に見えるので、
# 機械に見させる。
#
# 有効な指示文（disable= / enable= / source= など）は通す。禁じたいのは
# 「指示文の形をした散文」だけである。
$directivePattern = '^\s*#\s*shellcheck\s+(?!(disable|enable|source|shell|external-sources)=)'

foreach ($wf in $workflowFiles) {
    $bad = @(Get-Content -LiteralPath $wf.FullName |
             Where-Object { $_ -match $directivePattern })
    Assert-That ($bad.Count -eq 0) `
        "$($wf.Name) has no prose comment that shellcheck would read as a directive"
    if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Host "      $_" } }
}

# 同じ形の罠は .sh 側にもある。
foreach ($sh in @(& git -C $repoRoot ls-files '*.sh')) {
    $path = Join-Path $repoRoot $sh
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $bad = @(Get-Content -LiteralPath $path |
             Where-Object { $_ -match $directivePattern })
    Assert-That ($bad.Count -eq 0) `
        "$sh has no prose comment that shellcheck would read as a directive"
}

# --- restore を呼ぶ job には OpenCV のキャッシュを置く ---
#
# `opencv.ps1 restore` は木が既に在れば download を丸ごと省く。キャッシュが
# 無いと、その job が走るたびに artifact を探す API 呼び出しが発生する。
#
# **多数の workflow を同時に走らせるとレート制限に当たり、成果物にもコードにも
# 問題が無いのに CI が全部赤くなる。** 実測（2026-08-29）: Dependabot の PR
# 9 件と v0.1.1 のリリースが同時に落ちた。原因はどれも
# `API rate limit exceeded for installation` だった。
#
# **workflow を足すときに一緒に足すのを忘れる**——実際、codeql / nightly を
# 追加したときと、ci-unity を書き換えたときの計 3 回忘れた。目で追うと漏れる
# ので機械に見させる。
#
# **見るのは job 単位、しかも step 単位である。** ファイル単位で見ていた版は、
# 同じ workflow に restore を呼ぶ job が複数在るとき最初の 1 つの cache で
# 満足していた。job 単位にした後も「job 本文のどこかに `actions/cache@` と
# ハッシュ参照が在れば通る」形だったので、レビューで抜け道が 2 つ実証された:
#
#   (a) **`key:` を一度も見ていなかった。** 3 箇所の
#       `key: opencv-${{ steps.opencv-config.outputs.config-hash }}` を
#       `key: opencv-fixed` に書き換えても全部緑になる。**この形は cache が
#       無いより悪い。** 構成 A で保存した木が構成 B のハッシュのパスへ復元され、
#       opencv.ps1 の Test-OpenCvTreeValid が manifest の configHash 不一致で
#       弾いてディレクトリを消し、毎回 artifact を取り直す。しかも key は
#       完全一致するので保存もされない——つまり上のレート制限の問題が、
#       恒久的かつ不可視のまま戻る。
#   (b) **別の目的の cache で満たせた。** windows job には GoogleTest 用の
#       FetchContent キャッシュがあるので、`Cache OpenCV` step を丸ごと消して
#       ハッシュを含む echo を 1 行足すだけで緑になった。
#
# だから **step を特定して、その step の中の `path:` と `key:` の両方**を見る。
foreach ($job in $allJobs) {
    if (@($job.Commands | Where-Object { $_ -match $OpenCvRestorePattern }).Count -eq 0) { continue }

    $cacheSteps = @()
    $restoreSteps = @()
    foreach ($step in $job.Steps) {
        $cmds = @($step | Where-Object { $_ -notmatch '^\s*#' })
        $text = $cmds -join "`n"
        if ($text -match 'uses:\s*actions/cache@' -and $text -match 'third_party/opencv/') {
            $cacheSteps += , $step
        }
        if (@($cmds | Where-Object { $_ -match $OpenCvRestorePattern }).Count -gt 0) {
            $restoreSteps += , $step
        }
    }

    Assert-That ($cacheSteps.Count -eq 1) `
        "$($job.Workflow) job '$($job.Name)' calls opencv.ps1 restore and has exactly one step caching third_party/opencv (saw $($cacheSteps.Count))"
    if ($cacheSteps.Count -ne 1) { continue }

    $cacheStep = $cacheSteps[0]

    # **cache step の `if:` が restore step の `if:` と一致すること。**
    #
    # codeql.yml は c-cpp の leg でしか OpenCV を開かないので、この 2 step に
    # `if: matrix.language == 'c-cpp'` を付けてある。**その条件を書き損じても
    # 今まで誰も赤くならなかった。** 実測: cache 側だけ `'cpp'`（実在しない値）に
    # 変えても `all assertions passed` になる——cache は決して効かず、c-cpp の
    # leg は毎回 artifact を探す API 呼び出しを出す。GitHub にとっては正当な式
    # なので actionlint も黙るし、**ci-lint は必須チェックではない。**
    # 設定ファイル側は「Cache の if: は Restore の if: と一致させる」と散文で
    # 書いてあるだけだった。散文は機械が読まない。
    #
    # 同じファイルの release 側は「step 単位の if: を持たないこと」を要求して
    # いる（条件を書き損じても誰も赤くならないから）。cache step には
    # 「c-cpp の leg だけで走らせる」という正当な用途があるので禁じられない。
    # 代わりに**必ず対になる step と揃っていること**を機械が見る。
    Assert-That ($restoreSteps.Count -eq 1) `
        "$($job.Workflow) job '$($job.Name)' calls opencv.ps1 restore from exactly one step (saw $($restoreSteps.Count))"
    if ($restoreSteps.Count -eq 1) {
        $cacheIf = Get-StepIf -Step $cacheStep
        $restoreIf = Get-StepIf -Step $restoreSteps[0]
        Assert-That ($cacheIf -eq $restoreIf) `
            "$($job.Workflow) job '$($job.Name)' guards its OpenCV cache with the same if: as its restore step (cache: '$cacheIf' / restore: '$restoreIf')"
    }
    $pathBlock = Get-YamlValueBlock -Lines $cacheStep -Key 'path'
    $keyBlock = Get-YamlValueBlock -Lines $cacheStep -Key 'key'

    Assert-That ($null -ne $pathBlock -and $null -ne $keyBlock) `
        "$($job.Workflow) job '$($job.Name)' declares both path: and key: on its OpenCV cache step"
    if ($null -eq $pathBlock -or $null -eq $keyBlock) { continue }

    $hashRef = 'steps\.(?<id>[A-Za-z0-9_-]+)\.outputs\.config-hash'

    # **path のハッシュと key のハッシュは別の仕事をする。**
    #   key  — 「構成を変えたら cache に当たらない」を作る。ここを定数にすると、
    #          別構成で保存された木が復元され、しかも key 一致で保存もされない。
    #   path — 「構成違いの木がディスク上で混ざらない」だけを作る。
    # 古い木が黙って再利用されるのを防いでいるのは path のハッシュではなく、
    # opencv.ps1 の Test-OpenCvTreeValid（manifest の configHash 照合）である。
    Assert-That ($pathBlock -match $hashRef) `
        "$($job.Workflow) job '$($job.Name)' caches the OpenCV tree at a path keyed on the configuration hash"
    Assert-That ($keyBlock -match $hashRef) `
        "$($job.Workflow) job '$($job.Name)' keys the OpenCV cache on the configuration hash (定数キーだと別構成の木が復元され、しかも保存もされない)"

    # 参照している step id が同じ job に実在すること。`steps.opencv-confg...`
    # のような打ち間違いは空文字に展開されるので、定数キーで cache する形へ
    # 静かに落ちる。actionlint は未定義の id を指摘するが、**ci-lint は必須
    # チェックではない**ので赤いまま merge できる。
    $ids = @()
    foreach ($m in [regex]::Matches("$pathBlock`n$keyBlock", $hashRef)) {
        $ids += $m.Groups['id'].Value
    }
    foreach ($id in ($ids | Sort-Object -Unique)) {
        Assert-That (@($job.Lines | Where-Object {
            $_ -match "^\s+id:\s*$([regex]::Escape($id))\s*`$"
        }).Count -gt 0) `
            "$($job.Workflow) job '$($job.Name)' declares the step id '$id' that its OpenCV cache refers to"
    }
}


# --- テストレーンを走らせる job は結果を artifact 化する ---
#
# M0 の完了条件「テスト結果を機械可読な形式で artifact 化し、**失敗時に
# 読める**状態にする」がこの検査の根拠である。
#
# **要点は `if: always()` を見ることである。** 付いていないと成功時しか
# upload されず、目的（落ちたときに何が落ちたのかを読む）をちょうど
# 果たさない形で緑になる。「upload step が在るか」だけを見る検査はこの穴を
# 通す——step が在ることは目で見て確認できるが、条件が付いていないことは
# 失敗するまで表に出ない。
#
# upload 先は dev.ps1 の $ResultsDir から読む。両方に同じパスを直書きすると、
# 出力先を動かしたときに検査だけが古いパスを見て黙って通る。
$devPs1Text = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/dev.ps1') -Raw
$resultsDir = $null
if ($devPs1Text -match "(?m)^\`$ResultsDir\s*=\s*Join-Path\s+\`$RepoRoot\s+'([^']+)'") {
    $resultsDir = $Matches[1]
}
Assert-That ($null -ne $resultsDir) `
    'dev.ps1 declares where the machine-readable test results go (読めなければ下の検査は空振りする)'

if ($resultsDir) {
    $laneJobs = @()
    foreach ($job in $allJobs) {
        # 対象は `dev.ps1 test` と `dev.ps1 test-asan`、および**引数を省いた
        # 起動**（既定が `test`）の 3 通り。test-tools-slow / test-managed-probe /
        # test-unity-* は別のレーンなので $DevTestLanePattern が外す。
        if (@($job.Commands | Where-Object { $_ -match $DevTestLanePattern }).Count -eq 0) { continue }
        $laneJobs += $job

        $uploadSteps = @()
        foreach ($step in $job.Steps) {
            $text = $step -join "`n"
            if ($text -match 'uses:\s*actions/upload-artifact@' -and
                $text -match [regex]::Escape($resultsDir)) {
                $uploadSteps += , $step
            }
        }

        Assert-That ($uploadSteps.Count -gt 0) `
            "$($job.Workflow) job '$($job.Name)' runs a dev.ps1 test lane and uploads $resultsDir"

        # `if: always()` と `if: ${{ always() }}` の両方を通す（後者も慣用で、
        # 落とすと回避策を書かれて検査の意味が消える）。逆に `always() && ...`
        # のような複合条件は通さない——第 2 項が false なら失敗時に上がらず、
        # 「付いているのに読めない」という一番たちの悪い形になる。足したい人が
        # ここで一度止まるのが正しい。
        foreach ($step in $uploadSteps) {
            Assert-That (@($step | Where-Object {
                $_ -match '^\s+if:\s*(\$\{\{\s*)?always\(\)(\s*\}\})?\s*$'
            }).Count -gt 0) `
                "$($job.Workflow) job '$($job.Name)' uploads the test results with if: always() (無いと失敗時に読めない)"
        }
    }

    Assert-That ($laneJobs.Count -gt 0) `
        'at least one CI job runs a dev.ps1 test lane (0 件なら上の検査は空振りしている)'
}


# --- すべての job に timeout-minutes がある ---
#
# M0 の完了条件「すべての CI ジョブに timeout-minutes が設定されている」。
# 根拠は「クラッシュは赤いテストでなければならない」——ハングした job は
# 赤くならず、runner の上限（6 時間）まで居座って何も教えない。
#
# 現状は全 job に付いているが、**それを保っているものが今まで何も無かった。**
# workflow や job を足したときに忘れても誰も気づかない類である。
foreach ($job in $allJobs) {
    Assert-That (@($job.Lines | Where-Object { $_ -match '^    timeout-minutes:\s*\S' }).Count -gt 0) `
        "$($job.Workflow) job '$($job.Name)' has a job-level timeout-minutes"
}


# --- tools/tests/*.Tests.ps1 が dev.ps1 から呼ばれている ---
#
# `tools/tests/` に置いただけでは**どこからも走らない**。dev.ps1 の
# $ToolsTestScriptsFast / $ToolsTestScriptsSlow に名前で載せて初めて走る。
#
# M1 のレビューで「書かれているがどこからも走らない検査」を H2 として
# 指摘した実績があり、これは同じ形である。書いた本人には走っているように
# 見えるので（ローカルで直接叩けば通る）、目視では捕まらない。
#
# **その 2 つの配列を実際に解析して、所属を見る。** 「dev.ps1 のどこかに
# 名前が出てくるか」を見ていた版は、レビューでコメント 1 行に破られた——
# `# Orphan.Tests.ps1 は意図的にどこからも呼んでいない。` と書き足すだけで
# 緑になり、テストはどこからも走らないまま残った。**H2 を防ぐための検査が
# H2 そのものを再現した形**である。配線を見るなら配線先を見るしかない。
#
# **配列の中のコメントも落とす。** 落とさない版はレビューで実測の抜け道が
# 出た: `$ToolsTestScriptsFast = @(` の直後に
# `    # 'Orphan.Tests.ps1'  # 一時的に無効化` を 1 行足すだけで、どこからも
# 走らないテストが「配線済み」と読まれて緑になる。**「一時的に外す」はごく
# 普通の操作**なので、M1 の H2（書かれているがどこからも走らない）がそのまま
# 復活する。job 本文に対しては同じ手法（$job.Commands）を既に使っている。
$wiredToolsTests = @()
foreach ($m in [regex]::Matches($devPs1Text, '(?s)\$ToolsTestScripts(?:Fast|Slow)\s*=\s*@\((?<body>[^)]*)\)')) {
    $body = [regex]::Replace($m.Groups['body'].Value, '(?m)#.*$', '')
    foreach ($lit in [regex]::Matches($body, "'(?<name>[^']+)'")) {
        $wiredToolsTests += $lit.Groups['name'].Value
    }
}
# **先に集合が空でないことを見る。** 変数名を変えられたときに、空振りして
# 全部通るのではなく、ここで落ちてほしい。
Assert-That ($wiredToolsTests.Count -gt 0) `
    'dev.ps1 の $ToolsTestScriptsFast / $ToolsTestScriptsSlow を解析できた (0 件なら下の検査は空振りする)'

$toolsTests = @(& git -C $repoRoot ls-files 'tools/tests/*.Tests.ps1')
Assert-That ($toolsTests.Count -gt 0) `
    'git lists the tools tests (0 件なら下の検査は空振りする)'
foreach ($t in $toolsTests) {
    $leaf = Split-Path -Leaf $t
    Assert-That ($leaf -in $wiredToolsTests) `
        "tools/dev.ps1 runs $leaf (ToolsTestScriptsFast/Slow に載せないとどこからも走らない)"
}


# --- Release を作る job は、job 単位で tag に限られていること ---
#
# **step 単位の `if:` で公開を止めない。** このリポジトリは同じ形で既に
# 一度踏んでいる（移植性検査。下の節を参照）——「step が在る」だけを見る
# 検査は、条件を書き損じても緑のまま通り、しかも打ち間違いは GitHub に
# とって正当な式なのでどこも赤くならない。
#
# **公開はそれより結果が重い。** 失敗は両方向に静かである:
#
#   常に false になる打ち間違い → tag を打っても Release が作られないのに
#                                 job は緑で、ログも成功時と変わらない
#   常に true になる打ち間違い → 空撃ちで Release が作られる
#
# job 単位に置けば、この走査で見られる。**event まで見ることを要求する**のは、
# `workflow_dispatch` の ref 選択に tag も出るためである —— tag を選んで手動
# 起動すると `github.ref` は `refs/tags/v…` になるので、ref だけの条件では
# 「空撃ちでは Release を作らない」が成り立たない。
$releaseCreators = @()
foreach ($job in $allJobs) {
    if (@($job.Commands | Where-Object { $_ -match 'gh\s+release\s+(create|upload|edit|delete)' }).Count -eq 0) { continue }
    $releaseCreators += $job
}
Assert-That ($releaseCreators.Count -gt 0) `
    'some job creates a GitHub Release (0 件なら下の検査は空振りする)'

# **条件は 1 字ずつ突き合わせる。部分一致にしない。**
#
# 最初は「`refs/tags/` を含むか」「`event_name == 'push'` を含むか」で見ていた。
# レビューで 3 通り実測され、**どれも素通りした**:
#
#   `&&` を `||` にする   → tag を選んだ手動起動で Release が作られる
#   `startsWith` を否定する → tag を打っても作られないのに job は緑
#   step 開始行に `- if:` を書き戻す → 「2 箇所に置かない」が空振り
#
# 部分一致は**論理構造を一切見ない**ので、書き損じが全部通る。公開の条件は
# 1 つしかないのだから、その 1 形だけを受理する。
$ExpectedReleaseGate = "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"

foreach ($job in $releaseCreators) {
    $gate = @($job.Commands | Where-Object { $_ -match '^    if:\s*\S' } | ForEach-Object { $_.Trim() })
    Assert-That ($gate.Count -eq 1) `
        "$($job.Workflow) job '$($job.Name)' has exactly one job-level if: (saw $($gate.Count))"
    if ($gate.Count -ne 1) { continue }

    Assert-That ($gate[0] -ceq $ExpectedReleaseGate) `
        "$($job.Workflow) job '$($job.Name)' gates the release exactly as '$ExpectedReleaseGate' (saw: '$($gate[0])')"

    # 公開する step 側に条件を残さない。**判定が 2 箇所にあると、片方だけを
    # 直したときに食い違う。** step の `if:` は 8 スペースの他に、step 開始行に
    # 直接書く `      - if:` の形もある —— 同じファイルの Get-StepIf が既に
    # 両方を扱っているので、そちらと同じ形を使う（3 つ目を書き下ろして
    # 落としたのが上の C である）。
    $stepGates = @()
    foreach ($step in $job.Steps) {
        $cmds = @($step | Where-Object { $_ -notmatch '^\s*#' })
        if (@($cmds | Where-Object { $_ -match 'gh\s+release\s+' }).Count -eq 0) { continue }
        $stepGates += @(Get-StepIf -Step $cmds | Where-Object { $_ })
    }
    Assert-That ($stepGates.Count -eq 0) `
        "$($job.Workflow) job '$($job.Name)' does not also gate the release step with a step-level if: (判定を 2 箇所に置かない。saw: $($stepGates -join ' / '))"
}


# --- 配る binary を作る job が移植性を検査する ---
#
# **v0.1.0 でこの欠陥を実際に配った。** ubuntu-24.04 で作った .so が
# GLIBC_2.38 を要求し、それより古い環境では DllNotFoundException になった。
# ビルドも linkage 検証も配布物生成も通っていたので、Unity を実際に
# 動かすまで誰も知らなかった。
#
# 対策の verify-plugin-portability.ps1 は作られたが、**呼ぶのは
# ci-unity と nightly だけで、tag を打ったときには走らなかった。**
# つまり実際に配る binary には 1 度も掛かっていなかった。今は Linux の
# ビルドを ubuntu:22.04 のコンテナに移したので構造的には防げているが、
# 「構造で防げているから検査は要らない」は v0.1.0 が否定した論法そのもの
# である。
#
# 見るのは「release のどこかに書いてあるか」ではなく「**plugin を
# ビルドする job が**呼んでいるか」。行頭からの起動だけを数えるので、
# 散文や、エラーメッセージの中にパスが出てくる行では満たされない。
$releaseBuilders = @()
foreach ($job in $allJobs) {
    if ($job.Stem -ne 'release') { continue }
    if (@($job.Commands | Where-Object { $_ -match 'dev\.ps1\s+build(?![-\w])' }).Count -eq 0) { continue }
    $releaseBuilders += $job
}
Assert-That ($releaseBuilders.Count -gt 0) `
    'the release workflow has a job that builds the native plugin (0 件なら下の検査は空振りする)'

foreach ($job in $releaseBuilders) {
    $portabilitySteps = @()
    foreach ($step in $job.Steps) {
        $cmds = @($step | Where-Object { $_ -notmatch '^\s*#' })
        if (@($cmds | Where-Object {
                $_ -match '^\s*(run:\s*)?(&\s+)?\./tools/verify-plugin-portability\.ps1(\s|$)'
            }).Count -gt 0) {
            $portabilitySteps += , $step
        }
    }

    Assert-That ($portabilitySteps.Count -eq 1) `
        "$($job.Workflow) job '$($job.Name)' builds the shipped plugin and runs verify-plugin-portability.ps1 in exactly one step (saw $($portabilitySteps.Count))"
    if ($portabilitySteps.Count -ne 1) { continue }

    $portabilityStep = $portabilitySteps[0]

    # **step 単位の `if:` を持たないこと。**
    #
    # `if: matrix.platform == 'linux-64'`（打ち間違い）や、デバッグ中に置いた
    # `if: false` の消し忘れがあっても、「step が在る」だけを見る検査は緑の
    # まま通る——そして配る binary には二度と検査が掛からない。しかも
    # 打ち間違いは GitHub にとって正当な式なので、どこも赤くならない。
    #
    # この step は platform の振り分けを script 本体の中で行い、未知の
    # platform は exit 1 で落とす設計になっている（足した人が「検査するか
    # しないか」を決めるまで進めない）。その設計を検査が守る。
    # step の属性は 8 スペース（`      - name:` の key と同じ列）。step 開始行に
    # 直接書く `      - if:` の形も拾う。`with:` の中など、より深い階層の if は
    # step 単位の条件ではないので対象外。
    Assert-That (@($portabilityStep | Where-Object {
        $_ -match '^(      -\s+|        )if:\s*\S'
    }).Count -eq 0) `
        "$($job.Workflow) job '$($job.Name)' guards portability inside the script, not with a step-level if: (条件を書き損じても誰も赤くならない)"

    # **matrix の platform 集合と、振り分けが名指ししている platform 集合が
    # 一致すること。**
    #
    # 一致を見ないと、matrix に platform を足した人は **PR では緑**になる
    # （ci-native も ci-sanitizers も release を実行しない）。気づくのは tag を
    # 打った後で、しかも新しい platform の binary は検査されないまま配られる
    # ——**v0.1.0 の形そのもの**である。逆に条件を「決して真にならないもの」へ
    # 狭めても、行が残っている限り緑のままになる。
    $matrixPlatforms = @()
    foreach ($m in [regex]::Matches(($job.Commands -join "`n"), '(?m)^\s*-\s*platform:\s*(?<p>[A-Za-z0-9_.-]+)\s*$')) {
        $matrixPlatforms += $m.Groups['p'].Value
    }
    Assert-That ($matrixPlatforms.Count -gt 0) `
        "$($job.Workflow) job '$($job.Name)' declares its platforms in a matrix (読めなければ下の突き合わせは空振りする)"

    $branchPlatforms = @()
    foreach ($line in ($portabilityStep | Where-Object { $_ -match '\$platform\s+-(eq|ne|in|notin)\b' })) {
        foreach ($m in [regex]::Matches($line, "'(?<p>[A-Za-z0-9_.-]+)'")) {
            $branchPlatforms += $m.Groups['p'].Value
        }
    }
    Assert-That ($branchPlatforms.Count -gt 0) `
        "$($job.Workflow) job '$($job.Name)' branches the portability check on the platform (読めなければ下の突き合わせは空振りする)"

    if ($matrixPlatforms.Count -gt 0 -and $branchPlatforms.Count -gt 0) {
        $unhandled = @($matrixPlatforms | Where-Object { $_ -notin $branchPlatforms } | Sort-Object -Unique)
        $unknown = @($branchPlatforms | Where-Object { $_ -notin $matrixPlatforms } | Sort-Object -Unique)
        Assert-That ($unhandled.Count -eq 0) `
            "$($job.Workflow) job '$($job.Name)' decides for every matrix platform whether to verify portability (未決定: $($unhandled -join ', '))"
        Assert-That ($unknown.Count -eq 0) `
            "$($job.Workflow) job '$($job.Name)' does not branch on a platform the matrix never produces (余分: $($unknown -join ', '))"
    }
}


# --- CodeQL の query-filters が静かに壊れていないこと ---
#
# codeql-config.yml の query-filters には、機械が見ていない静かな失敗が
# 2 つある。**どちらも設定ファイルのコメントで警告しているだけだった。**
#
#   1. **並び順。** 最初のフィルタが `exclude` のとき「他は全部含める」が
#      既定になる。先頭に `- include:` を足すと既定が反転し、解析が
#      その 1 規則だけに縮む——**書いた覚えのない規則までまとめて消える。**
#   2. **綴り。** codeql-action が持つ設定の JSON schema は query-filters の
#      要素に「何でも通る」分岐を持つので、`exclude` を `excludes` と
#      書いても schema 検証は通る（実測）。CI は緑のままで、外したはずの
#      指摘だけが黙って出続ける。
#
# id が今も解決することの証明にはならないが、順序の罠を固定でき、
# filter の変更が「静かな変更」ではなく「意図した変更」になる。
$codeqlConfigPath = Join-Path $repoRoot '.github/codeql/codeql-config.yml'
Assert-That (Test-Path -LiteralPath $codeqlConfigPath) 'the CodeQL config file exists'

if (Test-Path -LiteralPath $codeqlConfigPath) {
    $codeqlLines = @(Get-Content -LiteralPath $codeqlConfigPath)

    $filtersAt = -1
    for ($i = 0; $i -lt $codeqlLines.Count; $i++) {
        if ($codeqlLines[$i] -match '^query-filters:\s*$') { $filtersAt = $i; break }
    }
    Assert-That ($filtersAt -ge 0) `
        'the CodeQL config declares query-filters (読めなければ下の検査は空振りする)'

    if ($filtersAt -ge 0) {
        $filtersEnd = $codeqlLines.Count - 1
        for ($i = $filtersAt + 1; $i -lt $codeqlLines.Count; $i++) {
            if ($codeqlLines[$i] -match '^[^\s#]') { $filtersEnd = $i - 1; break }
        }

        $entryKeys = @()
        $entryIds = @()
        $rawEntries = 0
        foreach ($line in $codeqlLines[$filtersAt..$filtersEnd]) {
            if ($line -match '^\s*-\s') { $rawEntries++ }
            if ($line -match '^\s*-\s*(?<key>[A-Za-z]+):\s*(#.*)?$') { $entryKeys += $Matches['key'] }
            if ($line -match '^\s+id:\s*(?<id>\S+)\s*$') { $entryIds += $Matches['id'] }
        }

        # 認識できない書き方（`- exclude: {id: ...}` のようなフロー形式など）が
        # 在れば、空振りではなく落とす。
        Assert-That ($rawEntries -gt 0 -and $rawEntries -eq $entryKeys.Count) `
            "every query-filter entry is in the recognised form (entries $rawEntries / recognised $($entryKeys.Count))"

        Assert-That (@($entryKeys | Where-Object { $_ -ne 'exclude' }).Count -eq 0) `
            "every query-filter is an exclude (include を混ぜると既定が反転する。saw: $($entryKeys -join ', '))"
        Assert-That ($entryKeys.Count -gt 0 -and $entryKeys[0] -eq 'exclude') `
            'the first query-filter is an exclude (先頭が include だと「それ以外は全部含む」が反転する)'

        $expectedIds = @('cs/call-to-unmanaged-code', 'cs/unmanaged-code')
        $actualIds = @($entryIds | Sort-Object -Unique)
        Assert-That (($actualIds -join ',') -eq ($expectedIds -join ',')) `
            "query-filters exclude exactly the two P/Invoke rules (expected: $($expectedIds -join ', ') / saw: $($actualIds -join ', '))"
    }
}


# --- モバイル platform が構成を引ける（M4 Task 1）---
#
# 既存の 3 platform は「実行中の OS = 対象 platform」を前提にしていた
# （Get-OpenCvPlatform が $IsWindows 等から判定する）。**モバイルはクロス
# コンパイルなので host と対象が一致しない。** Get-OpenCvPlatform（host 判定）は
# 変えず、Get-OpenCvConfig -Platform に対象を明示的に渡す形にする。
# **クロスビルドする platform。** モバイル 2 つに加えて Web も同じ性質を持つ
# （host で実行できない／ASan の preset を作らない／toolchain file を指す）。
$MobilePlatforms = @('android-arm64', 'ios-arm64', 'web-wasm')
$AllTargetPlatforms = @('windows-x64', 'macos-arm64', 'linux-x64') + $MobilePlatforms

foreach ($mobile in $MobilePlatforms) {
    $cfg = Get-OpenCvConfig -Platform $mobile
    Assert-That ($cfg.Platform -eq $mobile) "Get-OpenCvConfig -Platform $mobile returns that platform"
    Assert-That ($null -ne $cfg.Toolchain) "$mobile has a toolchain"
    Assert-That ($cfg.Toolchain.Generator -eq 'Ninja') `
        "$mobile builds with Ninja (生成物の配置を platform 間で揃える)"

    $hash = Get-OpenCvConfigHash -Config $cfg
    Assert-That ($hash -match '^[0-9a-f]{12}$') "$mobile hash is 12 lowercase hex characters"
}

<#
    **構成ハッシュが platform 間で衝突しない。**

    衝突すると、Android の artifact 名で iOS の木が展開されるような事故が
    静かに成立する。

    **ただし「5 つのハッシュが全部違う」を assert しても何も証明しない** ——
    Config には Platform が入っており、ハッシュは Config 全体から取るので、
    platform が違えば必ず違うハッシュになる。**構造的に常に真な検査は検査で
    はない**（実測: android の toolchain を丸ごと ios と同じにしても通った）。

    落ちうる形にする: **Platform を抜いたらハッシュが変わること**を見る。
    これが成り立たなくなるのは、誰かが Get-OpenCvConfigHash を「選んだキーだけ
    ハッシュする」形に変えたときで、そのとき初めて衝突が現実になる。
#>
foreach ($p in $AllTargetPlatforms) {
    $cfg = Get-OpenCvConfig -Platform $p
    $withPlatform = Get-OpenCvConfigHash -Config $cfg

    $withoutPlatform = $cfg | Select-Object -Property * -ExcludeProperty Platform
    Assert-That ((Get-OpenCvConfigHash -Config $withoutPlatform) -ne $withPlatform) `
        "the hash for $p depends on Platform (依存しなくなると別 platform の artifact が展開される)"
}

# **未知の platform は黙って通さない。** 既定に倒すと、対応していない対象で
# 「Windows の構成で Android をビルドする」が静かに成立する。
$rejected = $false
try { Get-OpenCvConfig -Platform 'android-armv7' | Out-Null } catch { $rejected = $true }
Assert-That $rejected 'an unknown platform is rejected, not defaulted'

# **artifact 名に platform が入る。** 入らないと 5 platform が同じ名前を取り合う
# （M3 の Release asset 名の衝突と同じ形）。
foreach ($p in $AllTargetPlatforms) {
    $name = Get-OpenCvArtifactName -Config (Get-OpenCvConfig -Platform $p)
    Assert-That ($name -like "*-$p-*") "the artifact name for $p embeds the platform (saw: $name)"
}



# --- 16 KB page size の検査が、両方向に動く（M4 Task 4）---
#
# **実物の .so だけで試さない。** 実物は通る側にしかならないので、
# 「検査が効いている」と「検査が空振りしている」が区別できない。
# 最小の ELF を合成して、通る側と落ちる側の両方を見る。
function New-TestElf {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][long] $PAlign,
        [int] $PhNum = 1,
        # program header の p_type。既定は PT_LOAD(1)。PT_NOTE(4) を渡すと
        # 「header はあるが PT_LOAD は 0 件」の ELF が作れる。
        [uint32] $PType = 1
    )

    # ELF64 little-endian、program header が PT_LOAD $PhNum 個だけの最小構成。
    $phoff = 0x40
    $phentsize = 0x38
    $size = $phoff + $phentsize * [Math]::Max($PhNum, 1)
    $bytes = New-Object byte[] $size

    $bytes[0] = 0x7F; $bytes[1] = 0x45; $bytes[2] = 0x4C; $bytes[3] = 0x46  # \x7fELF
    $bytes[4] = 2      # EI_CLASS = ELFCLASS64
    $bytes[5] = 1      # EI_DATA  = little endian
    $bytes[6] = 1      # EI_VERSION
    [BitConverter]::GetBytes([uint16]3).CopyTo($bytes, 0x10)      # e_type = ET_DYN
    [BitConverter]::GetBytes([uint16]0xB7).CopyTo($bytes, 0x12)   # e_machine = AArch64
    [BitConverter]::GetBytes([uint64]$phoff).CopyTo($bytes, 0x20) # e_phoff
    [BitConverter]::GetBytes([uint16]$phentsize).CopyTo($bytes, 0x36)
    [BitConverter]::GetBytes([uint16]$PhNum).CopyTo($bytes, 0x38)

    for ($i = 0; $i -lt $PhNum; $i++) {
        $off = $phoff + $i * $phentsize
        [BitConverter]::GetBytes($PType).CopyTo($bytes, $off)              # p_type
        [BitConverter]::GetBytes([uint64]$PAlign).CopyTo($bytes, $off + 0x30) # p_align
    }

    [IO.File]::WriteAllBytes($Path, $bytes)
}

$pageScript = Join-Path $repoRoot 'tools/verify-android-page-size.ps1'
<#
    **一時ファイル名を実行ごとに一意にする。**

    固定名にしていたら、2 つの実行が同じパスを共有して潰し合った（実測:
    片方が消した直後にもう片方が読みに行き、無関係な assertion が落ちた）。
    `dev.ps1 test` は tools のテストを他と並べて走らせるので、これは
    起こりうる。**「たまたま赤い」は「コードが理由で赤い」と区別できない。**
#>
$tmpDir = [IO.Path]::GetTempPath()
$runId = [guid]::NewGuid().ToString('n').Substring(0, 8)
$elfOk   = Join-Path $tmpDir "ocvu-align-ok-$runId.so"
$elfBad  = Join-Path $tmpDir "ocvu-align-bad-$runId.so"
$elfNone = Join-Path $tmpDir "ocvu-align-none-$runId.so"

New-TestElf -Path $elfOk  -PAlign 16384
New-TestElf -Path $elfBad -PAlign 4096
<#
    **PT_LOAD が 0 件の ELF を、program header ごと 0 個にして作らない。**

    最初は -PhNum 0 で作っていたが、それでは script 冒頭の
    「program header が読めません」で先に落ちるので、**「0 件で緑にしない」の
    番人には一度も到達していなかった**（実測: その番人を無効化しても検査は
    緑のままだった）。header は 1 つ置き、種類だけ PT_NOTE にする。
#>
New-TestElf -Path $elfNone -PAlign 16384 -PhNum 1 -PType 4

& pwsh -NoProfile -File $pageScript -PluginPath $elfOk *> $null
Assert-That ($LASTEXITCODE -eq 0) 'a 16384-aligned ELF passes the page size check'

& pwsh -NoProfile -File $pageScript -PluginPath $elfBad *> $null
Assert-That ($LASTEXITCODE -ne 0) 'a 4096-aligned ELF FAILS the page size check (落ちないなら検査は無意味)'

<#
    **0 件で緑にしない。**

    ただし**終了コードだけを見ても、この番人が在るかは分からない** ——
    番人を外しても StrictMode 下の Measure-Object が空の入力で throw して
    exit 1 になるからである（実測）。区別できないものを検査したことにしない。

    番人の値打ちは「読み方が想定と違った」と**読める形で**落ちることなので、
    メッセージまで見る。
#>
$noneOut = & pwsh -NoProfile -File $pageScript -PluginPath $elfNone 2>&1 | Out-String
Assert-That ($LASTEXITCODE -ne 0) 'an ELF with zero PT_LOAD segments FAILS (0 件は「違反なし」ではない)'
Assert-That ($noneOut -match 'PT_LOAD') `
    'the zero-PT_LOAD failure names PT_LOAD (生の例外で落ちるのと区別が付く形で落ちること)'

# 存在しないファイルも失敗させる。**「検査対象が無いので合格」にしない。**
& pwsh -NoProfile -File $pageScript -PluginPath (Join-Path $tmpDir 'ocvu-does-not-exist.so') *> $null
Assert-That ($LASTEXITCODE -ne 0) 'a missing plugin FAILS the page size check'

Remove-Item $elfOk, $elfBad, $elfNone -Force -ErrorAction SilentlyContinue



# --- CMakePresets とクロスビルドの前提（M4 Task 3 / 5）---
$presets = Get-Content -LiteralPath (Join-Path $repoRoot 'CMakePresets.json') -Raw | ConvertFrom-Json
$configureNames = @($presets.configurePresets | ForEach-Object { $_.name })
$buildNames = @($presets.buildPresets | ForEach-Object { $_.name })

foreach ($p in @('android-arm64-debug', 'ios-arm64-debug', 'web-wasm-debug')) {
    Assert-That ($configureNames -contains $p) "CMakePresets.json has a configure preset named $p"
    Assert-That ($buildNames -contains $p) "CMakePresets.json has a build preset named $p"
}

# **モバイルに ASan の preset を作らない。** クロス環境では走らせないので、
# 「あるのに誰も走らせていない」状態を作らない。
foreach ($p in @('android-arm64-asan', 'ios-arm64-asan', 'web-wasm-asan')) {
    Assert-That (-not ($configureNames -contains $p)) "there is no $p preset (クロス環境で ASan は走らせない)"
}

# **モバイルの preset は toolchain file を指す。** 指さないと host 向けに
# ビルドされ、**成功したように見えて中身が別物になる。**
foreach ($p in @('android-arm64-debug', 'ios-arm64-debug', 'web-wasm-debug')) {
    $preset = $presets.configurePresets | Where-Object { $_.name -eq $p }
    Assert-That ($preset.PSObject.Properties.Name -contains 'toolchainFile') `
        "$p sets a toolchainFile (指さないと host 向けにビルドされる)"
    $tc = $preset.toolchainFile -replace '\$\{sourceDir\}', $repoRoot
    Assert-That (Test-Path -LiteralPath $tc) "$p の toolchain file が実在する ($tc)"
}

<#
    **iOS だけ静的ライブラリを作る。**

    iOS はアプリの外から .dylib を読み込めない。**SHARED のままでもビルドは
    成功する**ので、Unity に入れて初めて壊れる —— v0.1.0 が踏んだ
    「ビルドできた ≠ 動く」と同じ形である。分岐が消えていないことを見る。
#>
$nativeCMakeLines = @(Get-Content -LiteralPath (Join-Path $repoRoot 'native/CMakeLists.txt') |
                      Where-Object { $_ -notmatch '^\s*#' })
<#
    iOS の分岐は 2 つある。**どちらも欠けてはならない。**

      1. ライブラリの種類を STATIC にする（共有ライブラリは iOS で読み込めない）
      2. **OpenCV を .a に束ねる** —— CMake は STATIC ライブラリに依存アーカイブを
         取り込まないので、これが無いと自分の object しか入らず、Unity が Xcode で
         リンクした時点で未解決シンボルになる（M4 のレビューで発見）

    **1 だけあって 2 が無い状態がいちばん危ない。** ビルドも「形の検査」も通り、
    実機に載せる段で初めて壊れる。
#>
Assert-That (@($nativeCMakeLines | Where-Object {
    $_ -match 'CMAKE_SYSTEM_NAME\s+STREQUAL\s+"iOS"'
}).Count -eq 2) 'native/CMakeLists.txt branches on iOS twice (種類の指定と、OpenCV の束ね)'
Assert-That (@($nativeCMakeLines | Where-Object {
    $_ -match 'OCVU_LIBRARY_KIND\s+STATIC'
}).Count -eq 1) 'native/CMakeLists.txt builds a STATIC library for iOS (共有ライブラリは iOS で読み込めない)'
Assert-That (@($nativeCMakeLines | Where-Object {
    $_ -match 'OCVU_LIBTOOL'
}).Count -ge 1) 'native/CMakeLists.txt bundles OpenCV into the iOS .a (CMake は依存アーカイブを取り込まない)'
Assert-That (@($nativeCMakeLines | Where-Object {
    $_ -match 'add_library\(opencv_unity_native\s+SHARED'
}).Count -eq 0) 'the shipped library kind is not hardcoded to SHARED any more'



# --- 5 platform が build-opencv / release / ci-native を通る（M4 Task 2/10）---
#
# **matrix から静かに漏れると、restore が「artifact が無い」で落ちる。**
# しかもそれは、モバイルをビルドしようとした人の手元で初めて起きる。
# **写さず正本から読む。** ここは長らく platform 名を直書きしていたが、
# `add-a-platform` skill が言うとおり「写している場所は直す場所を 1 つ増やす」。
# 読めなければ空振りではなく落とす。
$AllTargetPlatformsForWorkflows = @(
    (Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'tools/opencv-config.psd1')).Toolchains.Keys |
        Sort-Object)
Assert-That ($AllTargetPlatformsForWorkflows.Count -ge 3) `
    "opencv-config.psd1 から platform 一覧を読めた ($($AllTargetPlatformsForWorkflows.Count) 件)"

foreach ($wf in @('build-opencv.yml', 'release.yml')) {
    $text = Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/$wf") -Raw
    foreach ($p in $AllTargetPlatformsForWorkflows) {
        Assert-That ($text -match "(?m)^\s*- platform:\s*$([regex]::Escape($p))\s*$") `
            "$wf has a matrix entry for $p"
    }
}

# **モバイルは ci-native でもクロスビルドされる。** release でしかビルドされないと、
# 壊れたことが分かるのが tag を打った後になる —— M3.5 で踏んだ
# 「配る直前に初めて走る配線」と同じ形である。
$ciNativeText = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/ci-native.yml') -Raw
foreach ($p in @('android-arm64', 'ios-arm64', 'web-wasm')) {
    Assert-That ($ciNativeText -match "(?m)^\s*- platform:\s*$([regex]::Escape($p))\s*$") `
        "ci-native.yml cross-builds $p (release でしか作らないと、壊れたと分かるのが tag の後になる)"
}

# **Android の 16 KB 検査は、配る binary を作る job でも走る。**
# ci-native だけだと、tag を打ったときには掛からない —— v0.1.0 の
# verify-plugin-portability.ps1 がまさにその状態だった。
$releaseLines = @(Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/release.yml') |
                  Where-Object { $_ -notmatch '^\s*#' })
Assert-That (@($releaseLines | Where-Object {
    $_ -match '^\s*(run:\s*)?(&\s+)?\./tools/verify-android-page-size\.ps1(\s|$)'
}).Count -eq 1) 'release.yml runs verify-android-page-size.ps1 in exactly one step (配る binary に掛からないと意味が無い)'

# --- platform を振り分ける step は、どれも全 platform を名指しすること ---
#
# **同じファイルの中に振り分けが 2 つ在り、片方だけが置いていかれる。**
# release.yml は「未知の platform は失敗させる」形（`unknown platform '...'`）を
# 2 箇所に持つ —— linkage の検査と、移植性の検査である。**M6 で、後者にだけ
# web-wasm を足して前者に足し忘れた。** ローカルの全レーンは緑のまま、
# CI の `Package web-wasm` だけが落ち、`Assemble` がそれに連鎖した。
#
# **これは M4 から数えて 3 度目の「同一ファイルの 2 つ目の一覧」である**
# （`pack-upm-tarball.ps1` の switch、`PackageRelease.Tests.ps1` の 3 つ目の一覧）。
# 人が読んで気づく形ではないので、機械に見させる。
#
# **一覧を持たない。** 正本（opencv-config.psd1）から読んだ全 platform が、
# **すべての振り分けに現れること**だけを見るので、platform が増えれば
# 要求も自動で増える。
$releaseRaw = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/release.yml') -Raw
$platformGuards = [regex]::Matches($releaseRaw, "unknown platform '")

# **0 件を緑にしない。** 振り分けごと消えたら、この検査は何も見ていない。
Assert-That ($platformGuards.Count -ge 2) `
    "release.yml has at least 2 platform dispatches guarded by `"unknown platform`" ($($platformGuards.Count) found)"

foreach ($guard in $platformGuards) {
    $head = $releaseRaw.Substring(0, $guard.Index)
    # 直前の `- name:` から guard までが、その step の振り分け本体である。
    $stepStart = $head.LastIndexOf('- name:')
    if ($stepStart -lt 0) {
        Assert-That $false 'unknown platform guard is inside a named step'
        continue
    }
    $window = $releaseRaw.Substring($stepStart, $guard.Index - $stepStart)
    $stepName = ($window -split "`r?`n")[0].Trim() -replace '^- name:\s*', ''

    $missing = @($AllTargetPlatformsForWorkflows | Where-Object {
        $window -notmatch [regex]::Escape("'$_'")
    })
    Assert-That ($missing.Count -eq 0) `
        "release.yml step `"$stepName`" names every platform ($(if ($missing.Count) { "missing: $($missing -join ', ')" } else { 'all present' }))"
}



# --- action の参照は固定されていて、同じ action の版が割れていないこと ---
#
# **動くタグを踏むと、こちらは 1 行も変えていないのに CI が落ちる。**
# `.github/dependabot.yml` の冒頭がそのために在る —— 上流の変化を
# 「いつの間にか変わっていた」ではなく「差分として見える変更」にする。
# ただし Dependabot が見るのは `owner/repo@ref` の形だけで、
# **`docker://` は parser が明示的に読み飛ばす**（dependabot-core の
# github_actions/lib/dependabot/github_actions/file_parser.rb）。
# つまり最も追跡しにくい参照が、最も追跡されない。だからここで見る。
#
# **版の割れも見る。** 実際に踏んだ: Dependabot が upload-artifact を
# v4 -> v7 に上げた PR を手で当てたとき、そのとき手元に無かった
# unity-probe.yml だけ v6 のまま残った（2026-09-01 に発見）。
# **どの workflow も緑のまま**で、気づく契機が無い —— unity-probe は
# 手動起動なので、次に誰かが起動するまで走りさえしない。
#
# `github/codeql-action/init` と `.../analyze` のように 1 つの action の
# 別 path を使う場合があるので、名前は owner/repo に丸めて突き合わせる。
# **片方だけ上げると落ちる**のが狙いである。
#
# **参照は「認識できたら通す」ではなく「認識できなければ落とす」で扱う。**
# レビューで実測された抜け道がこれである —— 値を \S+ で拾っていた版は
# 引用符付きの `uses: "actions/checkout@main"` を名前 `"actions/checkout`・
# 版 `main"` に割ってしまい、**pin 検査と版の割れ検査の両方を素通りした**
# （引用符が付くだけで、動くタグも版違いも 1 件も FAIL が出なかった）。
# しかも下の「拾えた数」の門も、誤った値で 1 件と数えるので発火しない ——
# **2 つの門が同じ穴を共有していた。**
$usesLines = @()
foreach ($wf in $workflowFiles) {
    foreach ($line in (Get-Content -LiteralPath $wf.FullName)) {
        if ($line -match '^\s*#') { continue }
        if ($line -notmatch '^\s*(-\s+)?uses:\s*(.+?)\s*$') { continue }
        # 行末コメントを落とし、引用符を剥がす。`@<40 桁 SHA> # v4.2.2` は
        # GitHub が推奨する固定の形なので、**誤検知で落としてはいけない。**
        $value = ($Matches[2] -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
        $usesLines += [pscustomobject]@{ Workflow = $wf.Name; Ref = $value }
    }
}

# **拾えた数が合わなければ、空振りではなく落とす。** 上の正規表現が
# 書き方の揺れで当たらなくなると、以下の assertion は全部「対象 0 件」で
# 緑になる。**ただしこの門だけでは足りない**（上のコメント参照）ので、
# 値の側でも「分類できなければ落とす」を持つ。
$looseUses = 0
foreach ($wf in $workflowFiles) {
    $looseUses += @(Get-Content -LiteralPath $wf.FullName |
                    Where-Object { $_ -notmatch '^\s*#' -and $_ -match '(?<![-\w])uses:' }).Count
}
Assert-That ($usesLines.Count -gt 0) 'the workflows declare at least one action (0 件なら以下は全部空振りする)'
Assert-That ($usesLines.Count -eq $looseUses) `
    "every uses: line was parsed (parsed $($usesLines.Count) / found $looseUses)"

# 参照を「名前」と「版」に割る。**知っている 3 つの形のどれでもなければ落とす。**
#   1. docker://image[:tag]      —— タグが版
#   2. ./path                    —— リポジトリ内の action。版という概念が無い
#   3. owner/repo[/path]@ref     —— ref が版（タグでも SHA でもよい）
$actionRefs = @()
foreach ($u in $usesLines) {
    if ($u.Ref -like 'docker://*') {
        $image = $u.Ref.Substring('docker://'.Length)
        $sep   = $image.LastIndexOf(':')
        # `host:port/image` にタグが無い形を版付きと誤認しない。
        if ($sep -lt 0 -or $image.Substring($sep + 1).Contains('/')) { $name = $image; $version = '' }
        else { $name = $image.Substring(0, $sep); $version = $image.Substring($sep + 1) }
        $actionRefs += [pscustomobject]@{
            Workflow = $u.Workflow; Ref = $u.Ref; Name = "docker://$name"; Version = $version
        }
    }
    elseif ($u.Ref -match '^\.{1,2}/') {
        # リポジトリ内の action は git が版を持つ。pin する対象が無いので
        # 以下の 2 つの検査には掛けない（**掛けると必ず落ちる誤検知になる**）。
        continue
    }
    elseif ($u.Ref -match '^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(/[A-Za-z0-9._/-]+)?@(\S+)$') {
        $actionRefs += [pscustomobject]@{
            Workflow = $u.Workflow; Ref = $u.Ref; Name = $Matches[1]; Version = $Matches[3]
        }
    }
    else {
        Assert-That $false "$($u.Workflow) uses a reference this check can classify (saw '$($u.Ref)')"
    }
}
Assert-That ($actionRefs.Count -gt 0) 'at least one external action reference was classified'

# (a) 動くタグを禁じる。空の版（`@` の後ろが無い）もここで落ちる。
$floating = @('main', 'master', 'head', 'latest', '')
foreach ($a in $actionRefs) {
    Assert-That (-not ($floating -contains $a.Version.ToLowerInvariant())) `
        "$($a.Workflow) pins $($a.Name) to a fixed version (saw '$($a.Ref)')"
}

# (b) 同じ action が 2 つの版で参照されていないこと。
foreach ($group in ($actionRefs | Group-Object -Property Name)) {
    $versions = @($group.Group | ForEach-Object { $_.Version } | Sort-Object -Unique)
    Assert-That ($versions.Count -eq 1) `
        "$($group.Name) is referenced at one version across the workflows (saw: $($versions -join ', '))"
    if ($versions.Count -gt 1) {
        $group.Group | ForEach-Object { Write-Host "      $($_.Workflow): $($_.Ref)" -ForegroundColor Yellow }
    }
}


# --- NuGet の版が csproj の間で割れていないこと ---
#
# 同じ 4 つのテスト用パッケージを 2 つの csproj が持つ
# （`tests/Managed/CvUnity.Tests.Managed` と、M5 で足した
# `bindings/generator/Ocvu.Generator.Tests`）。**割れると、同じ solution の
# 中で 2 つの test runner が別の版で走る。**
#
# **Dependabot が両方を見るかは確かめていない。** 設定に書いてある
# `directory` は `/tests/Managed` の 1 つで、generator の csproj は
# solution からの project 参照で繋がっているだけである（依存グラフは
# パッケージ名でまとめてしまうので、どちらの manifest 由来かも読めない）。
# **この検査はその答を要らなくする** —— 片方だけ上がれば落ちる。
#
# **正規表現ではなく XML として読む。** 属性の順を入れ替えた書き方
# （`Version=` が先）と、版を `<Version>` 子要素で書く形は、どちらも
# MSBuild として妥当である。**レビューで実測されたとおり、属性順を頼りに
# した版はその 2 つを黙って読み飛ばし、版が割れているのに全部緑になった。**
$packagePins = @{}
$parsedRefs  = 0
$looseRefs   = 0
$csprojFiles = @(& git -C $repoRoot ls-files '*.csproj')
Assert-That ($csprojFiles.Count -gt 0) 'git lists the csproj files (0 件なら以下は空振りする)'
foreach ($rel in $csprojFiles) {
    $path = Join-Path $repoRoot $rel
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $looseRefs += @(Get-Content -LiteralPath $path |
                    Where-Object { $_ -match '<PackageReference[\s>]' }).Count
    $xml = [xml](Get-Content -LiteralPath $path -Raw)
    foreach ($node in $xml.SelectNodes("//*[local-name()='PackageReference']")) {
        $pkg = $node.GetAttribute('Include')
        if (-not $pkg) { $pkg = $node.GetAttribute('Update') }
        $ver = $node.GetAttribute('Version')
        if (-not $ver) {
            $child = @($node.ChildNodes | Where-Object { $_.LocalName -eq 'Version' })
            if ($child.Count -gt 0) { $ver = $child[0].InnerText.Trim() }
        }
        if (-not $pkg) { continue }
        $parsedRefs++
        if (-not $packagePins.ContainsKey($pkg)) { $packagePins[$pkg] = @() }
        $packagePins[$pkg] += [pscustomobject]@{ Project = $rel; Version = $ver }
    }
}

# **workflow 側と同じ門を csproj 側にも置く。** 片方にだけ置いていた版は、
# 読み飛ばした PackageReference が 1 件も報告されずに緑になった。
Assert-That ($parsedRefs -eq $looseRefs) `
    "every PackageReference was parsed (parsed $parsedRefs / found $looseRefs)"
Assert-That ($packagePins.Count -gt 0) 'the csproj files declare at least one PackageReference'
foreach ($pkg in ($packagePins.Keys | Sort-Object)) {
    $versions = @($packagePins[$pkg] | ForEach-Object { $_.Version } | Sort-Object -Unique)
    Assert-That ($versions.Count -eq 1) `
        "$pkg is pinned to one version across the csproj files (saw: $($versions -join ', '))"
    if ($versions.Count -gt 1) {
        $packagePins[$pkg] | ForEach-Object { Write-Host "      $($_.Project): $($_.Version)" -ForegroundColor Yellow }
    }
}


# --------------------------------------------------------------------------
# 必須チェックの本数は、README.md と README.ja.md の両方に書いてある。
#
# `CLAUDE.md` は「リポジトリ内で二重に書かれているのはこの箇所だけ」と宣言して
# おり、日本語版を足したことで**二重が三重になった**。3 つを人が揃え続けるのは
# 無理なので、**少なくとも 2 つの README が同じ数を言っていること**を機械が見る。
#
# **`CLAUDE.md` 側は含めない** —— あちらは表の形で内訳まで書いており、
# 「数を 1 つ抜き出す」形になっていないためである。README 同士がずれたら
# ここが落ちる。
#
# **限界を書いておく: これは 2 つが互いに一致することしか見ない。**
# **3 つとも同じだけ古ければ緑になる。** 必須チェックを増減したときに
# `CLAUDE.md` と README を両方直すのは、依然として人の仕事である ——
# この検査が守るのは「片方だけ直して忘れる」のほうだけである。
$readmeEn = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
$readmeJa = Get-Content -LiteralPath (Join-Path $repoRoot 'README.ja.md') -Raw

$enMatch = [regex]::Match($readmeEn, '(?<n>[A-Za-z]+(?:-[a-z]+)?) checks are\s+required')
$jaMatch = [regex]::Match($readmeJa, '必須チェックは (?<n>\d+) 本')

Assert-That ($enMatch.Success) 'README.md states how many checks are required (書き方が変わったら空振りせず落ちる)'
Assert-That ($jaMatch.Success) 'README.ja.md states how many checks are required (書き方が変わったら空振りせず落ちる)'

if ($enMatch.Success -and $jaMatch.Success) {
    # 英語版は綴りで書く（"Twenty-one"）ので、数字へ直してから比べる。
    $spelled = @{
        'Thirteen' = 13; 'Fourteen' = 14; 'Fifteen' = 15; 'Sixteen' = 16
        'Seventeen' = 17; 'Eighteen' = 18; 'Nineteen' = 19; 'Twenty' = 20
        'Twenty-one' = 21; 'Twenty-two' = 22; 'Twenty-three' = 23
        'Twenty-four' = 24; 'Twenty-five' = 25
    }
    $enWord = $enMatch.Groups['n'].Value
    $enCount = if ($spelled.ContainsKey($enWord)) { $spelled[$enWord] } else { $null }

    Assert-That ($null -ne $enCount) `
        "README.md の必須チェック数を数値にできる (saw '$enWord' —— 綴りの表が古いなら足すこと)"

    if ($null -ne $enCount) {
        Assert-That ($enCount -eq [int]$jaMatch.Groups['n'].Value) `
            "both READMEs state the same required-check count (EN $enCount / JA $($jaMatch.Groups['n'].Value))"
    }
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
