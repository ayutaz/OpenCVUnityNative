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
        # 配布は opencv_unity_native.dll 1 個で完結させる。
        # iOS（M4）は静的リンクが必須なので、最初からその形にしておく。
        '-DBUILD_SHARED_LIBS=OFF'

        # Unity のネイティブプラグインは動的 CRT が標準。
        # MSVC の ASan もこちらを前提にしており、M0 の L2 レーンを維持できる。
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
