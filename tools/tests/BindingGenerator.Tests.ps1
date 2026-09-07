#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# $PSScriptRoot はこのファイルの置かれたディレクトリ（tools/tests）なので、
# 2 段上がると repo root になる。既存の tools/tests/*.Tests.ps1 と同じ導出。
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dev = Join-Path $repoRoot 'tools/dev.ps1'

# --- 生成物が spec と一致していること ---
& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'the generated bindings match the spec'

# --- **生成物を手で変えたら落ちること。** これが無いと検査が働いた証拠が無い ---
$header = Join-Path $repoRoot 'native/include/ocvu/infra.h'
$backup = Get-Content -LiteralPath $header -Raw
try {
    Add-Content -LiteralPath $header -Value '/* 手で足した行 */'
    & pwsh -NoProfile -File $dev verify-generated 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'editing a generated file by hand fails the check'
}
finally { Set-Content -LiteralPath $header -Value $backup -NoNewline }

# --- 戻したら通ること（後始末が効いていることの確認） ---
& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'restoring the generated file makes the check pass again'

# --- 生成物に「生成物である」と書いてあること ---
Assert-That ((Get-Content -LiteralPath $header -Raw) -match 'このファイルは生成物である') `
    'the generated header says it is generated'

# --- **文書も同じ網に入っていること。** 上の 2 件はヘッダ 1 本で満たせるので、
# Program.cs の outputs から docs/api-map.md の行が消えても緑のままである。
# そのとき表は凍り、ABI が増えても増えない —— つまり手書きだった頃と同じ
# 陳腐化に戻るが、「生成物である」と書いてあるぶん質が悪い。名指しで見る。
$apiMap = Join-Path $repoRoot 'docs/api-map.md'
$apiMapBackup = Get-Content -LiteralPath $apiMap -Raw
try {
    Add-Content -LiteralPath $apiMap -Value '手で足した行'
    & pwsh -NoProfile -File $dev verify-generated 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'editing docs/api-map.md by hand fails the check'
}
finally { Set-Content -LiteralPath $apiMap -Value $apiMapBackup -NoNewline }

& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'restoring docs/api-map.md makes the check pass again'

# --- **名指しをやめる。** 上の 4 件は infra.h と api-map.md を名前で守るが、
# 生成物は当時 10 個あり、残る 8 個は誰も見ていなかった（**いまは 20 個ある** ——
# module が増えるたびに 2 つずつ増える。だから下は名指しをやめている）。実測: Program.cs の
# outputs から AbiReachabilityChecks.g.cs の配線を外すと、**この script は
# 全 assertion PASS で exit 0 になった**（以後 spec に足した関数だけが
# Player から呼ばれなくなる。Unity は緑のまま）。名前を 10 個に増やすと
# 11 個目で同じ穴が開くので、**生成器が申告する一覧から導く**。
$listArgs = @('run', '--project', (Join-Path $repoRoot 'bindings/generator/Ocvu.Generator'),
              '--', '--repo-root', $repoRoot, '--list-outputs')
$declared = @(& dotnet @listArgs | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
Assert-That ($declared.Count -gt 0) `
    'the generator declares its outputs (0 件は「違反なし」ではない)'

# **逆向き 1: 生成物を名乗るファイルが、全部その一覧に載っていること。**
# 配線を外すと、ファイルは「生成物である」と書かれたまま残り、誰も
# 再生成しなくなる —— 手書きだった頃より悪い（読む人は生成物だと信じる）。
# 判定は **先頭 5 行の名乗り** で行う。生成器のソースにも同じ文字列は
# 在るが、そちらは 50 行以上あとに現れる（生成物は必ず冒頭で名乗る）。
$claimsGenerated = @(
    foreach ($f in @(& git -C $repoRoot ls-files)) {
        $full = Join-Path $repoRoot $f
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $head = (Get-Content -LiteralPath $full -TotalCount 5 -ErrorAction SilentlyContinue) -join "`n"
        if ($head -match 'このファイルは生成物である') { $f }
    }
)
Assert-That ($claimsGenerated.Count -gt 0) `
    'the scan found files that announce themselves as generated (0 件は「違反なし」ではない)'

$unwired = @($claimsGenerated | Where-Object { $declared -notcontains $_ })
$unwiredDetail = if ($unwired.Count -gt 0) { ' — 申告に無い: ' + ($unwired -join ', ') } else { '' }
Assert-That ($unwired.Count -eq 0) `
    "every file that says it is generated is declared by the generator$unwiredDetail"

