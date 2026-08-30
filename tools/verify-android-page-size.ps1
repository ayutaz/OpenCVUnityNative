#Requires -Version 7.0

<#
    Android の .so が 16 KB page size に対応していることを検査する。

    ## なぜ要るか

    Android 15 (API 35) 以降を対象とするアプリは Google Play 上で 16 KB に
    対応していなければならず、**2027-02-01 から未対応の更新は公開できなく
    なる**（https://developer.android.com/guide/practices/page-sizes）。

    **止まるのは利用者のリリースである** —— こちらが配る .so が利用者の
    アプリに入るため。だから配る側で検査する。

    ## なぜ readelf に頼らないか

    verify-plugin-portability.ps1 と同じ理由である。開発機に readelf が
    無いと検査できない、という穴を作らない。ELF の program header は
    固定長のレコードが並んでいるだけなので、自分で読む。

    ## 何を見るか

    PT_LOAD セグメントの p_align。これが 16384 以上なら 16 KB の page で
    マップできる。**4096 だと 16 KB page の端末で読み込めない。**
#>
param(
    # 検査する .so。省略すると package の Android plugin。
    [string] $PluginPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$RequiredAlign = 16384

if (-not $PluginPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $PluginPath = Join-Path $repoRoot `
        'Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/Android/arm64-v8a/libopencv_unity_native.so'
}

if (-not (Test-Path -LiteralPath $PluginPath)) {
    [Console]::Error.WriteLine("Android plugin が見つかりません: $PluginPath")
    [Console]::Error.WriteLine('先に ./tools/dev.ps1 build -Platform android-arm64 を実行すること。')
    exit 1
}

$bytes = [IO.File]::ReadAllBytes($PluginPath)

if ($bytes.Length -lt 64 -or
    $bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
    [Console]::Error.WriteLine("ELF ではありません: $PluginPath")
    exit 1
}
if ($bytes[4] -ne 2) {
    [Console]::Error.WriteLine('ELF64 ではありません（arm64-v8a は 64-bit）。')
    exit 1
}

# e_phoff (0x20, 8 bytes) / e_phentsize (0x36, 2) / e_phnum (0x38, 2)
$phoff     = [BitConverter]::ToUInt64($bytes, 0x20)
$phentsize = [BitConverter]::ToUInt16($bytes, 0x36)
$phnum     = [BitConverter]::ToUInt16($bytes, 0x38)

if ($phnum -eq 0 -or $phentsize -lt 0x38) {
    [Console]::Error.WriteLine(
        "program header が読めません（phnum=$phnum phentsize=$phentsize）。共有ライブラリではない可能性があります。")
    exit 1
}

$loads = @()
for ($i = 0; $i -lt $phnum; $i++) {
    $off = [int]$phoff + $i * $phentsize
    if ($off + 0x38 -gt $bytes.Length) { break }
    # p_type (offset 0x00, 4 bytes)。PT_LOAD = 1。
    if ([BitConverter]::ToUInt32($bytes, $off) -ne 1) { continue }
    # p_align (offset 0x30, 8 bytes)
    $align = [BitConverter]::ToUInt64($bytes, $off + 0x30)
    $loads += [pscustomobject]@{ Index = $i; Align = $align }
}

<#
    **0 件で緑にしない。**

    PT_LOAD を 1 つも読めていない状態を「違反なし」と読むと、検査が丸ごと
    空振りする —— しかも成功として出力される。ELF の読み方が想定と違った
    ことを、合格と区別できる形で報告する。
#>
if ($loads.Count -eq 0) {
    [Console]::Error.WriteLine('PT_LOAD セグメントが 1 つも見つかりません。ELF の読み方が想定と違います。')
    [Console]::Error.WriteLine('**0 件は「違反なし」ではない。**')
    exit 1
}

$bad = @($loads | Where-Object { $_.Align -lt $RequiredAlign })
if ($bad.Count -gt 0) {
    [Console]::Error.WriteLine("16 KB page size に対応していません: $PluginPath")
    foreach ($b in $bad) {
        [Console]::Error.WriteLine("  PT_LOAD[$($b.Index)] p_align = $($b.Align)（$RequiredAlign 以上が要る）")
    }
    [Console]::Error.WriteLine('2027-02-01 から、未対応のアプリは Google Play で更新を公開できない。')
    [Console]::Error.WriteLine('止まるのは利用者のリリースである —— この .so が利用者のアプリに入るため。')
    exit 1
}

$minAlign = ($loads | Measure-Object -Property Align -Minimum).Minimum
Write-Host "==> $(Split-Path -Leaf $PluginPath): PT_LOAD $($loads.Count) 件、最小 p_align = $minAlign（>= $RequiredAlign）" -ForegroundColor Green
exit 0
