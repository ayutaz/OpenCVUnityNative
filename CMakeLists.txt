cmake_minimum_required(VERSION 3.25)
project(opencv_unity_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(OCVU_BUILD_TESTS "Build native tests" ON)
option(OCVU_ENABLE_ASAN "Build with AddressSanitizer" OFF)

if(OCVU_ENABLE_ASAN)
    if(MSVC)
        # MSVC の ASan は /RTC1 と /INCREMENTAL と併用できない
        string(REGEX REPLACE "/RTC[su1]+" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
        add_compile_options(/fsanitize=address /Zi)
        add_link_options(/INCREMENTAL:NO /DEBUG)
    else()
        add_compile_options(-fsanitize=address -fno-omit-frame-pointer -g)
        add_link_options(-fsanitize=address)
    endif()
endif()

if(MSVC)
    add_compile_options(/utf-8)
endif()

add_subdirectory(native)

if(OCVU_BUILD_TESTS)
    enable_testing()
    add_subdirectory(native/tests)
endif()
