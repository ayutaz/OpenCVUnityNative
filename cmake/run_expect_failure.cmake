# 「失敗するはずのコマンド」を実行し、実際に失敗したら PASS する。
#
# 必須: OCVU_COMMAND (実行ファイルのパス), OCVU_MODE, OCVU_TIMEOUT,
#       OCVU_EXPECT_REGEX (結合した stdout+stderr がこれにマッチすること)
#
# OCVU_EXPECT_REGEX は必須で、空文字列も許さない。
# 「非 0 で終わったこと」だけを条件にすると、プローブが目的のコードパスに
# 到達しないまま落ちても（未知のモードで usage error、実行ファイルが見つからない、
# 起動直後にクラッシュ、など）テストが緑のままになる。それではこのテストが
# 証明するはずの性質が黙って消える。マーカー文字列で到達を裏取りする。

if(NOT DEFINED OCVU_COMMAND OR NOT DEFINED OCVU_MODE OR NOT DEFINED OCVU_TIMEOUT)
    message(FATAL_ERROR "OCVU_COMMAND, OCVU_MODE and OCVU_TIMEOUT are required")
endif()

if(NOT DEFINED OCVU_EXPECT_REGEX OR OCVU_EXPECT_REGEX STREQUAL "")
    message(FATAL_ERROR
        "OCVU_EXPECT_REGEX is required and must not be empty. Without it this "
        "test would pass on any non-zero exit, including one where the probe "
        "never reached the behaviour under test.")
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

# 終了コード 2 はプローブの usage error（ocvu_probe.cpp を参照）。
# ハーネスが何かを検出したのではなく、呼び出し方を間違えた合図なので
# 「期待された失敗」ではなくテスト失敗として扱う。
if(result STREQUAL "2")
    message(FATAL_ERROR
        "probe '${OCVU_MODE}' exited with the usage-error code 2. The probe was "
        "invoked incorrectly (unknown mode or missing argument); it did not "
        "exercise the failure this test asserts.")
endif()

if(NOT combined MATCHES "${OCVU_EXPECT_REGEX}")
    message(FATAL_ERROR
        "probe '${OCVU_MODE}' failed as expected, but its output did not match "
        "'${OCVU_EXPECT_REGEX}'. The probe did not reach the behaviour under test.")
endif()

message(STATUS "probe '${OCVU_MODE}' failed as expected")
