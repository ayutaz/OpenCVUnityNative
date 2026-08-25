# 「失敗するはずのコマンド」を実行し、実際に失敗したら PASS する。
#
# 必須: OCVU_COMMAND (実行ファイルのパス), OCVU_MODE, OCVU_TIMEOUT
# 任意: OCVU_EXPECT_REGEX (結合した stdout+stderr がこれにマッチすること)

if(NOT DEFINED OCVU_COMMAND OR NOT DEFINED OCVU_MODE OR NOT DEFINED OCVU_TIMEOUT)
    message(FATAL_ERROR "OCVU_COMMAND, OCVU_MODE and OCVU_TIMEOUT are required")
endif()

execute_process(
    COMMAND "${OCVU_COMMAND}" "${OCVU_MODE}"
    TIMEOUT ${OCVU_TIMEOUT}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE stdout_text
    ERROR_VARIABLE stderr_text
)

set(combined "${stdout_text}${stderr_text}")
message(STATUS "probe '${OCVU_MODE}' result: ${result}")
message(STATUS "probe output:\n${combined}")

# 成功終了(0)なら、検出できていないので FAIL。
# タイムアウト時 result は 0 ではない説明文字列になる。
if(result STREQUAL "0")
    message(FATAL_ERROR
        "probe '${OCVU_MODE}' exited successfully, but a failure was expected. "
        "The harness is NOT detecting this class of failure.")
endif()

if(DEFINED OCVU_EXPECT_REGEX AND NOT OCVU_EXPECT_REGEX STREQUAL "")
    if(NOT combined MATCHES "${OCVU_EXPECT_REGEX}")
        message(FATAL_ERROR
            "probe '${OCVU_MODE}' failed as expected, but its output did not match "
            "'${OCVU_EXPECT_REGEX}'.")
    endif()
endif()

message(STATUS "probe '${OCVU_MODE}' failed as expected")
