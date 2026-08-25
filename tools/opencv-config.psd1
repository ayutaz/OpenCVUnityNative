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
    Modules = @('core', 'imgproc', 'imgcodecs', 'objdetect', 'features')

    Toolchain = @{
        Generator    = 'Visual Studio 17 2022'
        Architecture = 'x64'
        BuildType    = 'Release'
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
