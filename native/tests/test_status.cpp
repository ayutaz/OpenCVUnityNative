#include <gtest/gtest.h>

#include <set>

#include "opencv_unity_native.h"
#include "ocvu_error.h"

// ネイティブ側の status 表は OCVU_STATUS_LIST から生成される。
// この表と C# の CvUnity.CvStatus の同期は L3 の StatusCodeSyncTests が守る。
// ここでは表を公開する ABI 自体の契約だけを検証する。

TEST(StatusTable, CountMatchesTheDeclaredList) {
    int32_t expected = 0;
#define OCVU_COUNT_ENTRY_(name, value) ++expected;
    OCVU_STATUS_LIST(OCVU_COUNT_ENTRY_)
#undef OCVU_COUNT_ENTRY_
    EXPECT_EQ(ocvu_get_status_count(), expected);
}

TEST(StatusTable, ExposesEveryDeclaredValueInOrder) {
    int32_t index = 0;
#define OCVU_CHECK_ENTRY_(name, value)                                  \
    {                                                                   \
        int32_t observed = -1;                                          \
        EXPECT_EQ(ocvu_get_status_value(index, &observed),              \
                  OCVU_STATUS_OK);                                      \
        EXPECT_EQ(observed, static_cast<int32_t>(value)) << #name;      \
        EXPECT_EQ(observed, static_cast<int32_t>(name)) << #name;       \
        ++index;                                                        \
    }
    OCVU_STATUS_LIST(OCVU_CHECK_ENTRY_)
#undef OCVU_CHECK_ENTRY_
    EXPECT_EQ(index, ocvu_get_status_count());
}

TEST(StatusTable, ValuesAreUnique) {
    std::set<int32_t> seen;
    const int32_t count = ocvu_get_status_count();
    for (int32_t i = 0; i < count; ++i) {
        int32_t value = -1;
        ASSERT_EQ(ocvu_get_status_value(i, &value), OCVU_STATUS_OK);
        EXPECT_TRUE(seen.insert(value).second) << "duplicate status value " << value;
    }
}

TEST(StatusTable, RejectsOutOfRangeIndex) {
    int32_t value = -1;
    EXPECT_EQ(ocvu_get_status_value(-1, &value), OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_get_status_value(ocvu_get_status_count(), &value),
              OCVU_STATUS_INVALID_ARGUMENT);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_INVALID_ARGUMENT);
}

TEST(StatusTable, RejectsNullOutValue) {
    EXPECT_EQ(ocvu_get_status_value(0, nullptr), OCVU_STATUS_NULL_POINTER);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_NULL_POINTER);
}

TEST(StatusTable, SuccessPathClearsPreviousError) {
    ocvu::set_last_error(OCVU_STATUS_UNKNOWN_ERROR, "stale error");
    int32_t value = -1;
    EXPECT_EQ(ocvu_get_status_value(0, &value), OCVU_STATUS_OK);
    EXPECT_EQ(ocvu_get_last_error_status(), OCVU_STATUS_OK);
}
