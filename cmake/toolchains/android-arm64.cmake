# Android arm64-v8a の toolchain 変数を 1 箇所に集める。
#
# **NDK の toolchain file を include するだけにしない。** ANDROID_ABI などの
# 変数は NDK 側の toolchain を読み込む「前」に決まっていなければならないので、
# ここで設定してから include する。
#
# NDK の場所は環境変数から探す。GitHub Actions の ubuntu runner は
# ANDROID_NDK_ROOT を設定する。
if(NOT DEFINED ANDROID_NDK)
  if(DEFINED ENV{ANDROID_NDK_ROOT})
    set(ANDROID_NDK "$ENV{ANDROID_NDK_ROOT}")
  elseif(DEFINED ENV{ANDROID_NDK_HOME})
    set(ANDROID_NDK "$ENV{ANDROID_NDK_HOME}")
  else()
    # **探せなかったことを既定で埋めない。** 見つからないまま host 向けに
    # ビルドすると、成功したように見えて中身が別物になる。
    message(FATAL_ERROR
      "Android NDK not found. Set ANDROID_NDK_ROOT or ANDROID_NDK_HOME.")
  endif()
endif()

set(ANDROID_ABI "arm64-v8a" CACHE STRING "")

# Unity 6.3 が Android の minSdk を 23 -> 25 に上げた。それより低い API を
# 対象にしても Unity 側が受け取らない。tools/opencv-config.psd1 の
# Toolchains['android-arm64'].AndroidPlatform と同じ値であること。
set(ANDROID_PLATFORM "android-25" CACHE STRING "")

# STL は共有ではなく静的に。共有だと libc++_shared.so を利用者のアプリに
# 同梱してもらう必要があり、他の native plugin と衝突しうる。
set(ANDROID_STL "c++_static" CACHE STRING "")

if(NOT EXISTS "${ANDROID_NDK}/build/cmake/android.toolchain.cmake")
  message(FATAL_ERROR
    "ANDROID_NDK does not look like an NDK: ${ANDROID_NDK}")
endif()

include("${ANDROID_NDK}/build/cmake/android.toolchain.cmake")
