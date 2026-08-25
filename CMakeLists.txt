cmake_minimum_required(VERSION 3.25)
project(opencv_unity_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# CRT linkage を OpenCV の静的ライブラリと一致させる。
#
# ランタイムライブラリは共有形（/MD、DLL 版 CRT）にする。これは意図の選択
# であって既定への迎合ではない: このパッケージを組み込む開発者が、自分の
# ゲームに何を同梱するかを自分で決められる状態を保つのが目的で、パッケージ
# 側が embedded 形（/MT）を強制して選択肢を奪わない。
#
# tools/opencv-config.psd1 は CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL を
# 渡しているが、OpenCV は BUILD_SHARED_LIBS=OFF のとき既定で
# BUILD_WITH_STATIC_CRT（MSVC 既定 ON）を優先し、cmake/OpenCVCRTLinkage.cmake
# がこちらの指定を "MultiThreaded"（/MT）へ黙って上書きしていた（M1 Task 7
# で発見。旧ハッシュ b671241615d9 の opencv_core500.lib は DEFAULTLIB
# "LIBCMT" のみで "MSVCRT" が 0 件だった）。対策として opencv-config.psd1 に
# -DBUILD_WITH_STATIC_CRT=OFF を追加し、構成ハッシュを 6ba270f342e3 に
# 動かして再ビルドした。新しい成果物を同じ方法で調べ直し、要求どおり
# MSVCRT を参照し LIBCMT を参照しないことを確認済み（M1 Task 8）。
# 確認コマンド:
#   grep -a -o 'DEFAULTLIB:"[A-Za-z0-9._]*"' \
#     third_party/opencv/6ba270f342e3/x64/vc17/staticlib/opencv_core500.lib \
#     | sort | uniq -c
# これで下の指定は「たまたま存在するバイナリに合わせた妥協」ではなく、
# 「要求どおりに効く指定」になっている。
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

option(OCVU_BUILD_TESTS "Build native tests" ON)
option(OCVU_ENABLE_ASAN "Build with AddressSanitizer" OFF)

if(OCVU_ENABLE_ASAN)
    if(MSVC)
        # MSVC の ASan は /RTC1 と /INCREMENTAL と併用できない
        string(REGEX REPLACE "/RTC[su1]+" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
        add_compile_options(/fsanitize=address /Zi)
        add_link_options(/INCREMENTAL:NO /DEBUG)

        # MSVC の ASan は std::string / std::vector に container-overflow 検出用の
        # 注釈（annotate_string / annotate_vector）を STL ヘッダへ埋め込む。この
        # 注釈の有無はオブジェクトの ABI の一部として linker に記録され、
        # 有無が食い違うオブジェクト同士をリンクすると LNK2038 で拒否される。
        # third_party/opencv/<hash> は ASan なしでビルドされた成果物なので
        # 注釈が無く（0）、自前コードだけ ASan 有りだと注釈が付く（1）ため
        # 不一致になる。OpenCV を作り直せない以上、自前側もこの注釈を無効化
        # して揃える他ない。ASan 自体（ヒープの use-after-free や
        # out-of-bounds 検出）はこれとは独立で、無効化後も機能する。
        #
        # ランタイムライブラリを /MT から /MD に変えた 6ba270f342e3 でも
        # 再発することを確認済み（M1 Task 8: この定義を一時的に外して
        # `./tools/dev.ps1 test-asan` を実行すると、上と同じ 'annotate_string'
        # / 'annotate_vector' の LNK2038 で失敗した）。原因は CRT linkage の
        # /MD・/MT ではなく ASan 計装の有無の食い違いなので、CRT を直しても
        # 消えない。
        add_compile_definitions(_DISABLE_STRING_ANNOTATION _DISABLE_VECTOR_ANNOTATION)
    else()
        add_compile_options(-fsanitize=address -fno-omit-frame-pointer -g)
        add_link_options(-fsanitize=address)
    endif()
endif()

if(MSVC)
    add_compile_options(/utf-8)
endif()

option(OCVU_WITH_OPENCV "Link against the pinned OpenCV build" ON)
set(OCVU_OPENCV_ROOT "" CACHE PATH "Root of the restored OpenCV tree")
set(OCVU_OPENCV_REQUIRED_VERSION "5.0.0" CACHE STRING "")

if(OCVU_WITH_OPENCV)
    include(${CMAKE_SOURCE_DIR}/cmake/FindOpenCvUnityDeps.cmake)
endif()

add_subdirectory(native)

if(OCVU_BUILD_TESTS)
    enable_testing()
    add_subdirectory(native/tests)
endif()
