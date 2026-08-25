#include <gtest/gtest.h>

#include "ocvu_test_platform.h"

int main(int argc, char** argv) {
    ocvu_test::suppress_crash_dialogs();
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
