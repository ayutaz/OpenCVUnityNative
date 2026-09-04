// imgproc のうち「形を返す」もの —— 線分・角点・輪郭。
//
// **ocvu_imgproc_ops.cpp と分けてある。** あちらは画像を入れて画像を出すだけだが、
// こちらは座標や点列を境界の外へ出すので、容量の検証と「溢れたら 1 バイトも
// 書かない」契約が 3 本すべてに掛かる。
//
// 3 本とも「容量 + OCVU_STATUS_BUFFER_TOO_SMALL + 実際の個数」という 1 つの形に
// 載せてある（native/src/ocvu_calibration.cpp の ocvu_find_chessboard_corners と
// 同じ作法）。**出力の所有権は最初から最後まで呼ぶ側にある** —— native が確保した
// blob を handle で返す形は採らない（docs/abi-ownership-and-versioning.md §1）。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <cstdint>
#include <vector>

#include "ocvu_error.h"
#include "ocvu_mat_table.h"

/*
 * ABI に出す定数が OpenCV の値と一致していることを、写し間違いではなく
 * コンパイル時に固定する。OpenCV 側が値を変えたらビルドが落ちる。
 */
static_assert(OCVU_RETR_EXTERNAL == cv::RETR_EXTERNAL, "RETR_EXTERNAL drift");
static_assert(OCVU_RETR_LIST == cv::RETR_LIST, "RETR_LIST drift");
static_assert(OCVU_RETR_CCOMP == cv::RETR_CCOMP, "RETR_CCOMP drift");
static_assert(OCVU_RETR_TREE == cv::RETR_TREE, "RETR_TREE drift");
static_assert(OCVU_CHAIN_APPROX_NONE == cv::CHAIN_APPROX_NONE, "CHAIN_APPROX_NONE drift");
static_assert(OCVU_CHAIN_APPROX_SIMPLE == cv::CHAIN_APPROX_SIMPLE, "CHAIN_APPROX_SIMPLE drift");

namespace {

// 線分 1 本は x1, y1, x2, y2 の 4 要素で表す。点 1 つは x, y の 2 要素。
// **どちらの並びも spec の summary が呼ぶ側に約束している。**
constexpr int64_t kLineElements = 4;
constexpr int64_t kPointElements = 2;

bool IsKnownRetrievalMode(int32_t mode) {
    // **OCVU_RETR_FLOODFILL は出していない。** cv::RETR_FLOODFILL は 32 bit の
    // ラベル画像を要求するので、この関数が受ける 8 bit の 2 値画像では使えない。
    return mode >= OCVU_RETR_EXTERNAL && mode <= OCVU_RETR_TREE;
}

bool IsKnownApproximationMethod(int32_t method) {
    // **範囲比較にしない。** cv::ContourApproximationModes は 0 が CHAIN_CODE、
    // 3 と 4 が Teh-Chin 系で、そのどれも出していない。名指しで 2 つだけ通す。
    return method == OCVU_CHAIN_APPROX_NONE || method == OCVU_CHAIN_APPROX_SIMPLE;
}

}  // namespace

