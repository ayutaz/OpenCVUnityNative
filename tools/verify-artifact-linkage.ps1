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

# **switch の default に到達できる形にしておく。**
#
# 素直に Get-OpenCvConfig -Platform <未知> を呼ぶと、そこで「未知の platform」
# 例外が出て switch まで届かない。すると default 分岐（「読み取りロジックが
# 無い platform は失敗にする」という、この検査で最も重要な安全側の既定）が
# **一度も実行されないまま**になり、効いているかどうか誰にも分からない。
#
# Toolchains に登録されているが読み取りロジックを書いていない platform は
# 実際に起こり得る — 4 つ目を足した人が opencv-config.psd1 だけ更新して
# この検査を忘れる、というのがまさにその形である。構成の取得に失敗した場合は
# 空の構成で先へ進め、switch に判定させる。
$config = $null
try {
    $config = Get-OpenCvConfig -Platform $Platform
}
catch {
    # 構成が引けない platform でも switch まで進める。実装のある platform なら
    # 下で $config を使うので、そこで改めて落ちる。
    $config = [pscustomobject]@{ Platform = $Platform; CMakeArgs = @() }
}

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

# $PlatformLabel は switch の case と**同じ綴りの platform 名**を受け取る
# （'linux-x64' / 'macos-arm64'）。表示用の別名（'Linux' など）を渡すと、
# 下の platform 別分岐が一致せず黙って素通りする — 恒真な検査を足すのと同じ
# ことになる（実際に一度そう書いた）。
function Test-StaticArchiveLinkage([string]$Root, [string]$PlatformLabel) {
    <#
        **`libopencv_*` に絞っている。** bundled されている 3rdparty
        （libzlib.a / liblibpng.a など）は見ていない。

        絞る理由は、判定に使っている材料が OpenCV 自身のビルド設定を前提に
        しているからである（未定義シンボルの allowlist は OpenCV の module 構成、
        architecture と位置独立の指定は OpenCV へ渡した flag）。3rdparty は
        それぞれ独自の CMake を持ち、指定の効き方が違い得る。

        **これは既知の穴である。** `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` は
        3rdparty にも効くべき指定で、そちらだけ漏れると共有ライブラリへ
        リンクするときに落ちる——つまりこの検査が通っても、その失敗は防げない。
        絞りを外すなら、3rdparty ごとの期待値を決めてからにする必要がある
        （でないと「読めなかったら通す」か「誤検出で赤くなる」のどちらかになる）。
    #>
    $libs = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter '*.a' |
              Where-Object { $_.Name -like 'libopencv_*' })
    if ($libs.Count -eq 0) {
        Write-VerifyFailure (@(
            "no libopencv_*.a found under $Root"
            '0 件を「違反なし」と読まない。検査対象が見つからないのは失敗である。'
        ) -join "`n")
    }

    <#
        --- 有効言語: アセンブラが勝手に有効化されていないか（Unix 側）---

        roadmap の条件 5 は「linkage・**有効言語**・リンク済み依存」の 3 つを
        求めている。Windows 側は「MSVC のビルドに .a が現れたら GNU 言語が
        有効化された証拠」で判別できるが、Unix では .a が正常な形なので
        同じ手が使えない。**この分岐には長らく有効言語の検査が無かった。**

        代わりに archive の**メンバ名**を読む。CMake は object file を元ソースの
        拡張子込みで名付けるので、ASM が有効なら `foo.S.o` のようなメンバが
        現れる。opencv-config.psd1 は全 platform 共通で
        -DCMAKE_ASM_COMPILER=NOTFOUND を送っているから、1 つでも出れば
        その指定が守られていない。

        これは「送った flag」ではなく「できた成果物」を読んでいる。
        check_language(ASM) は PATH 上のアセンブラを拾うので、runner の
        中身が変わると成果物が変わる。M1 Task 4 が Windows で踏んだのが
        まさにこれで、同じことが Unix 側で起きても今までは誰も見ていなかった。
    #>
    $assembled = @()
    foreach ($lib in $libs) {
        $members = & ar t $lib.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-VerifyFailure (@(
                "ar failed on $($lib.Name); cannot determine which languages were enabled"
                ($members -join "`n")
            ) -join "`n")
        }
        foreach ($member in $members) {
            if ($member -match '\.(S|s|asm)\.o$') {
                $assembled += "$($lib.Name): $member"
            }
        }
    }
    if ($assembled.Count -gt 0) {
        Write-VerifyFailure (@(
            "assembled objects are present ($($assembled.Count)); the assembler was enabled"
            ($assembled | Select-Object -First 10 | ForEach-Object { "  $_" })
            'configured: -DCMAKE_ASM_COMPILER=NOTFOUND'
            'CMake の check_language(ASM) が PATH 上のアセンブラを拾うと、'
            'runner の中身次第で成果物が変わる。構成の意図と食い違う。'
        ) -join "`n")
    }
    Write-Host "==> no assembled objects in $($libs.Count) archives; the assembler stayed disabled" -ForegroundColor Green

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

    # --- 構成が指定した platform 固有の意図を、成果物から読む ---
    #
    # 上の未定義シンボル検査だけでは足りない。この構成には videoio が無く
    # FFmpeg / GStreamer を呼ぶコードが存在しないので、探しているシンボルは
    # **原理的に現れない** — つまりあの判定は恒真である（実測で確認）。
    # 0 件を失敗にする防御は正しいが、その先が何も判別していなかった。
    #
    # Windows 側は DEFAULTLIB を読んで CRT linkage を判別している。同じ性質の
    # 検査を Unix 側にも置く: PlatformCMakeArgs が送っている指定が、実際に
    # 守られたかを成果物から確かめる。これが roadmap の条件 5 が言う
    # 「送った CMake flag ではなく、できたバイナリを読む」である。
    if ($PlatformLabel -eq 'macos-arm64') {
        <#
            -DCMAKE_OSX_ARCHITECTURES=arm64 が守られたか。指定が無視されると
            universal binary や x86_64 になり得て、成果物の中身が構成から
            読めなくなる。

            **1 本だけ見ない。** 位置独立コードの検査を全走査に直したときと
            同じ理由である。architecture は全 object に現れるので実害は
            そちらより小さいが、「先頭がたまたま代表的でない」可能性は
            同じように存在する。こちらは**全部が arm64 のみ**であることを
            求める（architecture は 1 本でも違えば構成違反なので、
            位置独立コードの「1 本でもあれば」とは向きが逆になる）。
        #>
        $wantsArm64 = $config.CMakeArgs -contains '-DCMAKE_OSX_ARCHITECTURES=arm64'
        if ($wantsArm64) {
            $wrongArch = @()
            foreach ($lib in $libs) {
                $arch = & lipo -info $lib.FullName 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-VerifyFailure "lipo failed on $($lib.Name); cannot determine the architecture"
                }
                if (-not (($arch -match 'arm64') -and ($arch -notmatch 'x86_64'))) {
                    $wrongArch += "$($lib.Name): $arch"
                }
            }
            if ($wrongArch.Count -gt 0) {
                Write-VerifyFailure (@(
                    "architecture does not match the configuration ($($wrongArch.Count) of $($libs.Count) archives)"
                    "  configured: arm64 only"
                    ($wrongArch | Select-Object -First 5 | ForEach-Object { "  $_" })
                ) -join "`n")
            }
            Write-Host "==> architecture matches the configuration (arm64, $($libs.Count) archives)" -ForegroundColor Green
        }
    }

    if ($PlatformLabel -eq 'linux-x64') {
        # -DCMAKE_POSITION_INDEPENDENT_CODE=ON が守られたか。無視されると
        # 共有ライブラリへ取り込むときに relocation エラーになる。ELF の
        # 再配置種別に現れるので readelf で読める。
        $wantsPic = $config.CMakeArgs -contains '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
        if ($wantsPic) {
            # **1 つだけ見ない。** 最初のライブラリだけを調べると、それがたまたま
            # 再配置を持たない小さなモジュールだったときに誤検出する（実測: CI の
            # Linux job が「痕跡が無い」で落ちたが、原因は指定が無視されたのではなく
            # 標本の選び方だった）。
            #
            # 位置独立の指定はプロジェクト全体に効くので、**どれか 1 つにでも痕跡が
            # あれば守られている**。逆に全部を調べて 1 つも無ければ、指定が
            # 無視されたと言ってよい。
            $inspected = 0
            $withPic = 0
            foreach ($lib in $libs) {
                $relocs = & readelf --relocs $lib.FullName 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-VerifyFailure "readelf failed on $($lib.Name); cannot determine relocation types"
                }
                $inspected++
                <#
                    **PLT32 と GOTOFF を判定材料から外した。**

                    R_X86_64_PLT32 は外部関数呼び出しに対して**非 PIC ビルドでも**
                    現代の GCC / clang が既定で出す。これを合格材料に含めると
                    判定はほぼ恒真になり、「通った」ことの意味がほとんど無くなる。

                    位置独立かどうかを実際に分けるのは、外部データ参照を
                    GOT 経由にするかどうかである。位置独立なら GOTPCREL 系、
                    そうでなければ絶対アドレス（R_X86_64_32S 等）が出る。

                    この絞り込みは、以前ここを「1 本だけ見る」から「全部見る」に
                    直したときの反省でもある。あのときは偽陽性を消すために
                    **合格条件を緩める**方向へ直してしまい、テストを 1 行も
                    足さなかった。緩めた側の意味は誰も確かめていなかった。
                #>
                if ($relocs -match 'GOTPCREL') { $withPic++ }
            }

            if ($inspected -eq 0) {
                Write-VerifyFailure 'no archive could be inspected for relocation types'
            }
            if ($withPic -eq 0) {
                Write-VerifyFailure (@(
                    "none of the $inspected archives carries a position-independent relocation"
                    "configured: -DCMAKE_POSITION_INDEPENDENT_CODE=ON"
                    '指定が無視された可能性がある。1 つでも痕跡があれば守られていると'
                    '判断するので、全部に無いのは構成と食い違う。'
                ) -join "`n")
            }
            <#
                **この検査が捕まえないもの。** 「1 つでもあれば合格」なので、
                指定が全体に無視された場合（全滅）は捕まえるが、一部の
                archive だけ位置独立から漏れた場合（まだら）は捕まえない。

                厳しくするなら「再配置を持つのに位置独立のものが 1 つも無い
                archive」を違反とする形が考えられるが、位置独立なコードでも
                データ節には絶対再配置が出るため誤検出が出やすい。全滅を
                確実に捕まえる側を優先し、まだらは捕まえないと決めた。
                内訳を出しているのは、その前提が崩れたときに気づけるように
                するためである（$withPic が急に減ったら見に行く手がかりになる）。
            #>
            Write-Host "==> position-independent code confirmed ($withPic of $inspected archives)" -ForegroundColor Green
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

        # --- 有効言語: ASM が勝手に enable されていないか ---
        #
        # M1 Task 4 の欠陥をここで捕まえる。OpenCV の CMakeLists は
        # check_language(ASM) で PATH 上のアセンブラを探し、見つけると
        # enable_language(ASM) する。GNU 言語が 1 つでも有効になると CMake は
        # 静的ライブラリの命名規約をプロジェクト全体で GNU 側（libX.a）へ倒す。
        #
        # つまり **MSVC のビルドに .a が現れることが、ASM が有効化された証拠**
        # である。opencv-config.psd1 は -DCMAKE_ASM_COMPILER=NOTFOUND で
        # 「送る側」を固定しているが、それが守られたかは成果物からしか読めない。
        # roadmap の条件 5 が「有効言語」を名指ししているのはこの経路である。
        $gnuStyle = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter '*.a')
        if ($gnuStyle.Count -gt 0) {
            Write-VerifyFailure (@(
                "GNU-style static libraries found in an MSVC build ($($gnuStyle.Count) file(s)):"
                ($gnuStyle | Select-Object -First 5 | ForEach-Object { "  $($_.Name)" })
                ''
                'MSVC の構成で libX.a が出るのは、CMake が GNU 言語（多くは ASM）を'
                '有効化して命名規約をプロジェクト全体で倒したときである。'
                'opencv-config.psd1 の -DCMAKE_ASM_COMPILER=NOTFOUND が効いていない。'
                'M1 Task 4 で実際に起きた欠陥である。'
            ) -join "`n")
        }

        Write-Host "==> $($libs.Count) libraries match the configured runtime linkage" -ForegroundColor Green
        Write-Host "==> no GNU-style archives; the assembler stayed disabled" -ForegroundColor Green
    }
    'linux-x64' {
        Test-StaticArchiveLinkage -Root $Root -PlatformLabel 'linux-x64'
    }
    'macos-arm64' {
        Test-StaticArchiveLinkage -Root $Root -PlatformLabel 'macos-arm64'
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
