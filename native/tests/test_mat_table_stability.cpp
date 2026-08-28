#include <gtest/gtest.h>

#include <cstddef>
#include <vector>

#include "ocvu_mat_table.h"
#include "opencv_unity_native.h"

/*
 * table が伸びても、先に解決した Mat のアドレスは動いてはならない。
 *
 * これは行儀の話ではない。mat_table_get が返すポインタは、呼び出し元が
 * OpenCV に渡している間ずっと生きている必要がある。table が Mat を値で
 * 抱えていると、別スレッドの create が 1 回入るだけで全 Mat が引っ越し、
 * 先に解決したポインタは解放済みメモリを指す。
 *
 * そのとき壊れるのは、その別スレッドが触っている handle ではなく、
 * **まったく無関係な handle** である。2 つのスレッドがそれぞれ自分の Mat
 * だけを触るという、契約上まったく正しい使い方で壊れる。
 *
 * CI (run 33149830773, Windows) が実際にこれを踏んだ。xUnit がテストクラスを
 * 並列に走らせ、resize の書き込み先が旧バッファへ、直後の get_info が
 * 引っ越し後の Mat へ向かい、1x1 のまま残った dst を読んだ。
 */
TEST(MatTableStability, ResolvedPointerSurvivesTableGrowth) {
    ocvu_mat_handle first = OCVU_MAT_HANDLE_NONE;
    ASSERT_EQ(ocvu_mat_create(4, 4, OCVU_MAT_TYPE_8UC1, &first), OCVU_STATUS_OK);

    cv::Mat* before = ocvu::mat_table_get(first);
    ASSERT_NE(before, nullptr);

    /*
     * free list を使い切ってから emplace_back が走る。他のテストが解放した
     * 索引を先に消費するので、成長を確実にするには多めに握る必要がある。
     *
     * **「1024 なら足りるだろう」で終わらせない。** 足りなくなったときに
     * 誰も気づけないからである。この test が固定しようとしているのは
     * 「**再配置が起きても** Mat のアドレスが動かないこと」なので、
     * 再配置が起きなければバグが再発していても通ってしまう。
     *
     * 再配置が起きない道は 2 つある。(a) free list に十分な索引が残って
     * いて emplace_back に到達しない、(b) 到達しても容量に余りがあって
     * 既存要素が動かない。**容量**を測れば両方まとめて捕まる。
     */
    const size_t capacity_before = ocvu::mat_table_slot_capacity();

    std::vector<ocvu_mat_handle> held;
    for (int i = 0; i < 1024; ++i) {
        ocvu_mat_handle h = OCVU_MAT_HANDLE_NONE;
        ASSERT_EQ(ocvu_mat_create(1, 1, OCVU_MAT_TYPE_8UC1, &h), OCVU_STATUS_OK);
        held.push_back(h);
    }

    const size_t capacity_after = ocvu::mat_table_slot_capacity();
    ASSERT_GT(capacity_after, capacity_before)
        << "table の内部配列が 1 度も再配置されなかったので、この test は"
           "何も検証していない（容量 " << capacity_before << " のまま）。"
           "確保する数を増やすか、先に走るテストが容量を伸ばし切っていないか"
           "確かめること。";

    cv::Mat* after = ocvu::mat_table_get(first);
    EXPECT_EQ(before, after)
        << "table が伸びたときに Mat のアドレスが動いた。"
           "この間に別スレッドがこのポインタを使っていれば、"
           "解放済みメモリへの書き込みになる。";

    for (ocvu_mat_handle h : held) { ASSERT_EQ(ocvu_mat_release(h), OCVU_STATUS_OK); }
    ASSERT_EQ(ocvu_mat_release(first), OCVU_STATUS_OK);
}
