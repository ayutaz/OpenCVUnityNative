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

# **16 KB page size。ここで設定する。**
#
# 最初は tools/opencv-config.psd1 の PlatformCMakeArgs に書いていたが、
# **あれは OpenCV 本体のビルドにしか渡らない** —— しかも OpenCV は
# BUILD_SHARED_LIBS=OFF なので共有ライブラリを 1 つも作らず、
# CMAKE_SHARED_LINKER_FLAGS は何にも当たらなかった（レビューで発見）。
#
# 実際に配る libopencv_unity_native.so を作るのはこの toolchain を使う
# ビルドなので、**掛けるべき場所はここである。**
#
# Android 15 (API 35) 以降を対象とするアプリは Google Play 上で 16 KB に
# 対応していなければならず、2027-02-01 から未対応の更新は公開できなくなる。
# **止まるのは利用者のリリースである** —— この .so が利用者のアプリに入るため。
#
# NDK r28 以降は既定で 16 KB だが、明示しておく。**既定に頼ると NDK を
# 下げたときに黙って壊れる。** 検査は tools/verify-android-page-size.ps1。
#
# NDK の toolchain を include した「後」に足す —— 前に置くと上書きされる。
#
# **_INIT ではなく、こちらに足す。** レビューで「toolchain file では
# CMAKE_SHARED_LINKER_FLAGS_INIT が正規の入口で、_INIT でない方は project()
# が作る cache entry に負けうる」と指摘され、_INIT に変えて CI に出した。
# **結果は逆だった** —— _INIT では効かず、実物の .so の p_align が
# 16384 から 4096 に落ちた（run 33323002468）。元の形に戻す。
#
# **この失敗が、開いていた問いを同時に閉じた。** それまでは「実測の
# p_align=16384 は NDK r27 の既定かもしれず、flag が効いた証拠にならない」
# という留保が残っていた。_INIT にして 4096 になったということは、
# **16 KB 整列を作っているのはこの flag である**（NDK の既定ではない）。
# あわせて tools/verify-android-page-size.ps1 が**実物の .so で実際に
# 落ちる**ことも確かめられた —— 合成 ELF だけでなく本番の経路で。
string(APPEND CMAKE_SHARED_LINKER_FLAGS " -Wl,-z,max-page-size=16384")
