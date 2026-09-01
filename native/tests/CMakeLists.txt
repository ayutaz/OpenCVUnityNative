include(FetchContent)

FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.15.2
    GIT_SHALLOW    TRUE
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

add_executable(ocvu_tests
    test_main.cpp
    ocvu_test_platform.cpp
    test_version.cpp
    test_error.cpp
    test_status.cpp
    test_exception_barrier.cpp
    test_opencv_link.cpp
    test_mat_lifecycle.cpp
    test_mat_buffer.cpp
    test_imgproc.cpp
    test_imgcodecs.cpp
    test_geometry.cpp
    test_mat_table_stability.cpp
    test_module_linkage.cpp
    test_objdetect.cpp
    test_features.cpp
    test_calibration.cpp
)

# SHARED ではなく STATIC 側にリンクする（native/CMakeLists.txt の注記を参照）
target_link_libraries(ocvu_tests PRIVATE ocvu_static GTest::gtest)

# MSVC の ASan ランタイム DLL は cl.exe と同じディレクトリにある。
# 開発者コマンドプロンプト外でも見つかるよう、テストの PATH に足す。
set(OCVU_TEST_ENV_MODIFICATION "")
if(OCVU_ENABLE_ASAN AND MSVC)
    get_filename_component(OCVU_MSVC_BIN_DIR "${CMAKE_CXX_COMPILER}" DIRECTORY)
    set(OCVU_TEST_ENV_MODIFICATION
        "PATH=path_list_prepend:${OCVU_MSVC_BIN_DIR}")
endif()

add_test(NAME ocvu_tests COMMAND ocvu_tests)
# このレーンの実測は 0.1 秒未満。ハングしたときのローカルループの損失を
# 抑えるため、実測の ~400 倍の余裕を残しつつ 30 秒で打ち切る。
set_tests_properties(ocvu_tests PROPERTIES
    TIMEOUT 30
    ENVIRONMENT_MODIFICATION "${OCVU_TEST_ENV_MODIFICATION}")

add_executable(ocvu_probe
    ocvu_probe.cpp
    ocvu_test_platform.cpp
)

# name: テスト名 / mode: プローブのモード
# inner_timeout_s: プローブ自体に許す秒数
# expect_regex: 出力に期待する正規表現。必須で、空文字列は許されない。
#   「非 0 で終わった」だけを条件にすると、プローブが目的の挙動に到達しないまま
#   落ちてもテストが緑になり、このレーンが証明するはずの性質が黙って消える。
#   プローブは各挙動の直前に stderr へマーカーを出すので、それを指定する。
function(ocvu_add_expect_failure_test name mode inner_timeout_s expect_regex)
    if(expect_regex STREQUAL "")
        message(FATAL_ERROR
            "ocvu_add_expect_failure_test(${name}): expect_regex must not be empty")
    endif()
    add_test(NAME ${name}
        COMMAND ${CMAKE_COMMAND}
            -DOCVU_COMMAND=$<TARGET_FILE:ocvu_probe>
            -DOCVU_MODE=${mode}
            -DOCVU_TIMEOUT=${inner_timeout_s}
            -DOCVU_EXPECT_REGEX=${expect_regex}
            -P ${CMAKE_SOURCE_DIR}/cmake/run_expect_failure.cmake
    )
    math(EXPR outer_timeout "${inner_timeout_s} + 60")
    set_tests_properties(${name} PROPERTIES
        TIMEOUT ${outer_timeout}
        ENVIRONMENT_MODIFICATION "${OCVU_TEST_ENV_MODIFICATION}")
endfunction()

# 正常系: プローブ自体が動くことの確認
add_test(NAME harness.probe_ok COMMAND ocvu_probe ok)
set_tests_properties(harness.probe_ok PROPERTIES
    TIMEOUT 30
    ENVIRONMENT_MODIFICATION "${OCVU_TEST_ENV_MODIFICATION}")

# ネイティブクラッシュが赤になり、ダイアログでハングしないこと。
# regex はプローブが実際に null 参照の直前まで到達したことの裏取り。
ocvu_add_expect_failure_test(harness.segfault_is_detected segfault 30
    "probe: dereferencing null")

# 無限ループが有限時間で赤になること。
# regex はプローブが実際に無限ループへ入ったことの裏取り。
ocvu_add_expect_failure_test(harness.hang_is_detected hang 5
    "probe: sleeping forever")

if(OCVU_ENABLE_ASAN)
    # ASan ビルドでのみ意味を持つ。通常ビルドでは UAF が検出されず、
    # プローブが 0 で終了してしまうため登録しない。
    ocvu_add_expect_failure_test(harness.use_after_free_is_detected
        use-after-free 60 "heap-use-after-free")

    # リーク検出。**Windows では登録しない。**
    #
    # MSVC の ASan は LeakSanitizer を含まないので、リークしても probe は 0 で
    # 終了し、expect-failure テストが「落ちなかった」で赤くなる。リーク検出は
    # M3 の Linux レーンが担うと roadmap で決めてある。
    #
    # regex は「リークが報告されたこと」まで見る。単に非 0 で終わっただけでは、
    # 別の理由で落ちたのか区別できない（cmake/run_expect_failure.cmake が
    # L1/L2 の他のプローブに課しているのと同じ規律）。
    if(NOT MSVC)
        ocvu_add_expect_failure_test(harness.leak_is_detected
            leak 60 "detected memory leaks")
    endif()
endif()