# **逆向き 2: 申告された一覧の全部が、実際に --check の比較対象であること。**
# 全部を同時に壊して、報告に 1 つ残らず出ることを見る（1 回の実行で済む）。
$backups = @{}
try {
    foreach ($rel in $declared) {
        $full = Join-Path $repoRoot $rel
        $backups[$full] = Get-Content -LiteralPath $full -Raw
        Add-Content -LiteralPath $full -Value '手で足した行'
    }
    $report = (& pwsh -NoProfile -File $dev verify-generated 2>&1) -join "`n"
    $checkFailed = $LASTEXITCODE -ne 0
    $missing = @($declared | Where-Object { $report -notmatch [regex]::Escape((Split-Path -Leaf $_)) })
    $missingDetail = if ($missing.Count -gt 0) { ' — 報告に出ない: ' + ($missing -join ', ') } else { '' }
    Assert-That $checkFailed 'editing every generated file by hand fails the check'
    Assert-That ($missing.Count -eq 0) `
        "the check reports every one of the $($declared.Count) generated files$missingDetail"
}
finally {
    foreach ($full in $backups.Keys) {
        Set-Content -LiteralPath $full -Value $backups[$full] -NoNewline
    }
}

& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'restoring every generated file makes the check pass again'

# --- **実装 -> spec の逆向き。** spec -> 実装は L1 のリンクと L3 の P/Invoke が
# 見ているが、逆は誰も見ていなかった: extern "C" で ocvu_ を実装して spec に
# 書き忘れると、C ヘッダにも C# にも宣言が生まれず、export だけが残る。
# ビルドも CI も緑のまま、誰からも呼べない関数が配布物に入る。
$specDir = Join-Path $repoRoot 'bindings/spec'
$srcDir = Join-Path $repoRoot 'native/src'

# **実効 entry point で突き合わせる。** entryPoint を持つ entry（byte[] 版と
# ポインタ版のように C の 1 本へ 2 つの C# 宣言を向けるもの）は、その名前の
# 関数が実装側に存在しない。比べるべきは C から見える名前である。
$specEntryPoints = @()
foreach ($specFile in Get-ChildItem -LiteralPath $specDir -Filter '*.json') {
    if ($specFile.Name -eq 'schema.json') { continue }
    $spec = Get-Content -LiteralPath $specFile.FullName -Raw | ConvertFrom-Json
    foreach ($fn in $spec.functions) {
        $explicit = $fn.PSObject.Properties['entryPoint']
        $specEntryPoints += if ($explicit) { $explicit.Value } else { $fn.name }
    }
}
$specEntryPoints = @($specEntryPoints | Sort-Object -Unique)
Assert-That ($specEntryPoints.Count -gt 0) 'the spec scan found entry points (0 件は「違反なし」ではない)'

# コメントを先に落とす。**散文の中の extern "C" に当たらないため** ——
# native/src/ocvu_error.cpp の冒頭は、例外が extern "C" 関数を抜ける話を
# 日本語で書いている（prove-a-check-works の「述語が散文に当たる」）。
$implNames = @()
$externCount = 0
foreach ($srcFile in Get-ChildItem -LiteralPath $srcDir -Filter '*.cpp' -Recurse) {
    $code = Get-Content -LiteralPath $srcFile.FullName -Raw
    $code = [regex]::Replace($code, '/\*[\s\S]*?\*/', ' ')
    $code = [regex]::Replace($code, '//[^\r\n]*', ' ')
    $externCount += ([regex]::Matches($code, 'extern\s+"C"')).Count
    # `[^;{}()]*?` が戻り値の型を跨ぐ。lazy なので最初の ocvu_xxx( で止まり、
    # 文の区切りは越えない。
    foreach ($m in [regex]::Matches($code, 'extern\s+"C"\s+[^;{}()]*?\b(ocvu_[a-z0-9_]+)\s*\(')) {
        $implNames += $m.Groups[1].Value
    }
}
$implNames = @($implNames | Sort-Object -Unique)

Assert-That ($implNames.Count -gt 0) 'the native scan found extern "C" ocvu_* definitions (0 件は「違反なし」ではない)'
# **切れなかったときは空振りではなく落ちる。** extern "C" があるのに名前を
# 取り出せなかったら、その 1 本はこの検査の網から静かに外れている。
Assert-That ($implNames.Count -eq $externCount) `
    "every extern C block in native/src was attributed to an ocvu_ name (取り出せた $($implNames.Count) / extern C $externCount)"

$notInSpec = @($implNames | Where-Object { $specEntryPoints -notcontains $_ })
$detail = if ($notInSpec.Count -gt 0) { ' — spec に無い実装: ' + ($notInSpec -join ', ') } else { '' }
Assert-That ($notInSpec.Count -eq 0) "every extern C ocvu_* in native/src is declared in the spec$detail"

# --- **手で書く唯一の行を見る。** ---
#
# M5 以降、境界の宣言はすべて生成物である。**例外は 1 つだけ** ——
# `native/include/opencv_unity_native.h` の `#include "ocvu/<module>.h"` で、
# 新しい module を足した人が手で書く（add-abi-function skill にそう書いてある）。
#
# **その 1 行を見るものが、どこにも無かった。** 忘れたときの壊れ方が悪い:
#
#   - 実装 (.cpp) は**コンパイルが通る** —— extern "C" の定義は事前宣言なしでも合法
#   - plugin はシンボルを export し、C# の P/Invoke は名前で解決するので **L3 も L5 も緑**
#   - 下の「実装 -> spec」の検査は native/src しか見ないので **緑**
#   - 壊れるのは**公開ヘッダを include する外部の C の呼び手だけ**で、
#     それを試すレーンはこのリポジトリに 1 本も無い
#
# いま気づけるのは L1 が公開ヘッダ経由で関数を呼んでいるからだが、
# **その L1 の登録（native/tests/CMakeLists.txt）も手作業**である ——
# **2 つを同時に忘れると、必須チェック 21 本が全部緑のまま公開ヘッダだけが壊れる。**
$umbrella = Join-Path $repoRoot 'native/include/opencv_unity_native.h'
$umbrellaText = Get-Content -LiteralPath $umbrella -Raw

$specModules = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'bindings/spec') -Filter '*.json' |
                 Where-Object { $_.BaseName -ne 'schema' } |
                 ForEach-Object { $_.BaseName })
