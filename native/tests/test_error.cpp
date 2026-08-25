#include <gtest/gtest.h>

#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "opencv_unity_native.h"
#include "ocvu_error.h"

namespace {

std::string ReadLastErrorMessage() {
    int32_t required = 0;
    const ocvu_status query = ocvu_get_last_error_message(nullptr, 0, &required);
    EXPECT_EQ(query, OCVU_STATUS_INVALID_ARGUMENT);
    if (required <= 1) {
        return std::string();
    }
    std::vector<char> buffer(static_cast<size_t>(required));
    const ocvu_status copy =
        ocvu_get_last_error_message(buffer.data(), required, &required);
    EXPECT_EQ(copy, OCVU_STATUS_OK);
    return std::string(buffer.data());
}

}  // namespace

TEST(LastError, IsEmptyAfterClear) {
    ocvu::clear_last_error();
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OK);
    EXPECT_EQ(ReadLastErrorMessage(), "");
}

TEST(LastError, StoresStatusAndMessage) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "bad width");
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ReadLastErrorMessage(), "bad width");
}

TEST(LastError, SetLastErrorReturnsTheStatusItStored) {
    EXPECT_EQ(ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, "null"),
              OCVU_STATUS_NULL_POINTER);
}

TEST(LastError, RequiresOutRequiredSize) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "boom");
    // Null check takes priority over buffer validity
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, nullptr),
              OCVU_STATUS_NULL_POINTER);
    // Null check also applies with valid buffer
    char buffer[100] = {0};
    EXPECT_EQ(ocvu_get_last_error_message(buffer, 100, nullptr),
              OCVU_STATUS_NULL_POINTER);
}

TEST(LastError, ReportsRequiredSizeIncludingNulTerminator) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "abcd");
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, &required),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(required, 5);
}

TEST(LastError, RejectsTooSmallBuffer) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "abcd");
    char small[2] = {0};
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_last_error_message(small, 2, &required),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(required, 5);
}

TEST(LastError, IsThreadLocal) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "main thread");

    ocvu_status observed_in_worker = OCVU_STATUS_INVALID_ARGUMENT;
    std::thread worker([&observed_in_worker]() {
        observed_in_worker = ocvu_get_last_error_status();
        ocvu::set_last_error(OCVU_STATUS_OUT_OF_MEMORY, "worker thread");
    });
    worker.join();

    EXPECT_EQ(observed_in_worker, OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ReadLastErrorMessage(), "main thread");
}

// --- 固定長バッファの保証（Fix 4） -----------------------------------------
//
// set_last_error は OCVU_TRY_END の catch(std::bad_alloc) の内側からも
// 呼ばれるため、決してアロケートしてはならない。noexcept はその契約であり、
// 下の static_assert が宣言の変更を機械的に赤にする。

static_assert(noexcept(ocvu::set_last_error(OCVU_STATUS_OK, "x")),
              "set_last_error must not be able to throw: it runs inside the "
              "bad_alloc handler of OCVU_TRY_END.");
static_assert(noexcept(ocvu::clear_last_error()),
              "clear_last_error must not be able to throw.");

TEST(LastError, AcceptsNullMessageAsEmpty) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "not empty");
    ocvu::set_last_error(OCVU_STATUS_NULL_POINTER, nullptr);

    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ReadLastErrorMessage(), "");

    int32_t required = 0;
    ocvu_get_last_error_message(nullptr, 0, &required);
    EXPECT_EQ(required, 1);
}

TEST(LastError, StoresAMessageThatExactlyFillsTheBuffer) {
    const size_t max_bytes = ocvu::kLastErrorMessageCapacity - 1;
    const std::string message(max_bytes, 'a');
    ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, message.c_str());

    int32_t required = 0;
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, &required),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(required, static_cast<int32_t>(ocvu::kLastErrorMessageCapacity));
    EXPECT_EQ(ReadLastErrorMessage(), message);
}

TEST(LastError, TruncatesAMessageOneByteTooLong) {
    const std::string message(ocvu::kLastErrorMessageCapacity, 'a');
    ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, message.c_str());

    const std::string observed = ReadLastErrorMessage();
    EXPECT_EQ(observed.size(), ocvu::kLastErrorMessageCapacity - 1);
    EXPECT_EQ(observed, message.substr(0, ocvu::kLastErrorMessageCapacity - 1));
}

TEST(LastError, TruncatesAVeryLongMessageAndKeepsTheContractExact) {
    const std::string message(ocvu::kLastErrorMessageCapacity * 4, 'z');
    ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, message.c_str());

    // out_required_size は「実際に取得できるバイト数 + NUL」でなければならない。
    int32_t required = 0;
    EXPECT_EQ(ocvu_get_last_error_message(nullptr, 0, &required),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(required, static_cast<int32_t>(ocvu::kLastErrorMessageCapacity));

    // required ちょうどのバッファで成功し、NUL 終端されていること。
    std::vector<char> buffer(static_cast<size_t>(required), '\xCC');
    int32_t reported = 0;
    EXPECT_EQ(ocvu_get_last_error_message(buffer.data(), required, &reported),
              OCVU_STATUS_OK);
    EXPECT_EQ(reported, required);
    EXPECT_EQ(buffer[static_cast<size_t>(required) - 1], '\0');
    EXPECT_EQ(std::strlen(buffer.data()),
              ocvu::kLastErrorMessageCapacity - 1);

    // required より 1 バイト小さいバッファは拒否されること。
    std::vector<char> small(static_cast<size_t>(required) - 1, '\0');
    EXPECT_EQ(ocvu_get_last_error_message(small.data(), required - 1, &reported),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(reported, required);
}

TEST(LastError, TruncationDoesNotSplitAUtf8Sequence) {
    const size_t max_bytes = ocvu::kLastErrorMessageCapacity - 1;
    const std::string kanji = "\xE3\x81\x82";  // U+3042 (3 バイト)

    // 3 バイト文字の 1 バイト目だけが上限内に収まる長さにする。
    const std::string message = std::string(max_bytes - 1, 'a') + kanji;
    ASSERT_GT(message.size(), max_bytes);
    ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, message.c_str());

    const std::string observed = ReadLastErrorMessage();
    EXPECT_EQ(observed, std::string(max_bytes - 1, 'a'));
    EXPECT_EQ(observed.size(), max_bytes - 1);

    // 2 バイト目までが収まる場合も、文字ごと落ちること。
    const std::string message2 = std::string(max_bytes - 2, 'a') + kanji;
    ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, message2.c_str());
    EXPECT_EQ(ReadLastErrorMessage(), std::string(max_bytes - 2, 'a'));
}

TEST(LastError, KeepsAUtf8SequenceThatExactlyFits) {
    const size_t max_bytes = ocvu::kLastErrorMessageCapacity - 1;
    const std::string kanji = "\xE3\x81\x82";
    const std::string message = std::string(max_bytes - 3, 'a') + kanji;
    ASSERT_EQ(message.size(), max_bytes);

    ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, message.c_str());
    EXPECT_EQ(ReadLastErrorMessage(), message);
}
