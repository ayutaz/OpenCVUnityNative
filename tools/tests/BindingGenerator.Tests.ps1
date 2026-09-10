#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# --------------------------------------------------------------------------
# **復元は「中身」だけでなく「更新日時」も戻す（M7b）。**
#
# このファイルの負の対照は、生成物を書き換えて `verify-generated` が
# 落ちることを見たあと、バイト単位で元へ戻す。**バイト単位で元へ戻しても
# `LastWriteTime` は新しいまま**で、CMake が configure し直した `.vcxproj`
# を MSBuild が見ると、その依存先ヘッダの mtime が新しいというだけで
# 依存する翻訳単位を再コンパイル対象と判定する。実測: `dev.ps1 test-tools`
# （このファイルを含む）の直後に `dev.ps1 test-native` を単体で走らせると、
# native が温まっていれば 9 秒のところが 56 秒に伸びた
# （`native/src/*.cpp` が 20 本超、全部再コンパイルされたため）。
#
# **危険なのは「中身が戻っていないのに mtime だけ戻すこと」である。** それは
# 壊れた復元を隠す —— ビルドシステムがもう「変更されていない」と見なす
# ので、誰も再ビルドしないまま古い内容の生成物がそのまま残る。これは
# slow lane へ逃がすより悪い、静かな事故である。
#
# **「戻したつもりの中身」を自分自身と比べても意味が無い。** 最初の実装は
# 「$backup を書き込み、読み直して $backup と比べる」形だったが、これは
# 同語反復である —— 呼び出し側が渡す変数を取り違えても（例えば api-map 用の
# backup をヘッダへ書いてしまっても）、書いた値と読み直した値は常に一致する。
# **判定は自分の外に置く**: `verify-generated` は spec から独立に再生成した
# 内容と比べるので、「本当に元の生成物と一致しているか」の第三者の審判になる。
# だから mtime を戻すのは、その直後の `verify-generated` が成功したときだけに
# し、失敗したら mtime には触れない（下の「戻したら通ること」の
# assertion が、その判定をそのまま兼ねる）。

# $PSScriptRoot はこのファイルの置かれたディレクトリ（tools/tests）なので、
# 2 段上がると repo root になる。既存の tools/tests/*.Tests.ps1 と同じ導出。
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dev = Join-Path $repoRoot 'tools/dev.ps1'

# **この 1 関数だけ、$LASTEXITCODE の取り扱いを固めてある。**
#
# `$LASTEXITCODE` は、直前の native コマンドが**起動すらできなかった**
# ときには更新されない —— 前に別の native コマンドが残した値がそのまま
# 見える。ファイルの他の場所にある `& pwsh ... ; Assert-That ($LASTEXITCODE -eq 0) ...`
# は全部この同じ形を共有しているが、**あえて直さない**: そちらが古い値を
# 読んでも「本来 FAIL すべき assertion が誤って PASS する」だけで、木の
# 状態は変わらない（次に人が気づける）。**ここだけは違う** —— 誤って
# 「検証できた」と読むと mtime を進めてしまい、このガード全体の存在理由
# である「静かな事故を作らない」（中身が戻っていないのに戻ったふりを
# する）を、判定を守るはずのこの関数自身が再現することになる。だから
# ここだけ、呼ぶ前に `$LASTEXITCODE` を明示的に消し、呼んだ後も残っていない
# （＝更新されなかった）なら「未検証」として false を返す。起動失敗を
# 検出する側も汎用の下請け（`Test-ProcessExitedZero`）に切り出してあるので、
# 合成した「存在しない実行ファイル」で単体に確かめられる。
function Test-ProcessExitedZero {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $global:LASTEXITCODE = $null
    try {
        & $FilePath @ArgumentList 2>&1 | Out-Null
    }
    catch {
        # 実行ファイルの解決自体が失敗すると、PowerShell はここへ来る
        # （$LASTEXITCODE は更新されないまま）。
        return $false
    }
    if ($null -eq $LASTEXITCODE) { return $false }
    return $LASTEXITCODE -eq 0
}