extern "C" ocvu_status ocvu_hough_lines_p(ocvu_mat_handle src, double rho, double theta, int32_t threshold, double min_line_length, double max_line_gap, float* out_lines, int32_t capacity, int32_t* out_count) {
    OCVU_TRY_BEGIN
    // **out_count を何より先に見る。** 無いと呼ぶ側は溢れたときの必要量を
    // 受け取れず、確保し直して呼び直す経路が成り立たない。
    if (out_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_hough_lines_p: out_count is NULL");
    }
    // どの経路で返っても、呼ぶ側が読む値が前回の残りにならないようにする。
    // **以降のすべての早期 return はこの行の後ろに来る。**
    *out_count = 0;

    if (rho <= 0.0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: rho must be greater than 0");
    }
    if (theta <= 0.0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: theta must be greater than 0");
    }
    if (threshold < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: threshold must be at least 1");
    }
    if (capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_hough_lines_p: capacity must not be negative");
    }
    // **capacity が 0 なら out_lines は NULL でよい** —— それが「何本あるか」だけを
    // 問い合わせる呼び方である（ocvu_find_chessboard_corners と同じ形）。
    // 「NULL なら常に拒否」と書くと、その問い合わせが呼べなくなる。
    if (capacity > 0 && out_lines == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_hough_lines_p: out_lines is NULL but capacity is positive");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_hough_lines_p: src handle is invalid");
    }

    std::vector<cv::Vec4i> lines;
    try {
        // **写しを渡す。** OpenCV の doc は HoughLinesP の image について
        // 「この関数が書き換えることがある」と明記している（imgproc.hpp）。
        // 同じヘッダの findContours がわざわざ「3.2 以降は書き換えない」と
        // 断っている以上、こちらの記述は書き忘れではなく契約である。
        // **実測で書き換わらなかったことを根拠に省略しない** —— 上流が契約として
        // 残している以上、次の版で変わりうる。
        // **const を付けない。** OpenCV はこれを書き換えうる（それがここで
        // 写しを作っている理由である）ので、書き換えられる物として宣言する。
        cv::Mat work = src_mat->clone();
        cv::HoughLinesP(work, lines, rho, theta, threshold, min_line_length, max_line_gap);
    } catch (const cv::Exception& e) {
        // **cv::Exception を個別に受ける。** OCVU_TRY_END に任せると
        // std::exception として UNKNOWN_ERROR に落ち、原因が読めなくなる。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    const int64_t found = static_cast<int64_t>(lines.size());
    // int32_t で表せない大きさは ABI に載らないので、切り詰めずに断る
    // （4 倍しても桁あふれしないことも、この 1 行が同時に保証する）。
    if (found > INT32_MAX / kLineElements) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_hough_lines_p: the result is too large to describe through this ABI");
    }

    const int64_t needed = found * kLineElements;
    if (needed > static_cast<int64_t>(capacity)) {
        // **ここまで来ても out_lines には 1 バイトも書いていない。**
        // 部分的に書くと、呼ぶ側は途中まで正しい buffer を掴むことになり、
        // 壊れ方が「その場では気づけない」形になる。
        //
        // **入れるのは本数であって要素数ではない。** 呼ぶ側は 4 倍して確保する。
        *out_count = static_cast<int32_t>(found);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_hough_lines_p: capacity (in elements) is smaller than 4 times the line count");
    }

    for (int64_t i = 0; i < found; ++i) {
        const cv::Vec4i& line = lines[static_cast<size_t>(i)];
        const int64_t base = i * kLineElements;
        out_lines[base + 0] = static_cast<float>(line[0]);
        out_lines[base + 1] = static_cast<float>(line[1]);
        out_lines[base + 2] = static_cast<float>(line[2]);
        out_lines[base + 3] = static_cast<float>(line[3]);
    }

    // **1 本も見つからないのは誤りではない。** 線分が写っていなかっただけである。
    *out_count = static_cast<int32_t>(found);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_corner_sub_pix(ocvu_mat_handle src, float* points, int64_t points_length, int32_t point_count, int32_t win_size, int32_t zero_zone, int32_t max_iterations, double epsilon) {
    OCVU_TRY_BEGIN
    // **points は入出力兼用である** —— この ABI で唯一この形をしている。
    // 出力でもあるので、断った場合に 1 バイトも書き換えないことが契約になる。
    if (points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_corner_sub_pix: points is NULL");
    }
    if (point_count < 1 || point_count > OCVU_CORNER_MAX_POINTS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_corner_sub_pix: point_count must be between 1 and OCVU_CORNER_MAX_POINTS");
    }
    // **int64_t で作る。** point_count は上で OCVU_CORNER_MAX_POINTS 以下だと
    // 確かめてあるので桁あふれしないが、形を揃えておく（負の points_length は
    // この比較にそのまま捕まる）。単位はバイトで、この ABI の length は全部そうである。
    const int64_t needed =
        static_cast<int64_t>(point_count) * kPointElements * static_cast<int64_t>(sizeof(float));
    if (points_length < needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_corner_sub_pix: points_length (in bytes) is too small for point_count");
    }
    if (win_size < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_corner_sub_pix: win_size must be at least 1");
    }
    if (max_iterations < 1) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_corner_sub_pix: max_iterations must be at least 1");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_corner_sub_pix: src handle is invalid");
    }

    // **呼ぶ側の buffer を直接 OpenCV へ渡さない。** cv::cornerSubPix は
    // InputOutputArray を受けるので、そのまま渡すと途中で例外になったときに
    // points が書きかけで残る。写してから戻すことで、失敗時に 1 バイトも
    // 変わっていないことを構造で保証する。
    std::vector<cv::Point2f> corners(static_cast<size_t>(point_count));
    for (int32_t i = 0; i < point_count; ++i) {
        const int64_t base = static_cast<int64_t>(i) * kPointElements;
        corners[static_cast<size_t>(i)] = cv::Point2f(points[base], points[base + 1]);
    }

    try {
        cv::cornerSubPix(
            *src_mat, corners, cv::Size(win_size, win_size), cv::Size(zero_zone, zero_zone),
            cv::TermCriteria(cv::TermCriteria::EPS + cv::TermCriteria::MAX_ITER,
                             max_iterations, epsilon));
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // ここから書き戻す。**失敗しうる経路はもう無い。**
    for (int32_t i = 0; i < point_count; ++i) {
        const int64_t base = static_cast<int64_t>(i) * kPointElements;
        points[base] = corners[static_cast<size_t>(i)].x;
        points[base + 1] = corners[static_cast<size_t>(i)].y;
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_find_contours(ocvu_mat_handle src, int32_t mode, int32_t method, float* out_points, int32_t points_capacity, int32_t* out_counts, int32_t counts_capacity, int32_t* out_contour_count, int32_t* out_total_points) {
    OCVU_TRY_BEGIN
    // **2 つの out を何より先に見る。** どちらも溢れたときの必要量を伝える器で、
    // 片方でも欠けると呼ぶ側は確保し直せない。
    // **0 を書くのは、それぞれの NULL 判定の直後である。** 2 つとも見てから
    // まとめて 0 を入れると、片方だけ NULL だったときに**もう片方が前回の値の
    // まま残る** —— 呼ぶ側は同じ変数を使い回すので、その値を信じて確保する
    // 経路ができてしまう。
    if (out_contour_count == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_contours: out_contour_count is NULL");
    }
    *out_contour_count = 0;
    if (out_total_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_find_contours: out_total_points is NULL");
    }
    *out_total_points = 0;
    // **以降のすべての早期 return はこの 2 行の後ろに来る。**

    if (!IsKnownRetrievalMode(mode)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_find_contours: mode is not one of OCVU_RETR_*");
    }
    if (!IsKnownApproximationMethod(method)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_contours: method is not one of OCVU_CHAIN_APPROX_*");
    }
    if (points_capacity < 0 || counts_capacity < 0) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_find_contours: capacities must not be negative");
    }
    // 容量 0 なら NULL でよい —— それが「どれだけ要るか」だけを問い合わせる
    // 呼び方である。ocvu_hough_lines_p と同じ形にしてある。
    if (points_capacity > 0 && out_points == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_find_contours: out_points is NULL but points_capacity is positive");
    }
    if (counts_capacity > 0 && out_counts == nullptr) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NULL_POINTER,
            "ocvu_find_contours: out_counts is NULL but counts_capacity is positive");
    }

    const cv::Mat* src_mat = ::ocvu::mat_table_get(src);
    if (src_mat == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_HANDLE,
                                      "ocvu_find_contours: src handle is invalid");
    }

    std::vector<std::vector<cv::Point>> contours;
    try {
        cv::findContours(*src_mat, contours, mode, method);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **数も和も int64_t で作る。** 輪郭の本数も点の総数も OpenCV 由来なので
    // 上限を仮定しない。
    const int64_t contour_count = static_cast<int64_t>(contours.size());
    int64_t total_points = 0;
    for (const std::vector<cv::Point>& contour : contours) {
        total_points += static_cast<int64_t>(contour.size());
    }

    // int32_t に入らない大きさは ABI で表現できないので、切り詰めずに断る。
    // 点のほうは要素数が 2 倍になるので、その 2 倍まで含めて見る。
    if (contour_count > INT32_MAX || total_points > INT32_MAX / kPointElements) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_find_contours: the result is too large to describe through this ABI");
    }

    if (contour_count > static_cast<int64_t>(counts_capacity) ||
        total_points * kPointElements > static_cast<int64_t>(points_capacity)) {
        // **どちらの配列にも 1 バイトも書いていない。** 片方だけ書くと、
        // 呼ぶ側は「点はあるのに本数が無い」半端な状態を掴む。
        *out_contour_count = static_cast<int32_t>(contour_count);
        *out_total_points = static_cast<int32_t>(total_points);
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_find_contours: points_capacity or counts_capacity is too small");
    }

    int64_t written = 0;
    for (int64_t i = 0; i < contour_count; ++i) {
        const std::vector<cv::Point>& contour = contours[static_cast<size_t>(i)];
        out_counts[i] = static_cast<int32_t>(contour.size());
        for (const cv::Point& p : contour) {
            const int64_t base = written * kPointElements;
            out_points[base] = static_cast<float>(p.x);
            out_points[base + 1] = static_cast<float>(p.y);
            ++written;
        }
    }

    // **1 本も見つからないのは誤りではない。** 白い塊が無かっただけである。
    *out_contour_count = static_cast<int32_t>(contour_count);
    *out_total_points = static_cast<int32_t>(total_points);
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
