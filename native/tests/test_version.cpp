#include <gtest/gtest.h>

#include "opencv_unity_native.h"

TEST(AbiVersion, ReturnsCurrentAbiVersion) {
    EXPECT_EQ(ocvu_get_abi_version(), OCVU_ABI_VERSION);
}

TEST(AbiVersion, IsPositive) {
    EXPECT_GT(ocvu_get_abi_version(), 0);
}