function Test-GeneratedTreeVerifies {
    return Test-ProcessExitedZero -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $dev, 'verify-generated')
}

# **壊して、落ちることを見る（このガード自身。prove-a-check-works）。**
# `$LASTEXITCODE` を「0（成功）」で意図的に汚してから、実在しない
# 実行ファイル名を渡す —— 起動が失敗する経路を安全に再現できる
# （pwsh 自体を PATH から外すような、ファイル全体を巻き添えにする
# 手段は取らない）。汚した値をそのまま読めば「検証できた」と誤判定する
# はずなので、それが起きないことを確かめる。
$global:LASTEXITCODE = 0
$launchFailureVerified = Test-ProcessExitedZero -FilePath 'ocvu-nonexistent-command-abcxyz' -ArgumentList @()
Assert-That (-not $launchFailureVerified) `
    'a process that fails to launch is NOT verified, even when a stale exit code of 0 was left lying around (静かな事故を作らない)'

# --- 生成物が spec と一致していること ---
& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'the generated bindings match the spec'

# --- **生成物を手で変えたら落ちること。** これが無いと検査が働いた証拠が無い ---
$header = Join-Path $repoRoot 'native/include/ocvu/infra.h'
$backup = Get-Content -LiteralPath $header -Raw
$backupWriteTime = (Get-Item -LiteralPath $header).LastWriteTime
try {
    Add-Content -LiteralPath $header -Value '/* 手で足した行 */'
    & pwsh -NoProfile -File $dev verify-generated 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'editing a generated file by hand fails the check'
}
finally { Set-Content -LiteralPath $header -Value $backup -NoNewline }

# --- 戻したら通ること（後始末が効いていることの確認）。mtime はここが緑のときだけ戻す ---
$headerRestoreVerified = Test-GeneratedTreeVerifies
Assert-That $headerRestoreVerified 'restoring the generated file makes the check pass again'
if ($headerRestoreVerified) {
    (Get-Item -LiteralPath $header).LastWriteTime = $backupWriteTime
}

# --------------------------------------------------------------------------
# **壊して、落ちることを見る（このガード自身。prove-a-check-works）。**
#
# 上のガードが実際に「中身が戻っていない」ことを検出し、mtime に触れずに
# 済ませることを、実物のヘッダで確かめる。合成ファイルでは
# `verify-generated` の審判を借りられない（spec と比べる対象が実在の
# 生成物でなければならない）ので、ここでは実物を使い、最後に必ず
# 正しい内容へ戻す。
$brokenRestoreWriteTime = $null
try {
    # 意図的に**間違った**内容で「復元」する —— 例えば呼び出し側が
    # 変数を取り違えたときに実際に起きる形。
    Set-Content -LiteralPath $header -Value 'この内容は spec からの再生成と一致しない' -NoNewline
    $brokenRestoreWriteTime = (Get-Item -LiteralPath $header).LastWriteTime

    $wrongRestoreVerified = Test-GeneratedTreeVerifies
    Assert-That (-not $wrongRestoreVerified) `
        'a restore that leaves the WRONG content still fails verify-generated (ガードが検出できる形であることの確認)'

    # ここが本題: verify-generated が失敗と判定した以上、mtime には
    # 一切触れない（意図的に何もしない —— 触れないことそのものが主張）。
    $afterWrongRestoreTime = (Get-Item -LiteralPath $header).LastWriteTime
    Assert-That ($afterWrongRestoreTime -eq $brokenRestoreWriteTime) `
        'a failed restore leaves the timestamp untouched (mtime だけ戻して中身の違いを隠さない)'
}
finally {
    # 本当に元へ戻す。
    Set-Content -LiteralPath $header -Value $backup -NoNewline
    $reallyRestoredVerified = Test-GeneratedTreeVerifies
    Assert-That $reallyRestoredVerified `
        'the header is genuinely back to its original content after the negative control'
    if ($reallyRestoredVerified) {
        (Get-Item -LiteralPath $header).LastWriteTime = $backupWriteTime
    }
}

