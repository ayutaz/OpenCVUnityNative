#!/usr/bin/env pwsh
param(
    # 実物の binary から読む場合。
    [string]$LibraryPath,
    # シンボル一覧を直接与える場合（テスト用。1 行 1 名）。
    [string]$SymbolListPath,
    # spec を読む場所（テスト用。既定は実物の bindings/spec）。
    [string]$SpecDir
)

function Get-ExportedSymbol {
    param([Parameter(Mandatory = $true)][string]$Path)

    # **道具が無いことを「合格」にしない。** 見つからなければ落とす ——
    # tools/verify-artifact-linkage.ps1 が SKIP を出すのとは扱いを変える。
    # あちらは検査の対象が複数あるが、こちらは 1 つで、
    # **SKIP は「公開面を確かめていない」と同義である。**
    if ($IsWindows) {
        $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
        if (-not $dumpbin) {
            # Visual Studio の配下を探す。
            $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
            if (Test-Path -LiteralPath $vswhere) {
                $vs = & $vswhere -latest -property installationPath
                <#
                    **単純に最初の 1 件を採らない。** このマシンには複数の
                    MSVC toolset 版が入っており、`-Recurse` が返す順の先頭は
                    `HostX64\arm\dumpbin.exe` だった。host が x64 なのに
                    target が arm のツールは、実行はできても隣接する
                    companion dll（mspdbcore.dll）を欠いて `LNK1171` で落ちる
                    （実測）。**host も target も x64 のものを優先する** ——
                    それが動くことは実測で確かめてある。複数の toolset 版が
                    あれば、パス文字列の版数（`14.NN.NNNNN`）は桁数が揃っているので
                    文字列の降順ソートがそのまま最新版を選ぶ。
                    見つからない環境（VS のレイアウトが違う）では、
                    従来どおり最初の 1 件にフォールバックする。
                #>
                $found = Get-ChildItem -Path $vs -Filter 'dumpbin.exe' -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -match '[\\/][Hh]ost[xX]64[\\/]x64[\\/]' } |
                    Sort-Object FullName -Descending |
                    Select-Object -First 1
                if (-not $found) {
                    $found = Get-ChildItem -Path $vs -Filter 'dumpbin.exe' -Recurse -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                }
                if ($found) { $dumpbin = $found.FullName }
            }
        }
        if (-not $dumpbin) {
            Write-Error 'dumpbin が見つからない。公開面を確かめられないので落とす'
            exit 1
        }
        $out = & $dumpbin /EXPORTS $Path 2>&1
        # dumpbin の出力は「序数 / RVA / 名前」の 3 列。名前だけを取る。
        return @($out | ForEach-Object {
            if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') { $Matches[1] }
        })
    }

    $nm = Get-Command nm -ErrorAction SilentlyContinue
    if (-not $nm) {
        Write-Error 'nm が見つからない。公開面を確かめられないので落とす'
        exit 1
    }

    <#
        **ELF: `.symtab` ではなく `.dynsym` を読む。**

        `nm -g --defined-only` はデバッグ用のシンボル表（`.symtab`）を読む。
        実際にリンカが export する面は動的シンボル表（`.dynsym`）で、
        `nm -D` がそちらを読む。今日まで `-g` で正しい答えが出ていたのは、
        hidden visibility を持つシンボルをリンカが local へ格下げするから
        であって、`-g` が export 表そのものを見ていたからではない
        （レビュー指摘）。測りたいものを直接測る。

        **macOS の Mach-O には `.dynsym` に相当する別テーブルが無い**ので
        `nm -D` は使えない。`-g`（外部シンボル）で足りる —— dylib でも
        hidden visibility のシンボルは同じくリンカが local に格下げする。
    #>
    if ($IsLinux) {
        $out = & nm -D --defined-only $Path 2>&1
    } else {
        $out = & nm -g --defined-only $Path 2>&1
    }

    <#
        **正規表現は大文字の T/D だけを通す。** 小文字（t/d）は local シンボル
        を指し、export の証拠にはならない。`-g` が今日それらを除外しているので
        実害は無かったが、正規表現自体が「言っていることより緩い」述語に
        なっていた（レビュー指摘）。

        **フェイルクローズ**: 見たことのない出力形式で 1 行もマッチしなければ
        この関数は空配列を返し、呼び出し側で `$actual` が空になる。その結果
        `$missing` が spec の全件になり、この検査は必ず赤くなる —— 道具の
        出力形式が変わっても、静かに green にはならない。
    #>
    return @($out | ForEach-Object {
        if ($_ -match '^\S+\s+[TD]\s+_?(\S+)') { $Matches[1] }
    })
}

