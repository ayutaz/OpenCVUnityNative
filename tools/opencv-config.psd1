@{
    # OpenCV のバージョンは明示的に bump するまで固定する。
    # 変更するとここから算出される構成ハッシュが変わり、
    # 古い artifact は自動的に使われなくなる。
    Tag = '5.0.0'

    # OpenCV 5 のモジュール名。4.x から再編されているので注意:
    #   features2d -> features
    #   calib3d    -> calib / geometry / stereo / ptcloud
    # BUILD_LIST は依存を自動解決するので、実際にビルドされる集合は
    # これより大きくなり得る。実測値は build-manifest.json に記録する。
    Modules = @('core', 'imgproc', 'imgcodecs', 'objdetect', 'features', 'calib')

    # platform ごとの toolchain。実行中の platform に対応する 1 つが選ばれ、
    # 構成ハッシュに混ざる（Get-OpenCvConfigHash は Config 全体を正規化する）。
    #
    # Generator が platform ごとに違うのは避けられない: MSVC は Visual Studio
    # generator、macOS / Linux は Ninja を使う。Ninja を選ぶのは、Xcode /
    # Unix Makefiles と違って生成物の配置が platform 間で揃うためである。
    Toolchains = @{
        'windows-x64' = @{
            Generator    = 'Visual Studio 17 2022'
            Architecture = 'x64'
            BuildType    = 'Release'
        }
        'macos-arm64' = @{
            Generator    = 'Ninja'
            Architecture = 'arm64'
            BuildType    = 'Release'
        }
        'linux-x64' = @{
            Generator    = 'Ninja'
            Architecture = 'x86_64'
            BuildType    = 'Release'

            <#
                Linux はこのコンテナの中でビルドする。**runner のイメージで
                直接ビルドしない。**

                共有ライブラリは、ビルドした環境と同じかそれより新しい
                glibc / libstdc++ でしか読み込めない。古い環境で作ったものは
                新しい環境でも動くが、逆は成立しない。

                v0.1.0 でこれを踏んだ。ubuntu-24.04（glibc 2.39）でビルドした
                .so が GLIBC_2.38 を要求し、それより古い環境で
                `DllNotFoundException: Unable to load DLL 'opencv_unity_native'`
                になった。**ビルドは成功し、linkage 検証も通り、配布物も
                作れた。** 読み込めないことは Unity を実際に動かすまで
                誰も知らなかった。公開済みの tarball も同じ状態だった。

                jammy = Ubuntu 22.04 = glibc 2.35 / GLIBCXX 3.4.30。現役の
                LTS で、利用者の環境として現実的に多い。runner の世代が
                上がっても要求が上がらないよう、runner ではなくコンテナで
                固定する。

                **この値は構成ハッシュに入る。** ビルド環境が変われば
                成果物も変わるので、同じハッシュのまま古い artifact が
                再利用されないようにするためである。

                上限の検査は tools/verify-plugin-portability.ps1 が行う。
                値を変えるときは、そちらの既定値も一緒に動かすこと
                （tools/tests/OpenCvConfig.Tests.ps1 が食い違いを検出する）。
            #>
            Container    = 'ubuntu:22.04'
        }

        <#
            Android。**クロスコンパイルなので host と対象が一致しない。**
            NDK の toolchain file を使う（cmake/toolchains/android-arm64.cmake）。

            arm64-v8a だけを対象にする。x86_64（エミュレータ）を含めるかの
            判断は roadmap の M4 節に書いてある。
        #>
        'android-arm64' = @{
            Generator    = 'Ninja'
            Architecture = 'arm64-v8a'
            BuildType    = 'Release'
        }

        <#
            iOS。**共有ライブラリを作らない。** iOS はアプリの外から .dylib を
            読み込めないので、Unity は静的ライブラリ (.a) を受け取って IL2CPP の
            バイナリへ静的リンクし、P/Invoke は DllImport("__Internal") で
            解決する（CLAUDE.md「IL2CPP / AOT を前提とする」）。

            **SHARED のままでもビルドは成功する。** 壊れるのは Unity に入れて
            からで、これは v0.1.0 が踏んだ「ビルドできた ≠ 動く」と同じ形である。
        #>
        'ios-arm64' = @{
            Generator    = 'Ninja'
            Architecture = 'arm64'
            BuildType    = 'Release'
        }

        <#
            Web / Wasm。**クロスコンパイルであり、かつ静的ライブラリである**
            —— iOS と同じ 2 つの性質を同時に持つ。

            toolchain は cmake/toolchains/web-wasm.cmake（Unity 同梱または
            emsdk の Emscripten.cmake を include する）。

            **Architecture は wasm32 と書く。** CMake の -A には渡さない
            （Ninja generator は -A を取らない）が、**構成ハッシュに混ざる**
            ので、将来 wasm64 を足したときに別ハッシュになる。

            **ここに新しいキーを足しても、既存 platform のハッシュは動かない**
            —— Get-OpenCvConfig が組み立てるのは Toolchains[$Platform] だけで
            ある（2026-09-03 に実測。windows-x64 / linux-x64 / android-arm64 の
            ハッシュが web-wasm 追加の前後で同一だった）。**対して Modules を
            触ると全 platform が動く**ので、Web のために module を足さないこと。
        #>
        'web-wasm' = @{
            Generator    = 'Ninja'
            Architecture = 'wasm32'
            BuildType    = 'Release'
        }
    }

    # platform 固有の CMake flag。共通の CMakeArgs に足される。
    PlatformCMakeArgs = @{
        'windows-x64' = @()
        'macos-arm64' = @(
            # 単一アーキテクチャに固定する。指定しないと universal binary に
            # なり得て、成果物の中身が構成から読めなくなる。
            '-DCMAKE_OSX_ARCHITECTURES=arm64'
            # 配布先の下限を固定する。指定しないとビルドマシンの OS 版に
            # 引きずられ、同じ構成ハッシュで別物ができる。
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0'
        )
        'linux-x64' = @(
            # 共有ライブラリへ静的ライブラリを取り込むため。
            # 指定しないとリンク時に relocation エラーになる。
            '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
        )
        'android-arm64' = @(
            <#
                **Android の sample プロジェクトを configure させない。**

                OpenCV の samples/android/*/CMakeLists.txt は `add_android_project`
                を呼び、Android SDK と Gradle を要求する。BUILD_EXAMPLES=OFF は
                これを止めない —— 別の変数だからである。**実測（CI）**:

                    CMake Error at samples/android/15-puzzle/CMakeLists.txt:3
                      (add_android_project)

                この 2 つは「ビルドするモジュール」ではなく「同梱するサンプル /
                プロジェクト」の話なので、BUILD_LIST では絞れない。
            #>
            '-DBUILD_ANDROID_EXAMPLES=OFF'
            '-DBUILD_ANDROID_PROJECTS=OFF'
            '-DANDROID_ABI=arm64-v8a'
            '-DANDROID_PLATFORM=android-25'
            # STL は静的に。共有だと libc++_shared.so を利用者のアプリに
            # 同梱してもらう必要があり、他の native plugin と衝突しうる。
            '-DANDROID_STL=c++_static'
            # 共有ライブラリへ静的ライブラリを取り込むため（linux と同じ）。
            '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
            <#
                **16 KB page size の flag はここに書かない。**

                最初はここに -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384
                を置いていたが、**ここは OpenCV 本体のビルドにしか渡らない** ——
                しかも OpenCV は BUILD_SHARED_LIBS=OFF なので共有ライブラリを
                1 つも作らず、**この flag は何にも当たらなかった**（レビューで発見）。

                実際に配る libopencv_unity_native.so を作るのは
                cmake/toolchains/android-arm64.cmake を使うビルドなので、
                **flag はそちらに置いてある。**
            #>
        )
        'ios-arm64' = @(
            '-DCMAKE_SYSTEM_NAME=iOS'
            '-DCMAKE_OSX_ARCHITECTURES=arm64'
            # 配布先の下限を固定する。Unity 6.3 の要求に合わせる。
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0'
            # 実機向け。シミュレータは別の sysroot なので同じ .a では動かない。
            '-DCMAKE_OSX_SYSROOT=iphoneos'
            # bitcode は Xcode 14 で廃止された。明示的に切らないと古い CMake が
            # 有効化しようとする。
            '-DCMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE=NO'
        )

        <#
            Web / Wasm。**この一覧は着手時の仮説であり、configure summary を
            読んでから確定させる**（計画の Task 2 Step 4）。想定外の依存が
            有効なら、名前を allowlist に足す前に一次情報でライセンスを確認し、
            THIRD_PARTY_NOTICES.md に全文を足すこと（M4 の cpufeatures と同じ形）。
        #>
        'web-wasm' = @(
            # wasm に共有ライブラリは無い。
            '-DBUILD_SHARED_LIBS=OFF'
            # **single-thread を先に成立させる**（roadmap の完了条件 3）。
            # threads profile は非ゴールで、別 profile として後続する。
            '-DWITH_PTHREADS_PF=OFF'
            # ブラウザから開けるカメラ・動画は videoio ではなく Unity 側の
            # 担当なので、ここでは要らない（既定でも切ってあるが明示する）。
            '-DWITH_FFMPEG=OFF'
            '-DWITH_GSTREAMER=OFF'
            # host 向けの実行ファイルを作らせない。クロスでは動かせない。
            '-DBUILD_opencv_apps=OFF'
            '-DBUILD_PERF_TESTS=OFF'
            '-DBUILD_TESTS=OFF'

            <#
                **SIMD を有効にする。これは選択ではなく、必要である。**

                OpenCV は wasm 向けに intrin_wasm.hpp（SIMD 実装）を使う。
                コンパイラ側で simd128 が有効でないと、そこが always_inline
                の要件を満たせず**ビルドが止まる**（2026-09-03 に実測）:

                    error: always_inline function 'wasm_f32x4_add' requires
                    target feature 'simd128', but would be inlined into
                    function ... that is compiled without support for 'simd128'
                    error: '__builtin_wasm_shuffle_i8x16' needs target feature simd128

                **つまり「SIMD 無しの wasm ビルド」は、この構成では成立しない**
                —— 成立させるなら CV_ENABLE_INTRINSICS=OFF にして別の構成を
                作ることになる。roadmap の完了条件 3 は
                「single-thread / SIMD を先に成立させる」なので、
                **SIMD 有りが出荷する構成である。**

                **この flag が効いていることの負の対照は強い** —— 外すと
                ビルドが通らない（上のエラー）。加えて出来た wasm に SIMD の
                命令が入っていることを tools/verify-wasm-features.ps1 が見る
                （計画の Task 5）。

                threads は非ゴールなので -mthreads は入れない。
            #>
            # **-fexceptions も要る。** Emscripten は既定で C++ 例外を無効に
            # するので、OpenCV が投げた例外を **こちらの OCVU_TRY_END が
            # 捕まえられない**（実測: 束ねた .a に __cxa_throw が 244 件、
            # __cxa_begin_catch が 0 件）。**両側に要る** —— 投げる側
            # （OpenCV）と捕まえる側（この plugin）のどちらが欠けても
            # バリアは成立しない。
            '-DCMAKE_C_FLAGS=-msimd128 -fexceptions'
            '-DCMAKE_CXX_FLAGS=-msimd128 -fexceptions'

            <#
                **x86 の baseline / dispatch を空にする。これも必要である。**

                `-msimd128` を付けると Emscripten の SSE 互換ヘッダ
                （compat/emmintrin.h 等）が使えるようになり、**OpenCV の CPU
                検査が「SSE が在る」と判断して x86 の経路を選ぶ。**
                ところが互換ヘッダは完全ではないので、そこで落ちる
                （2026-09-03 に実測）:

                    error: use of undeclared identifier '_mm_setr_epi64'
                    error: cannot initialize a parameter of type 'long long'
                    with an rvalue of type '__m128i' (aka 'v128_t')

                **欲しいのは wasm の SIMD（intrin_wasm.hpp）であって、
                SSE の翻訳ではない。** 空にすると OpenCV は x86 の経路を
                作らなくなり、wasm の実装が使われる。

                **測った組み合わせは 2 つだけである**（正直に書く）:

                  - `-msimd128` 無し・baseline 既定 → **落ちる**
                    （always_inline が simd128 を要求する）
                  - `-msimd128` 有り・baseline 既定 → **落ちる**
                    （SSE 互換ヘッダの経路に入る。上のエラー）

                **`-msimd128` 無し・baseline 空**は測っていない。
                intrin_wasm.hpp が simd128 を要求する以上そちらも落ちるはず
                だが、**「はず」であって実測ではない。**
            #>
            '-DCPU_BASELINE='
            '-DCPU_DISPATCH='

            <#
                **Web では PNG を外す。これは機能の縮小であり、記録する。**

                Unity の WebGL 支援は**自前の libpng を同梱している。**
                こちらが OpenCV の libpng を束ねると **Player のリンク段で
                シンボルが衝突する**（実測 2026-09-03: 9 シンボル 27 件。
                `wasm-ld: error: duplicate symbol: png_get_eXIf`）。

                **束ねないほうも成立しない** —— Unity 同梱は古い部分集合で、
                OpenCV の PNG コードが要求する 60 シンボルが未解決になる
                （`undefined symbol: png_destroy_read_struct` 等）。

                **どちらの極端も通らないので、Web では PNG を持たない。**
                `imgcodecs` は JPEG のみになる。**これは Web だけの制限で、
                他の 5 platform は PNG / JPEG の両方を持つ。**

                **利用者に見える制限なので、roadmap と README に書く。**
                zlib は他が使うので残す（衝突していない）。
            #>
            '-DWITH_PNG=OFF'
        )
    }

    CMakeArgs = @(
        # OpenCV のトップレベル CMakeLists.txt (行 81-84) は
        # `check_language(ASM)` で「たまたま PATH 上にある」アセンブラを
        # 探しに行き、見つかれば `enable_language(ASM)` する。GitHub Actions
        # の windows-2022 runner は C:\mingw64\bin を PATH に持ち、そこの
        # cc.exe が GNU アセンブラとして見つかってしまう。GNU 言語が 1 つでも
        # enable されると、CMake は静的ライブラリの prefix/suffix を
        # プロジェクト全体で GNU 規約（libX.a）に倒す — MSVC 規約（X.lib）を
        # 前提にした verify-opencv-artifact.ps1 の allowlist もリンクする
        # 側の consumer も壊れる。この構成（x86_64、dnn 不使用、
        # PNG/JPEG の ASM 最適化は ARM 限定）では ASM は本来どこにも
        # 要らないので、CMAKE_ASM_COMPILER を NOTFOUND に固定して
        # `check_language(ASM)` 自体を no-op にする（OpenCV 自身の
        # 3rdparty/mlas/CMakeLists.txt のコメントがこの no-op 挙動を
        # 前提にしている）。PATH に何が乗っているかで結果が変わる状態を
        # やめ、構成ファイル側で決着させる。
        #
        # このピンの効力範囲はアセンブラだけである。同じ「PATH に何が
        # 乗っているかで結果が変わる」問題は他の言語・ツールにも起こり得るが、
        # それぞれ別の場所で個別に決着させている: generator は上の Toolchain
        # ブロック（'Visual Studio 17 2022'、CMAKE_ASM_COMPILER のような
        # 動的検出を経由しない）、WITH_CUDA は下の「その他の optional 依存」
        # ブロックで明示的に OFF。ここに 1 か所へまとめて書かないのは、
        # 効力範囲を広げて読ませないためである。
        '-DCMAKE_ASM_COMPILER=NOTFOUND'

        # 配布は opencv_unity_native.dll 1 個で完結させる。
        # iOS（M4）は静的リンクが必須なので、最初からその形にしておく。
        '-DBUILD_SHARED_LIBS=OFF'

        # 実行時に必要な共通ライブラリは、プラグインに埋め込まず利用者側と
        # 共有する形にする。ライブラリを組み込む開発者が自分のビルドで
        # 何を同梱するかを選べる状態を保つのが目的で、こちらで抱え込まない。
        # MSVC の ASan もこの形を前提にしており、M0 の L2 レーンを維持できる。
        #
        # 次の 2 行はどちらも必要である。CMAKE_MSVC_RUNTIME_LIBRARY だけでは
        # 効かない: OpenCV の cmake/OpenCVCRTLinkage.cmake が
        # BUILD_SHARED_LIBS=OFF のとき BUILD_WITH_STATIC_CRT（MSVC 既定 ON）を
        # 見て、こちらの指定を上書きするためである。
        #
        # 実測（M1 Task 7）: BUILD_WITH_STATIC_CRT を指定しなかった
        # b671241615d9 の opencv_core500.lib を直接調べたところ、
        #   DEFAULTLIB:"LIBCMT"  114 件  <- 埋め込む形になっていた
        #   MSVCRT                 0 件  <- 共有する形ならこちらが出る
        # つまり下の MultiThreadedDLL は黙って無視されていた。
        #
        # 構成ハッシュはここに書いた指定を固定するが、ビルドがそれを
        # 守ったかまでは見ない。変更したら成果物側を必ず確認すること:
        #   grep -a -o 'DEFAULTLIB:"[A-Za-z0-9._]*"' <lib> | sort | uniq -c
        '-DBUILD_WITH_STATIC_CRT=OFF'
        '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'

        # --- videoio 系を完全に排除する ---
        # WITH_FFMPEG は Windows で既定 ON で、configure 時に prebuilt の
        # FFmpeg プラグインを取得しに行くことがある（計画書 §8.2）。
        '-DWITH_FFMPEG=OFF'
        '-DWITH_GSTREAMER=OFF'
        '-DWITH_MSMF=OFF'
        '-DWITH_DSHOW=OFF'
        '-DWITH_V4L=OFF'

        # --- imgcodecs が引き込む codec を PNG / JPEG だけに絞る ---
        # 少ないほど third-party notice の管理量が減る。
        # bundled（BUILD_*=ON）にするのは、システムのライブラリ版に
        # 依存しないほうが再現性が高いため。
        '-DBUILD_ZLIB=ON'
        '-DBUILD_PNG=ON'
        '-DBUILD_JPEG=ON'
        '-DWITH_TIFF=OFF'
        '-DWITH_WEBP=OFF'
        '-DWITH_OPENEXR=OFF'
        '-DWITH_OPENJPEG=OFF'
        '-DWITH_JASPER=OFF'
        '-DWITH_IMGCODEC_HDR=OFF'
        '-DWITH_IMGCODEC_SUNRASTER=OFF'
        '-DWITH_IMGCODEC_PXM=OFF'
        '-DWITH_IMGCODEC_PFM=OFF'

        # --- その他の optional 依存 ---
        # IPP は Intel のバイナリ配布物で独自のライセンス条項を持つ。
        # 性能のための再検討は M7 の担当。
        '-DWITH_IPP=OFF'
        # ITT (Intel VTune 計装) は既定で ON になる。ittnotify は
        # BSD-3-Clause / GPL-2.0-only のデュアルライセンスで配布され、
        # BSD 側を選ぶこと自体は問題ないが、この project に何ら価値を
        # 与えないものを「気づかず有効」のままにしない（計画書 §8.2）。
        '-DWITH_ITT=OFF'
        '-DBUILD_ITT=OFF'
        '-DWITH_PROTOBUF=OFF'
        '-DWITH_EIGEN=OFF'
        '-DWITH_OPENCL=OFF'
        '-DWITH_CUDA=OFF'
        '-DWITH_QUIRC=OFF'
        '-DWITH_ADE=OFF'
        '-DWITH_VTK=OFF'
        '-DWITH_GTK=OFF'
        '-DWITH_WIN32UI=OFF'

        # --- ビルドしないもの ---
        '-DBUILD_TESTS=OFF'
        '-DBUILD_PERF_TESTS=OFF'
        '-DBUILD_EXAMPLES=OFF'
        '-DBUILD_DOCS=OFF'
        '-DBUILD_opencv_apps=OFF'
        '-DBUILD_JAVA=OFF'
        '-DBUILD_opencv_python3=OFF'
        '-DBUILD_opencv_python_bindings_generator=OFF'
        '-DBUILD_opencv_js=OFF'
        '-DOPENCV_GENERATE_SETUPVARS=OFF'
        '-DOPENCV_GENERATE_PKGCONFIG=OFF'
    )
}
