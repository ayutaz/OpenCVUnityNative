#include <gtest/gtest.h>

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
