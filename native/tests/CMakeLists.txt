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
    test_version.cpp
    test_error.cpp
)

# SHARED ではなく STATIC 側にリンクする（native/CMakeLists.txt の注記を参照）
target_link_libraries(ocvu_tests PRIVATE ocvu_static GTest::gtest)

add_test(NAME ocvu_tests COMMAND ocvu_tests)
set_tests_properties(ocvu_tests PROPERTIES TIMEOUT 120)
