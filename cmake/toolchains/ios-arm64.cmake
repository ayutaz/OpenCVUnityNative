# iOS arm64（実機）の toolchain。
#
# **シミュレータ向けではない。** シミュレータは arm64 でも別の sysroot
# （iphonesimulator）を使うので、同じ .a では動かない。シミュレータを足すときは
# この file を複製せず CMAKE_OSX_SYSROOT を変数にすること。
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")

# Unity 6.3 が iOS の target を 13.0 -> 15.0 に上げた。
# tools/opencv-config.psd1 の Toolchains['ios-arm64'].IosDeploymentTarget と
# 同じ値であること。
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "")
set(CMAKE_OSX_SYSROOT "iphoneos" CACHE STRING "")

# bitcode は Xcode 14 で廃止された。明示的に切らないと古い CMake が
# 有効化しようとする。
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO CACHE STRING "")

# **クロスコンパイルなので try_run は実行できない。** 既定のままだと
# CMake が「実行して確かめる」検査で止まる。静的ライブラリだけを作らせる。
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
