# Web / Wasm（wasm32）の toolchain。
#
# **クロスコンパイルであり、かつ静的ライブラリである** —— iOS と同じ 2 つの
# 性質を同時に持つ。したがって iOS の toolchain と同じ配慮が要る
# （try_run が使えない、依存アーカイブは自分で束ねる）。
#
# **Emscripten の在り処はこちらでは探さない。** `tools/Emscripten.psm1` が
# 解決して `OCVU_EMSCRIPTEN_ROOT` で渡す。理由は 2 つ:
#   - 探索の規則を CMake と PowerShell の 2 箇所に持つと、片方だけ直したときに
#     気づけない（M4 で「plugin 側は塞いだが OpenCV 側が塞がれていなかった」を
#     踏んでいる）
#   - Unity 同梱と emsdk のどちらを使うかは**版の整合の話**であり、
#     tools/emscripten-versions.psd1 と assert-emscripten-version.ps1 が
#     持っている。CMake から二重に判断させない

if(NOT DEFINED OCVU_EMSCRIPTEN_ROOT)
    if(DEFINED ENV{OCVU_EMSCRIPTEN_ROOT})
        set(OCVU_EMSCRIPTEN_ROOT "$ENV{OCVU_EMSCRIPTEN_ROOT}")
    else()
        message(FATAL_ERROR
            "OCVU_EMSCRIPTEN_ROOT が設定されていません。\n"
            "tools/Emscripten.psm1 の Get-EmscriptenToolchain が解決して渡します。\n"
            "手で configure するなら -DOCVU_EMSCRIPTEN_ROOT=<Emscripten の根> を渡してください。")
    endif()
endif()

# **try_compile は toolchain file を入れ子でもう一度実行する。**
# そのとき `-D` で渡した変数は既定では届かない —— この一覧に載せたものだけが
# 引き継がれる。載せ忘れると、上の FATAL_ERROR が **入れ子の側で**発火して
#
#     CMake Error: CMAKE_CXX_COMPILER not set, after EnableLanguage
#     Failed to configure test project build system.
#
# という、原因が 2 段隠れた形で落ちる（2026-09-03 に実測）。
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES OCVU_EMSCRIPTEN_ROOT)

set(_ocvu_em_toolchain
    "${OCVU_EMSCRIPTEN_ROOT}/emscripten/cmake/Modules/Platform/Emscripten.cmake")
if(NOT EXISTS "${_ocvu_em_toolchain}")
    message(FATAL_ERROR
        "Emscripten の CMake toolchain が見つかりません: ${_ocvu_em_toolchain}\n"
        "OCVU_EMSCRIPTEN_ROOT='${OCVU_EMSCRIPTEN_ROOT}' が Emscripten の根を指していません。")
endif()

# **同梱の toolchain を先に include し、こちらの上書きはその後に書く。**
# 逆にすると、Emscripten.cmake が同じ変数を設定し直して**こちらの指定が
# 黙って消える**（M4 の 16 KB page size で踏んだ形 —— flag を効かない場所に
# 置いていて、ビルドは通るのに何にも当たっていなかった）。
include("${_ocvu_em_toolchain}")

# --- ここから下が、このプロジェクト固有の指定である ---

# **クロスコンパイルなので try_run は実行できない。** 既定のままだと CMake が
# 「実行して確かめる」検査で止まる。静的ライブラリだけを作らせる（iOS と同じ）。
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# wasm に共有ライブラリは無い。**明示しないと、共有を作ろうとして
# 分かりにくい形で落ちる。**
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# **SIMD を有効にする。**
#
# 当初は「先に SIMD 無しで成立させ、flag を足すと中身が変わることを見る」
# 手順にしていたが、**OpenCV 側で SIMD 無しはビルドが通らない**ことが
# 分かったので（intrin_wasm.hpp が simd128 を要求する）、
# **SIMD 有りが出荷する構成である**（計画に裁定として記録した）。
#
# **こちら側の object にも要る。** OpenCV のビルドにだけ入れていたので、
# plugin 自身の object は SIMD 無しで作られていた（2026-09-03 に実測:
# 束ねた .a の最初の member の target_features が
# `mutable-globals, sign-ext` だけだった）。
# **リンクは通るので、検査するまで気づかない。**
#
# **include の後に書く。** Emscripten.cmake が同じ変数を設定し直すので、
# 前に書くと黙って消える。
string(APPEND CMAKE_C_FLAGS " -msimd128")
string(APPEND CMAKE_CXX_FLAGS " -msimd128")

# **例外を有効にする。これはこの ABI の中核である。**
#
# Emscripten は**既定で C++ 例外を無効にする。** その状態でビルドすると、
# `throw` は残るが **`catch` が 1 つも組み込まれない** ——
# つまり `OCVU_TRY_BEGIN` / `OCVU_TRY_END` の例外バリアが**存在しない。**
#
# 実測（2026-09-03、束ねた .a を llvm-nm で見た）:
#
#     __cxa_throw            244 件
#     __cxa_begin_catch        0 件
#     __gxx_personality_v0     0 件
#
# 表に出たのは Player の
# `Uncaught exception from main loop: 17622920 / Halting program.`
# で、**例外オブジェクトのポインタが数字で出るだけ**だった。
#
# **CLAUDE.md の不変条件「例外を ABI の外へ伝播させない」は、この flag が
# 無いと Web でだけ黙って成立しない。** ビルドもリンクも通り、
# **実際に OpenCV が投げるまで誰も気づかない。**
#
# `-fexceptions`（JavaScript 側で扱う形）にする。Unity の Player 側も
# Exception Support を有効にしたときこの形なので、揃えておく。
string(APPEND CMAKE_C_FLAGS " -fexceptions")
string(APPEND CMAKE_CXX_FLAGS " -fexceptions")
string(APPEND CMAKE_EXE_LINKER_FLAGS " -fexceptions")
