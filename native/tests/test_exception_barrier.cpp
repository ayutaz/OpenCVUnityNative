#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "opencv_unity_native.h"
#include "ocvu_error.h"

namespace {

std::string ReadLastErrorMessage() {
    int32_t required = 0;
    ocvu_get_last_error_message(nullptr, 0, &required);
    if (required <= 1) {
        return std::string();
    }
    std::vector<char> buffer(static_cast<size_t>(required));
    ocvu_get_last_error_message(buffer.data(), required, &required);
    return std::string(buffer.data());
}

}  // namespace

TEST(ExceptionBarrier, StdExceptionBecomesUnknownErrorStatus) {
    EXPECT_EQ(ocvu_debug_throw(0), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_NE(ReadLastErrorMessage().find("ocvu_debug_throw"), std::string::npos);
}

TEST(ExceptionBarrier, BadAllocBecomesOutOfMemoryStatus) {
    EXPECT_EQ(ocvu_debug_throw(1), OCVU_STATUS_OUT_OF_MEMORY);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OUT_OF_MEMORY);
}

TEST(ExceptionBarrier, NonStandardExceptionBecomesUnknownErrorStatus) {
    EXPECT_EQ(ocvu_debug_throw(2), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_UNKNOWN_ERROR);
    EXPECT_NE(ReadLastErrorMessage(), "");
}

TEST(ExceptionBarrier, SuccessPathClearsPreviousError) {
    ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT, "stale error");
    EXPECT_EQ(ocvu_debug_throw(3), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OK);
    EXPECT_EQ(ReadLastErrorMessage(), "");
}

TEST(ExceptionBarrier, UnknownKindIsRejectedWithoutThrowing) {
    EXPECT_EQ(ocvu_debug_throw(99), OCVU_STATUS_INVALID_ARGUMENT);
}
