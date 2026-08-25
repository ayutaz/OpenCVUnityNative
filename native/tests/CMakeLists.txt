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
    test_exception_barrier.cpp
)

# SHARED ではなく STATIC 側にリンクする（native/CMakeLists.txt の注記を参照）
target_link_libraries(ocvu_tests PRIVATE ocvu_static GTest::gtest)

add_test(NAME ocvu_tests COMMAND ocvu_tests)
set_tests_properties(ocvu_tests PROPERTIES TIMEOUT 120)

add_executable(ocvu_probe
    ocvu_probe.cpp
    ocvu_test_platform.cpp
)

# name: テスト名 / mode: プローブのモード
# inner_timeout_s: プローブ自体に許す秒数
# expect_regex: 出力に期待する正規表現 (不要なら "")
function(ocvu_add_expect_failure_test name mode inner_timeout_s expect_regex)
    add_test(NAME ${name}
        COMMAND ${CMAKE_COMMAND}
            -DOCVU_COMMAND=$<TARGET_FILE:ocvu_probe>
            -DOCVU_MODE=${mode}
            -DOCVU_TIMEOUT=${inner_timeout_s}
            -DOCVU_EXPECT_REGEX=${expect_regex}
            -P ${CMAKE_SOURCE_DIR}/cmake/run_expect_failure.cmake
    )
    math(EXPR outer_timeout "${inner_timeout_s} + 60")
    set_tests_properties(${name} PROPERTIES TIMEOUT ${outer_timeout})
endfunction()

# 正常系: プローブ自体が動くことの確認
add_test(NAME harness.probe_ok COMMAND ocvu_probe ok)
set_tests_properties(harness.probe_ok PROPERTIES TIMEOUT 30)

# ネイティブクラッシュが赤になり、ダイアログでハングしないこと
ocvu_add_expect_failure_test(harness.segfault_is_detected segfault 30 "")

# 無限ループが有限時間で赤になること
ocvu_add_expect_failure_test(harness.hang_is_detected hang 5 "")
