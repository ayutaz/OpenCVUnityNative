// geometry module のうち「姿勢」に関わるもの。
//
// **ocvu_geometry.cpp に足していない。** あちらは 2 枚の画像の間の射影変換を
// 推定する 1 本で完結しており、こちらは 3D と 2D の間の姿勢である。用途が違う。
//
// **handle を 1 つも受け取らない 4 本である。** 入力も出力も呼ぶ側の配列で、
// 借用はこの呼び出しの内側で完結する（docs/abi-ownership-and-versioning.md §1）。

#include <opencv_unity_native.h>

#include <opencv2/core.hpp>
#include <opencv2/geometry.hpp>

#include <cmath>
#include <cstdint>
#include <cstdio>

#include "ocvu_error.h"

// 境界に出す method の値は OpenCV のものをそのまま使う。
// 写し間違いをコンパイル時に落とす（ocvu_geometry.cpp と同じ形）。
static_assert(OCVU_SOLVEPNP_ITERATIVE == cv::SOLVEPNP_ITERATIVE,
              "OCVU_SOLVEPNP_ITERATIVE が cv::SOLVEPNP_ITERATIVE と違う");
static_assert(OCVU_SOLVEPNP_EPNP == cv::SOLVEPNP_EPNP,
              "OCVU_SOLVEPNP_EPNP が cv::SOLVEPNP_EPNP と違う");
static_assert(OCVU_SOLVEPNP_P3P == cv::SOLVEPNP_P3P,
              "OCVU_SOLVEPNP_P3P が cv::SOLVEPNP_P3P と違う");
static_assert(OCVU_SOLVEPNP_AP3P == cv::SOLVEPNP_AP3P,
              "OCVU_SOLVEPNP_AP3P が cv::SOLVEPNP_AP3P と違う");
static_assert(OCVU_SOLVEPNP_IPPE == cv::SOLVEPNP_IPPE,
              "OCVU_SOLVEPNP_IPPE が cv::SOLVEPNP_IPPE と違う");
static_assert(OCVU_SOLVEPNP_IPPE_SQUARE == cv::SOLVEPNP_IPPE_SQUARE,
              "OCVU_SOLVEPNP_IPPE_SQUARE が cv::SOLVEPNP_IPPE_SQUARE と違う");
static_assert(OCVU_SOLVEPNP_SQPNP == cv::SOLVEPNP_SQPNP,
              "OCVU_SOLVEPNP_SQPNP が cv::SOLVEPNP_SQPNP と違う");

