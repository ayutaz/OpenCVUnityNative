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
#   OCVU_PYTHON  — emar.py を動かす python（同梱のものでよい）
#   OCVU_EMAR    — emar.py のパス
#   OCVU_MRI     — MRI script
#   OCVU_OUTPUT  — 出来るはずのアーカイブ（**作られたことを確かめるため**）

foreach(_var OCVU_PYTHON OCVU_EMAR OCVU_MRI OCVU_OUTPUT)
    if(NOT DEFINED ${_var})
        message(FATAL_ERROR "bundle_wasm_archive.cmake: -D${_var} が渡されていません。")
    endif()
endforeach()

if(NOT EXISTS "${OCVU_MRI}")
    message(FATAL_ERROR "MRI script が見つかりません: ${OCVU_MRI}")
endif()

execute_process(
    COMMAND "${OCVU_PYTHON}" "${OCVU_EMAR}" -M
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
