@{
    # Unity の minor 系列 -> その Unity が同梱する Emscripten（M6）。
    #
    # **これは写しである。** Unity が何を同梱するかはこちらが決められないので、
    # ここの値は必ず「誰かが読んで書き写したもの」になる。
    #
    # **だから写しだけを持たない。** `tools/assert-emscripten-version.ps1` が
    # Unity の導入先から emscripten-version.txt を読み、この表と突き合わせる
    # （`dev.ps1 test-unity-web` が必ず走らせる —— WebGL の Player を
    # 建てられる時点で Unity と WebGL 支援は必ず在るので、
    # **「道具が無いから飛ばす」経路が構造的に生まれない**）。
    # 表の自己整合（Unity の版に対応する項が在るか、workflow の pin と一致するか）は
    # `tools/tests/EmscriptenVersion.Tests.ps1` が速いレーンで見る。
    #
    # **なぜ版を合わせる必要があるか**: LLVM はバージョン間のバイナリ互換を
    # 保証しない。CI は Unity を持たないので emsdk から Emscripten を入れるが、
    # そこで入れた版が Unity の同梱と食い違うと、**CI で通った wasm が Unity の
    # ビルドで壊れる。**
    #
    # **なぜ minor 系列で持つか**: patch まで持つと Unity を 1 つ上げるたびに
    # この表を触ることになる。Emscripten が変わるのは minor 系列の境目である。
    #
    # 値は実測（2026-09-03、Unity 6000.3.16f1、Windows）:
    #   <Unity>/Editor/Data/PlaybackEngines/WebGLSupport/BuildTools/Emscripten/
    #     emscripten/emscripten-version.txt      -> 3.1.39-git
    #     emscripten/emscripten-git-commit.txt   -> commit a2ee372...（2023-05-15）
    '6000.3' = @{
        # emscripten-version.txt は '3.1.39-git' と書く。'-git' を落とした値を持つ
        # —— emsdk が受け取るのは '3.1.39' の形だからである。
        Emscripten = '3.1.39'

        # **同梱版は tag ではなく git の途中である**（'-git' の意味）。したがって
        # emsdk の '3.1.39' と完全に同じ木とは限らない。**その差はここでは見ない**
        # —— 束ねた archive が `cv::` を定義しているか（Task 3）と、実物の
        # Web Player が動くか（Task 6）で受ける。ここが見るのは版の食い違いだけ。
        Commit     = 'a2ee372fd4bf28c71c2bd8ab1bd74af016ff1bf9'
    }
}