namespace {

// 1 枚ぶんの姿勢は 4 点から決まる。それ未満は解が無いのではなく問いが成立しない。
constexpr int32_t kMinPointsForPnp = 4;

// 回転ベクトル・並進ベクトルは 3 要素、カメラ行列は 3x3 で固定である。
constexpr int64_t kVec3Bytes = 3 * static_cast<int64_t>(sizeof(double));
constexpr int64_t kMatrix3x3Bytes = 9 * static_cast<int64_t>(sizeof(double));

// **焦点距離が 0 のカメラは、カメラではない。**
//
// 実測（2026-09-05）: 全要素 0 のカメラ行列を cv::solvePnP に渡すと、
// **例外も投げず false も返さず、有限の 0 を答えとして返す** —— つまり
// 「もっともらしいが無意味な姿勢」が OCVU_STATUS_OK で戻る。呼ぶ側は
// status では気づけない。
//
// **これは一般的な特異性の検査ではない。** fx / fy が 0 でないことだけを見る ——
// 定義上そこが 0 なら投影が成立しないので、呼ぶ側が直せる誤りとして断れる。
// fx = 1e-300 のような病的な値までは見ない（そこまで行くと「どこで線を引くか」の
// 判断になり、この境界の仕事ではない）。
bool HasUsableFocalLengths(const double* camera_matrix) {
    return camera_matrix[0] != 0.0 && camera_matrix[4] != 0.0;
}

bool IsKnownSolvePnpMethod(int32_t method) {
    return method >= OCVU_SOLVEPNP_ITERATIVE && method <= OCVU_SOLVEPNP_SQPNP;
}

// OpenCV が受け取る歪み係数の個数。**この一覧は OpenCV の都合であって
// こちらの判断ではない**（native/src/ocvu_calibration.cpp と同じ集合である）。
bool IsAcceptedDistCoeffCount(int64_t count) {
    return count == 4 || count == 5 || count == 8 || count == 12 || count == 14;
}

// 「関数名: 理由」の形でメッセージを組み立てて last-error に入れる。
//
// **エラー経路でアロケートしない。** 組み立て先は固定長のスタック buffer で、
// ::ocvu::set_last_error はそこから bounded copy するだけである
// （あの関数は OCVU_TRY_END の catch(std::bad_alloc) の内側からも呼ばれる）。
ocvu_status FailWith(ocvu_status status, const char* who, const char* reason) {
    char message[256];
    std::snprintf(message, sizeof(message), "%s: %s", who, reason);
    return ::ocvu::set_last_error(status, message);
}

// dist_coeffs の (ポインタ, バイト数) を検証し、cv::Mat の借用ビューを作る。
//
// **長さ 0 が「歪み無し」の正規の指定である。** 長さが 0 でないのに
// ポインタが NULL なら、呼ぶ側は何かを取り違えているので拒否する。
ocvu_status MakeDistCoeffView(const double* dist_coeffs, int64_t dist_coeffs_length,
                              const char* who, cv::Mat* out_view) {
    if (dist_coeffs_length < 0) {
        return FailWith(OCVU_STATUS_INVALID_ARGUMENT, who,
                        "dist_coeffs_length (bytes) is negative");
    }
    if (dist_coeffs_length == 0) {
        *out_view = cv::Mat();
        return OCVU_STATUS_OK;
    }
    if (dist_coeffs == nullptr) {
        return FailWith(OCVU_STATUS_NULL_POINTER, who,
                        "dist_coeffs is NULL but dist_coeffs_length is not 0");
    }
    if (dist_coeffs_length % static_cast<int64_t>(sizeof(double)) != 0) {
        return FailWith(OCVU_STATUS_INVALID_ARGUMENT, who,
                        "dist_coeffs_length (bytes) is not a whole number of doubles");
    }
    const int64_t count = dist_coeffs_length / static_cast<int64_t>(sizeof(double));
    if (!IsAcceptedDistCoeffCount(count)) {
        return FailWith(OCVU_STATUS_INVALID_ARGUMENT, who,
                        "dist_coeffs must hold 4, 5, 8, 12 or 14 doubles");
    }
    *out_view = cv::Mat(1, static_cast<int>(count), CV_64F, const_cast<double*>(dist_coeffs));
    return OCVU_STATUS_OK;
}

// OpenCV の出力を「連続した double 1 行」に直す。
//
// **型を確かめて弾くのではなく変換する。** native/src/ocvu_calibration.cpp の
// :345-351 と :405-408 が既にその作法で、あちらのコメントが述べているとおり
// 「OpenCV は 64F を返すが、契約は自分でも確かめる」。**弾くと、OpenCV が
// 別の depth を返すようになった日に、正しい入力が失敗し始める。**
//
// 要素数が expected_elements と違えば false を返す（そこは変換では直らない）。
bool FlattenToDoubles(const cv::Mat& src, int64_t expected_elements, cv::Mat* out) {
    if (src.empty()) {
        return false;
    }
    cv::Mat converted;
    if (src.depth() == CV_64F) {
        // reshape は連続でないと投げるので、そうでなければ写しを取る。
        converted = src.isContinuous() ? src : src.clone();
    } else {
        // rtype に depth だけを渡すと channel 数は入力のまま保たれる。
        src.convertTo(converted, CV_64F);
    }
    const int64_t elements =
        static_cast<int64_t>(converted.total()) * static_cast<int64_t>(converted.channels());
    if (elements != expected_elements) {
        return false;
    }
    *out = converted.reshape(1, 1);
    return true;
}

// **有限でない結果を「成功」として返さない。** 特異なカメラ行列を渡すと
// OpenCV は投げるとは限らず、inf / NaN を返しうる。そのまま OK で返すと
// 呼ぶ側は「もっともらしい失敗」を掴む —— このリポジトリが繰り返し記録して
// いる「ビルドは通るが動かない」と同じ形である。
bool AllFinite(const double* values, int count) {
    for (int i = 0; i < count; ++i) {
        if (!std::isfinite(values[i])) {
            return false;
        }
    }
    return true;
}

}  // namespace

