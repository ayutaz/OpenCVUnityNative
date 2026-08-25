cmake_minimum_required(VERSION 3.25)
project(opencv_unity_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# CRT linkage を OpenCV の静的ライブラリと一致させる。
#
# tools/opencv-config.psd1 は CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
# （/MD）を渡しているが、OpenCV は BUILD_SHARED_LIBS=OFF のとき
# BUILD_WITH_STATIC_CRT（既定 ON、MSVC）を優先し、cmake/OpenCVCRTLinkage.cmake
# が CMAKE_MSVC_RUNTIME_LIBRARY を "MultiThreaded"（/MT、非デバッグ）へ
# 上書きする。つまり third_party/opencv/<hash> に実在するバイナリは /MT で
# あり、意図（/MD）とは異なる。ここを既定（Debug 構成では /MDd）のままにすると
# 自前コードと OpenCV の間で CRT が不一致になり、実際にリンクエラーになる
# （実測: LNK2038 'RuntimeLibrary' の不一致、LNK2005 の多重定義）。
# ここでは意図ではなく実在するバイナリに合わせ、Debug/Release を問わず /MT に
# 固定する（OpenCV の成果物が Release の /MT しか提供しないため）。
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

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
        # 不一致になる（実測）。OpenCV を作り直せない以上、自前側もこの注釈を
        # 無効化して揃える他ない。ASan 自体（ヒープの use-after-free や
        # out-of-bounds 検出）はこれとは独立で、無効化後も機能する。
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