Assert-That ($specModules.Count -gt 0) 'the spec directory lists modules (0 件なら以下は空振りする)'

foreach ($m in $specModules) {
    $line = '#include "ocvu/' + $m + '.h"'
    Assert-That ($umbrellaText.Contains($line)) `
        "opencv_unity_native.h includes ocvu/$m.h (**この 1 行だけは生成物ではない。手で足す**)"
}

# **逆向きも見る。** module を消したのに include が残ると、次の generate で
# ヘッダが消えてコンパイルが落ちる —— そちらはコンパイラが捕まえるので
# 検査は要らないが、**数が合わないことは言う**（spec に無い module を
# include している状態は、どちらかが古い）。
$includedModules = @([regex]::Matches($umbrellaText, '#include\s+"ocvu/([a-z0-9_]+)\.h"') |
                     ForEach-Object { $_.Groups[1].Value })
Assert-That ($includedModules.Count -eq $specModules.Count) `
    "opencv_unity_native.h includes exactly the spec modules (included $($includedModules.Count) / spec $($specModules.Count))"

# --------------------------------------------------------------------------
# **手書きの API リファレンスが、spec の関数を取りこぼしていないこと。**
#
# `docs/api-reference.md` は生成物ではない —— 冒頭で「関数を足したらここを手で
# 直すところまでが作業である」と自分で宣言している文書である。**宣言しただけでは
# 守られない**（2026-09-03 に手で突き合わせるまで、誰も見ていなかった）。
#
# **意図的に載せないものがあるので、除外を明示する。除外はここに書いたものだけで、
# それ以外が載っていなければ落ちる。**
# **除外リストは持たない。** 最初の版は診断 API を 9 本まとめて除外していたが、
# **実測すると 5 本は名前で載っており、除外する必要が無かった** ——
# **不要な除外はそのまま穴になる**（`ocvu_debug_crash` の記述を丸ごと消しても
# 検査が緑のままだった。レビュアーが実証した）。
#
# 残る 4 本（last-error と status 表）は文書が総称でしか触れていなかったので、
# **除外を狭めるのではなく、文書に名前を書いた。**
# `prove-a-check-works` の「列挙に基づく門を、出口側の構造に基づく門へ変える」
# —— **一覧を持たなければ、一覧が古くなることも無い。**
#
# **例外は 1 つも無い。** `*_ptr` の 2 本も、当初は「規則で表せる」として skip して
# いたが、**そちらも文書に名前で載っていた**（`docs/api-reference.md` の
# 「この allowlist に含まれないもの」）—— **規則で表せることと、除外する必要が
# あることは別である。** 除外している間は、その 2 本を文書から消しても検査が
# 緑だった（レビュアーが実証した）。
$apiRefText = Get-Content -LiteralPath (Join-Path $repoRoot 'docs/api-reference.md') -Raw

$undocumented = @()
$checkedCount = 0
foreach ($specFile in Get-ChildItem -Path (Join-Path $repoRoot 'bindings/spec') -Filter '*.json') {
    if ($specFile.Name -eq 'schema.json') { continue }
    $model = Get-Content -LiteralPath $specFile.FullName -Raw | ConvertFrom-Json
    foreach ($fn in $model.functions) {
        $checkedCount++
        # **部分一致にしない。** `-like "*name*"` だと `ocvu_debug_crash_GONE` も
        # `X_ocvu_debug_crash` も `ocvu_debug_crash` を含んでしまい、**名前を
        # 書き換えても検査が通る**（両方向とも実測で踏んだ）。
        # **前後どちらにも識別子の文字が続かない**ことまで見る。
        #
        # **`-cnotmatch` であって `-notmatch` ではない。** PowerShell の `-match` は
        # 既定で大文字小文字を区別しないので、文書側が `OCVU_DEBUG_CRASH` になっても
        # 緑になる —— **C の識別子は大文字小文字を区別するので、それは別の名前であり、
        # 「その関数は文書に無い」が正しい**（実測: 小文字が 0 箇所になっても通った）。
        if ($apiRefText -cnotmatch ('(?<![A-Za-z0-9_])' + [regex]::Escape($fn.name) + '(?![A-Za-z0-9_])')) {
            $undocumented += $fn.name
        }
    }
}

# **0 件を照合して緑にしない。** spec の読み取りが空振りしたら、下の assertion は
# 何も見ないまま通る。
Assert-That ($checkedCount -gt 0) `
    'the API reference check actually had functions to look for (0 件なら spec の読み取りが空振りしている)'
Assert-That ($undocumented.Count -eq 0) `
    "docs/api-reference.md documents every spec function (missing: $($undocumented -join ', '))"

# --------------------------------------------------------------------------
# **native/modules.cmake の module 一覧が、spec のファイル名と一致すること。**
#
# CMake 側は写しである（glob すると生成物が構成に混ざって再現性が落ちる）。
# **写しを持つなら、機械が正本と突き合わせる。**
$specModulesForCmake = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'bindings/spec') -Filter '*.json' |
        Where-Object { $_.Name -ne 'schema.json' } |
        ForEach-Object { $_.BaseName }
) | Sort-Object

