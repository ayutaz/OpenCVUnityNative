// **2 つ目の handle 表が、1 つ目と同じ欠陥を持たないことを決定的に固定する。**
//
// M3 の PR #8 で mat_table が踏んだ形: Slot が値でオブジェクトを持ち、
// get が配列内部のポインタを返すと、別スレッドの add で配列が伸びたときに
// **先に解決したポインタが全部ぶら下がる。**
//
// **ローカル 3 回と直前 3 回の CI が緑で、1 度だけ落ちた。**
// フレークとして再実行していたら残っていた。だからここでは
// **確率に頼らず、伸びを強制してから古いポインタを触る。**
#include <gtest/gtest.h>
#include <memory>
#include <thread>
#include <vector>

#include "ocvu_dnn_table.h"

TEST(DnnTableStability, APointerStaysValidWhileTheTableGrows) {
    // 1 つ確保して、そのポインタを先に解決しておく。
    auto first = ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    cv::dnn::Net* resolved = ocvu::net_table_get(first);
    ASSERT_NE(resolved, nullptr);

    // 表を大きく伸ばす。**vector<Slot> が値を持っていれば、ここで再配置が起きる。**
    std::vector<ocvu_net_handle> others;
    for (int i = 0; i < 4096; ++i) {
        others.push_back(ocvu::net_table_add(std::make_unique<cv::dnn::Net>()));
    }

    // **先に解決したポインタがまだ生きていること。**
    EXPECT_EQ(ocvu::net_table_get(first), resolved);
    EXPECT_TRUE(resolved->empty());   // 触って落ちないこと

    for (auto h : others) { ocvu::net_table_remove(h); }
    EXPECT_TRUE(ocvu::net_table_remove(first));
}

TEST(DnnTableStability, ConcurrentAddAndGetDoNotCorruptEachOther) {
    auto mine = ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    cv::dnn::Net* resolved = ocvu::net_table_get(mine);
    ASSERT_NE(resolved, nullptr);

    std::thread grower([] {
        std::vector<ocvu_net_handle> hs;
        for (int i = 0; i < 2048; ++i) {
            hs.push_back(ocvu::net_table_add(std::make_unique<cv::dnn::Net>()));
        }
        for (auto h : hs) { ocvu::net_table_remove(h); }
    });

    // **自分の handle だけを触る。これが「正しい使い方」である。**
    for (int i = 0; i < 2048; ++i) {
        cv::dnn::Net* again = ocvu::net_table_get(mine);
        ASSERT_EQ(again, resolved);
        ASSERT_TRUE(again->empty());
    }
    grower.join();
    EXPECT_TRUE(ocvu::net_table_remove(mine));
}

TEST(DnnTableStability, AReleasedHandleResolvesToNull) {
    auto h = ocvu::net_table_add(std::make_unique<cv::dnn::Net>());
    EXPECT_NE(ocvu::net_table_get(h), nullptr);
    EXPECT_TRUE(ocvu::net_table_remove(h));
    EXPECT_EQ(ocvu::net_table_get(h), nullptr);

    // **二重解放は落とさず false を返す。**
    EXPECT_FALSE(ocvu::net_table_remove(h));
}

TEST(DnnTableStability, AnUnknownHandleResolvesToNull) {
    EXPECT_EQ(ocvu::net_table_get(0), nullptr);
    EXPECT_EQ(ocvu::net_table_get(0xDEADBEEF), nullptr);
}