extern "C" ocvu_status ocvu_solve_pnp(const float* object_points, int64_t object_points_length, const float* image_points, int64_t image_points_length, int32_t point_count, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, int32_t method, double* out_rvec, int32_t rvec_capacity, double* out_tvec, int32_t tvec_capacity) {
    OCVU_TRY_BEGIN
    if (object_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: object_points is NULL");
    }
    if (image_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: image_points is NULL");
    }
    if (camera_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: camera_matrix is NULL");
    }
    if (out_rvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: out_rvec is NULL");
    }
    if (out_tvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_solve_pnp: out_tvec is NULL");
    }
    if (point_count < kMinPointsForPnp || point_count > OCVU_PNP_MAX_POINTS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: point_count must be between 4 and OCVU_PNP_MAX_POINTS");
    }
    // **知らない method は素通しにしない。** OpenCV に落とすと
    // 「原因不明」になるか、黙って既定の挙動になる（ocvu_find_homography と同じ）。
    if (!IsKnownSolvePnpMethod(method)) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_solve_pnp: method is not one of OCVU_SOLVEPNP_*");
    }

    // **積は int64_t に上げてから作る。** point_count は上で縛ってあるので
    // 収まるが、桁あふれを「収まるはずだから安全」で済ませない（M2 で踏んだ）。
    const int64_t object_needed =
        static_cast<int64_t>(point_count) * 3 * static_cast<int64_t>(sizeof(float));
    const int64_t image_needed =
        static_cast<int64_t>(point_count) * 2 * static_cast<int64_t>(sizeof(float));
    if (object_points_length < object_needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: object_points_length (bytes) is too small for point_count");
    }
    if (image_points_length < image_needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: image_points_length (bytes) is too small for point_count");
    }
    if (camera_matrix_length < kMatrix3x3Bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: camera_matrix_length (bytes) is too small for a 3x3 matrix");
    }
    if (!HasUsableFocalLengths(camera_matrix)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_solve_pnp: camera_matrix must have non-zero focal lengths at [0] and [4]");
    }

    cv::Mat dist_view;
    const ocvu_status dist_status =
        MakeDistCoeffView(dist_coeffs, dist_coeffs_length, "ocvu_solve_pnp", &dist_view);
    if (dist_status != OCVU_STATUS_OK) {
        return dist_status;
    }

    // **出力の容量は最後に見る。** 入力が壊れているときに BUFFER_TOO_SMALL を
    // 返すと、呼ぶ側は buffer を大きくして再挑戦し、また同じところで失敗する。
    if (rvec_capacity < 3 || tvec_capacity < 3) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_solve_pnp: rvec_capacity and tvec_capacity (elements) must each be at least 3");
    }

    // 借用はこの呼び出しの内側で完結する。cv::Mat で包むだけで所有はしない。
    const cv::Mat object_view(point_count, 3, CV_32F, const_cast<float*>(object_points));
    const cv::Mat image_view(point_count, 2, CV_32F, const_cast<float*>(image_points));
    const cv::Mat camera_view(3, 3, CV_64F, const_cast<double*>(camera_matrix));

    // **求めてから書く。** 直接 out_rvec / out_tvec へ書かせると、失敗したときに
    // 途中まで書き換わった状態で残りうる。
    cv::Mat rvec;
    cv::Mat tvec;
    bool solved = false;
    try {
        solved = cv::solvePnP(object_view, image_view, camera_view, dist_view,
                              rvec, tvec, false, method);
    } catch (const cv::Exception& e) {
        // **OCVU_TRY_END でも捕まるが、そこでは UNKNOWN_ERROR になる。**
        // OpenCV 由来だと分かる status を返すためにここで先に受ける。
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    cv::Mat rvec_flat;
    cv::Mat tvec_flat;
    if (!solved || !FlattenToDoubles(rvec, 3, &rvec_flat) ||
        !FlattenToDoubles(tvec, 3, &tvec_flat)) {
        // **解が無いのは誤りではない。** 入力の形は正しいので NOT_FOUND で返す
        // （ocvu_find_homography と同じ扱い）。
        return ::ocvu::set_last_error(
            OCVU_STATUS_NOT_FOUND,
            "ocvu_solve_pnp: no pose could be estimated from these correspondences");
    }

    const double* r = rvec_flat.ptr<double>();
    const double* t = tvec_flat.ptr<double>();
    if (!AllFinite(r, 3) || !AllFinite(t, 3)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_NOT_FOUND,
            "ocvu_solve_pnp: the estimated pose is not finite (the camera matrix may be singular)");
    }

    for (int i = 0; i < 3; ++i) {
        out_rvec[i] = r[i];
        out_tvec[i] = t[i];
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_rodrigues_to_matrix(const double* rotation_vector, int64_t rotation_vector_length, double* out_matrix, int32_t matrix_capacity) {
    OCVU_TRY_BEGIN
    if (rotation_vector == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_matrix: rotation_vector is NULL");
    }
    if (out_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_matrix: out_matrix is NULL");
    }
    if (rotation_vector_length < kVec3Bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_rodrigues_to_matrix: rotation_vector_length (bytes) is too small for 3 doubles");
    }
    if (matrix_capacity < 9) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_rodrigues_to_matrix: matrix_capacity (elements) must be at least 9");
    }

    const cv::Mat vector_view(3, 1, CV_64F, const_cast<double*>(rotation_vector));
    cv::Mat matrix;
    try {
        cv::Rodrigues(vector_view, matrix);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **行優先で書き出す約束をしているので、3x3 であることは確かめる。**
    // 型は確かめずに変換する（FlattenToDoubles）。
    if (matrix.rows != 3 || matrix.cols != 3) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_rodrigues_to_matrix: OpenCV returned a matrix that is not 3x3");
    }
    cv::Mat flat;
    if (!FlattenToDoubles(matrix, 9, &flat)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_rodrigues_to_matrix: OpenCV returned a matrix that is not 9 elements");
    }

    const double* m = flat.ptr<double>();
    for (int i = 0; i < 9; ++i) {
        out_matrix[i] = m[i];
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_rodrigues_to_vector(const double* rotation_matrix, int64_t rotation_matrix_length, double* out_vector, int32_t vector_capacity) {
    OCVU_TRY_BEGIN
    if (rotation_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_vector: rotation_matrix is NULL");
    }
    if (out_vector == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_rodrigues_to_vector: out_vector is NULL");
    }
    if (rotation_matrix_length < kMatrix3x3Bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_rodrigues_to_vector: rotation_matrix_length (bytes) is too small for 9 doubles");
    }
    if (vector_capacity < 3) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_rodrigues_to_vector: vector_capacity (elements) must be at least 3");
    }

    const cv::Mat matrix_view(3, 3, CV_64F, const_cast<double*>(rotation_matrix));
    cv::Mat vector;
    try {
        cv::Rodrigues(matrix_view, vector);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    cv::Mat flat;
    if (!FlattenToDoubles(vector, 3, &flat)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_rodrigues_to_vector: OpenCV returned a vector that is not 3 elements");
    }

    const double* v = flat.ptr<double>();
    for (int i = 0; i < 3; ++i) {
        out_vector[i] = v[i];
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}

extern "C" ocvu_status ocvu_project_points(const float* object_points, int64_t object_points_length, int32_t point_count, const double* rvec, int64_t rvec_length, const double* tvec, int64_t tvec_length, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, float* out_image_points, int32_t out_capacity) {
    OCVU_TRY_BEGIN
    if (object_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: object_points is NULL");
    }
    if (rvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: rvec is NULL");
    }
    if (tvec == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: tvec is NULL");
    }
    if (camera_matrix == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: camera_matrix is NULL");
    }
    if (out_image_points == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_project_points: out_image_points is NULL");
    }
    // **姿勢は与えられているので 4 点は要らない。** 1 点でも投影できる。
    if (point_count < 1 || point_count > OCVU_PNP_MAX_POINTS) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: point_count must be between 1 and OCVU_PNP_MAX_POINTS");
    }

    const int64_t object_needed =
        static_cast<int64_t>(point_count) * 3 * static_cast<int64_t>(sizeof(float));
    if (object_points_length < object_needed) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: object_points_length (bytes) is too small for point_count");
    }
    if (rvec_length < kVec3Bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: rvec_length (bytes) is too small for 3 doubles");
    }
    if (tvec_length < kVec3Bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: tvec_length (bytes) is too small for 3 doubles");
    }
    if (camera_matrix_length < kMatrix3x3Bytes) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: camera_matrix_length (bytes) is too small for a 3x3 matrix");
    }
    if (!HasUsableFocalLengths(camera_matrix)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_INVALID_ARGUMENT,
            "ocvu_project_points: camera_matrix must have non-zero focal lengths at [0] and [4]");
    }

    cv::Mat dist_view;
    const ocvu_status dist_status =
        MakeDistCoeffView(dist_coeffs, dist_coeffs_length, "ocvu_project_points", &dist_view);
    if (dist_status != OCVU_STATUS_OK) {
        return dist_status;
    }

    // 出力の必要量は呼ぶ側が知り得る（point_count * 2）ので 2 回呼びにしない。
    const int64_t element_count = static_cast<int64_t>(point_count) * 2;
    if (static_cast<int64_t>(out_capacity) < element_count) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_BUFFER_TOO_SMALL,
            "ocvu_project_points: out_capacity (elements) must be at least point_count * 2");
    }

    const cv::Mat object_view(point_count, 3, CV_32F, const_cast<float*>(object_points));
    const cv::Mat rvec_view(3, 1, CV_64F, const_cast<double*>(rvec));
    const cv::Mat tvec_view(3, 1, CV_64F, const_cast<double*>(tvec));
    const cv::Mat camera_view(3, 3, CV_64F, const_cast<double*>(camera_matrix));

    // **出力は cv::Mat で受ける。** std::vector<cv::Point2f> から作った
    // _OutputArray は型が固定されるので、入力の depth が混ざっている
    // （object_points が 32F、rvec / tvec / camera_matrix が 64F）この呼び出しでは
    // OpenCV 側が別の depth を要求した瞬間に例外になる。cv::Mat なら
    // OpenCV が自分で create するので、その食い違いが起きない。
    //
    // **求めてから書く。** 失敗したときに out_image_points が途中まで
    // 書き換わった状態で残らないようにする。
    cv::Mat projected;
    try {
        cv::projectPoints(object_view, rvec_view, tvec_view, camera_view, dist_view, projected);
    } catch (const cv::Exception& e) {
        return ::ocvu::set_last_error(OCVU_STATUS_OPENCV_ERROR, e.what());
    }

    // **型を確かめて弾くのではなく変換する。** OpenCV は objectPoints の depth に
    // 合わせて 32F の 2 channel を返すが、そこに寄りかからない。
    cv::Mat flat;
    if (!FlattenToDoubles(projected, element_count, &flat)) {
        return ::ocvu::set_last_error(
            OCVU_STATUS_OPENCV_ERROR,
            "ocvu_project_points: OpenCV returned a different number of projected points");
    }

    const double* p = flat.ptr<double>();
    for (int64_t i = 0; i < element_count; ++i) {
        out_image_points[i] = static_cast<float>(p[i]);
    }
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