# 配布する binary がエクスポートしているシンボルが、spec の関数一覧と
# **完全一致**することを要求する。
#
# **両向きに効く。**
#   - spec に在るのにエクスポートされていない → 利用者が呼べない関数を宣言している
#   - エクスポートされているのに spec に無い  → 契約の外に出ている面がある
#
# **数を写さない。** 期待する一覧は bindings/spec/*.json から毎回読む。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SpecDir) { $SpecDir = Join-Path $repoRoot 'bindings/spec' }

# --- spec の全関数を正本から読む ---
$specFunctions = @(
    Get-ChildItem -LiteralPath $SpecDir -Filter '*.json' |
        Where-Object { $_.Name -ne 'schema.json' } |
        ForEach-Object {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).functions
        }
)

#
# **@() は右辺のパイプライン全体を包む。** `@(a | b) | c` のように途中までしか
# 包まないと、`c`（Sort-Object -Unique）が 0 件を出したとき代入結果は
# 配列ではなく $null になり、StrictMode 下で後段の `.Count` が例外を投げる
# （実測。次の $entryPoints / $expected / $actual / $discarded も同じ形で
# 統一する）。
$allNames = @($specFunctions | ForEach-Object { $_.name } | Sort-Object -Unique)

<#
    **`entryPoint` が指す先が実在する name であることを証明する。**

    下の折り畳み（entryPoint があればそちらを、無ければ name を使う）は、
    「entryPoint の値は必ず他の entry の name と一致する」という前提の上に
    立っている。この前提は、C ヘッダを生成する CHeaderEmitter.cs の
    skip 規則（entryPoint を持つ entry の宣言を出さない）と、この検査の
    fold 規則が **たまたま同じ値を指しているから**今日は一致しているだけで、
    どちらのコードもそれを強制していない。ここで検証しないと、typo した
    entryPoint はどちらの規則からも見えない形で紛れ込む —— C ヘッダは単に
    宣言をスキップし、この検査は単に name にフォールバックするので、
    どちらも赤くならない。
#>
$entryPoints = @(
    $specFunctions | ForEach-Object {
        $ep = $_.PSObject.Properties['entryPoint']
        if ($ep -and $ep.Value) { $ep.Value }
    } | Sort-Object -Unique
)

$unknownEntryPoints = @($entryPoints | Where-Object { $_ -notin $allNames })
if ($unknownEntryPoints.Count -gt 0) {
    Write-Error (@(
        "entryPoint が spec のどの関数名にも一致しない: $($unknownEntryPoints -join ', ')"
        'entryPoint は既存の関数の name を指すエイリアスでなければならない。'
    ) -join "`n")
    exit 1
}

<#
    **spec の entry 数と C ABI の export 数は同じではない。** `entryPoint` を
    持つ entry は「C# 側だけの別 overload」で、C の宣言・export は 1 本に
    集約される（bindings/generator/Ocvu.Generator/CHeaderEmitter.cs のコメント
    「entryPoint を持つものは C# 側の別 overload であって、C の宣言は 1 本
    である」と同じ規則。上の検証で、この前提が実在の name に対して
    成り立つことは確かめてある）。実例: `ocvu_mat_copy_from_buffer_ptr` は
    `entryPoint: "ocvu_mat_copy_from_buffer"` を持ち、native が export するのは
    後者だけである。ここで `entryPoint` を見ずに `name` だけを集めると、
    **実際には食い違っていない構成を毎回「不足」と誤報する**（実測）。
