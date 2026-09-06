#!/usr/bin/env pwsh
param(
    # 実物の binary から読む場合。
    [string]$LibraryPath,
    # シンボル一覧を直接与える場合（テスト用。1 行 1 名）。
    [string]$SymbolListPath
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
    # -g は外部シンボルだけ、--defined-only は定義されているものだけ。
    $out = & nm -g --defined-only $Path 2>&1
    return @($out | ForEach-Object {
        if ($_ -match '^\S+\s+[TtDd]\s+_?(\S+)') { $Matches[1] }
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

# --- 期待する一覧を正本から読む ---
#
# **spec の entry 数と C ABI の export 数は同じではない。** `entryPoint` を
# 持つ entry は「C# 側だけの別 overload」で、C の宣言・export は 1 本に
# 集約される（bindings/generator/Ocvu.Generator/CHeaderEmitter.cs のコメント
# 「entryPoint を持つものは C# 側の別 overload であって、C の宣言は 1 本
# である」と同じ規則）。実例: `ocvu_mat_copy_from_buffer_ptr` は
# `entryPoint: "ocvu_mat_copy_from_buffer"` を持ち、native が export するのは
# 後者だけである。ここで `entryPoint` を見ずに `name` だけを集めると、
# **実際には食い違っていない構成を毎回「不足」と誤報する**（実測）。
$specDir = Join-Path $repoRoot 'bindings/spec'
$expected = @(
    Get-ChildItem -LiteralPath $specDir -Filter '*.json' |
        Where-Object { $_.Name -ne 'schema.json' } |
        ForEach-Object {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).functions |
                ForEach-Object {
                    $entryPoint = $_.PSObject.Properties['entryPoint']
                    if ($entryPoint -and $entryPoint.Value) { $entryPoint.Value } else { $_.name }
                }
        }
) | Sort-Object -Unique

# **0 件を「一致した」と読まない。** spec が読めていないなら、
# どんな binary とも「一致」してしまう。
if ($expected.Count -eq 0) {
    Write-Error 'spec から関数名が 1 つも拾えなかった。走査が効いていない'
    exit 1
}

# --- 実際の一覧を得る ---
if ($SymbolListPath) {
    $actual = @(Get-Content -LiteralPath $SymbolListPath |
        Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
} elseif ($LibraryPath) {
    if (-not (Test-Path -LiteralPath $LibraryPath)) {
        Write-Error "binary が無い: $LibraryPath"
        exit 1
    }
    $actual = @(Get-ExportedSymbol -Path $LibraryPath)
} else {
    Write-Error '-LibraryPath か -SymbolListPath のどちらかが要る'
    exit 1
}

$actual = @($actual | Where-Object { $_ -like 'ocvu_*' }) | Sort-Object -Unique

# --- 突き合わせる ---
$missing = @($expected | Where-Object { $_ -notin $actual })
$extra   = @($actual   | Where-Object { $_ -notin $expected })

Write-Host "==> exported symbols: $($actual.Count) (spec: $($expected.Count))"

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