$cmakeText = Get-Content -LiteralPath (Join-Path $repoRoot 'native/modules.cmake') -Raw
if ($cmakeText -notmatch '(?ms)set\(OCVU_ALL_MODULES\s+(.*?)\)') {
    Write-Host 'FAIL: modules.cmake から OCVU_ALL_MODULES を取り出せなかった'
    $script:failures += 'modules.cmake から OCVU_ALL_MODULES を取り出せなかった'
} else {
    $cmakeModules = @($Matches[1] -split '\s+' |
        Where-Object { $_ -ne '' }) | Sort-Object

    # **0 件を「一致」と読まない。**
    if ($cmakeModules.Count -eq 0) {
        Write-Host 'FAIL: OCVU_ALL_MODULES が空。抽出が効いていない'
        $script:failures += 'OCVU_ALL_MODULES が空。抽出が効いていない'
    } elseif (Compare-Object $specModulesForCmake $cmakeModules) {
        Write-Host 'FAIL: modules.cmake と bindings/spec の module 一覧が食い違う'
        Compare-Object $specModulesForCmake $cmakeModules |
            ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
        $script:failures += 'modules.cmake と bindings/spec の module 一覧が食い違う'
    } else {
        Write-Host "PASS: module 一覧が一致（$($cmakeModules.Count) 件）"
    }
}