# **`Test-ProcessExitedZero` の起動失敗を、実際のサイトと同じ形で運転する。**
# 各サイトはどれも `if ($verified) { mtime を戻す }` という形をしている。
# 上ですでに「起動が失敗すると $false を返す」ことは確かめたので、ここでは
# その $false を実物のヘッダに対して同じ if に通し、**この分岐に入らない
# こと（＝ mtime に触れないこと）**を直接見る。$launchFailureVerified は
# 既に $false と分かっている値なので、この if は絶対に実行されない
# はずだが、それこそが確かめたいことである。
$headerTimeBeforeLaunchFailureProbe = (Get-Item -LiteralPath $header).LastWriteTime
if ($launchFailureVerified) {
    (Get-Item -LiteralPath $header).LastWriteTime = Get-Date
}
Assert-That (((Get-Item -LiteralPath $header).LastWriteTime) -eq $headerTimeBeforeLaunchFailureProbe) `
    'gating a real restore on a launch-failure verdict leaves its timestamp untouched'

# --- 生成物に「生成物である」と書いてあること ---
Assert-That ((Get-Content -LiteralPath $header -Raw) -match 'このファイルは生成物である') `
    'the generated header says it is generated'

# --- **文書も同じ網に入っていること。** 上の 2 件はヘッダ 1 本で満たせるので、
# Program.cs の outputs から docs/api-map.md の行が消えても緑のままである。
# そのとき表は凍り、ABI が増えても増えない —— つまり手書きだった頃と同じ
# 陳腐化に戻るが、「生成物である」と書いてあるぶん質が悪い。名指しで見る。
$apiMap = Join-Path $repoRoot 'docs/api-map.md'
$apiMapBackup = Get-Content -LiteralPath $apiMap -Raw
$apiMapBackupWriteTime = (Get-Item -LiteralPath $apiMap).LastWriteTime
try {
    Add-Content -LiteralPath $apiMap -Value '手で足した行'
    & pwsh -NoProfile -File $dev verify-generated 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'editing docs/api-map.md by hand fails the check'
}
finally { Set-Content -LiteralPath $apiMap -Value $apiMapBackup -NoNewline }

$apiMapRestoreVerified = Test-GeneratedTreeVerifies
Assert-That $apiMapRestoreVerified 'restoring docs/api-map.md makes the check pass again'
if ($apiMapRestoreVerified) {
    (Get-Item -LiteralPath $apiMap).LastWriteTime = $apiMapBackupWriteTime
}

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
#
# **ここが M7b の主因だった。** `$declared` は 20 ファイル（生成物全部）——
# 一度に全部の mtime を動かすので、直後の native ビルドへの影響もここが
# 最大だった。
$backups = @{}
$backupTimes = @{}
try {
    foreach ($rel in $declared) {
        $full = Join-Path $repoRoot $rel
        $backups[$full] = Get-Content -LiteralPath $full -Raw
        $backupTimes[$full] = (Get-Item -LiteralPath $full).LastWriteTime
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

# **mtime を戻すのは、この検査が緑のときだけ。** 個々のファイルを
# 自分の書いた値と読み比べても同語反復にしかならないので（上の
# コメント参照）、判定は spec からの再生成と比べる `verify-generated`
# に一本化する —— これが失敗すれば、20 ファイルのうち 1 つでも
# 元へ戻っていないということであり、そのときは 1 つも mtime を戻さない
# （どれが壊れているか分からない以上、安全側に倒す）。
$allRestoreVerified = Test-GeneratedTreeVerifies
Assert-That $allRestoreVerified 'restoring every generated file makes the check pass again'
if ($allRestoreVerified) {
    foreach ($full in $backupTimes.Keys) {
        (Get-Item -LiteralPath $full).LastWriteTime = $backupTimes[$full]
    }
}

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