#>
$expected = @(
    $specFunctions | ForEach-Object {
        $ep = $_.PSObject.Properties['entryPoint']
        if ($ep -and $ep.Value) { $ep.Value } else { $_.name }
    } | Sort-Object -Unique
)

# **0 件を「一致した」と読まない。** spec が読めていないなら、
# どんな binary とも「一致」してしまう。
if ($expected.Count -eq 0) {
    Write-Error 'spec から関数名が 1 つも拾えなかった。走査が効いていない'
    exit 1
}

# --- 実際の一覧を得る ---
if ($SymbolListPath) {
    $rawActual = @(Get-Content -LiteralPath $SymbolListPath |
        Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
} elseif ($LibraryPath) {
    if (-not (Test-Path -LiteralPath $LibraryPath)) {
        Write-Error "binary が無い: $LibraryPath"
        exit 1
    }
    $rawActual = @(Get-ExportedSymbol -Path $LibraryPath)
} else {
    Write-Error '-LibraryPath か -SymbolListPath のどちらかが要る'
    exit 1
}

<#
    **`ocvu_` 以外の export は比較から外す。落とすだけで終わらせない。**

    静的リンクした OpenCV 等の third-party シンボルが動的シンボル表に
    紛れ込むことがあり（visibility を絞りきれていない依存が 1 つでもあれば
    起きる）、そのまま spec と比較すると「余剰」が third-party のシンボル数
    だけ常に出て、この検査自体が意味を成さなくなる。だからフィルタは残す。

    **ただし黙って捨てない。** 何件・どれを捨てたかを毎回報告する。
    以前はここが無条件かつ無言のフィルタで、`$actual` に非 ocvu_ の
    シンボルを混ぜても検査の合否が変わらない——つまり方向 (b)
    （「エクスポートされているのに spec に無い」）のうち非 ocvu_ の場合を
    このフィルタが常に無条件で通してしまう分岐に、合成テストのどの入力も
    一度も到達していなかった（レビュー指摘）。

    **ここを厳格な allowlist にする判断は見送ってある**（2026-09 レビューの
    裁定）。このマシンには nm/ar が無く、実物の ELF/Mach-O のエクスポート面を
    確かめられないので、いま allowlist を作ると「空のまま Linux の初回 CI で
    赤くなる」か「誰も検証していない名前で埋めた張りぼて」のどちらかにしか
    ならない。CI が実物の export 面を出してから、その実測を基に
    allowlist 化を検討する——**これは見落としではなく、保留中の判断である**。
#>
$actual    = @($rawActual | Where-Object { $_ -like 'ocvu_*' } | Sort-Object -Unique)
$discarded = @($rawActual | Where-Object { $_ -notlike 'ocvu_*' } | Sort-Object -Unique)

if ($discarded.Count -gt 0) {
    $sample = ($discarded | Select-Object -First 5) -join ', '
    Write-Host "==> $($discarded.Count) 件の非 ocvu_ export を比較から除外した（例: $sample）"
}

# --- 突き合わせる ---
$missing = @($expected | Where-Object { $_ -notin $actual })
$extra   = @($actual   | Where-Object { $_ -notin $expected })

# **何を数えているかを明示する。** Linux の binary は ocvu_ 以外にも多数を
# export し得るので、「exported symbols」とだけ言うと本数が一致しない。
Write-Host "==> ocvu_-prefixed exports: $($actual.Count) (spec: $($expected.Count))"

if ($missing.Count -gt 0) {
    Write-Host 'spec に在るのにエクスポートされていない:'
    $missing | ForEach-Object { Write-Host "  - $_" }
}
if ($extra.Count -gt 0) {
    Write-Host 'エクスポートされているのに spec に無い:'
    $extra | ForEach-Object { Write-Host "  + $_" }
}

if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
    Write-Error "公開面が spec と食い違う（不足 $($missing.Count) / 余剰 $($extra.Count)）"
    exit 1
}