# --------------------------------------------------------------------------
# **生成物のディレクトリに、申告に無いファイルが残っていないこと。**
#
# Step 7 の壊し方 2 で分かった穴を塞ぐ。生成器は「出すべき物」を
# --list-outputs で申告するが、**profile を変えると前の場所に古い物が残る。**
# 残った物は「生成物である」と名乗ったまま、誰も再生成しない。
#
# **上の $declared とまったく同じ呼び方をする。** --repo-root を渡さないと
# 生成器は自分の cwd を repo root と見なす —— $repoRoot はこの script が
# どこから呼ばれても同じ場所を指すために $PSScriptRoot から導いてあるのに、
# ここだけそれを迂回すると cwd 次第で全 9 ファイルが「申告に無い」と
# 誤判定される（本当の原因は「一覧が空」なのに、報告は「orphan が 9 件」と
# 見当違いを指す）。フィルタと非空の確認も揃える。
$listArgsForOrphanCheck = @('run', '--project', (Join-Path $repoRoot 'bindings/generator/Ocvu.Generator'),
                            '--', '--repo-root', $repoRoot, '--list-outputs')
$declaredForOrphanCheck = @(& dotnet @listArgsForOrphanCheck | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
Assert-That ($declaredForOrphanCheck.Count -gt 0) `
    'the generator declares its outputs for the orphan scan (0 件は「違反なし」ではない)'

# **走査するのは 1 つの木ではない。** 生成物の .g.cs は 2 か所に出る ——
# package の `Runtime/Interop*/` と、到達性テストの
# `tests/UnityProject/Assets/Tests/Shared*/`。**後者を見ていなかった** ——
# profile を変えて `Shared.Dnn/` に置き去りができても、この検査は緑のまま
# だった（捕まえるのは冒頭の名乗り検査だけで、しかも git に追跡された後に
# 限られる）。**profile ごとに 1 ファイル出る以上、置き去りはこちらでこそ起きる。**
$onDisk = @(
    foreach ($root in @(
        (Join-Path $repoRoot 'Packages/com.ayutaz.opencv-unity-native/Runtime'),
        (Join-Path $repoRoot 'tests/UnityProject/Assets/Tests'))) {
        Get-ChildItem -LiteralPath $root -Recurse -Filter '*.g.cs' -ErrorAction SilentlyContinue |
            ForEach-Object {
                [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/')
            }
    }
)

if ($onDisk.Count -eq 0) {
    Write-Host 'FAIL: .g.cs が 1 つも見つからない。走査が効いていない'
    $script:failures += '.g.cs が 1 つも見つからない。走査が効いていない'
} else {
    $orphans = @($onDisk | Where-Object { $_ -notin $declaredForOrphanCheck })
    if ($orphans.Count -gt 0) {
        Write-Host 'FAIL: 生成器が申告していない .g.cs が残っている:'
        $orphans | ForEach-Object { Write-Host "  $_" }
        $script:failures += '生成器が申告していない .g.cs が残っている'
    } else {
        Write-Host "PASS: 残留した生成物は無い（$($onDisk.Count) 件）"
    }
}

# --------------------------------------------------------------------------
# **レビュー fix round 1、Minor 1: Program.cs の profile 分岐そのものを運転する。**
#
# CsPInvokeEmitter / ReachabilityEmitter が profile で分岐することは
# Ocvu.Generator.Tests（ProfileTests.cs）が見ているが、それを実際に
# 呼び出す側の配線 —— Program.cs の interopDir 算出と、profile ごとに
# ループして出力先を積む部分 —— は Task 3 の Step 7 が手で 1 回壊して
# 確かめただけで、常設のレーンには乗っていなかった。この機構は
# plan (c)（dnn profile の追加）が実際に来るまで一度も動かないかもしれない
# 条件付きの将来のためのものなので、「そのときになれば誰か気づくだろう」に
# 賭けない。
#
# 合成した spec 木（standard 1 つ・非 standard 1 つ）を一時ディレクトリに
# 作り、--repo-root にそこを指定して --list-outputs だけを呼ぶ
# （Program.cs は listOutputs のとき書き込みの手前で continue するので、
# 何も書き込まれない副作用の無い呼び方である）。
$profileOrchestrationTmp = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('ocvu-profile-orchestration-' + [System.Guid]::NewGuid().ToString('N'))
$specDirTmp = Join-Path $profileOrchestrationTmp 'bindings/spec'
New-Item -ItemType Directory -Path $specDirTmp -Force | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'bindings/spec/schema.json') `
        -Destination (Join-Path $specDirTmp 'schema.json')

    Set-Content -LiteralPath (Join-Path $specDirTmp 'probe.json') -NoNewline -Value @'
{
  "module": "probe",
  "functions": [
    {
      "name": "ocvu_probe_thing",
      "summary": "profile 分岐の配線を運転するためだけの合成 spec（standard 側）。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": []
    }
  ]
}
'@

    Set-Content -LiteralPath (Join-Path $specDirTmp 'dnnprobe.json') -NoNewline -Value @'
{
  "module": "dnnprobe",
  "profile": "dnn",
  "functions": [
    {
      "name": "ocvu_dnnprobe_thing",
      "summary": "profile 分岐の配線を運転するためだけの合成 spec（非 standard 側）。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": []
    }
  ]
}
'@

    $listArgsForOrchestration = @('run', '--project', (Join-Path $repoRoot 'bindings/generator/Ocvu.Generator'),
                                   '--', '--repo-root', $profileOrchestrationTmp, '--list-outputs')
    $orchestrationOutputs = @(
        & dotnet @listArgsForOrchestration | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }
    )

    Assert-That ($orchestrationOutputs.Count -gt 0) `
        'the profile-orchestration scan produced output (0 件は空振り)'
    Assert-That ($orchestrationOutputs -contains 'Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Probe.g.cs') `
        'Program.cs still routes a standard-profile module under Runtime/Interop/'
    Assert-That ($orchestrationOutputs -contains 'Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/NativeMethods.Dnnprobe.g.cs') `
        'Program.cs routes a non-standard-profile module under Runtime/Interop.Dnn/'
    Assert-That ($orchestrationOutputs -contains 'tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs') `
        'Program.cs still emits the standard-profile reachability file'
    Assert-That ($orchestrationOutputs -contains 'tests/UnityProject/Assets/Tests/Shared.Dnn/AbiReachabilityChecks.Dnn.g.cs') `
        'Program.cs emits a separate reachability file for the non-standard profile'

    # **生成物そのものをコンパイルする検査は、ここには無い。**
    #
    # 上の 4 件は**出力先の path** しか見ていない（`--list-outputs` だけの
    # 副作用の無い呼び方なので安い）。「生成された非 standard profile の
    # C# が実際にコンパイルできるか」（最終レビュー C-1: `LibraryName` が
    # 見えず CS0103 になった欠陥を捕まえた検査）は、`dotnet run`（合成木への
    # 書き込み）と `dotnet build` を抱えて高く、fast lane 全体の実測 38 秒の
    # 大半をこの 1 本が占めていた（`dev.ps1 test` を 65 秒 → 144 秒へ押し
    # 上げた回帰の主因）。2026-09-07（M7b）に
    # `tools/tests/NonStandardProfileCompile.Tests.ps1` へ切り出し、
    # `$ToolsTestScriptsSlow` へ配線した —— 検査は削っていない。
}
finally {
    Remove-Item -LiteralPath $profileOrchestrationTmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($script:failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
