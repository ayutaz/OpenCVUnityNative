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

set(OpenCV_DIR "${OCVU_OPENCV_ROOT}" CACHE PATH "" FORCE)
find_package(OpenCV ${OCVU_OPENCV_REQUIRED_VERSION} EXACT REQUIRED
    COMPONENTS core imgproc
    NO_DEFAULT_PATH
    PATHS "${OCVU_OPENCV_ROOT}")

message(STATUS "OpenCV ${OpenCV_VERSION} from ${OCVU_OPENCV_ROOT}")
