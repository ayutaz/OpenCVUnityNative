#Requires -Version 7.0

<#
    ビルド済み OpenCV ツリーの linkage が、構成の意図と一致するかを検証する。

    送った CMake flag ではなく、**できたバイナリを読む**。M1 ではこの検証が無く、
    2 件の欠陥が人手で発見された（PATH から拾われたアセンブラ、黙って上書き
    された CRT linkage）。詳細は docs/roadmap.md の M1 節「既知の欠陥」。

    tools/verify-opencv-artifact.ps1 とは別軸である:
      あちら = どのファイルが在るか（依存の allowlist）
      こちら = そのファイルがどう作られたか（linkage）
    依存の集合が正しくても linkage が違えば M1 と同じ欠陥になる。

    **認識できなかったものは失敗側に落とす。** 読めない、1 件も見つからない、
    platform が未対応 — すべて exit 1 にする。「読み取れなかったら通す」は
    M1 が繰り返した欠陥の一形態である。
#>

param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Platform
)

# param ブロックは script の最初の実行文でなければ特別扱いされない
# （コメントと #Requires は例外だが、Set-StrictMode のような文が先にあると
# 普通の関数呼び出し "param(...)" として解釈され、パラメータが束縛されない
# まま StrictMode の未設定変数エラーになる。tools/verify-opencv-artifact.ps1
# と同じく、Set-StrictMode は param ブロックの後に置く）。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

Import-Module (Join-Path $PSScriptRoot 'OpenCvConfig.psm1') -Force

function Write-VerifyFailure([string]$Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

if (-not $Platform) { $Platform = Get-OpenCvPlatform }
if (-not (Test-Path -LiteralPath $Root)) {
    Write-VerifyFailure "artifact tree not found: $Root"
}

$config = Get-OpenCvConfig -Platform $Platform

# 構成が要求している CRT linkage を読む。これが「意図」の側である。
$wantsSharedRuntime = $config.CMakeArgs -contains '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'

switch ($Platform) {
    'windows-x64' {
        $libs = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter '*.lib' |
                  Where-Object { $_.Name -like 'opencv_*' })
        if ($libs.Count -eq 0) {
            Write-VerifyFailure (@(
                "no opencv_*.lib found under $Root"
                '0 件を「違反なし」と読まない。検査対象が見つからないのは失敗である。'
            ) -join "`n")
        }

        # .lib に埋め込まれた /DEFAULTLIB: 指令を読む。MSVC はリンク時に
        # 使う CRT をここに記録するので、実際にどちらでビルドされたか分かる。
        #   LIBCMT  = 静的 CRT (/MT)
        #   MSVCRT  = 共有 CRT (/MD)
        $violations = @()
        foreach ($lib in $libs) {
            $bytes = [System.IO.File]::ReadAllBytes($lib.FullName)
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            $static = [regex]::Matches($text, 'DEFAULTLIB:"LIBCMT"').Count
            $shared = [regex]::Matches($text, 'DEFAULTLIB:"MSVCRT"').Count

            if ($static -eq 0 -and $shared -eq 0) {
                $violations += "$($lib.Name): no CRT directive found (cannot determine linkage)"
                continue
            }
            if ($wantsSharedRuntime -and $static -gt 0) {
                $violations += "$($lib.Name): configured for the shared runtime but has $static static-CRT directive(s)"
            }
            if (-not $wantsSharedRuntime -and $shared -gt 0) {
                $violations += "$($lib.Name): configured for the static runtime but has $shared shared-CRT directive(s)"
            }
        }

        if ($violations.Count -gt 0) {
            Write-VerifyFailure (@(
                "linkage does not match the configuration ($($violations.Count) file(s)):"
                ($violations | ForEach-Object { "  $_" })
                ''
                "構成の意図: $(if ($wantsSharedRuntime) { '共有ランタイム (/MD)' } else { '静的ランタイム (/MT)' })"
                'tools/opencv-config.psd1 を変えたなら CI で再ビルドが要る。'
            ) -join "`n")
        }

        Write-Host "==> $($libs.Count) libraries match the configured runtime linkage" -ForegroundColor Green
    }
    default {
        # 未対応 platform を黙って通さない。Task 5 でここに macOS / Linux を足す。
        Write-VerifyFailure (@(
            "linkage verification is not implemented for platform '$Platform'."
            'この検査は未対応 platform を成功にしない。実装するまで失敗させる。'
        ) -join "`n")
    }
}

exit 0
