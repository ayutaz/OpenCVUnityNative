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

<#
    Linux / macOS 共通の静的アーカイブ検査。

    opencv-config.psd1 の共通 CMakeArgs（platform 別ではない）が
    -DBUILD_SHARED_LIBS=OFF を指定しているため、Windows と同じく Linux / macOS でも
    OpenCV module は静的アーカイブ（.a）としてビルドされる。実測（M3 Task 4 の CI が
    作った opencv-5.0.0-linux-x64-c4e3c491d973 / opencv-5.0.0-macos-arm64-1ccdc7f9ab94 を
    実際に download して確認）: lib/ 配下は libopencv_*.a と 3rdparty の lib*.a のみで、
    .so / .dylib は両 platform とも 1 つも存在しない。

    readelf -d / otool -L が読む「動的セクションの NEEDED エントリ」は、完全にリンクされた
    実行ファイルや共有ライブラリにしか存在しない。.a は再配置可能オブジェクト（.o）の
    単なるアーカイブで動的セクションを持たないため、この 2 つを .a に向けても何も
    見つからない。もし「.so / .dylib だけを対象にする」実装のままにすると、対象拡張子に
    一致するファイルが 1 つも無い（$inspected が常に 0 のまま）状態で "success" として
    抜けてしまう — この検査全体が禁じている「0 件を違反なしと読む」形の静かな抜け穴に
    なる。ここが計画書のスニペットをそのまま実装しなかった理由である。

    代わりに nm -u（未定義シンボル）で各静的アーカイブの参照先を見る。module が
    FFmpeg / GStreamer の関数を実際に呼んでいれば、そのシンボル名が未定義参照として
    現れる（avcodec_* / avformat_* / gst_* は各ライブラリが public API に使う命名規約）。
    nm は GNU binutils（Linux）と Xcode Command Line Tools（macOS）のどちらにも標準で
    入っており、-u は POSIX 共通のオプションなので同じロジックを両 platform で共有できる。
#>
$ForbiddenUndefinedSymbolPrefixes = @(
    @{ Prefix = 'avcodec_';  Library = 'libavcodec (FFmpeg)' }
    @{ Prefix = 'avformat_'; Library = 'libavformat (FFmpeg)' }
    @{ Prefix = 'gst_';      Library = 'libgstreamer' }
)

function Test-StaticArchiveLinkage([string]$Root, [string]$PlatformLabel) {
    $libs = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter '*.a' |
              Where-Object { $_.Name -like 'libopencv_*' })
    if ($libs.Count -eq 0) {
        Write-VerifyFailure (@(
            "no libopencv_*.a found under $Root"
            '0 件を「違反なし」と読まない。検査対象が見つからないのは失敗である。'
        ) -join "`n")
    }

    $violations = @()
    foreach ($lib in $libs) {
        # nm が無い、または対象ファイルを読めない場合はここで非 0 終了する
        # （$ErrorActionPreference = 'Stop' により、コマンド自体が見つからない
        # ケースはこの呼び出しで直接 terminating error になる）。「読み取れなかったら
        # 通す」を避けるため、$LASTEXITCODE も明示的に見る。
        $syms = & nm -u $lib.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-VerifyFailure (@(
                "nm failed on $($lib.Name); cannot determine linkage"
                ($syms -join "`n")
            ) -join "`n")
        }
        foreach ($rule in $ForbiddenUndefinedSymbolPrefixes) {
            if ($syms -match [regex]::Escape($rule.Prefix)) {
                $violations += "$($lib.Name): references an undefined '$($rule.Prefix)*' symbol, which points at $($rule.Library) (excluded by the configuration)"
            }
        }
    }

    if ($violations.Count -gt 0) {
        Write-VerifyFailure (@(
            "linkage does not match the configuration ($($violations.Count) violation(s)):"
            ($violations | ForEach-Object { "  $_" })
        ) -join "`n")
    }

    Write-Host "==> $($libs.Count) $PlatformLabel static libraries carry no excluded undefined symbol" -ForegroundColor Green
}

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
    'linux-x64' {
        Test-StaticArchiveLinkage -Root $Root -PlatformLabel 'Linux'
    }
    'macos-arm64' {
        Test-StaticArchiveLinkage -Root $Root -PlatformLabel 'macOS'
    }
    default {
        # 未対応 platform を黙って通さない。4 つ目の platform が増えたときの
        # 安全網として、実装済みの 3 platform を足した後も残す。
        Write-VerifyFailure (@(
            "linkage verification is not implemented for platform '$Platform'."
            'この検査は未対応 platform を成功にしない。実装するまで失敗させる。'
        ) -join "`n")
    }
}

exit 0
