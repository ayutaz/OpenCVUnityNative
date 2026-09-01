# tools/opencv.ps1 が展開した OpenCV を取り込む。
#
# find_package(OpenCV) をそのまま呼ばないのは、システムに入っている
# 別バージョンを拾ってしまうと「再現可能なビルド」が崩れるため。
# 構成ハッシュで決まる 1 つのツリーだけを見る。

if(NOT DEFINED OCVU_OPENCV_ROOT OR OCVU_OPENCV_ROOT STREQUAL "")
    message(FATAL_ERROR
        "OCVU_OPENCV_ROOT が指定されていません。"
        "tools/dev.ps1 経由で呼ぶか、'./tools/opencv.ps1 restore' を先に実行してください。")
endif()

if(NOT EXISTS "${OCVU_OPENCV_ROOT}/build-manifest.json")
    message(FATAL_ERROR
        "OpenCV が '${OCVU_OPENCV_ROOT}' にありません。"
        "'./tools/opencv.ps1 restore' を実行してください（失敗する場合はメッセージに従うこと）。")
endif()

# OpenCVConfig.cmake (Windows pack 形式) は OpenCV_STATIC が未定義だと
# BUILD_SHARED_LIBS の有無だけで判定し、無指定なら OFF に倒す。OFF のままだと
# staticlib/ ディレクトリを候補から外して探すため、tools/opencv.ps1 が作る
# 静的ビルド（third_party/opencv/<hash>/x64/vc17/staticlib）が見つからず、
# 「compatible ではない」という誤検出で FAIL する。ここで明示的に ON にする。
#
# ランタイムライブラリを /MT から /MD に変えた 6ba270f342e3 でも再発することを
# 確認済み（M1 Task 8: この行を一時的にコメントアウトして configure すると、
# vc14/vc15/vc16 のディレクトリ探索に落ちて "no binaries compatible with your
# configuration" で FAIL した）。この判定は CRT linkage とは独立（Windows
# pack のレイアウト探索ロジックの話であって /MD か /MT かではない）なので、
# CRT を直しても不要にはならない。
set(OpenCV_STATIC ON)

# **クロスコンパイルでは、探索が sysroot の中に閉じ込められる。**
#
# Android の NDK toolchain と CMake の iOS platform module はどちらも
# CMAKE_FIND_ROOT_PATH を sysroot に設定し、find_package の探索モードを
# ONLY にする。これは「host に入っているライブラリを誤って掴まない」ための
# 正しい既定だが、**こちらの OpenCV は sysroot の外**（third_party/opencv/<hash>）
# にあるので、PATHS で明示しても見えない。
#
# CI 実測（M4、iOS）: lib/cmake/opencv5/OpenCVConfig.cmake が確かに在るのに
#
#   Could not find a package configuration file provided by "OpenCV"
#
# で configure が落ちた。**成果物は正しく、探し方だけが間違っていた。**
#
# 探索の根に自分の木を足し、package の探索だけ BOTH に緩める。
# **library / include のモードは触らない** —— そちらまで緩めると、
# host の .a やヘッダを拾う経路が開く。
# **グローバルに緩めない。** 以前は CMAKE_FIND_ROOT_PATH_MODE_PACKAGE を
# BOTH にしていたが、これは include() 先のスコープ以降ずっと効く ——
# OpenCVConfig.cmake が内部で find_dependency() を呼ぶと host を掴む経路が
# 開く（COMPONENTS を増やしたときに顕在化する）。M4 のレビューで指摘。
# 代わりに、この find_package の呼び出しにだけ NO_CMAKE_FIND_ROOT_PATH を
# 付ける（下記）。探索の根に自分の木を足すのは引き続き必要。
if(CMAKE_CROSSCOMPILING)
    list(APPEND CMAKE_FIND_ROOT_PATH "${OCVU_OPENCV_ROOT}")
    message(STATUS "cross-compiling: added ${OCVU_OPENCV_ROOT} to CMAKE_FIND_ROOT_PATH")
endif()

# **Android は install の木ごと sdk/ の下に作り直す。**
#
# 実測（M4 の CI artifact）:
#   Windows / macOS / Linux / iOS   <root>/lib/cmake/opencv5/OpenCVConfig.cmake
#   Android                         <root>/sdk/native/jni/OpenCVConfig.cmake
#
# **候補を列挙する形にする。** 「どこかに OpenCVConfig.cmake があれば通す」に
# すると、意図しない木を掴んでも気づけない。
set(OCVU_OPENCV_CONFIG_CANDIDATES
    "${OCVU_OPENCV_ROOT}"
    "${OCVU_OPENCV_ROOT}/sdk/native/jni")

set(OpenCV_DIR "${OCVU_OPENCV_ROOT}" CACHE PATH "" FORCE)
foreach(_candidate IN LISTS OCVU_OPENCV_CONFIG_CANDIDATES)
    if(EXISTS "${_candidate}/OpenCVConfig.cmake")
        set(OpenCV_DIR "${_candidate}" CACHE PATH "" FORCE)
        break()
    endif()
endforeach()

# NO_CMAKE_FIND_ROOT_PATH: この呼び出しに限って sysroot への読み替えを外す。
# PATHS は既に絶対パスで、NO_DEFAULT_PATH が他の経路を閉じている。
find_package(OpenCV ${OCVU_OPENCV_REQUIRED_VERSION} EXACT REQUIRED
    COMPONENTS core imgproc imgcodecs objdetect features
    NO_DEFAULT_PATH
    NO_CMAKE_FIND_ROOT_PATH
    PATHS ${OCVU_OPENCV_CONFIG_CANDIDATES})

message(STATUS "OpenCV ${OpenCV_VERSION} from ${OCVU_OPENCV_ROOT}")
