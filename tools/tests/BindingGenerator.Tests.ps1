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
# 生成物は 10 個あり、残る 8 個は誰も見ていなかった。実測: Program.cs の
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
#   - 診断 / conformance 用の API —— 同文書の「この allowlist に含まれないもの」が
#     まとめて扱う。個別の行は持たない
#   - `*_ptr` —— managed 配列版と同じ C の entry point へポインタで入る C# 側の
#     入口で、C# としての契約は CvMat の IntPtr overload にある
$apiRefText = Get-Content -LiteralPath (Join-Path $repoRoot 'docs/api-reference.md') -Raw

$documentedElsewhere = @(
    'ocvu_get_abi_version', 'ocvu_get_last_error_status', 'ocvu_get_last_error_message',
    'ocvu_get_status_count', 'ocvu_get_status_value',
    'ocvu_get_opencv_version', 'ocvu_get_build_information',
    'ocvu_debug_throw', 'ocvu_debug_crash'
)

$undocumented = @()
$checkedCount = 0
foreach ($specFile in Get-ChildItem -Path (Join-Path $repoRoot 'bindings/spec') -Filter '*.json') {
    if ($specFile.Name -eq 'schema.json') { continue }
    $model = Get-Content -LiteralPath $specFile.FullName -Raw | ConvertFrom-Json
    foreach ($fn in $model.functions) {
        if ($documentedElsewhere -contains $fn.name) { continue }
        if ($fn.name -like '*_ptr') { continue }
        $checkedCount++
        if ($apiRefText -notlike "*$($fn.name)*") { $undocumented += $fn.name }
    }
}

# **0 件を照合して緑にしない。** spec の読み取りが空振りしたら、下の assertion は
# 何も見ないまま通る。
Assert-That ($checkedCount -gt 0) `
    'the API reference check actually had functions to look for (0 件なら spec の読み取りが空振りしている)'
Assert-That ($undocumented.Count -eq 0) `
    "docs/api-reference.md documents every spec function (missing: $($undocumented -join ', '))"

if ($script:failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($script:failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
