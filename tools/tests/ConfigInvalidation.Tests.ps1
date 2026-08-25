#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$base = Get-OpenCvConfig
$baseHash = Get-OpenCvConfigHash -Config $base
$baseRoot = Get-OpenCvRoot -Config $base

# 構成を変えた場合、install 先のパスそのものが変わること。
# ハッシュだけ変わってパスが同じなら、古いツリーが再利用されてしまう。
$changed = Get-OpenCvConfig
$changed.Modules = @($changed.Modules) + 'photo'
$changedHash = Get-OpenCvConfigHash -Config $changed
$changedRoot = Get-OpenCvRoot -Config $changed

Assert-That ($changedHash -ne $baseHash) 'adding a module changes the hash'
Assert-That ($changedRoot -ne $baseRoot) 'a different hash resolves to a different install root'
Assert-That ($changedRoot -like "*$changedHash*") 'the install root contains the new hash'

# 引数の並びだけが違う構成は同じハッシュになること。
# ここが変わると、意味の無い再ビルドが起きる。
$reordered = Get-OpenCvConfig
$reordered.CMakeArgs = @($reordered.CMakeArgs | Sort-Object -Descending)
Assert-That ((Get-OpenCvConfigHash -Config $reordered) -eq $baseHash) 'reordering flags does not change the hash'

# レビュー H3: Get-OpenCvConfigHash は以前 Tag / Modules /
# Toolchain.Generator / Toolchain.Architecture / Toolchain.BuildType /
# CMakeArgs の 6 つを名指しで拾う列挙式で、Toolchain に新しいキー
# （例: Toolset）を足してもハッシュが変わらなかった（実測で確認済み:
# 修正前は 6ba270f342e3 のまま）。まずはこの具体的な再現から。
$toolchainToolset = Get-OpenCvConfig
$toolchainToolset.Toolchain['Toolset'] = 'v142'
Assert-That ((Get-OpenCvConfigHash -Config $toolchainToolset) -ne $baseHash) 'adding Toolchain.Toolset changes the hash (H3 regression)'

# 上の 1 件だけを直すと、「著者が名前を思いついたキーだけ拾う」という
# 同じ形の欠陥を一段狭い範囲で繰り返すことになる（H3 のレビューコメント
# そのもの）。個別のキー名を決め打ちしたテストは、次に増えるキーの名前を
# 予測できない。そこで、あらかじめ存在し得ない名前（GUID）をキーに使い、
# 「どんな名前の新しいキーであっても」ハッシュが反応することを確認する —
# これは特定のキー名を検査しているのではなく、正規化が構造全体を
# 網羅的に辿っていること自体を検査している。
$unforeseenKey = "unforeseen-$([guid]::NewGuid().ToString('N'))"

# トップレベルに増えた、予測不能な名前のキー。
$topLevelAddition = Get-OpenCvConfig
$topLevelAddition | Add-Member -NotePropertyName $unforeseenKey -NotePropertyValue 'x'
Assert-That ((Get-OpenCvConfigHash -Config $topLevelAddition) -ne $baseHash) "adding an unforeseen top-level key ($unforeseenKey) changes the hash"

# ネストした Hashtable（Toolchain）に増えた、予測不能な名前のキー。
$nestedAddition = Get-OpenCvConfig
$nestedAddition.Toolchain[$unforeseenKey] = 'y'
Assert-That ((Get-OpenCvConfigHash -Config $nestedAddition) -ne $baseHash) "adding an unforeseen nested key (Toolchain.$unforeseenKey) changes the hash"

# さらに一段深い、新しく増えたネスト構造（Hashtable の中の Hashtable）も
# 拾われること。再帰が最初の階層だけで止まっていないことの確認。
$deeplyNestedAddition = Get-OpenCvConfig
$deeplyNestedAddition | Add-Member -NotePropertyName $unforeseenKey -NotePropertyValue @{ Inner = 'z' }
Assert-That ((Get-OpenCvConfigHash -Config $deeplyNestedAddition) -ne $baseHash) 'adding a new nested structure (not just a scalar) changes the hash'

# 対称性: キーを削って構成が縮んだ場合も、それは別の構成なのでハッシュは
# 変わるべきである（消し忘れ・移行漏れが古い artifact の再利用として
# 現れないようにする）。
$removed = [pscustomobject]@{
    Tag       = $base.Tag
    Modules   = $base.Modules
    Toolchain = $base.Toolchain
    # CMakeArgs を欠落させる。
}
Assert-That ((Get-OpenCvConfigHash -Config $removed) -ne $baseHash) 'removing a key changes the hash'

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
