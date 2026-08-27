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
)

add_library(opencv_unity_native SHARED ${OCVU_SOURCES})
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
endif()
