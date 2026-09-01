# 実装ソースは 2 つのターゲットにコンパイルする。
#   opencv_unity_native (SHARED) — 配布物。公開 ABI だけをエクスポートする
#   ocvu_static         (STATIC) — L1 テスト用
#
# テストを SHARED にリンクすると、DLL がエクスポートしていない内部シンボル
# (ocvu::set_last_error など) に到達できず link エラーになる。
# よってテストは STATIC 側へリンクする。
set(OCVU_SOURCES
    src/ocvu_version.cpp
    src/ocvu_error.cpp
    src/ocvu_status.cpp
    src/ocvu_debug.cpp
    src/ocvu_opencv_info.cpp
    src/ocvu_mat_table.cpp
    src/ocvu_mat.cpp
    src/ocvu_mat_buffer.cpp
    src/ocvu_imgproc.cpp
    src/ocvu_imgcodecs.cpp
    src/ocvu_objdetect.cpp
    src/ocvu_features.cpp
    src/ocvu_geometry.cpp
)

# **iOS だけ静的ライブラリにする。**
#
# iOS はアプリの外から .dylib を読み込めない。Unity は .a を受け取って
# IL2CPP のバイナリへ静的リンクし、P/Invoke は DllImport("__Internal") で
# 解決する。**SHARED のままでもビルドは成功する**ので、Unity に入れて
# 初めて壊れる —— v0.1.0 の「ビルドできた ≠ 動く」と同じ形である。
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set(OCVU_LIBRARY_KIND STATIC)
else()
  set(OCVU_LIBRARY_KIND SHARED)
endif()

add_library(opencv_unity_native ${OCVU_LIBRARY_KIND} ${OCVU_SOURCES})
target_include_directories(opencv_unity_native
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_compile_definitions(opencv_unity_native PRIVATE OCVU_BUILDING_DLL)
set_target_properties(opencv_unity_native PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    OUTPUT_NAME opencv_unity_native
)

add_library(ocvu_static STATIC ${OCVU_SOURCES})
target_include_directories(ocvu_static
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
           $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
)
# PUBLIC にすることで、リンクするテスト側のヘッダ展開でも
# __declspec(dllimport) が付かなくなる。
target_compile_definitions(ocvu_static PUBLIC OCVU_STATIC)

if(OCVU_WITH_OPENCV)
    target_link_libraries(opencv_unity_native PRIVATE ${OpenCV_LIBS})
    target_link_libraries(ocvu_static PUBLIC ${OpenCV_LIBS})

    # **静的ライブラリを配るときは、依存アーカイブを自分で束ねる。**
    #
    # CMake は STATIC ライブラリに依存アーカイブを取り込まない —— 記録するのは
    # usage requirement だけである。したがって出来る libopencv_unity_native.a は
    # 自分の object しか含まず、`cv::cvtColor` などは**未解決のまま**になる。
    # Unity がそれを Xcode プロジェクトへ足してリンクした時点で失敗する。
    #
    # **ビルドは成功する。** 壊れるのは実機に載せる段で、それは
    # 「ビルドできた ≠ 動く」の最も遠い形である（レビューで発見）。
    #
    # libtool -static は macOS の標準ツールで、複数のアーカイブを 1 つに
    # 束ねられる。iOS のビルドは必ず macOS 上で走るので、存在は保証される。
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        find_program(OCVU_LIBTOOL libtool REQUIRED)

        # OpenCV の静的ライブラリ（third-party 込み）を集める。
        # ${OpenCV_LIBS} は target 名なので、実ファイルへ解決する。
        set(OCVU_BUNDLE_INPUTS "")
        foreach(_lib IN LISTS OpenCV_LIBS)
            list(APPEND OCVU_BUNDLE_INPUTS "$<TARGET_FILE:${_lib}>")
        endforeach()

        # OpenCV が bundle する third-party（libpng / libjpeg-turbo / zlib /
        # kleidicv 等）は OpenCV_LIBS の target には現れないので、インストール木
        # から直接拾う。**実測した配置**（M4 の CI artifact、iOS）:
        #
        #   <root>/lib/opencv5/3rdparty/*.a   ← 実際にここ
        #   <root>/lib/*.a                     ← opencv_* 本体
        #
        # 版番号つきのディレクトリ名（opencv5）を決め打ちにせず、glob で拾う。
        file(GLOB OCVU_OPENCV_3RDPARTY
             "${OCVU_OPENCV_ROOT}/lib/opencv*/3rdparty/*.a"
             "${OCVU_OPENCV_ROOT}/lib/3rdparty/*.a"
             "${OCVU_OPENCV_ROOT}/share/OpenCV/3rdparty/lib/*.a")
        list(APPEND OCVU_BUNDLE_INPUTS ${OCVU_OPENCV_3RDPARTY})

        # **1 つも集まらなかったら止める。** 空のまま束ねると、
        # 「libtool は成功したのに中身は自分の object だけ」になり、
        # **この手当てが在ることが逆に安心材料になってしまう。**
        list(LENGTH OCVU_OPENCV_3RDPARTY _ocvu_3p_count)
        if(_ocvu_3p_count EQUAL 0)
            message(FATAL_ERROR
                "iOS: OpenCV の静的ライブラリが 1 つも見つかりません "
                "(OCVU_OPENCV_ROOT=${OCVU_OPENCV_ROOT})。"
                "束ねる相手が無いまま .a を配ると、リンク時に未解決シンボルになります。")
        endif()

        set(OCVU_BUNDLED "${CMAKE_CURRENT_BINARY_DIR}/bundled/libopencv_unity_native.a")
        add_custom_command(
            TARGET opencv_unity_native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/bundled"
            COMMAND ${OCVU_LIBTOOL} -static -o "${OCVU_BUNDLED}"
                    "$<TARGET_FILE:opencv_unity_native>" ${OCVU_BUNDLE_INPUTS}
            # 束ねた物で置き換える。**別名で残すと、配る側がどちらを拾うか
            # 決めなければならない** —— 決め損なうと未解決シンボルのほうが配られる。
            COMMAND ${CMAKE_COMMAND} -E copy "${OCVU_BUNDLED}" "$<TARGET_FILE:opencv_unity_native>"
            COMMENT "iOS: bundling OpenCV into libopencv_unity_native.a"
            VERBATIM
        )
    endif()
endif()
