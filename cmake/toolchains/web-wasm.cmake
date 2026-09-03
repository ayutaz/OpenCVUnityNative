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

# **SIMD はここでは有効にしない。** roadmap の完了条件 3 は
# 「single-thread / SIMD を先に成立させる」だが、**先に SIMD 無しで
# 成立させ、flag を足すと wasm の中身が変わることを実測する**手順にしてある
# （計画の Task 5）。ここで既定で入れると、その負の対照が取れなくなる。
