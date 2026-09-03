# emar に MRI script を食わせて、複数のアーカイブを 1 つに束ねる driver。
#
# **なぜ driver が要るか**: `llvm-ar -M` は MRI script を **stdin から**読む。
# `add_custom_command` は shell を通さないので `< script` のリダイレクトが
# 書けない（VERBATIM を付けると `<` はただの引数になる）。
# `execute_process` の INPUT_FILE なら shell 無しで stdin を渡せる。
#
# 同じ理由で存在する先例: cmake/run_expect_failure.cmake
#
# 呼び出し（すべて -D で渡す）:
#   OCVU_EMAR_CMD — 実際に起こすコマンド。**木によって形が違う**:
#                    emsdk は emar の実行ファイル（同梱の python が無い）、
#                    Unity 同梱は python（emar.py を渡す）
#   OCVU_EMAR_PY  — python 経路のときだけ在る（判定に使う）
#   OCVU_EMAR     — emar.py のパス（python 経路のときだけ使う）
#   OCVU_MRI      — MRI script
#   OCVU_OUTPUT   — 出来るはずのアーカイブ（**作られたことを確かめるため**）

foreach(_var OCVU_EMAR_CMD OCVU_MRI OCVU_OUTPUT)
    if(NOT DEFINED ${_var})
        message(FATAL_ERROR "bundle_wasm_archive.cmake: -D${_var} が渡されていません。")
    endif()
endforeach()

if(NOT EXISTS "${OCVU_MRI}")
    message(FATAL_ERROR "MRI script が見つかりません: ${OCVU_MRI}")
endif()

# **python 経由が要るのは、emar の実行ファイルが無い木だけ。**
# emsdk には同梱の python が無いので、そちらでは emar を直接呼ぶ。
if(OCVU_EMAR_PY AND EXISTS "${OCVU_EMAR_PY}")
    set(_cmd "${OCVU_EMAR_CMD}" "${OCVU_EMAR}" -M)
else()
    set(_cmd "${OCVU_EMAR_CMD}" -M)
endif()
message(STATUS "bundling with: ${_cmd}")

execute_process(
    COMMAND ${_cmd}
    INPUT_FILE "${OCVU_MRI}"
    RESULT_VARIABLE _rc
    OUTPUT_VARIABLE _out
    ERROR_VARIABLE _err
)

if(NOT _rc EQUAL 0)
    message(FATAL_ERROR
        "emar -M が失敗しました (exit ${_rc})\n"
        "stdout: ${_out}\n"
        "stderr: ${_err}\n"
        "MRI: ${OCVU_MRI}")
endif()

# **終了コードだけを見ない。** emar が 0 を返しても、MRI の綴り違いなどで
# 何も作られないことがある。**出来た物の存在まで見る。**
if(NOT EXISTS "${OCVU_OUTPUT}")
    message(FATAL_ERROR
        "emar は成功を返しましたが、アーカイブが作られていません: ${OCVU_OUTPUT}\n"
        "stdout: ${_out}\n"
        "stderr: ${_err}")
endif()
